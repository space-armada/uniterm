import AppKit
import AppletKit
import AppletTestSupport
import Darwin
import Preferences
import ScriptHost
import ScriptWire
import StatusKit
import TerminalSurface
import Theme
import XCTest

@testable import ReplApplet
@testable import WindowKit

@MainActor
final class ReplFakeSession: TerminalSession {
  let view = NSView()
  var onEvent: (@MainActor (TerminalEvent) -> Void)?
  var title = ""
  var workingDirectory: String?
  var gridSize = TerminalGridSize(columns: 80, rows: 24)

  /// What libghostty reports for any program with no prompt marks: always running. The REPL must
  /// never read it.
  var isRunningSomething = true
  var hasExited = false
  var closed = false
  let launch: TerminalLaunch

  init(launch: TerminalLaunch) { self.launch = launch }

  func send(text: String) {}
  func perform(_ action: TerminalAction) {}
  func resize(to size: CGSize) {}
  func setFocused(_ focused: Bool) {}
  func setVisible(_ visible: Bool) {}
  func close() { closed = true }
}

@MainActor
final class ReplFakeEngine: TerminalEngine {
  var sessions: [ReplFakeSession] = []
  var anySessionRunningSomething = false

  func makeSession(launch: TerminalLaunch) throws -> any TerminalSession {
    let session = ReplFakeSession(launch: launch)
    sessions.append(session)

    return session
  }

  func apply(palette: ThemePalette) throws {}
}

/// The REPL applet over a fake terminal engine and a real script host. A raw peer plays the helper,
/// so each test controls exactly what the helper reports and when it dies. These prove the pane's
/// behavior: what it launches, what it keeps, when it asks before closing, and what it does when
/// the helper dies. They cannot prove a real helper or a real terminal, which `ScriptReplTests` and
/// the UI tests cover.
@MainActor
final class ReplAppletTests: XCTestCase {
  private var directory: URL!
  private var host: ScriptHost!
  private var engine: ReplFakeEngine!
  private var applets: [ReplApplet] = []
  private var peers: [FramedSocket] = []
  private var suite = ""
  private var windows: WindowSet?
  private let killed = Killed()
  private var extraHosts: [(host: ScriptHost, directory: URL)] = []

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let killed = killed
    let reaper = ProcessReaper(
      delay: .milliseconds(20), isRunning: { _ in true }, kill: { killed.add($0) })

    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { _ in nil }, reaper: reaper)
    host.start()
    engine = ReplFakeEngine()
  }

  override func tearDown() async throws {
    for controller in windows?.controllers ?? [] {
      controller.window?.close()
    }

    for applet in applets {
      applet.close()
    }

    for peer in peers {
      peer.shutdownAndClose()
    }

    host.stop()
    try? FileManager.default.removeItem(at: directory)

    for extra in extraHosts {
      extra.host.stop()
      try? FileManager.default.removeItem(at: extra.directory)
    }

    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  }

  private var services: ReplServices {
    ReplServices(
      helper: { URL(fileURLWithPath: "/synthetic/uniterm") },
      openChannel: { [host] history in host?.admitRepl(history: history) ?? .refused(.scriptingOff)
      })
  }

  private func makeApplet(
    history: ReplHistory = ReplHistory(), host appletHost: RecordingHost? = nil
  ) -> ReplApplet {
    let applet = ReplApplet(
      engine: engine, services: services, history: history, home: "/synthetic/home")

    applet.host = appletHost
    applet.start(origin: .user)
    applets.append(applet)

    return applet
  }

  /// Plays the helper for the session's launch: connects to the address it names, presents the
  /// token it carries, and reads the history the app sends back.
  private func attach(_ session: ReplFakeSession) async throws -> (
    peer: FramedSocket, history: [String]
  ) {
    let launch = session.launch
    let address = try XCTUnwrap(launch.program?.last)
    let hex = try XCTUnwrap(launch.environment[ScriptProtocol.replTokenVariable])
    let token = try XCTUnwrap(Self.decode(hex))
    let peer = try Self.connect(address)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try peer.send(ScriptHelperMessage.attach(token: token).frame())

    // The host answers on the main actor, so the reads run off it.
    let lines = try await Task.detached {
      var lines: [String] = []

      while true {
        let frame = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

        guard
          case .history(let more, let final) = try ScriptAppMessage.decode(
            type: frame.type, body: frame.body)
        else { throw WireError.badValue("not a history") }

        lines += more

        if final { return lines }
      }
    }.value

    peers.append(peer)

    return (peer, lines)
  }

  private static func connect(_ address: String) throws -> FramedSocket {
    let socket = try UnixSocket.connect(path: address)
    var timeout = timeval(tv_sec: 10, tv_usec: 0)

    _ = setsockopt(
      socket.rawDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
      socklen_t(MemoryLayout<timeval>.size))

    return socket
  }

  private static func decode(_ hex: String) -> Data? {
    var data = Data()
    var index = hex.startIndex

    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)

      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }

      data.append(byte)
      index = next
    }

    return data
  }

  private func waitUntil(
    timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(20))
    }

    return condition()
  }

  // MARK: Launch

  /// Catches a launch that carries anything beyond the token, that starts in the pane's directory
  /// instead of home, or that reaches an address other than this instance's own. The environment is
  /// the terminal's identity variables and the token.
  func testALaunchCarriesHomeTheInstanceAddressAndTheTokenOnly() throws {
    let applet = makeApplet()
    let launch = try XCTUnwrap(engine.sessions.first?.launch)

    XCTAssertEqual(launch.workingDirectory, "/synthetic/home")
    XCTAssertEqual(
      launch.program, ["/synthetic/uniterm", "repl", "--socket", host.instanceAddress])

    let extra = Set(launch.environment.keys).subtracting(
      TerminalIdentity.environment(version: TerminalIdentity.bundleVersion).keys)

    XCTAssertEqual(extra, [ScriptProtocol.replTokenVariable])
    XCTAssertEqual(launch.environment[ScriptProtocol.replTokenVariable]?.count, 64)
    XCTAssertNil(applet.currentDirectory)
  }

  /// Catches two panes sharing a token, which would let one helper take the other's pane. Each
  /// pane has its own channel, token, and session.
  func testEachPaneHasItsOwnTokenAndSession() throws {
    _ = makeApplet()
    _ = makeApplet()

    let tokens = engine.sessions.compactMap {
      $0.launch.environment[ScriptProtocol.replTokenVariable]
    }

    XCTAssertEqual(tokens.count, 2)
    XCTAssertEqual(Set(tokens).count, 2)
  }

  // MARK: Running state

  /// Catches a close that asks about a REPL sitting at its prompt. The pty reports a program with no
  /// prompt marks as always running, and the REPL must follow the helper's own report instead.
  func testAnIdlePromptIsNotRunningSomethingWhateverThePtyReports() async throws {
    let applet = makeApplet()
    let session = try XCTUnwrap(engine.sessions.first)

    XCTAssertTrue(session.isRunningSomething)
    XCTAssertFalse(applet.isRunningSomething)
    XCTAssertTrue(applet.runningLabels.isEmpty)

    let (peer, _) = try await attach(session)

    try peer.send(ScriptHelperMessage.replEvaluating(true).frame())

    let running = await waitUntil { applet.isRunningSomething }

    XCTAssertTrue(running)
    XCTAssertEqual(applet.runningLabels, ["REPL"])

    try peer.send(ScriptHelperMessage.replEvaluating(false).frame())

    let idle = await waitUntil { !applet.isRunningSomething }

    XCTAssertTrue(idle)
  }

  // MARK: History

  /// Catches a saved layout that waits on the helper, or that misses a line. The helper reports
  /// each line and then never answers anything again. The description holds every line at once.
  func testHistoryIsKeptAsLinesAreEnteredAndSavingNeverContactsTheHelper() async throws {
    let recorder = RecordingHost()
    let applet = makeApplet(host: recorder)
    let (peer, _) = try await attach(try XCTUnwrap(engine.sessions.first))

    for line in ["(+ 1 2)", "", "(def x 1)", "(def x 1)", "(print x)"] {
      try peer.send(ScriptHelperMessage.replLine(line).frame())
    }

    let kept = await waitUntil { applet.historyLines.count == 3 }

    XCTAssertTrue(kept)
    XCTAssertEqual(applet.historyLines, ["(+ 1 2)", "(def x 1)", "(print x)"])
    XCTAssertGreaterThan(recorder.changes, 0, "the window was not told the description changed")

    let saved = try ReplDescription.decode(applet.describe())

    XCTAssertEqual(saved.history, ["(+ 1 2)", "(def x 1)", "(print x)"])
  }

  // MARK: Helper death

  /// Catches a pane that closes when its helper dies, one that loses its history, and one that
  /// restarts on its own. The pane stays open with a message, restarts only when the user asks, and
  /// the new helper is sent the history.
  func testWhenTheHelperDiesThePaneStaysAndRestartKeepsTheHistory() async throws {
    let recorder = RecordingHost()
    let applet = makeApplet(host: recorder)
    let first = try XCTUnwrap(engine.sessions.first)
    let (peer, _) = try await attach(first)

    try peer.send(ScriptHelperMessage.replLine("(+ 1 2)").frame())

    let kept = await waitUntil { applet.historyLines == ["(+ 1 2)"] }

    XCTAssertTrue(kept)

    peer.shutdownAndClose()

    let ended = await waitUntil { applet.endedMessage != nil }

    XCTAssertTrue(ended)
    XCTAssertFalse(recorder.exited, "the pane asked to close when the helper died")
    XCTAssertEqual(applet.segments.first?.text, "Ended")

    try await Task.sleep(for: .milliseconds(200))

    XCTAssertEqual(engine.sessions.count, 1, "the REPL restarted without the user")
    XCTAssertEqual(applet.historyLines, ["(+ 1 2)"])

    applet.restart()

    XCTAssertEqual(engine.sessions.count, 2)
    XCTAssertTrue(first.closed)
    XCTAssertNil(applet.endedMessage)

    let (_, history) = try await attach(engine.sessions[1])

    XCTAssertEqual(history, ["(+ 1 2)"])
    XCTAssertNotEqual(
      first.launch.environment[ScriptProtocol.replTokenVariable],
      engine.sessions[1].launch.environment[ScriptProtocol.replTokenVariable])
  }

  /// Catches a pane that closes when the session itself exits, the path a helper that dies before
  /// it connects takes. The message is shown and the history stays.
  func testASessionThatExitsLeavesTheMessageAndNoAutomaticRestart() async throws {
    let recorder = RecordingHost()
    let applet = makeApplet(history: ReplHistory(restoring: ["(+ 1 2)"]), host: recorder)
    let session = try XCTUnwrap(engine.sessions.first)

    session.onEvent?(.exited)

    XCTAssertEqual(applet.endedMessage, "The REPL ended.")
    XCTAssertFalse(recorder.exited)
    XCTAssertEqual(applet.historyLines, ["(+ 1 2)"])
    XCTAssertFalse(session.closed, "the helper's last output must stay on screen")

    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(engine.sessions.count, 1)

    applet.restart()

    XCTAssertEqual(engine.sessions.count, 2)
    XCTAssertTrue(session.closed)
  }

  /// Catches a restart that tears down a REPL that is running.
  func testRestartDoesNothingWhileTheHelperRuns() {
    let applet = makeApplet()

    applet.restart()

    XCTAssertEqual(engine.sessions.count, 1)
    XCTAssertFalse(engine.sessions[0].closed)
  }

  /// Catches a pane that has nothing to say when scripting is off or the helper is missing. Each
  /// is a message with a restart, and nothing crashes.
  func testAMissingHelperOrNoScriptingIsAMessageWithARestart() {
    let missing = ReplApplet(
      engine: engine,
      services: ReplServices(helper: { nil }, openChannel: { _ in .refused(.scriptingOff) }),
      home: "/synthetic/home")

    missing.start(origin: .user)
    applets.append(missing)

    XCTAssertTrue(
      missing.endedMessage?.contains("missing") == true,
      "\(String(describing: missing.endedMessage))")

    let off = ReplApplet(
      engine: engine,
      services: ReplServices(
        helper: { URL(fileURLWithPath: "/synthetic/uniterm") },
        openChannel: { _ in .refused(.scriptingOff) }),
      home: "/synthetic/home")

    off.start(origin: .user)
    applets.append(off)

    XCTAssertTrue(off.endedMessage?.contains("Scripting is not running") == true)
    XCTAssertTrue(engine.sessions.isEmpty)
  }

  /// Catches a close that leaves the helper alive. Closing the pane closes the session and the
  /// connection, and a helper still there after the delay is killed.
  func testClosingThePaneEndsTheHelper() async throws {
    let applet = makeApplet()
    let session = try XCTUnwrap(engine.sessions.first)
    let (peer, _) = try await attach(session)

    applet.close()

    XCTAssertTrue(session.closed)
    XCTAssertThrowsError(try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))) {
      XCTAssertEqual($0 as? WireError, .closed)
    }

    let reaped = await waitUntil { self.killed.all == [getpid()] }

    XCTAssertTrue(reaped)
  }

  // MARK: Restore

  /// Catches a restore that runs a saved line, or carries the history anywhere but the channel. A
  /// restored pane starts a fresh helper. The history reaches it only as text to recall, after the
  /// token binds, and nothing in the launch holds it.
  func testARestoredPaneStartsAFreshHelperAndSendsTheHistoryOnlyOverTheChannel() async throws {
    let saved = try ReplDescription(history: ["(spit \"/tmp/x\" \"y\")", "(os/exit 1)"])
      .appletDescription()
    let applet = try ReplApplet(
      engine: engine, services: services, restoring: saved, home: "/synthetic/home")

    applets.append(applet)
    applet.start(origin: .restore)

    let session = try XCTUnwrap(engine.sessions.first)
    let launch = session.launch
    let carried = (launch.program ?? []) + Array(launch.environment.values)

    XCTAssertFalse(carried.contains { $0.contains("spit") || $0.contains("os/exit") })

    let (_, history) = try await attach(session)

    XCTAssertEqual(history, ["(spit \"/tmp/x\" \"y\")", "(os/exit 1)"])
  }

  /// Catches a description from a newer build restoring as a REPL, and one that is not a REPL.
  func testARestoreRefusesADescriptionItCannotRead() {
    let newer = AppletDescription(type: "repl", version: 99, payload: .null)

    XCTAssertThrowsError(
      try ReplApplet(engine: engine, services: services, restoring: newer))
  }

  // MARK: Window

  private func makeWindows() throws -> (WindowSet, MainWindowController) {
    suite = "uniterm-repl-test-\(UUID().uuidString)"

    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    let appearance = AppearanceController(store: store)
    let services = services
    let engine = engine!

    let set = WindowSet(
      makeController: { [weak self] identifier, directory in
        let controller = try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          restoreApplet: { description in
            try ReplApplet(
              engine: engine, services: services, restoring: description, home: "/synthetic/home")
          },
          makeApplet: { _, _ in
            let applet = ReplApplet(engine: engine, services: services, home: "/synthetic/home")
            self?.applets.append(applet)

            return applet
          })

        controller.confirmer = { _, _ in
          self?.asked += 1

          return false
        }

        return controller
      })

    windows = set

    let controller = try set.open()
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    return (set, controller)
  }

  private var asked = 0

  /// Catches a script that can type into a REPL. The refusal is the property the REPL declares,
  /// proved against a real REPL applet in a real window set, and nothing is written.
  func testAScriptsSendToARealReplPaneIsRefused() async throws {
    let (set, controller) = try makeWindows()
    let pane = try XCTUnwrap(controller.openPane(.repl, axis: .row, from: controller.focusedPane))
    let reference = ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)
    let scripting = WindowScripting(windows: set, directoryExists: { _ in true })

    XCTAssertTrue(controller.paneArea.applet(for: pane) is ReplApplet)
    XCTAssertTrue((controller.paneArea.applet(for: pane) as Any) is any InputOwning)

    do {
      try scripting.prepareSend(to: reference)
      XCTFail("a send to a REPL pane was prepared")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
      XCTAssertTrue(error.text.contains("owns this pane's input"), error.text)
    }
  }

  /// Catches a close that asks about an idle REPL, and an undo that loses the history. The pane
  /// closes with no question. Undo reopens it from its description, with a fresh helper that is
  /// sent the history. A REPL evaluating a form does ask, and the user's refusal keeps it open.
  func testClosingAnIdleReplDoesNotAskAndUndoBringsTheHistoryBack() async throws {
    let (_, controller) = try makeWindows()
    let pane = try XCTUnwrap(controller.openPane(.repl, axis: .row, from: controller.focusedPane))
    let applet = try XCTUnwrap(controller.paneArea.applet(for: pane) as? ReplApplet)
    let session = try XCTUnwrap(engine.sessions.last)
    let (peer, _) = try await attach(session)

    try peer.send(ScriptHelperMessage.replLine("(+ 1 2)").frame())

    let kept = await waitUntil { applet.historyLines == ["(+ 1 2)"] }

    XCTAssertTrue(kept)

    controller.dispatch(.close)

    XCTAssertEqual(asked, 0, "closing an idle REPL asked")
    XCTAssertFalse(controller.paneIDs.contains(pane))
    XCTAssertTrue(session.closed)

    controller.reopenClosed()

    let reopened = try XCTUnwrap(
      controller.paneArea.applet(for: controller.focusedPane) as? ReplApplet)

    XCTAssertEqual(reopened.historyLines, ["(+ 1 2)"])

    let fresh = try XCTUnwrap(engine.sessions.last)

    XCTAssertTrue(fresh !== session)

    let (again, history) = try await attach(fresh)

    XCTAssertEqual(history, ["(+ 1 2)"])

    try again.send(ScriptHelperMessage.replEvaluating(true).frame())

    let running = await waitUntil { reopened.isRunningSomething }

    XCTAssertTrue(running)

    controller.dispatch(.close)
    await controller.pendingGuard?.value

    XCTAssertEqual(asked, 1, "closing a REPL that evaluates did not ask")
    XCTAssertTrue(controller.paneIDs.count == 2, "the user refused, so the pane stays")
  }
}

final class Killed: @unchecked Sendable {
  private let lock = NSLock()
  private var pids: [pid_t] = []

  func add(_ pid: pid_t) {
    lock.lock()
    pids.append(pid)
    lock.unlock()
  }

  var all: [pid_t] {
    lock.lock()
    defer { lock.unlock() }

    return pids
  }
}

// MARK: Limits

/// A footprint and a clock a test sets by hand.
private final class Knobs: @unchecked Sendable {
  private let lock = NSLock()
  private var storedFootprint = 0
  private var storedNow = ContinuousClock.Instant.now

  var footprint: Int {
    get { lock.withLock { storedFootprint } }
    set { lock.withLock { storedFootprint = newValue } }
  }

  var now: ContinuousClock.Instant { lock.withLock { storedNow } }

  func advance(by amount: Duration) {
    lock.withLock { storedNow = storedNow + amount }
  }
}

extension ReplAppletTests {
  /// A host with a small budget and a hand-set footprint, whose timer never fires.
  private func makeLimitedHost(knobs: Knobs, budget: Int) throws -> ReplServices {
    let local = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)

    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

    let killed = killed
    let limited = ScriptHost(
      listener: try ScriptListener.start(directory: local), issueProducer: { _ in nil },
      reaper: ProcessReaper(
        delay: .milliseconds(20), isRunning: { _ in true }, kill: { killed.add($0) }),
      replLimits: ReplLimits(
        helperCap: 1 << 30, killMargin: 1 << 28, budget: budget, sampleInterval: .seconds(3600),
        pongGrace: .seconds(3600)),
      replProbes: ReplProbes(footprint: { _ in knobs.footprint }, now: { knobs.now }))

    limited.start()
    extraHosts.append((limited, local))

    return ReplServices(
      helper: { URL(fileURLWithPath: "/synthetic/uniterm") },
      openChannel: { [limited] history in limited.admitRepl(history: history) })
  }

  private func makeApplet(services: ReplServices, host recorder: RecordingHost? = nil) -> ReplApplet
  {
    let applet = ReplApplet(engine: engine, services: services, home: "/synthetic/home")

    applet.host = recorder
    applet.start(origin: .user)
    applets.append(applet)

    return applet
  }

  /// Catches a new REPL that starts while the others hold more than the budget, a pane that gives
  /// no reason, a retry that runs on its own, a warning that repeats, and a running REPL that is
  /// ended for the total. The refused pane says why and offers Restart. The history holds one
  /// warning. A restored pane over the budget never retries, and the REPL that runs is untouched.
  func testANewReplOverTheBudgetSaysWhyOffersARetryAndWarnsOnce() async throws {
    let knobs = Knobs()
    let services = try makeLimitedHost(knobs: knobs, budget: 1000)
    let recorder = RecordingHost()

    let running = makeApplet(services: services)
    let session = try XCTUnwrap(engine.sessions.first)
    let (_, _) = try await attach(session)
    let local = try XCTUnwrap(extraHosts.last?.host)

    knobs.footprint = 5000

    await local.sampleRepls()

    let refused = makeApplet(services: services, host: recorder)

    XCTAssertEqual(engine.sessions.count, 1, "a REPL started over the budget")

    let message = try XCTUnwrap(refused.endedMessage)

    XCTAssertTrue(message.contains("did not start"), message)
    XCTAssertTrue(message.contains("Restart"), message)
    XCTAssertEqual(recorder.admitted.count, 1)
    XCTAssertEqual(recorder.admitted.first?.level, .warning)

    refused.restart()

    XCTAssertEqual(engine.sessions.count, 1, "a retry started a REPL while still over")
    XCTAssertEqual(recorder.admitted.count, 1, "the warning repeated")
    XCTAssertNil(running.endedMessage, "a running REPL was ended for the total")
    XCTAssertEqual(killed.all, [])

    knobs.footprint = 10

    await local.sampleRepls()

    refused.restart()

    XCTAssertEqual(engine.sessions.count, 2)
    XCTAssertNil(refused.endedMessage)
  }

  /// Catches a warning for every refused pane. Three panes are refused in one episode, and the
  /// history holds one warning. Once the total is back under the budget the episode is over, and
  /// a pane refused in a later one warns again.
  func testSeveralPanesRefusedInOneEpisodeGiveOneWarning() async throws {
    let knobs = Knobs()
    let services = try makeLimitedHost(knobs: knobs, budget: 1000)
    let recorder = RecordingHost()

    _ = makeApplet(services: services)

    let (_, _) = try await attach(try XCTUnwrap(engine.sessions.first))
    let local = try XCTUnwrap(extraHosts.last?.host)

    knobs.footprint = 5000

    let refused = (0..<3).map { _ in makeApplet(services: services, host: recorder) }

    XCTAssertTrue(refused.allSatisfy { $0.endedMessage != nil })
    XCTAssertEqual(recorder.admitted.count, 1)

    knobs.footprint = 10

    await local.sampleRepls()

    knobs.footprint = 5000

    _ = makeApplet(services: services, host: recorder)

    XCTAssertEqual(recorder.admitted.count, 2, "a new episode did not warn")
  }

  /// Catches a restored pane that retries a refused start by itself. The pane starts once, is
  /// refused, and stays refused with no timer behind it, however long it waits.
  func testARestoredPaneOverTheBudgetNeverRetriesOnItsOwn() async throws {
    let knobs = Knobs()
    let services = try makeLimitedHost(knobs: knobs, budget: 1000)

    _ = makeApplet(services: services)

    let (_, _) = try await attach(try XCTUnwrap(engine.sessions.first))
    let local = try XCTUnwrap(extraHosts.last?.host)

    knobs.footprint = 5000

    await local.sampleRepls()

    let description = try ReplDescription(history: ["(+ 1 2)"]).appletDescription()
    let restored = try ReplApplet(
      engine: engine, services: services, restoring: description, home: "/synthetic/home")

    restored.start(origin: .restore)
    applets.append(restored)

    XCTAssertNotNil(restored.endedMessage)

    knobs.footprint = 10

    await local.sampleRepls()
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(engine.sessions.count, 1, "a restored pane retried on its own")
    XCTAssertEqual(restored.historyLines, ["(+ 1 2)"])
  }

  /// Catches a Ctrl-C key that is read wrongly. Only Control and C, as a fresh press, counts.
  func testOnlyAFreshControlCPressIsTheInterruptKey() throws {
    func event(
      _ characters: String, _ flags: NSEvent.ModifierFlags, repeating: Bool = false
    ) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: repeating, keyCode: 8))
    }

    XCTAssertTrue(ReplApplet.isInterruptKey(try event("c", .control)))
    XCTAssertFalse(ReplApplet.isInterruptKey(try event("c", [])))
    XCTAssertFalse(ReplApplet.isInterruptKey(try event("c", [.control, .shift])))
    XCTAssertFalse(ReplApplet.isInterruptKey(try event("c", [.control, .command])))
    XCTAssertFalse(ReplApplet.isInterruptKey(try event("c", [.control, .option])))
    XCTAssertFalse(ReplApplet.isInterruptKey(try event("d", .control)))
    XCTAssertFalse(ReplApplet.isInterruptKey(try event("c", .control, repeating: true)))
  }

  /// Catches a Ctrl-C in the pane that never reaches the helper over the control channel. The
  /// first press while a form runs sends the stop request, and a press with nothing running sends
  /// none. A second press after the gap, with the form still running, ends the helper and the pane
  /// says why, keeps its history, and offers Restart.
  func testCtrlCInThePaneSendsAStopAndASecondEndsAStuckHelper() async throws {
    let knobs = Knobs()
    let services = try makeLimitedHost(knobs: knobs, budget: 1 << 40)
    let applet = makeApplet(services: services)
    let (peer, _) = try await attach(try XCTUnwrap(engine.sessions.first))

    try peer.send(ScriptHelperMessage.replLine("(while true)").frame())
    try peer.send(ScriptHelperMessage.replEvaluating(false).frame())

    let recorded = await waitUntil { applet.historyLines == ["(while true)"] }

    XCTAssertTrue(recorded)

    applet.interruptKeyPressed()

    let idleFrames = await Task.detached {
      var timeout = timeval(tv_sec: 0, tv_usec: 300_000)

      _ = setsockopt(
        peer.rawDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.size))

      return (try? peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))) == nil
    }.value

    XCTAssertTrue(idleFrames, "a press with nothing running sent a message")

    try peer.send(ScriptHelperMessage.replEvaluating(true).frame())

    let running = await waitUntil { applet.isRunningSomething }

    XCTAssertTrue(running)

    applet.interruptKeyPressed()

    let stop = try await Task.detached {
      var timeout = timeval(tv_sec: 10, tv_usec: 0)

      _ = setsockopt(
        peer.rawDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.size))

      let frame = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
    }.value

    XCTAssertEqual(stop, .stop)
    XCTAssertNil(applet.endedMessage)

    knobs.advance(by: .seconds(1))
    applet.interruptKeyPressed()

    let message = try XCTUnwrap(applet.endedMessage)

    XCTAssertTrue(message.contains("Ctrl-C twice"), message)
    XCTAssertEqual(applet.historyLines, ["(while true)"])
    XCTAssertEqual(killed.all.first, getpid())
  }

  /// Catches a helper that ran out of memory being shown as a lost connection. The helper's notice
  /// arrives first, and the pane names the cap and offers Restart.
  func testAMemoryLimitNoticeGivesThePaneItsReason() async throws {
    let knobs = Knobs()
    let services = try makeLimitedHost(knobs: knobs, budget: 1 << 40)
    let applet = makeApplet(services: services)
    let (peer, _) = try await attach(try XCTUnwrap(engine.sessions.first))

    try peer.send(ScriptHelperMessage.memoryLimit.frame())
    peer.shutdownAndClose()

    let ended = await waitUntil { applet.endedMessage != nil }

    XCTAssertTrue(ended)

    let message = try XCTUnwrap(applet.endedMessage)

    XCTAssertTrue(message.contains("1 GiB"), message)
    XCTAssertTrue(message.contains("Restart"), message)
  }
}
