import AppKit
import AppletKit
import FileRouting
import PaneModel
import ScriptHost
import StatusKit
import XCTest

@testable import WindowKit

/// Stands in for the system's process watcher, so a test ends a sender by hand.
/// The task a watcher starts to report its sender's end, so a test can wait for that report.
@MainActor
private final class EndingBox {
  var task: Task<Void, Never>?
}

@MainActor
private final class WatchLog {
  var ends: [Int32: [@MainActor () -> Void]] = [:]
  var watched: [Int32] = []
  var cancelled = 0

  var watcher: SenderWatcher {
    { [self] pid, onEnd in
      watched.append(pid)
      ends[pid, default: []].append(onEnd)

      return { [self] in cancelled += 1 }
    }
  }

  func end(_ pid: Int32) {
    for onEnd in ends[pid] ?? [] { onEnd() }
  }
}

private func app(_ pid: Int32, version: Int32 = 1, identifier: String = "com.example.launcher")
  -> SenderIdentity
{
  SenderIdentity(
    pid: pid, pidVersion: version, signingIdentifier: identifier, teamIdentifier: "TEAM123",
    isPlatformBinary: false, isAppleAnchored: false, opener: nil)
}

private let goBetween = SenderIdentity(
  pid: 300, pidVersion: 1, signingIdentifier: "com.apple.open", teamIdentifier: nil,
  isPlatformBinary: true, isAppleAnchored: true, opener: nil)

/// An open another program sends through Launch Services, through the real coordinator, the
/// permission queue, the router, and windows with fixture applets. They prove what the question
/// says, that no path is looked at before the user allows it, that an allowed open takes focus,
/// and that a session grant lives and dies with its sender. They cannot prove the system's own
/// sender lookup or its process watcher, which need a live process and are covered by hand.
@MainActor
final class LaunchOpenApprovalTests: XCTestCase {
  private var fixture: RoutingFixture!
  private var spy: PathSpy!
  private var watches: WatchLog!
  private var coordinator: LaunchOpenCoordinator!
  private var clock: TimeInterval = 0

  override func setUp() async throws {
    spy = PathSpy()
    watches = WatchLog()
    clock = 0
    fixture = try RoutingFixture(pathKind: spy.reader)

    coordinator = LaunchOpenCoordinator(
      windows: fixture.windows, opener: fixture.opener, now: { [unowned self] in clock },
      watchSender: watches.watcher, openFallbackWindow: {})
  }

  override func tearDown() async throws {
    fixture.cleanUp()
  }

  private var requests: PermissionRequests { fixture.windows.permissionRequests }

  /// Waits until the coordinator's drain ends. Routing runs off the main thread, so yields alone
  /// can return before it lands.
  private func settle() async {
    await coordinator.idle()
  }

  private func messages(_ controller: MainWindowController) -> [String] {
    controller.statusCenter.history.map(\.text)
  }

  private func running() throws -> RouteAnchor {
    let anchor = try fixture.anchoredWindow()

    coordinator.launchFinished()

    return anchor
  }

  private func row() throws -> PermissionRequests.Row {
    try XCTUnwrap(requests.rows.first)
  }

  // MARK: The question

  /// Catches a question that says "each" of one path, or puts the placement beside the sender's
  /// identity. One path lands in a new pane, and several each land in their own.
  func testTheQuestionPlacesOnePathAndSeveralPathsInTheirOwnWords() {
    let one = LaunchOpenApprovalText.detail(
      paths: ["/a"], skipped: 0, sender: app(200), onceOnly: false)
    let several = LaunchOpenApprovalText.detail(
      paths: ["/a", "/b"], skipped: 0, sender: nil, onceOnly: true)

    XCTAssertTrue(
      one.hasPrefix(
        "The program \u{201C}com.example.launcher (team TEAM123)\u{201D} asks to open this path in "
          + "a new pane. A new window opens when a batch or a lack of room calls for one:\n  /a\n"
          + "uniterm has not looked at it yet."), one)
    XCTAssertTrue(
      several.hasPrefix(
        "An unknown program asks to open these 2 paths, each in a new pane. A new window opens "
          + "when a batch or a lack of room calls for one:\n  /a\n  /b\nIt may have quit already, "
          + "and uniterm cannot tell which program it was. uniterm has not looked at them yet."),
      several)
  }

  /// Catches a question that names a sender from anything but its verified signing information,
  /// that leaves a path out, or that offers the wrong answers. The row names the signing identifier
  /// and the team, lists the path in full with the count, and offers the session answer to an app.
  func testAThirdPartyOpenWaitsAndNamesTheSenderAndEveryPath() async throws {
    let anchor = try running()
    let file = try fixture.textFile("a.txt")

    coordinator.receive([file], from: app(200))
    await settle()

    let row = try row()

    XCTAssertEqual(row.subject, "com.example.launcher (team TEAM123)")
    XCTAssertEqual(row.title, "Open a file or folder")
    XCTAssertTrue(row.detail.contains(file.path))
    XCTAssertTrue(row.detail.contains("this path"))
    XCTAssertTrue(row.detail.contains("new window"), "the question hides that a window may open")
    XCTAssertFalse(row.onceOnly)
    XCTAssertEqual(row.sessionTitle, "Allow Until This App Quits")
    XCTAssertTrue(row.detail.contains("until it quits"))
    XCTAssertEqual(spy.looked, [], "a pending open looked at a path")
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
    XCTAssertFalse(coordinator.hasPending, "a question that waits for the user is not an open")
  }

  /// Catches a program that hides a path in the question. A newline and a right-to-left override in
  /// a name are written out, so the question cannot fake a line or reorder a path.
  func testControlAndDirectionCharactersInAPathAreWrittenOut() async throws {
    _ = try running()

    let hostile = URL(fileURLWithPath: "/tmp/a\nb\u{202E}c.txt")

    coordinator.receive([hostile], from: app(200))
    await settle()

    let detail = try row().detail

    XCTAssertFalse(detail.contains("\n  b"))
    XCTAssertFalse(detail.contains("\u{202E}"))
    XCTAssertTrue(detail.contains("\\u{A}"))
    XCTAssertTrue(detail.contains("\\u{202E}"))
  }

  /// Catches an unknown sender that is named, or offered a session answer. The question says the
  /// sender is unknown, lists the path in full, and is once-only.
  func testAnUnidentifiedSenderIsSaidToBeUnknownAndGetsAllowOnceOnly() async throws {
    _ = try running()

    let file = try fixture.textFile("a.txt")

    coordinator.receive([file], from: nil)
    await settle()

    let row = try row()

    XCTAssertEqual(row.subject, "an unknown program")
    XCTAssertTrue(row.detail.contains("unknown"))
    XCTAssertTrue(row.detail.contains(file.path))
    XCTAssertTrue(row.onceOnly)
    XCTAssertTrue(watches.watched.isEmpty, "a sender nobody can name has nothing to watch")
  }

  /// Catches a go-between that is offered a session grant. `/usr/bin/open` is Apple-signed, so it
  /// is once-only. A session answer opens this event and grants nothing, so the next event asks.
  func testAGoBetweenGetsAllowOnceOnlyAndASessionAnswerGrantsNothing() async throws {
    let anchor = try running()

    coordinator.receive([try fixture.textFile("a.txt")], from: goBetween)
    await settle()

    let first = try row()

    XCTAssertTrue(first.onceOnly)
    XCTAssertTrue(first.detail.contains("Apple program"))
    XCTAssertEqual(first.subject, "com.apple.open (Apple)")

    requests.decide(first.id, .allowForSession)
    await settle()

    XCTAssertEqual(anchor.controller.paneIDs.count, 2)

    coordinator.receive([try fixture.textFile("b.txt")], from: goBetween)
    await settle()

    XCTAssertEqual(requests.rows.count, 1, "a go-between was asked once and remembered")
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
  }

  /// Catches a batch that raises more than one prompt, or asks again for its count. Twelve files
  /// are one row that lists all of them with the count. Allowing it opens every one in one new
  /// window, and the router's own question above ten files is never asked.
  func testABatchIsOneQuestionThatNamesEveryFileAndCoversTheCount() async throws {
    let anchor = try running()
    let files = try (0..<12).map { try fixture.textFile("f\($0).txt") }

    coordinator.receive(files, from: app(200))
    await settle()

    let row = try row()

    XCTAssertEqual(requests.rows.count, 1)
    XCTAssertEqual(row.title, "Open 12 files or folders")
    XCTAssertTrue(row.detail.contains("these 12 paths"))

    for file in files { XCTAssertTrue(row.detail.contains(file.path), file.path) }

    XCTAssertEqual(spy.looked, [])

    requests.decide(row.id, .allowOnce)
    await settle()

    XCTAssertTrue(fixture.box.asked.isEmpty, "the router asked a second question")
    XCTAssertEqual(fixture.box.entries.count, 12)
    XCTAssertEqual(fixture.windows.controllers.count, 2)
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
  }

  /// Catches an event with nothing to open that is dropped with no word. No question is asked, and
  /// the user is told.
  func testAnEventWithNoLocalFileSaysSoAndAsksNothing() async throws {
    let anchor = try running()

    coordinator.receive([URL(string: "https://example.com")!], from: app(200))
    await settle()

    XCTAssertTrue(requests.rows.isEmpty)
    XCTAssertTrue(messages(anchor.controller).contains { $0.contains("none of them is a local") })
  }

  // MARK: Allowed

  /// Catches an approved program's open that leaves the keyboard behind. A program's open is the
  /// user's open, so it lands beside the focused pane, the new pane takes the focus, and the file
  /// is looked at only now.
  ///
  /// This is the placement contract through the Launch Services authority: a sender's own
  /// identity is asked about, and the focused pane of the key window is the anchor. The
  /// `uniterm open` test of the same contract isolates the terminal-session anchor.
  func testAnAllowedOpenLandsBesideTheFocusedPaneAndTakesFocus() async throws {
    let anchor = try running()
    let original = anchor.controller.focusedPane
    let file = try fixture.textFile("a.txt")

    coordinator.receive([file], from: app(200))
    await settle()

    requests.decide(try row().id, .allowOnce)
    await settle()

    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
    let created = try XCTUnwrap(anchor.controller.paneIDs.first { $0 != original })
    XCTAssertEqual(anchor.controller.focusedPane, created)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(fixture.box.entries.map(\.file), [file])
    XCTAssertEqual(spy.looked, [file.path])
    XCTAssertTrue(requests.rows.isEmpty)

    coordinator.receive([try fixture.textFile("b.txt")], from: app(200))
    await settle()

    XCTAssertEqual(requests.rows.count, 1, "Allow once was remembered")
  }

  // MARK: Session grants

  /// Catches a session grant that does not cover later events, or outlives its sender. The grant
  /// covers a later event with no question. Once the sender exits, the next event asks again, and
  /// the watch on it was stopped.
  func testASessionGrantCoversTheSendersLaterOpensUntilItExits() async throws {
    let anchor = try running()

    coordinator.receive([try fixture.textFile("a.txt")], from: app(200))
    await settle()
    requests.decide(try row().id, .allowForSession)
    await settle()

    XCTAssertEqual(watches.watched, [200])
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)

    coordinator.receive([try fixture.textFile("b.txt")], from: app(200))
    await settle()

    XCTAssertTrue(requests.rows.isEmpty, "a granted sender was asked again")
    XCTAssertEqual(anchor.controller.paneIDs.count, 3)

    watches.end(200)
    XCTAssertEqual(watches.cancelled, 1)

    coordinator.receive([try fixture.textFile("c.txt")], from: app(200))
    await settle()

    XCTAssertEqual(requests.rows.count, 1, "a grant outlived its sender")
    XCTAssertEqual(anchor.controller.paneIDs.count, 3)
  }

  /// Catches a reused process ID that inherits a grant. The same ID with another version is
  /// another sender, so it is asked, and ending the first never touches it.
  func testAReusedPIDWithANewVersionNeverInheritsTheGrant() async throws {
    let anchor = try running()

    coordinator.receive([try fixture.textFile("a.txt")], from: app(200, version: 1))
    await settle()
    requests.decide(try row().id, .allowForSession)
    await settle()

    XCTAssertEqual(anchor.controller.paneIDs.count, 2)

    coordinator.receive([try fixture.textFile("b.txt")], from: app(200, version: 2))
    await settle()

    XCTAssertEqual(requests.rows.count, 1)
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)

    let second = try row()

    XCTAssertEqual(second.key.requester, .launchSender(pid: 200, pidVersion: 2))
  }

  /// Catches a grant that one sender's answer gives to another. A grant for one app never covers a
  /// different app.
  func testAGrantCoversOnlyItsOwnSender() async throws {
    let anchor = try running()

    coordinator.receive([try fixture.textFile("a.txt")], from: app(200))
    await settle()
    requests.decide(try row().id, .allowForSession)
    await settle()

    coordinator.receive(
      [try fixture.textFile("b.txt")], from: app(201, identifier: "com.example.b"))
    await settle()

    XCTAssertEqual(requests.rows.count, 1)
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
  }

  // MARK: Nothing without the user

  /// Catches an open that touches a path after a Deny. Nothing is looked at or opened, the user is
  /// told, and a denial of a once-only event is not remembered.
  func testADeniedOpenTouchesNothingSaysSoAndIsNotRememberedForAnUnknownSender() async throws {
    let anchor = try running()

    coordinator.receive([try fixture.textFile("a.txt")], from: nil)
    await settle()
    requests.decide(try row().id, .deny)
    await settle()

    XCTAssertEqual(spy.looked, [])
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
    XCTAssertTrue(messages(anchor.controller).contains { $0.contains("you denied it") })
    XCTAssertTrue(requests.denials.isEmpty, "a denial outlived its one event")

    coordinator.receive([try fixture.textFile("b.txt")], from: nil)
    await settle()

    XCTAssertEqual(requests.rows.count, 1, "the next unknown sender was refused unasked")
  }

  /// Catches an app that asks again at once after a Deny. The denial holds for as long as the app
  /// runs, so its next event is refused with the message and no question. Once it exits, it asks.
  func testAnAppsDenialLastsUntilItExits() async throws {
    let anchor = try running()

    coordinator.receive([try fixture.textFile("a.txt")], from: app(200))
    await settle()
    requests.decide(try row().id, .deny)
    await settle()

    clock = 100
    coordinator.receive([try fixture.textFile("b.txt")], from: app(200))
    await settle()

    XCTAssertTrue(requests.rows.isEmpty)
    XCTAssertEqual(spy.looked, [])
    XCTAssertEqual(messages(anchor.controller).filter { $0.contains("you denied it") }.count, 2)

    watches.end(200)

    coordinator.receive([try fixture.textFile("c.txt")], from: app(200))
    await settle()

    XCTAssertEqual(requests.rows.count, 1)
    XCTAssertTrue(requests.denials.isEmpty)
  }

  /// Catches a pending open that survives its sender. The app exits while the question waits. The
  /// row goes, nothing is looked at, and the user is told it quit.
  func testASenderThatExitsWhileTheQuestionWaitsWithdrawsItAndTouchesNothing() async throws {
    let anchor = try running()

    coordinator.receive([try fixture.textFile("a.txt")], from: app(200))
    await settle()

    XCTAssertEqual(requests.rows.count, 1)

    watches.end(200)
    await settle()

    XCTAssertTrue(requests.rows.isEmpty)
    XCTAssertEqual(spy.looked, [])
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
    XCTAssertTrue(messages(anchor.controller).contains { $0.contains("quit before you answered") })
  }

  /// Catches a sender that had exited before its question was asked, and gets its files opened. The
  /// system's watcher reports a process that is already gone at once, as this one does.
  func testASenderThatAlreadyExitedTouchesNothing() async throws {
    let anchor = try running()

    let ending = EndingBox()

    let exited: SenderWatcher = { _, onEnd in
      ending.task = Task { @MainActor in onEnd() }

      return {}
    }

    coordinator = LaunchOpenCoordinator(
      windows: fixture.windows, opener: fixture.opener, watchSender: exited, openFallbackWindow: {})
    coordinator.launchFinished()

    coordinator.receive([try fixture.textFile("a.txt")], from: app(200))
    await ending.task?.value
    await settle()

    XCTAssertTrue(requests.rows.isEmpty)
    XCTAssertEqual(spy.looked, [])
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
  }

  /// Catches a flood of events that fills the question queue, or leaves no room for anyone else.
  /// Once-only events bound together. Past the bound the event is refused with the coalesced
  /// message, the waiting rows stay, a loop of them posts one message, and another requester can
  /// still ask.
  func testAnOpenWithNoRoomInThePendingIndicatorIsRefusedWithOneMessage() async throws {
    let anchor = try running()
    let file = try fixture.textFile("a.txt")

    for _ in 0..<PermissionRequests.maxRowsPerRequester {
      coordinator.receive([file], from: nil)
    }

    XCTAssertEqual(requests.rows.count, PermissionRequests.maxRowsPerRequester)
    XCTAssertTrue(messages(anchor.controller).isEmpty)

    for _ in 0..<1000 {
      coordinator.receive([file], from: goBetween)
    }

    await settle()

    XCTAssertEqual(requests.rows.count, PermissionRequests.maxRowsPerRequester)
    XCTAssertEqual(
      messages(anchor.controller).filter { $0.contains("too many questions") }.count, 1)
    XCTAssertEqual(spy.looked, [])

    let other = requests.ask(
      PermissionRequests.Key(requester: .connection(1), power: "clipboard-read"),
      subject: "synthetic", title: "Read the clipboard", detail: "synthetic",
      sessionTitle: "Allow for This Run"
    ) { _ in }

    XCTAssertEqual(other, .waiting, "a flood of events left no room for another requester")
  }

  // MARK: Cold launch

  /// Catches a pending question that holds the launch back, or an approval that opens before
  /// restore ends. A question does not count as pending, so the layout opens its default window.
  /// An allowed open then waits for the launch to finish and opens beside that window's pane.
  func testAQuestionAtColdLaunchLetsTheDefaultWindowOpenAndTheAllowedOpenWaits() async throws {
    let file = try fixture.textFile("a.txt")

    coordinator.receive([file], from: app(200))
    await settle()

    XCTAssertFalse(coordinator.hasPending)
    XCTAssertEqual(requests.rows.count, 1)

    let anchor = try fixture.anchoredWindow()

    requests.decide(try row().id, .allowOnce)
    await settle()

    XCTAssertTrue(coordinator.hasPending, "an allowed open does not wait for restore")
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
    XCTAssertEqual(spy.looked, [])

    coordinator.launchFinished()
    await settle()

    XCTAssertFalse(coordinator.hasPending)
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
    XCTAssertEqual(spy.looked, [file.path])
  }
}
