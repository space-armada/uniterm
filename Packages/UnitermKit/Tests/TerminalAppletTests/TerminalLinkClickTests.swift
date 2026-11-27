import AppKit
import AppletKit
import AppletTestSupport
import StatusKit
import XCTest

@testable import TerminalApplet
@testable import TerminalSurface

/// A watcher that records how it was made and ended, so a test drives the remote signal by hand.
private final class FakeWatcher: RemoteClientWatching, @unchecked Sendable {
  let root: pid_t
  let found: @Sendable (String) -> Void
  private let lock = NSLock()
  private var ended = false

  init(root: pid_t, found: @escaping @Sendable (String) -> Void) {
    self.root = root
    self.found = found
  }

  var stopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return ended
  }

  func stop() {
    lock.lock()
    ended = true
    lock.unlock()
  }
}

/// A check that waits until the test lets it go, in place of an open that never returns.
@MainActor
private final class CheckGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var started = 0

  var isHolding: Bool { continuation != nil }

  func hold() async {
    started += 1

    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

/// What the applet does with a hover and a click on text in the terminal, through the session
/// protocol and the host. The file system is real, since the check of the opened path is part of
/// the contract.
@MainActor
final class TerminalLinkClickTests: XCTestCase {
  private var retained: [TerminalApplet] = []
  private var root: URL!
  private var watchers: [FakeWatcher] = []

  override func setUp() async throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appending(path: "uniterm-clicks-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func makeApplet() -> (TerminalApplet, FakeEngine, RecordingHost, FakeSession) {
    let engine = FakeEngine()
    let host = RecordingHost()
    let applet = TerminalApplet(engine: engine, directoryExists: { _ in true })
    applet.host = host
    applet.makeRemoteWatcher = { [unowned self] root, found in
      let watcher = FakeWatcher(root: root, found: found)
      self.watchers.append(watcher)
      return watcher
    }
    applet.start(origin: .user)
    retained.append(applet)
    return (applet, engine, host, engine.sessions[0])
  }

  private func makeFile(_ name: String) throws -> String {
    let url = root.appending(path: name)
    try "x".write(to: url, atomically: false, encoding: .utf8)
    return url.path
  }

  private func previewText(of applet: TerminalApplet) -> String? {
    guard let label = find(TerminalLinkPreview.labelIdentifier, in: applet.view),
      let preview = label.superview, !preview.isHidden
    else { return nil }

    return (label as? NSTextField)?.stringValue
  }

  private func find(_ identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier { return view }

    for child in view.subviews {
      if let found = find(identifier, in: child) { return found }
    }

    return nil
  }

  private func hover(_ session: FakeSession, _ text: String?) {
    session.onEvent?(.linkHovered(text))
  }

  /// Hovers, then clicks, and waits for the check and the open.
  private func click(
    _ text: String, hovering shown: String? = nil, in applet: TerminalApplet,
    _ session: FakeSession
  ) async {
    hover(session, shown ?? text)
    session.onEvent?(.linkOpenRequested(text))
    await applet.linkClick?.value
  }

  // MARK: Hover

  /// Catches a preview that shows a link's text, or nothing at all, in place of the target. An
  /// absolute path and a local file link show the path they open.
  func testHoverShowsTheTargetAsTheAbsolutePath() {
    let (applet, _, _, session) = makeApplet()

    hover(session, "/Users/me/a.txt")
    XCTAssertEqual(previewText(of: applet), "/Users/me/a.txt")

    hover(session, "file:///Users/me/My%20Notes.txt")
    XCTAssertEqual(previewText(of: applet), "/Users/me/My Notes.txt")

    hover(session, nil)
    XCTAssertNil(previewText(of: applet))
  }

  /// Catches a preview that cuts a path that fits in the pane. The user judges a click by reading
  /// the whole path, so the text may be cut only when the pane is too narrow for it.
  func testAPathThatFitsThePaneIsShownWhole() throws {
    let (applet, _, _, session) = makeApplet()
    let path = "/Users/me/" + String(repeating: "folder/", count: 12) + "file.txt"

    applet.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 400)
    hover(session, "/Users/me/a.txt")
    hover(session, path)

    let label = try XCTUnwrap(
      find(TerminalLinkPreview.labelIdentifier, in: applet.view) as? NSTextField)

    XCTAssertEqual(label.stringValue, path)
    let needed = try XCTUnwrap(
      label.cell?.cellSize(
        forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100)))

    XCTAssertGreaterThanOrEqual(
      label.frame.width, needed.width,
      "the label is narrower than its cell needs, so the path was cut")
    XCTAssertLessThanOrEqual(label.superview?.frame.width ?? .infinity, 1200 - 16)

    applet.view.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
    hover(session, nil)
    hover(session, path)

    XCTAssertLessThanOrEqual(label.superview?.frame.width ?? .infinity, 200 - 16)
  }

  /// Catches a preview for a link that no click would open. A relative path, a web address, and a
  /// file link to another host show no target, since showing it would promise an open.
  func testHoverOverALinkThatNeverOpensShowsNothing() {
    let (applet, _, _, session) = makeApplet()

    for text in ["notes.txt", "~/notes.txt", "https://example.com/a", "file://other.example/a"] {
      hover(session, text)
      XCTAssertNil(previewText(of: applet), text)
    }
  }

  /// Catches a hover that touches a file. The path does not exist, and the preview still shows
  /// it, with no error and no message.
  func testHoverTouchesNoFileAndPostsNothing() {
    let (applet, _, host, session) = makeApplet()

    hover(session, root.path + "/does-not-exist.txt")

    XCTAssertEqual(previewText(of: applet), root.path + "/does-not-exist.txt")
    XCTAssertTrue(host.posts.isEmpty)
  }

  /// Catches a preview that stays up after the tab it was hovered in is no longer shown, and one
  /// that comes back with the tab. The pointer may have left the link while the tab was hidden,
  /// so the old hover must not show again, and must not bind a click.
  func testThePreviewFollowsTheSelectedTabAndAHiddenTabsHoverIsForgotten() async throws {
    let (applet, engine, host, first) = makeApplet()
    let file = try makeFile("a.txt")

    hover(first, file)
    XCTAssertEqual(previewText(of: applet), file)

    applet.openTab()
    XCTAssertEqual(engine.sessions.count, 2)
    XCTAssertNil(previewText(of: applet))

    applet.selectTab(at: 0)
    XCTAssertNil(previewText(of: applet), "a hidden tab's old hover showed again")

    first.onEvent?(.linkOpenRequested(file))
    await applet.linkClick?.value

    XCTAssertTrue(host.openedFiles.isEmpty, "an old hover bound a click")
    XCTAssertEqual(host.posts.map(\.text), [TerminalLinkRefusal.changed.message])

    hover(first, file)
    XCTAssertEqual(previewText(of: applet), file)
  }

  // MARK: Click

  /// Catches a click that does not open the shown file, or opens a different path.
  func testAClickOpensExactlyTheShownFile() async throws {
    let (applet, _, host, session) = makeApplet()
    let file = try makeFile("a.txt")

    await click(file, in: applet, session)

    XCTAssertEqual(host.openedFiles, [URL(fileURLWithPath: file)])
    XCTAssertTrue(host.posts.isEmpty)
  }

  /// Catches a file link that opens only its own spelling. A link and its decoded path are the
  /// same file, and the file link opens the decoded path.
  func testAFileLinkOpensItsDecodedPath() async throws {
    let (applet, _, host, session) = makeApplet()
    let file = try makeFile("My Notes.txt")
    let link = URL(fileURLWithPath: file).absoluteString

    XCTAssertTrue(link.contains("%20"))

    await click(link, in: applet, session)

    XCTAssertEqual(host.openedFiles, [URL(fileURLWithPath: file)])
  }

  /// Catches a folder that needs no matching open, or one that does not open.
  func testAFolderOpensToo() async throws {
    let (applet, _, host, session) = makeApplet()

    await click(root.path, in: applet, session)

    XCTAssertEqual(host.openedFiles.map(\.path), [root.path])
  }

  /// Catches the hover-and-switch attack. A program that redraws the line between the hover and
  /// the click makes the clicked text another file than the one the user was shown.
  func testAClickOnTextOtherThanTheLastHoverOpensNothing() async throws {
    let (applet, _, host, session) = makeApplet()
    let shown = try makeFile("shown.txt")
    let other = try makeFile("other.txt")

    await click(other, hovering: shown, in: applet, session)

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertEqual(host.posts.map(\.text), [TerminalLinkRefusal.changed.message])
  }

  /// Catches a click that opens with no hover before it, and one after the pointer left.
  func testAClickWithNoHoverOpensNothing() async throws {
    let (applet, _, host, session) = makeApplet()
    let file = try makeFile("a.txt")

    session.onEvent?(.linkOpenRequested(file))
    XCTAssertNil(applet.linkClick)

    hover(session, file)
    hover(session, nil)
    session.onEvent?(.linkOpenRequested(file))
    await applet.linkClick?.value

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertEqual(host.posts.count, 2)
  }

  /// Catches a relative path, a home path, and a file link to another host that open, or that
  /// fail without saying why.
  func testRelativeAndOtherHostLinksSayWhyAndOpenNothing() async throws {
    let (applet, _, host, session) = makeApplet()

    _ = try makeFile("a.txt")
    await click("a.txt", in: applet, session)
    await click("~/a.txt", in: applet, session)
    await click("file://server.example/etc/hosts", in: applet, session)

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertEqual(
      host.posts.map(\.text),
      [
        TerminalLinkRefusal.relative.message, TerminalLinkRefusal.relative.message,
        TerminalLinkRefusal.otherHost.message,
      ])
  }

  /// Catches a click on a web address that does anything, even a message.
  func testAWebAddressDoesNothing() async {
    let (applet, _, host, session) = makeApplet()

    await click("https://example.com/a", in: applet, session)

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertTrue(host.posts.isEmpty)
    XCTAssertNil(applet.linkClick)
  }

  /// Catches a printed symlink that opens the file it leads to.
  func testAPrintedSymlinkOpensNothingAndSaysSo() async throws {
    let (applet, _, host, session) = makeApplet()
    let target = try makeFile("secret.txt")
    let link = root.appending(path: "readme.txt").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

    await click(link, in: applet, session)

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertEqual(host.posts.map(\.text), [TerminalLinkRefusal.differs.message])
  }

  /// Catches a click on a path that is gone, which must say so and open nothing.
  func testAMissingPathSaysSo() async {
    let (applet, _, host, session) = makeApplet()

    await click(root.path + "/missing.txt", in: applet, session)

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertEqual(host.posts.map(\.text), [TerminalLinkRefusal.unavailable.message])
  }

  // MARK: Remote output

  /// Catches an OSC 7 from another host that leaves clicks on. The preview shows the notice in
  /// place of the target, and the click opens nothing and says why.
  func testAReportFromAnotherHostTurnsOffClicksAndShowsTheNotice() async throws {
    let (applet, _, host, session) = makeApplet()
    let file = try makeFile("a.txt")

    session.onEvent?(.remoteHostReported("server.example"))
    XCTAssertEqual(applet.remoteSource(ofTabAt: 0), .host("server.example"))

    hover(session, file)
    XCTAssertEqual(previewText(of: applet), TerminalApplet.remoteNotice)

    session.onEvent?(.linkOpenRequested(file))
    await applet.linkClick?.value

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertEqual(host.posts.map(\.text), [TerminalLinkRefusal.remoteOutput.message])
  }

  /// Catches a marker that clears. The client exits and the output it wrote stays on screen, so
  /// a click still opens nothing. Nothing in the applet clears the marker.
  func testARemoteClientMarksTheTabForItsLife() async throws {
    let (applet, _, host, session) = makeApplet()
    let file = try makeFile("a.txt")

    session.onEvent?(
      .processStarted(TerminalProcessIdentity(pid: getpid(), started: 1, sessionGeneration: 1)))

    let watcher = try XCTUnwrap(watchers.first)
    XCTAssertEqual(watcher.root, getpid())

    watcher.found("ssh")
    await Task.yield()
    await Task.yield()

    XCTAssertEqual(applet.remoteSource(ofTabAt: 0), .client("ssh"))
    XCTAssertTrue(watcher.stopped, "the watcher kept running after it found a client")

    session.onEvent?(.commandFinished(exitCode: 0, duration: .zero))
    session.onEvent?(.workingDirectoryChanged(root.path))
    await click(file, in: applet, session)

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertEqual(host.posts.map(\.text), [TerminalLinkRefusal.remoteOutput.message])
  }

  /// Catches a marker that lands while a click is being checked. The click began local, and the
  /// remote report arrives before the open. The open must not happen.
  func testAMarkerSetWhileAClickIsBeingCheckedStopsTheOpen() async throws {
    let (applet, _, host, session) = makeApplet()
    let file = try makeFile("a.txt")

    hover(session, file)
    session.onEvent?(.linkOpenRequested(file))
    session.onEvent?(.remoteHostReported("server.example"))
    await applet.linkClick?.value

    XCTAssertTrue(host.openedFiles.isEmpty)
    XCTAssertEqual(host.posts.map(\.text), [TerminalLinkRefusal.remoteOutput.message])
  }

  /// Catches a click loop that parks a thread per click. The check of the first click never
  /// returns, as an open on a dead network mount does not. A second click in the tab is refused at
  /// once and says why, and the tab clicks again once the check returns. It cannot prove the
  /// system's thread count, only that a tab has one check at a time.
  func testAClickWhileAnEarlierOneIsBeingCheckedIsRefused() async throws {
    let (applet, _, host, session) = makeApplet()
    let file = try makeFile("a.txt")
    let gate = CheckGate()

    applet.verifyLink = { _ in
      await gate.hold()

      return nil
    }

    hover(session, file)
    session.onEvent?(.linkOpenRequested(file))

    let first = try XCTUnwrap(applet.linkClick)

    while !gate.isHolding { await Task.yield() }

    session.onEvent?(.linkOpenRequested(file))

    XCTAssertEqual(gate.started, 1, "a second check began beside the first")
    XCTAssertEqual(host.posts.map(\.text), [TerminalLinkRefusal.stillChecking.message])

    gate.release()
    await first.value

    XCTAssertEqual(host.openedFiles, [URL(fileURLWithPath: file)])

    applet.verifyLink = { _ in nil }
    await click(file, in: applet, session)

    XCTAssertEqual(host.openedFiles.count, 2, "the tab never clicked again")
  }

  /// Catches a marker shared between tabs. One tab's session is its own terminal, so a remote
  /// client in the first must leave the second's clicks on.
  func testTheMarkerCoversOneTabOnly() async throws {
    let (applet, engine, host, first) = makeApplet()
    let file = try makeFile("a.txt")

    first.onEvent?(.remoteHostReported("server.example"))
    applet.openTab()

    let second = engine.sessions[1]
    await click(file, in: applet, second)

    XCTAssertEqual(applet.remoteSource(ofTabAt: 0), .host("server.example"))
    XCTAssertNil(applet.remoteSource(ofTabAt: 1))
    XCTAssertEqual(host.openedFiles, [URL(fileURLWithPath: file)])
  }

  /// Catches a watcher left running after its tab closes, which would keep a descriptor and a
  /// timer for a process tree nobody looks at.
  func testClosingTheAppletStopsEveryWatcher() {
    let (applet, _, _, session) = makeApplet()

    session.onEvent?(
      .processStarted(TerminalProcessIdentity(pid: getpid(), started: 1, sessionGeneration: 1)))

    let watcher = watchers[0]
    XCTAssertFalse(watcher.stopped)

    applet.close()
    XCTAssertTrue(watcher.stopped)
  }

  /// Catches a click that opens in a host that has no way to open. The default host says so.
  func testAHostWithNoWayToOpenSaysSo() {
    let bare = BareHost()
    let applet = TerminalApplet(engine: FakeEngine(), directoryExists: { _ in true })

    bare.applet(applet, open: URL(fileURLWithPath: "/tmp/x"))

    XCTAssertEqual(bare.texts, ["uniterm cannot open files from this pane."])
  }
}

/// A host that implements only what the protocol requires, so the defaults answer the rest.
@MainActor
private final class BareHost: AppletHost {
  var texts: [String] = []

  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String
  ) -> StatusRecordID? {
    texts.append(text)
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
  ) {}
  func applet(_ applet: any Applet, sessionEnded tab: AppletTabID, pid: pid_t, started: Int) {}
}
