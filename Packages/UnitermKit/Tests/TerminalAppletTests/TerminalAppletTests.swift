import AppKit
import AppletKit
import AppletTestSupport
import StatusKit
import Theme
import XCTest

@testable import TerminalApplet
@testable import TerminalSurface

private final class Answers: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Bool] = []

  /// Records whether the answer let the request through.
  func append(_ answer: TerminalClipboardAnswer) {
    append(answer != .deny)
  }

  func append(_ value: Bool) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  var all: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

@MainActor
final class FakeSession: TerminalSession {
  let view = NSView()
  var onEvent: (@MainActor (TerminalEvent) -> Void)?
  var title = ""
  var workingDirectory: String?
  var gridSize = TerminalGridSize(columns: 80, rows: 24)
  var isRunningSomething = false
  var hasExited = false
  var closed = false
  var visible = true
  var launch: TerminalLaunch

  init(launch: TerminalLaunch) { self.launch = launch }

  func send(text: String) {}
  var acceptsInput = true
  func perform(_ action: TerminalAction) {}
  func resize(to size: CGSize) {}
  /// How many times the applet set the session's focus or visibility, including calls that changed
  /// nothing.
  var focusAndVisibilityCalls = 0

  func setFocused(_ focused: Bool) { focusAndVisibilityCalls += 1 }

  func setVisible(_ visible: Bool) {
    self.visible = visible
    focusAndVisibilityCalls += 1
  }

  /// Every policy the session was given, the one it was made with first.
  var clipboardPolicies: [TerminalClipboardPolicy] = []
  var clipboardPolicy: TerminalClipboardPolicy { clipboardPolicies.last ?? .interactive }
  func setClipboardPolicy(_ policy: TerminalClipboardPolicy) { clipboardPolicies.append(policy) }

  /// What `scrollbackText` answers.
  var scrollback: String?
  func scrollbackText() -> String? { scrollback }

  func close() { closed = true }
}

@MainActor
final class FakeEngine: TerminalEngine {
  var sessions: [FakeSession] = []
  var anySessionRunningSomething = false

  /// When set, the next sessions fail to start with this error.
  var failure: (any Error)?

  func makeSession(launch: TerminalLaunch, clipboardPolicy: TerminalClipboardPolicy) throws
    -> any TerminalSession
  {
    if let failure { throw failure }

    let session = FakeSession(launch: launch)
    session.clipboardPolicies = [clipboardPolicy]
    sessions.append(session)
    return session
  }

  func apply(palette: ThemePalette) throws {}
}

@MainActor
final class TerminalAppletTests: XCTestCase {
  /// A session holds its applet weakly, so a test that drops the applet would drop the handler.
  private var retained: [TerminalApplet] = []

  private func makeApplet() -> (TerminalApplet, FakeEngine, RecordingHost, FakeSession) {
    let engine = FakeEngine()
    let host = RecordingHost()
    let applet = TerminalApplet(engine: engine, directoryExists: { _ in true })
    applet.host = host
    applet.start(origin: .user)
    retained.append(applet)
    return (applet, engine, host, engine.sessions[0])
  }

  /// What every launch carries and nothing else, when the caller added no variables.
  private var identity: [String: String] {
    TerminalIdentity.environment(version: TerminalIdentity.bundleVersion)
  }

  // MARK: Identity

  /// Catches a launch path that reports libghostty's `TERM_PROGRAM=ghostty`. Every way a terminal
  /// starts must name uniterm: the first shell, a program, a new tab, a restored shell, and a
  /// restored program once the user runs it. Undo restores through the same description, so it is
  /// the restored cases.
  func testEveryLaunchKindReportsUnitermAsTheTerminalProgram() throws {
    let (applet, engine, _, _) = makeApplet()
    applet.openTab()

    let restoredShell = try TerminalApplet(
      engine: engine, restoring: applet.describe(), directoryExists: { _ in true })
    retained.append(restoredShell)
    restoredShell.start(origin: .user)

    let program = try TerminalApplet(engine: engine, program: "vim")
    retained.append(program)
    program.start(origin: .user)

    let host = RecordingHost()
    let restoredProgram = try restoreProgram(
      try programDescription(), engine: engine, host: host)
    let prompt = try XCTUnwrap(
      restoredProgram.view.subviews.compactMap { $0 as? TerminalRunPrompt }.first)
    prompt.run()

    XCTAssertEqual(engine.sessions.count, 6)

    for session in engine.sessions {
      XCTAssertEqual(session.launch.environment["TERM_PROGRAM"], "uniterm")
      XCTAssertEqual(
        session.launch.environment["TERM_PROGRAM_VERSION"], TerminalIdentity.bundleVersion)
    }

    withExtendedLifetime(host) {}
  }

  // MARK: Directories

  /// Catches an applet that reports a path it cannot start a terminal in, such as one from another
  /// machine after an ssh login, or one that is gone. Only an absolute local directory is
  /// reported, and it follows the shell.
  func testCurrentDirectoryFollowsTheShellAndIsNilForPathsThatAreNotUsableHere() {
    let engine = FakeEngine()
    let applet = TerminalApplet(engine: engine, workingDirectory: "/tmp", home: "/home-x")
    retained.append(applet)
    applet.start(origin: .user)

    XCTAssertEqual(applet.currentDirectory, "/tmp")

    let session = engine.sessions[0]
    session.onEvent?(.workingDirectoryChanged("/private/var"))
    XCTAssertEqual(applet.currentDirectory, "/private/var")

    for path in ["me@host:/srv", "relative/dir", "/no/such/uniterm-directory", "/etc/hosts"] {
      session.onEvent?(.workingDirectoryChanged(path))
      XCTAssertNil(applet.currentDirectory, path)
    }
  }

  /// Catches a terminal that leaves its start to the engine. A given directory that is usable is
  /// passed on, and anything else starts in the home directory, for a shell and for a program.
  func testATerminalAlwaysLaunchesWithAnExplicitDirectory() throws {
    let engine = FakeEngine()

    let cases: [(given: String?, expected: String)] = [
      (nil, "/home-x"), ("/tmp", "/tmp"), ("/no/such/uniterm-directory", "/home-x"),
      ("me@host:/srv", "/home-x"),
    ]

    for (given, expected) in cases {
      let shell = TerminalApplet(engine: engine, workingDirectory: given, home: "/home-x")
      let program = try TerminalApplet(
        engine: engine, program: "htop", workingDirectory: given, home: "/home-x")

      for applet in [shell, program] {
        retained.append(applet)
        applet.start(origin: .user)
      }

      XCTAssertEqual(
        engine.sessions.suffix(2).map { $0.launch.workingDirectory }, [expected, expected],
        "\(given ?? "nil")")
    }
  }

  /// Catches a new tab that carries a path from another machine into the engine. It falls back to
  /// the home directory instead.
  func testANewTabFromARemotePathStartsInHome() {
    let engine = FakeEngine()
    let applet = TerminalApplet(engine: engine, workingDirectory: "/tmp", home: "/home-x")
    retained.append(applet)
    applet.start(origin: .user)

    engine.sessions[0].onEvent?(.workingDirectoryChanged("me@host:/srv"))
    applet.openTab()

    XCTAssertEqual(engine.sessions[1].launch.workingDirectory, "/home-x")
  }

  /// Waits for the applet's confirmation task, which hops through the main actor.
  private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Catches an applet that starts a shell by reaching past the protocol, or that never hosts the
  /// session's view.
  func testStartMakesOneSessionAndHostsItsView() {
    let (applet, engine, _, session) = makeApplet()

    XCTAssertEqual(engine.sessions.count, 1)
    XCTAssertTrue(session.view.isDescendant(of: applet.view))
  }

  /// Catches a pane that stays open after its shell ends.
  func testExitAsksTheHostToClosePane() {
    let (_, _, host, session) = makeApplet()

    session.onEvent?(.exited)

    XCTAssertTrue(host.exited)
  }

  /// Catches a notification that posts without a source level, or one whose control characters
  /// forge a second line in the status bar.
  func testNotificationPostsSanitizedInfo() {
    let (_, _, host, session) = makeApplet()

    session.onEvent?(.notification(title: "Build\nOK", body: "all\u{1B}[31m done"))

    XCTAssertEqual(host.posts.count, 1)
    XCTAssertEqual(host.posts[0].0, .info)
    XCTAssertFalse(host.posts[0].1.contains("\n"))
    XCTAssertFalse(host.posts[0].1.contains("\u{1B}"))
    XCTAssertEqual(host.posts[0].1, "Build OK: all [31m done")
  }

  private struct Refused: LocalizedError {
    var errorDescription: String? { "the shell is missing" }
  }

  /// Catches a start failure rated as lost work. A shell that cannot start loses nothing the user
  /// made. It leaves the requested content unshown, which is a warning, for the first shell and
  /// for a tab opened later.
  func testASessionThatCannotStartIsAWarning() {
    let engine = FakeEngine()
    engine.failure = Refused()
    let host = RecordingHost()
    let applet = TerminalApplet(engine: engine, directoryExists: { _ in true })
    applet.host = host
    retained.append(applet)

    applet.start(origin: .user)

    XCTAssertEqual(host.posts.map(\.0), [.warning])
    XCTAssertTrue(host.posts[0].1.hasPrefix("The terminal could not start"))
    XCTAssertTrue(host.exited)

    let (live, liveEngine, liveHost, _) = makeApplet()
    liveEngine.failure = Refused()
    live.openTab()

    XCTAssertEqual(liveHost.posts.map(\.0), [.warning])
    XCTAssertTrue(liveHost.posts[0].1.hasPrefix("The tab could not open"))

    let programEngine = FakeEngine()
    let programHost = RecordingHost()
    let restored = try? restoreProgram(
      try programDescription(), engine: programEngine, host: programHost)
    programEngine.failure = Refused()

    let prompt = restored?.view.subviews.compactMap { $0 as? TerminalRunPrompt }.first
    prompt?.run()

    XCTAssertEqual(programHost.posts.map(\.0), [.warning])
    XCTAssertTrue(programHost.posts.first?.1.hasPrefix("The program could not start") == true)
  }

  /// Catches many restored terminals that fail to start and bury the bar. A start failure on a
  /// launch restore is a warning that raises attention and takes no turn. The same failure on a
  /// user start takes a turn.
  func testAStartFailureOnALaunchRestoreRaisesAttentionWithoutATurn() {
    func failing(_ origin: StartOrigin) -> RecordingHost {
      let engine = FakeEngine()
      engine.failure = Refused()
      let host = RecordingHost()
      let applet = TerminalApplet(engine: engine, directoryExists: { _ in true })
      applet.host = host
      retained.append(applet)
      applet.start(origin: origin)
      return host
    }

    let restored = failing(.restore)

    XCTAssertTrue(restored.posts.isEmpty, "\(restored.posts)")
    XCTAssertEqual(restored.attentions.map(\.0), [.warning])
    XCTAssertTrue(restored.attentions[0].1.hasPrefix("The terminal could not start"))

    XCTAssertEqual(failing(.user).posts.map(\.0), [.warning])
  }

  func testLongNotificationIsCapped() {
    let (_, _, host, session) = makeApplet()

    session.onEvent?(.notification(title: "", body: String(repeating: "x", count: 5000)))

    XCTAssertEqual(host.posts[0].1.count, 200)
  }

  /// Catches an OSC 52 read that is answered before the user chose. The request is open while the
  /// host's answer is pending, and a declined request stays declined.
  func testClipboardReadWaitsForTheUserAndDenies() async {
    let (_, _, host, session) = makeApplet()
    host.answer = false

    let answers = Answers()
    let request = TerminalClipboardRequest(kind: .read, text: "secret") { answers.append($0) }
    session.onEvent?(.clipboardRequest(request))

    XCTAssertEqual(answers.all, [], "answered before the host was asked")

    await settle { answers.all.count == 1 }

    XCTAssertEqual(host.confirmations.count, 1)
    XCTAssertEqual(answers.all, [false])
    XCTAssertTrue(host.confirmations[0].detail.contains("secret"))
  }

  func testClipboardReadIsAllowedOnlyWhenTheUserAgrees() async {
    let (_, _, host, session) = makeApplet()
    host.answer = true

    let answers = Answers()
    let request = TerminalClipboardRequest(kind: .read, text: "x") { answers.append($0) }
    session.onEvent?(.clipboardRequest(request))

    await settle { answers.all.count == 1 }

    XCTAssertEqual(answers.all, [true])
  }

  /// A second answer to one request does nothing.
  func testRequestResolvesOnce() {
    let answers = Answers()
    let request = TerminalClipboardRequest(kind: .read, text: "x") { answers.append($0) }

    request.resolve(allow: true)
    request.resolve(allow: false)

    XCTAssertEqual(answers.all, [true])
  }

  func testRunningStateComesFromTheSession() {
    let (applet, _, _, session) = makeApplet()

    XCTAssertFalse(applet.isRunningSomething)
    session.isRunningSomething = true
    XCTAssertTrue(applet.isRunningSomething)

    session.hasExited = true
    XCTAssertFalse(applet.isRunningSomething)
  }

  func testCloseHangsUpTheSession() {
    let (applet, _, _, session) = makeApplet()

    applet.close()

    XCTAssertTrue(session.closed)
    XCTAssertNil(session.view.superview)
  }

  /// The description follows the shell's last reported directory, and restoring it starts a shell
  /// in that directory. Nothing else runs.
  func testDescriptionTracksDirectoryAndRestores() throws {
    let (applet, engine, _, session) = makeApplet()
    session.onEvent?(.workingDirectoryChanged("/var/tmp"))

    let description = applet.describe()
    let restored = try TerminalApplet(
      engine: engine, restoring: description, directoryExists: { _ in true })
    retained.append(restored)
    restored.start(origin: .user)

    XCTAssertEqual(engine.sessions.count, 2)
    XCTAssertEqual(engine.sessions[1].launch.workingDirectory, "/var/tmp")
  }

  /// Catches segments that go stale, or a change that does not tell the host.
  func testSegmentsFollowTheDirectoryAndTheLastExitCode() {
    let (applet, _, host, session) = makeApplet()
    XCTAssertEqual(applet.segments, [AppletSegment(symbolName: "folder", text: "~")])

    session.onEvent?(.workingDirectoryChanged("/var/tmp"))
    XCTAssertEqual(applet.segments, [AppletSegment(symbolName: "folder", text: "tmp")])
    XCTAssertEqual(host.changes, 1)

    session.onEvent?(.commandFinished(exitCode: 2, duration: .seconds(1)))
    XCTAssertEqual(
      applet.segments,
      [
        AppletSegment(symbolName: "folder", text: "tmp"),
        AppletSegment(symbolName: "xmark.circle", text: "2", style: .error),
      ])
    XCTAssertEqual(host.changes, 2)

    session.onEvent?(.commandFinished(exitCode: 0, duration: .seconds(1)))
    XCTAssertEqual(applet.segments, [AppletSegment(symbolName: "folder", text: "tmp")])
    XCTAssertEqual(host.changes, 3)
  }

  /// Catches a directory label that shows a long path, or the home folder as its own name.
  func testDirectoryLabelShowsTheLastComponentAndTildeForHome() {
    XCTAssertEqual(TerminalApplet.directoryLabel("/Users/pat", home: "/Users/pat"), "~")
    XCTAssertEqual(TerminalApplet.directoryLabel("/Users/pat/src/app", home: "/Users/pat"), "app")
    XCTAssertEqual(TerminalApplet.directoryLabel("/", home: "/Users/pat"), "/")
    XCTAssertEqual(TerminalApplet.directoryLabel("/tmp/a\nb", home: "/Users/pat"), "a b")
  }

  private func programDescription(
    _ command: String? = "./deploy.sh --now", directory: String? = "/work"
  ) throws -> AppletDescription {
    try TerminalDescription(
      mode: .program, command: command, tabs: [.init(workingDirectory: directory)]
    ).appletDescription()
  }

  private func restoreProgram(
    _ description: AppletDescription, engine: FakeEngine, host: RecordingHost
  ) throws -> TerminalApplet {
    let restored = try TerminalApplet(
      engine: engine, restoring: description, directoryExists: { _ in true })
    restored.host = host
    retained.append(restored)
    restored.start(origin: .user)
    return restored
  }

  /// Catches a restore that runs the program unasked. Starting a restored program-mode applet makes
  /// no session, shows the command with a Run button, and asks the host nothing. The applet is not
  /// running anything, so closing it never needs a dialog.
  func testProgramDescriptionRestoresIntoAPromptThatRunsNothing() throws {
    let engine = FakeEngine()
    let host = RecordingHost()

    let restored = try restoreProgram(try programDescription(), engine: engine, host: host)

    XCTAssertTrue(engine.sessions.isEmpty, "a session started without the user asking")
    XCTAssertFalse(host.exited, "an applet waiting to run asked its pane to close")
    XCTAssertFalse(restored.isRunningSomething)
    XCTAssertTrue(restored.isAwaitingRun)

    let prompt = try XCTUnwrap(
      restored.view.subviews.compactMap { $0 as? TerminalRunPrompt }.first)
    XCTAssertFalse(prompt.isHidden)
    XCTAssertEqual(prompt.command, "./deploy.sh --now")
  }

  /// Catches a Run action that does not start the one program. Pressing Run makes exactly one
  /// session. It runs the saved words in the saved directory, in program mode, and hides the prompt.
  func testRunStartsTheSavedProgramOnce() throws {
    let engine = FakeEngine()
    let host = RecordingHost()
    let restored = try restoreProgram(try programDescription(), engine: engine, host: host)
    let prompt = try XCTUnwrap(
      restored.view.subviews.compactMap { $0 as? TerminalRunPrompt }.first)

    prompt.run()
    prompt.run()

    XCTAssertEqual(engine.sessions.count, 1)
    XCTAssertEqual(engine.sessions[0].launch.program, ["./deploy.sh", "--now"])
    XCTAssertEqual(engine.sessions[0].launch.workingDirectory, "/work")
    XCTAssertTrue(prompt.isHidden)
    XCTAssertFalse(restored.isAwaitingRun)
    XCTAssertFalse(restored.canOpenTab)
  }

  /// Catches a description that forgets the command after a restore, so a second close and undo
  /// would lose it.
  func testARestoredProgramDescribesItselfWithTheSameCommand() throws {
    let host = RecordingHost()
    let restored = try restoreProgram(try programDescription(), engine: FakeEngine(), host: host)

    let again = try TerminalDescription.decode(restored.describe())

    XCTAssertEqual(again.mode, .program)
    XCTAssertEqual(again.command, "./deploy.sh --now")
  }

  /// Catches a stored command that cannot be read and still restores. An unclosed quote and a
  /// missing command are corrupt, and no session starts.
  func testAProgramDescriptionWithoutAUsableCommandIsRefused() throws {
    let engine = FakeEngine()

    for command in ["echo 'open", nil] {
      let description = try programDescription(command)

      XCTAssertThrowsError(try TerminalApplet(engine: engine, restoring: description)) { error in
        guard case .corrupt = error as? AppletRestoreError else {
          return XCTFail("expected a corrupt description, got \(error)")
        }
      }
    }

    XCTAssertTrue(engine.sessions.isEmpty)
  }

  /// Catches a restored shell that starts in a directory the description cannot vouch for. Each
  /// tab's reported directory wins when it exists. Otherwise its starting directory is next, and
  /// the home directory is last. A path that is not absolute, such as one from a remote login, is
  /// skipped even when something by that name exists.
  func testRestoredShellsFollowTheDirectoryRule() throws {
    let engine = FakeEngine()
    let description = try TerminalDescription(
      mode: .shell, command: nil,
      tabs: [
        .init(workingDirectory: "/reported", startDirectory: "/start"),
        .init(workingDirectory: "/gone", startDirectory: "/start"),
        .init(workingDirectory: "/gone", startDirectory: "/also-gone"),
        .init(workingDirectory: "me@host:/srv", startDirectory: nil),
      ]
    ).appletDescription()

    let existing: Set<String> = ["/reported", "/start", "me@host:/srv"]
    let restored = try TerminalApplet(
      engine: engine, restoring: description, directoryExists: { existing.contains($0) },
      home: "/home/pat")
    retained.append(restored)
    restored.start(origin: .user)

    XCTAssertEqual(
      engine.sessions.map { $0.launch.workingDirectory },
      ["/reported", "/start", "/home/pat", "/home/pat"])
    XCTAssertTrue(engine.sessions.allSatisfy { $0.launch.program == nil })
  }

  /// Catches a description that drops the starting directory, so the fallback has nothing to use.
  /// A tab launched in /start that has since reported /elsewhere describes both.
  func testTheDescriptionCarriesTheStartingDirectory() throws {
    let engine = FakeEngine()
    let applet = TerminalApplet(engine: engine, launch: .loginShell(workingDirectory: "/start"))
    retained.append(applet)
    applet.start(origin: .user)
    engine.sessions[0].onEvent?(.workingDirectoryChanged("/elsewhere"))

    let described = try TerminalDescription.decode(applet.describe())

    XCTAssertEqual(described.tabs[0].workingDirectory, "/elsewhere")
    XCTAssertEqual(described.tabs[0].startDirectory, "/start")
  }

  /// Catches a description from before the starting directory existed that no longer reads.
  func testADescriptionWithoutAStartingDirectoryStillReads() throws {
    let payload: JSONValue = .object([
      "mode": .string("shell"), "selectedTab": .number(0),
      "tabs": .array([.object(["workingDirectory": .string("/old")])]),
    ])

    let decoded = try TerminalDescription.decode(
      AppletDescription(type: "terminal", version: 1, payload: payload))

    XCTAssertEqual(decoded.tabs[0].workingDirectory, "/old")
    XCTAssertNil(decoded.tabs[0].startDirectory)
  }

  // MARK: Tabs

  private func tabBar(of applet: TerminalApplet) throws -> AppletTabBar {
    try XCTUnwrap(applet.view.subviews.compactMap { $0 as? AppletTabBar }.first)
  }

  /// Catches a tab bar that runs under the host's control badge. The badge covers the bar's
  /// trailing 24 points here, so the new-tab button must end before that edge.
  func testTheNewTabButtonStaysClearOfTheControlBadge() throws {
    let (applet, _, _, _) = makeApplet()
    applet.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    applet.openTab()

    applet.hostBadgeReachDidChange(24)
    applet.view.layoutSubtreeIfNeeded()

    let bar = try tabBar(of: applet)
    bar.layoutSubtreeIfNeeded()

    let button = try XCTUnwrap(bar.subviews.first { $0.accessibilityIdentifier() == "new-tab" })
    let end = bar.convert(button.frame, to: applet.view).maxX

    XCTAssertLessThanOrEqual(end, applet.view.bounds.width - 24)

    applet.hostBadgeReachDidChange(0)
    bar.layoutSubtreeIfNeeded()

    XCTAssertGreaterThan(bar.convert(button.frame, to: applet.view).maxX, end)
  }

  /// Catches a reselect that leaves the selected tab out of view. The user scrolls the selected tab
  /// off the bar, then selects it again from the keyboard or the palette. The tab is already
  /// selected, yet it comes back into view.
  func testReselectingTheSelectedTabScrollsItBackIntoView() throws {
    let (applet, _, _, _) = makeApplet()
    applet.view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)

    for _ in 0..<9 { applet.openTab() }

    applet.view.layoutSubtreeIfNeeded()

    let bar = try tabBar(of: applet)
    let last = applet.tabCount - 1

    XCTAssertEqual(applet.selectedTabIndex, last)
    XCTAssertTrue(TabBarProbe.isFullyInView(bar, tab: last))

    TabBarProbe.scroll(bar, by: -10_000)
    XCTAssertFalse(TabBarProbe.isFullyInView(bar, tab: last))

    applet.selectTab(at: last)
    applet.view.layoutSubtreeIfNeeded()

    XCTAssertTrue(TabBarProbe.isFullyInView(bar, tab: last))

    TabBarProbe.scroll(bar, by: -10_000)
    XCTAssertTrue(applet.selectTab(id: applet.publishedTabs.selected))
    applet.view.layoutSubtreeIfNeeded()

    XCTAssertTrue(TabBarProbe.isFullyInView(bar, tab: last), "the palette's reselect")
  }

  /// Catches a tab bar that shows for a single tab, or that stays after the second tab closes.
  func testTheTabBarShowsOnlyWhileThereIsMoreThanOneTab() async throws {
    let (applet, _, _, _) = makeApplet()
    let bar = try tabBar(of: applet)
    XCTAssertTrue(bar.isHidden)

    applet.openTab()
    XCTAssertFalse(bar.isHidden)

    let closed = await applet.closeCurrentTab()
    XCTAssertEqual(closed, .closed)
    XCTAssertTrue(bar.isHidden)
  }

  /// Catches a terminal tab marked as controlled. A terminal owns its input and takes neither
  /// commands nor sent content, so even a grant the host accepted marks no tab.
  func testATerminalTabNeverCarriesTheAuthorityMarker() throws {
    let (applet, _, _, _) = makeApplet()

    applet.openTab()
    applet.authorityDidChange(PaneAuthority(owners: [AppletCaller(grant: "connection 1")]))

    XCTAssertTrue(applet.publishedTabs.all.allSatisfy { $0.markers.isEmpty })

    let bar = try tabBar(of: applet)

    XCTAssertTrue(bar.subviews.allSatisfy { !($0 is AppletMarkerView) })
  }

  /// Catches a chip that lands on every tab, on the wrong one, or not in the bar. The host names the
  /// second tab, so only that tab publishes the chip, and the bar draws it there. A terminal still
  /// takes no authority marker. Dropping the tab from the host's value clears the chip, and the
  /// host hears of each change.
  func testTheTerminalPublishesTheChipOnTheTabTheHostNames() throws {
    let (applet, _, host, _) = makeApplet()

    applet.openTab()

    let tabs = applet.publishedTabs.all
    let before = host.tabChanges

    applet.authorityDidChange(PaneAuthority(controlling: [tabs[1].id: ["watch (PID 5)"]]))

    XCTAssertEqual(applet.publishedTabs.all[0].markers.isEmpty, true)
    XCTAssertEqual(applet.publishedTabs.all[1].markers[.chip]?.controllers, ["watch (PID 5)"])
    XCTAssertNil(applet.publishedTabs.all[1].markers[.authority])
    XCTAssertGreaterThan(host.tabChanges, before)

    let bar = try tabBar(of: applet)

    XCTAssertEqual(bar.descendants(ofType: AppletMarkerView.self).map(\.kind), [.chip])

    applet.authorityDidChange(.none)

    XCTAssertTrue(applet.publishedTabs.all.allSatisfy { $0.markers.isEmpty })
    XCTAssertTrue(bar.descendants(ofType: AppletMarkerView.self).isEmpty)
  }

  /// Catches a bar close that resolves its index only when the close runs. A tab closes before the
  /// queued close runs, so the clicked tab shifts down one place. The clicked tab closes, and its
  /// neighbor stays.
  func testABarCloseClosesTheClickedTabAfterTheTabsShift() async throws {
    let (applet, engine, _, _) = makeApplet()

    for _ in 0..<3 { applet.openTab() }

    let bar = try tabBar(of: applet)
    bar.onClose?(1)

    let first = await applet.closeTab(at: 0)
    XCTAssertEqual(first, .closed)

    var turns = 0

    while applet.tabCount > 2, turns < 1000 {
      await Task.yield()
      turns += 1
    }

    XCTAssertEqual(applet.tabCount, 2)
    XCTAssertEqual(engine.sessions.map(\.closed), [true, true, false, false])
  }

  /// Catches a new tab that reuses the first tab's session, so both would share one tty. Each tab
  /// gets its own session, and only the selected one is shown and visible.
  func testEachTabIsItsOwnSessionAndOnlyTheSelectedOneShows() {
    let (applet, engine, _, _) = makeApplet()

    applet.openTab()

    XCTAssertEqual(engine.sessions.count, 2)
    XCTAssertFalse(engine.sessions[0] === engine.sessions[1])
    XCTAssertTrue(engine.sessions[0].view.isHidden)
    XCTAssertFalse(engine.sessions[1].view.isHidden)
    XCTAssertFalse(engine.sessions[0].visible)
    XCTAssertTrue(engine.sessions[1].visible)
    XCTAssertEqual(applet.tabCount, 2)
    XCTAssertEqual(applet.selectedTabIndex, 1)

    applet.selectTab(at: 0)

    XCTAssertFalse(engine.sessions[0].view.isHidden)
    XCTAssertTrue(engine.sessions[1].view.isHidden)
    XCTAssertTrue(engine.sessions[0].visible)
    XCTAssertFalse(engine.sessions[1].visible)
  }

  /// Catches a tab switch whose work grows with the tab count. A switch touches the tab that was
  /// shown and the one that shows now, and no other session. A close or reopen of a tab touches no
  /// other tab's session either. It cannot prove the cost of the walk over the tab list itself.
  func testASwitchTouchesOnlyTheTabsThatChangeVisibility() async {
    let (applet, engine, _, _) = makeApplet()

    for _ in 0..<4 { applet.openTab() }

    applet.selectTab(at: 2)
    for session in engine.sessions { session.focusAndVisibilityCalls = 0 }

    applet.selectTab(at: 4)

    XCTAssertEqual(
      engine.sessions.map { $0.focusAndVisibilityCalls > 0 }, [false, false, true, false, true])
    XCTAssertEqual(engine.sessions.map(\.visible), [false, false, false, false, true])
    XCTAssertEqual(engine.sessions.map(\.view.isHidden), [true, true, true, true, false])

    for session in engine.sessions { session.focusAndVisibilityCalls = 0 }

    let closed = await applet.closeTab(at: 0)
    XCTAssertEqual(closed, .closed)

    XCTAssertEqual(engine.sessions[1...].map { $0.focusAndVisibilityCalls }, [0, 0, 0, 0])
    XCTAssertTrue(engine.sessions[4].visible)
    XCTAssertEqual(applet.selectedTabIndex, 3)
  }

  /// Catches a terminal that draws under the tab bar. The bar is 28 points. A 300 point applet gives
  /// 272 to the terminal while there are two tabs and all 300 with one. A hidden tab's terminal
  /// keeps the pane's size too, so its program never draws at a stale width.
  func testTheTerminalFillsWhatTheBarLeaves() async throws {
    let (applet, engine, _, _) = makeApplet()

    func frame(of session: FakeSession) -> NSRect {
      session.view.convert(session.view.bounds, to: applet.view)
    }

    applet.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    XCTAssertEqual(frame(of: engine.sessions[0]), NSRect(x: 0, y: 0, width: 400, height: 300))

    applet.openTab()
    XCTAssertEqual(frame(of: engine.sessions[1]), NSRect(x: 0, y: 28, width: 400, height: 272))
    XCTAssertEqual(frame(of: engine.sessions[0]), NSRect(x: 0, y: 28, width: 400, height: 272))

    applet.view.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
    XCTAssertEqual(frame(of: engine.sessions[1]), NSRect(x: 0, y: 28, width: 500, height: 172))
    XCTAssertEqual(frame(of: engine.sessions[0]), NSRect(x: 0, y: 28, width: 500, height: 172))

    let closed = await applet.closeCurrentTab()
    XCTAssertEqual(closed, .closed)
    XCTAssertEqual(frame(of: engine.sessions[0]), NSRect(x: 0, y: 0, width: 500, height: 200))
  }

  /// Catches a new tab that starts elsewhere than the tab it was opened from, or lands at the end.
  /// With tabs in /a and /b and the first selected, the new tab starts in /a and sits between them.
  func testANewTabStartsInTheSelectedTabsDirectoryAndSitsRightAfterIt() throws {
    let (applet, engine, _, first) = makeApplet()
    first.onEvent?(.workingDirectoryChanged("/a"))
    applet.openTab()
    engine.sessions[1].onEvent?(.workingDirectoryChanged("/b"))
    applet.selectTab(at: 0)

    applet.openTab()

    XCTAssertEqual(engine.sessions[2].launch.workingDirectory, "/a")
    XCTAssertNil(engine.sessions[2].launch.program)
    engine.sessions[2].onEvent?(.workingDirectoryChanged("/c"))

    let description = try TerminalDescription.decode(applet.describe())
    XCTAssertEqual(description.tabs.map(\.workingDirectory), ["/a", "/c", "/b"])
    XCTAssertEqual(description.selectedTab, 1)
  }

  /// Catches program mode that opens a second tab. The one tab is the one program.
  func testProgramModeRunsOneProgramAndOpensNoTab() throws {
    let engine = FakeEngine()
    let applet = try TerminalApplet(engine: engine, program: "vim -u NONE -N 'my file'")
    retained.append(applet)
    applet.start(origin: .user)

    XCTAssertFalse(applet.canOpenTab)
    applet.openTab()

    XCTAssertEqual(engine.sessions.count, 1)
    XCTAssertEqual(applet.tabCount, 1)
    XCTAssertEqual(engine.sessions[0].launch.program, ["vim", "-u", "NONE", "-N", "my file"])
    XCTAssertEqual(engine.sessions[0].launch.environment, identity)
    XCTAssertEqual(applet.title, "vim")
  }

  /// Catches a description that loses the program or the mode. It stays data: building the applet
  /// and describing it starts nothing beyond the one session the caller asked for.
  func testProgramDescriptionKeepsTheModeAndTheCommand() throws {
    let engine = FakeEngine()
    let applet = try TerminalApplet(engine: engine, program: "./deploy.sh --dry-run")

    let description = try TerminalDescription.decode(applet.describe())

    XCTAssertEqual(description.mode, .program)
    XCTAssertEqual(description.command, "./deploy.sh --dry-run")
    XCTAssertEqual(description.tabs.count, 1)
    XCTAssertTrue(engine.sessions.isEmpty)
  }

  /// Catches a command line that reaches a shell. Each of these would run something other than one
  /// program, or nothing at all, so the applet refuses it before any session starts.
  func testProgramLinesThatAreNotOneProgramAreRefusedBeforeAnythingStarts() {
    let engine = FakeEngine()
    let lines = ["", "   ", "ls | less", "echo 'oops", "rm -rf ~", "echo $HOME", "a; b", "x \\"]

    for line in lines {
      XCTAssertThrowsError(try TerminalApplet(engine: engine, program: line), "\(line)") {
        XCTAssertTrue($0 is ShellWordsError, "\(line) threw \($0)")
      }
    }

    XCTAssertTrue(engine.sessions.isEmpty)
  }

  /// Catches `program:` that builds its launch some way other than the program launch, which would
  /// drop the ssh fallback TERM. The rule itself is owned by the ShellWords and integration tests.
  func testProgramModeSshGetsAFallbackTerm() throws {
    let engine = FakeEngine()

    for (line, expected) in [
      ("ssh -F /dev/null host", "xterm-256color"),
      ("/usr/bin/ssh host", "xterm-256color"),
      ("ssh-keygen -l", nil),
      ("mosh host", nil),
    ] as [(String, String?)] {
      let applet = try TerminalApplet(engine: engine, program: line)
      retained.append(applet)
      applet.start(origin: .user)

      XCTAssertEqual(engine.sessions.last?.launch.environment["TERM"], expected, line)
    }
  }

  /// Catches a tab close that ends a program without asking. An idle tab closes at once. A tab
  /// running something asks, naming the tab by its title, and stays open when the user declines.
  func testClosingATabRunningSomethingAsksAndAnIdleTabDoesNot() async {
    let (applet, engine, host, _) = makeApplet()
    applet.openTab()
    engine.sessions[1].onEvent?(.titleChanged("vim notes.txt"))

    let idleClosed = await applet.closeCurrentTab()
    XCTAssertEqual(idleClosed, .closed)
    XCTAssertTrue(host.confirmations.isEmpty, "an idle prompt asked first")
    XCTAssertTrue(engine.sessions[1].closed)
    XCTAssertEqual(applet.tabCount, 1)

    applet.openTab()
    engine.sessions[2].onEvent?(.titleChanged("vim notes.txt"))
    engine.sessions[2].isRunningSomething = true
    host.answer = false

    let declined = await applet.closeCurrentTab()
    XCTAssertEqual(declined, .declined)
    XCTAssertEqual(host.confirmations.count, 1)
    XCTAssertTrue(
      host.confirmations.first?.detail.contains("\u{201C}vim notes.txt\u{201D}") ?? false)
    XCTAssertEqual(applet.tabCount, 2)
    XCTAssertFalse(engine.sessions[2].closed)

    host.answer = true
    let accepted = await applet.closeCurrentTab()
    XCTAssertEqual(accepted, .closed)
    XCTAssertEqual(host.confirmations.count, 2)
    XCTAssertEqual(applet.tabCount, 1)
    XCTAssertTrue(engine.sessions[2].closed)
  }

  /// Catches a second Cmd-W that stacks on an open tab question, and a decline that closes the pane
  /// once the tab count drops to one while the question is open. The second request is declined, and
  /// so is the answer, so neither the tab nor the pane goes.
  func testADeclinedQuestionKeepsTheTabEvenWhenTheCountDropsToOne() async {
    let (applet, engine, host, _) = makeApplet()
    applet.openTab()
    engine.sessions[1].isRunningSomething = true
    host.holdsQuestions = true

    let first = Task { await applet.closeCurrentTab() }
    var questions = host.questions.stream.makeAsyncIterator()
    await questions.next()
    XCTAssertNotNil(host.pendingAnswer)

    let second = await applet.closeCurrentTab()
    XCTAssertEqual(second, .declined)
    XCTAssertEqual(host.confirmations.count, 1)

    engine.sessions[0].onEvent?(.exited)
    XCTAssertEqual(applet.tabCount, 1)

    host.pendingAnswer?.resume(returning: false)
    let answer = await first.value

    XCTAssertEqual(answer, .declined)
    XCTAssertEqual(applet.tabCount, 1)
    XCTAssertFalse(host.exited)
  }

  /// Catches an agreed question that closes a tab which became the only one. There is no tab to
  /// close then, so the host's pane close asks again before ending the work.
  func testAnAgreedQuestionOnTheOnlyTabLeftAnswersNothingToClose() async {
    let (applet, engine, host, _) = makeApplet()
    applet.openTab()
    engine.sessions[1].isRunningSomething = true
    host.holdsQuestions = true

    let task = Task { await applet.closeCurrentTab() }
    var questions = host.questions.stream.makeAsyncIterator()
    await questions.next()
    engine.sessions[0].onEvent?(.exited)

    host.pendingAnswer?.resume(returning: true)

    let answer = await task.value
    XCTAssertEqual(answer, .nothingToClose)
    XCTAssertEqual(applet.tabCount, 1)
    XCTAssertFalse(engine.sessions[1].closed)
  }

  /// Catches the last tab closing as a tab. It is a pane close, which the host owns, so the applet
  /// refuses and leaves its session running, whatever that session is doing.
  func testTheLastTabIsNeverClosedAsATab() async {
    let (applet, _, host, session) = makeApplet()
    session.isRunningSomething = true

    let closed = await applet.closeCurrentTab()

    XCTAssertEqual(closed, .nothingToClose)
    XCTAssertTrue(host.confirmations.isEmpty)
    XCTAssertFalse(session.closed)
    XCTAssertEqual(applet.tabCount, 1)
  }

  /// Catches a pane that reads as idle while a background tab runs something, which would let a
  /// later close skip its dialog. The pane is running when any tab is, and the labels name them.
  func testAPaneIsRunningSomethingWhenAnyTabIs() {
    let (applet, engine, _, first) = makeApplet()
    first.onEvent?(.titleChanged("vim"))
    applet.openTab()
    XCTAssertFalse(applet.isRunningSomething)

    first.isRunningSomething = true

    XCTAssertEqual(applet.selectedTabIndex, 1)
    XCTAssertTrue(applet.isRunningSomething)
    XCTAssertEqual(applet.runningTabLabels, ["vim"])

    first.isRunningSomething = false
    engine.sessions[1].isRunningSomething = true
    engine.sessions[1].hasExited = true
    XCTAssertFalse(applet.isRunningSomething, "an exited tab still counts")
  }

  /// Catches status bar segments that follow the last event instead of the selected tab. Tab one
  /// is in /var/tmp with a failed command. Tab two starts in the same directory with no failure. A
  /// background tab's new directory still reaches the host, which saves the layout. It does not
  /// change the segments.
  func testSegmentsReflectTheSelectedTab() {
    let (applet, engine, host, first) = makeApplet()
    first.onEvent?(.workingDirectoryChanged("/var/tmp"))
    first.onEvent?(.commandFinished(exitCode: 2, duration: .seconds(1)))

    applet.openTab()
    XCTAssertEqual(applet.segments, [AppletSegment(symbolName: "folder", text: "tmp")])

    engine.sessions[1].onEvent?(.workingDirectoryChanged("/Users/x/proj"))
    XCTAssertEqual(applet.segments, [AppletSegment(symbolName: "folder", text: "proj")])

    let changes = host.changes
    first.onEvent?(.workingDirectoryChanged("/etc"))
    XCTAssertEqual(applet.segments, [AppletSegment(symbolName: "folder", text: "proj")])
    XCTAssertGreaterThan(host.changes, changes, "a background directory change was never saved")

    applet.selectTab(at: 0)
    XCTAssertEqual(
      applet.segments,
      [
        AppletSegment(symbolName: "folder", text: "etc"),
        AppletSegment(symbolName: "xmark.circle", text: "2", style: .error),
      ])
    XCTAssertGreaterThan(host.changes, changes)
  }

  /// Catches a pane that closes when one of several shells exits, or stays open when the last one
  /// does.
  func testAShellExitClosesItsTabAndOnlyTheLastClosesThePane() {
    let (applet, engine, host, first) = makeApplet()
    applet.openTab()
    applet.selectTab(at: 0)

    engine.sessions[1].hasExited = true
    engine.sessions[1].onEvent?(.exited)

    XCTAssertFalse(host.exited)
    XCTAssertEqual(applet.tabCount, 1)
    XCTAssertTrue(engine.sessions[1].closed)

    first.hasExited = true
    first.onEvent?(.exited)

    XCTAssertTrue(host.exited)
  }

  /// Catches a pane close that leaves a background tab's shell running.
  func testClosingTheAppletClosesEveryTab() {
    let (applet, engine, _, _) = makeApplet()
    applet.openTab()
    applet.openTab()

    applet.close()

    XCTAssertEqual(engine.sessions.count, 3)
    XCTAssertTrue(engine.sessions.allSatisfy { $0.closed })
  }

  /// Catches a description that drops tabs or the selection. Restoring starts a fresh shell in each
  /// tab's directory, runs no program, and selects the same tab.
  func testDescriptionKeepsEveryTabAndRestoresThem() throws {
    let (applet, engine, _, first) = makeApplet()
    first.onEvent?(.workingDirectoryChanged("/one"))
    applet.openTab()
    engine.sessions[1].onEvent?(.workingDirectoryChanged("/two"))
    applet.openTab()
    engine.sessions[2].onEvent?(.workingDirectoryChanged("/three"))
    applet.selectTab(at: 1)

    let description = applet.describe()
    let restored = try TerminalApplet(
      engine: engine, restoring: description, directoryExists: { _ in true })
    retained.append(restored)
    restored.start(origin: .user)

    XCTAssertEqual(engine.sessions.count, 6)
    XCTAssertEqual(
      engine.sessions[3...].map { $0.launch.workingDirectory }, ["/one", "/two", "/three"])
    XCTAssertTrue(engine.sessions[3...].allSatisfy { $0.launch.program == nil })
    XCTAssertEqual(restored.tabCount, 3)
    XCTAssertEqual(restored.selectedTabIndex, 1)
  }

  // MARK: Published tabs

  /// Catches a tab list that omits background tabs, or whose directory comes from the selected tab.
  /// Each tab reports its own title and the directory its own shell reported.
  func testEveryTabPublishesItsOwnTitleAndDirectory() {
    let (applet, engine, _, first) = makeApplet()
    first.onEvent?(.titleChanged("vim notes"))
    first.onEvent?(.workingDirectoryChanged("/a"))
    applet.openTab()
    engine.sessions[1].onEvent?(.workingDirectoryChanged("/b"))

    let list = applet.publishedTabs

    XCTAssertEqual(list.all.map(\.title), ["vim notes", "Terminal"])
    XCTAssertEqual(list.all.map(\.details), [["/a"], ["/b"]])
    XCTAssertEqual(list.selected, list.rest[0].id)
    XCTAssertEqual(Set(list.all.map(\.id)).count, 2)
  }

  /// Catches a change signal that fires only for the selected tab, as the title signal does. A
  /// program in a background tab that retitles itself must still reach the palette.
  func testABackgroundTabsTitleAndDirectoryChangesSignal() {
    let (applet, engine, host, first) = makeApplet()
    applet.openTab()
    host.tabChanges = 0
    host.changes = 0

    first.onEvent?(.titleChanged("htop"))
    XCTAssertEqual(host.tabChanges, 1)

    first.onEvent?(.workingDirectoryChanged("/var"))
    XCTAssertEqual(host.tabChanges, 2)

    XCTAssertEqual(applet.publishedTabs.first.title, "htop")
    XCTAssertEqual(engine.sessions.count, 2)
  }

  /// Catches opening, selecting, or closing a tab that leaves the palette's list stale.
  func testOpeningSelectingAndClosingATabSignal() async {
    let (applet, _, host, _) = makeApplet()
    host.tabChanges = 0

    applet.openTab()
    XCTAssertEqual(host.tabChanges, 1)

    applet.selectTab(at: 0)
    XCTAssertEqual(host.tabChanges, 2)

    _ = await applet.closeCurrentTab()
    XCTAssertEqual(host.tabChanges, 3)
    XCTAssertEqual(applet.publishedTabs.all.count, 1)
  }

  /// Catches selection by ID that falls back to an index, which would pick another tab after a
  /// tab before it closed. A closed tab's ID selects nothing.
  func testSelectingByIDFollowsTheTabAndAClosedIDIsGone() async {
    let (applet, _, _, _) = makeApplet()
    applet.openTab()
    applet.openTab()

    let ids = applet.publishedTabs.all.map(\.id)
    XCTAssertEqual(ids.count, 3)

    XCTAssertTrue(applet.selectTab(id: ids[0]))
    XCTAssertEqual(applet.publishedTabs.selected, ids[0])

    XCTAssertTrue(applet.selectTab(id: ids[2]))
    XCTAssertEqual(applet.publishedTabs.selected, ids[2])

    _ = await applet.closeCurrentTab()
    XCTAssertFalse(applet.selectTab(id: ids[2]), "a closed tab's ID resolved")
    XCTAssertEqual(applet.publishedTabs.all.map(\.id), [ids[0], ids[1]])
  }

  /// Catches tab IDs that survive a save. A restored tab is a new tab, so the ID of the tab it was
  /// saved from resolves to nothing.
  func testARestoredTabGetsANewID() throws {
    let (applet, engine, _, _) = makeApplet()
    let old = applet.publishedTabs.first.id

    let restored = try TerminalApplet(
      engine: engine, restoring: applet.describe(), directoryExists: { _ in true })
    retained.append(restored)

    XCTAssertNotEqual(restored.publishedTabs.first.id, old)
    XCTAssertFalse(restored.selectTab(id: old))
  }
}

extension NSView {
  fileprivate func descendants<T: NSView>(ofType type: T.Type) -> [T] {
    subviews.flatMap { ($0 as? T).map { [$0] } ?? [] }
      + subviews.flatMap { $0.descendants(ofType: type) }
  }
}
