import AppKit
import AppletKit
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import Theme
import XCTest

@testable import ReplApplet
@testable import ScriptHost
@testable import TerminalSurface

/// Records the sessions the applet reports, as a window does, so the script host knows the root a
/// helper must descend from. Everything else the applet asks of a window is answered with nothing.
@MainActor
private final class SessionRecordingHost: AppletHost {
  let scriptHost: ScriptHost
  private(set) var posts: [String] = []

  init(_ scriptHost: ScriptHost) {
    self.scriptHost = scriptHost
  }

  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String
  ) -> StatusRecordID? {
    posts.append(text)

    return nil
  }

  func appletDidExit(_ applet: any Applet) {}
  func appletDidChange(_ applet: any Applet) {}
  func appletTabsDidChange(_ applet: any Applet) {}
  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool { false }
  func issueCloseStamp() -> UInt64 { 0 }

  func applet(
    _ applet: any Applet, sessionStarted tab: AppletTabID, pid: pid_t, started: Int,
    generation: UInt64
  ) {
    scriptHost.recordSessionRoot(
      ProcessIdentity(pid: pid, started: started), sessionGeneration: generation, window: 1,
      pane: NodeID(rawValue: 1))
  }

  func applet(_ applet: any Applet, sessionEnded tab: AppletTabID, pid: pid_t, started: Int) {}
}

/// The REPL's real process tree, started the way the app starts it: the real terminal engine runs
/// the real helper through the applet's own launch, with the terminal's wrapper around it.
///
/// This proves what the group stop must reach. The session's child leads the process group, and the
/// helper is its child and a member, not a leader. The package's other REPL tests start a helper
/// by hand, so only this one can catch a group guard that a wrapper-led tree fails.
@MainActor
final class ReplProcessTreeTests: XCTestCase {
  private var directory: URL!
  private var host: ScriptHost!
  private var engine: GhosttyTerminalEngine!
  private var pasteboard: NSPasteboard!
  private var window: NSWindow!

  /// What the engine changes in the process environment. `GhosttyTerminalEngine` sets
  /// `GHOSTTY_RESOURCES_DIR` for its children. The other production site, `InheritedEnvironment`'s
  /// scrub, runs only when the app starts or in the one terminal test that calls it, never here. The
  /// terminal tests that run later in this process must see the variable as it was.
  private var savedResourcesDirectory: String?

  override func setUp() async throws {
    continueAfterFailure = false
    savedResourcesDirectory = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
    _ = NSApplication.shared

    directory = try Self.makeSocketDirectory()
    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { _ in .noWindow })
    host.start()

    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources = root.appending(path: "Frameworks/GhosttyResources/ghostty")
    let helpers = root.deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Support/ghostty-bin", directoryHint: .isDirectory)

    pasteboard = NSPasteboard.withUniqueName()
    engine = try GhosttyTerminalEngine(
      configStore: TerminalConfigStore(directory: directory.appending(path: "config")),
      resourcesDirectory: resources, helperDirectory: helpers, palette: .latte,
      pasteboard: pasteboard)

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
  }

  override func tearDown() async throws {
    window.close()
    engine = nil
    pasteboard.releaseGlobally()

    if let savedResourcesDirectory {
      setenv("GHOSTTY_RESOURCES_DIR", savedResourcesDirectory, 1)
    } else {
      unsetenv("GHOSTTY_RESOURCES_DIR")
    }

    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  /// The unsandboxed helper that SwiftPM builds beside the test bundle.
  private static func helper() -> URL {
    let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
    let products = bundle?.bundleURL.deletingLastPathComponent()

    return (products ?? URL(fileURLWithPath: ".")).appendingPathComponent("ScriptHelper")
  }

  /// A short private folder for a socket, since a socket path holds 104 bytes.
  private static func makeSocketDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    return directory
  }

  private func waitUntil(_ what: String, timeout: Duration = .seconds(40), _ condition: () -> Bool)
    async throws
  {
    let deadline = ContinuousClock.now + timeout

    while !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("timed out waiting for \(what)")

        throw CancellationError()
      }

      try await Task.sleep(for: .milliseconds(25))
    }
  }

  /// Catches a group guard that only a hand-made group passes. The helper must be a child of the
  /// session's child and a member of its group. Ctrl-Z in the pane then stops the group, the
  /// helper reads as stopped, and a second Ctrl-Z continues it.
  func testTheRealHelperIsAMemberOfTheSessionChildsGroupAndSuspendsWithIt() async throws {
    let recording = SessionRecordingHost(host)
    let services = ReplServices(
      helper: { ReplProcessTreeTests.helper() },
      openChannel: { [host] history in host!.admitRepl(history: history) })
    let applet = ReplApplet(
      engine: engine, services: services, history: ReplHistory(), home: NSHomeDirectory())

    applet.host = recording
    window.contentView = applet.view
    applet.start(origin: .user)

    addTeardownBlock { @MainActor in applet.close() }

    try await waitUntil("the helper to attach") { applet.controllerSuspension != nil }

    let channel = try XCTUnwrap(host.boundRepls.values.first)
    let root = try XCTUnwrap(channel.sessionRoot)
    let helper = try XCTUnwrap(channel.helper)

    XCTAssertNotEqual(
      root.pid, helper.pid, "the session child and the helper are one process, so no wrapper stands"
    )
    XCTAssertEqual(ProcessInspection.parent(of: helper.pid)?.pid, root.pid)
    XCTAssertEqual(ProcessInspection.processGroup(of: root.pid), root.pid)
    XCTAssertEqual(
      ProcessInspection.processGroup(of: helper.pid), root.pid,
      "the helper is in another group than the session child's")
    XCTAssertNotEqual(root.pid, getpgrp())
    XCTAssertFalse(
      ProcessInspection.leadsItsOwnGroup(helper.pid), "the helper leads a group of its own")

    applet.suspendKeyPressed(isRepeat: false)

    try await waitUntil("the helper to read as suspended") {
      channel.suspension.isSuspendedByUniterm
    }

    XCTAssertEqual(ProcessInspection.isStopped(pid: helper.pid), true)
    XCTAssertEqual(recording.posts, [], "a suspend that worked told the user it failed")

    applet.suspendKeyPressed(isRepeat: false)

    try await waitUntil("the helper to read as running") { !channel.suspension.isSuspended }

    XCTAssertEqual(ProcessInspection.isStopped(pid: helper.pid), false)
  }
}
