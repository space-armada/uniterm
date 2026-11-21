import AppKit
import AppletFixtures
import AppletKit
import ControllerPackage
import ExecDriver
import ExecTestSupport
import LayoutKit
import PaneModel
import ScriptHost
import ScriptWire
import XCTest

@testable import WindowKit

/// The window side of consent: a driver's typed clipboard requests, a terminal's OSC 52 question
/// in the Pending Requests panel, host launches a controller's run covers, and what remembered
/// trust never does to a pane. Real windows, a real driver process, and a controller authority
/// that stands in for the script host's view of live runs.
@MainActor
final class ConsentWindowTests: XCTestCase {
  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func waitUntil(
    _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async throws {
    try await waitOrFail(what, timeout: timeout, file: file, line: line, condition)
  }

  private func row(_ fixture: ExecPaneFixture, _ title: String) -> PermissionRequests.Row? {
    fixture.windows.permissionRequests.rows.first { $0.title == title }
  }

  // MARK: A driver's typed clipboard requests

  /// Catches a driver's read that rides on its write's approval, a denied read that sends text,
  /// and a session answer that outlives the run. Reads and writes ask apart, each is checked at the
  /// clipboard, and a new run starts with neither.
  func testADriversReadsAndWritesAskApartAndEndWithItsRun() async throws {
    let fixture = try makeFixture()
    let clipboard = MemoryClipboard(text: "synthetic clipboard")

    fixture.windows.clipboard = clipboard

    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let messages = [
      #"{"type":"clipboard-write","text":"from the driver"}"#, #"{"type":"clipboard-read"}"#,
    ]

    try controller.declareExecDriver(fixture.declaration("script", messages), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    let writeTitle = ControllerPermissionText.write
    let readTitle = ControllerPermissionText.read

    try await waitUntil("both requests wait") {
      self.row(fixture, writeTitle) != nil && self.row(fixture, readTitle) != nil
    }

    XCTAssertEqual(row(fixture, writeTitle)?.sessionTitle, "Allow for This Run")
    XCTAssertEqual(clipboard.writes, 0, "a write reached the clipboard before the user answered")

    fixture.windows.permissionRequests.decide(
      try XCTUnwrap(row(fixture, writeTitle)?.id), .allowForSession)
    fixture.windows.permissionRequests.decide(try XCTUnwrap(row(fixture, readTitle)?.id), .deny)

    XCTAssertEqual(clipboard.text, "from the driver")
    XCTAssertEqual(clipboard.reads, 0, "a denied read reached the clipboard")
    XCTAssertEqual(controller.execAttachments[pane]?.clipboardGrants, [.clipboardWrite])

    controller.execAttachments[pane]?.channel?.close()

    try await waitUntil("the run ends") {
      if case .ended? = controller.execAttachments[pane]?.state { return true }
      return false
    }

    XCTAssertEqual(controller.execAttachments[pane]?.clipboardGrants, [])
    XCTAssertTrue(fixture.windows.permissionRequests.denials.isEmpty, "a run's denial outlived it")
  }

  /// Catches a driver that owns no group and keeps its Allow for This Run clipboard grant with no
  /// way to take it back. Revoke Controller on the driver's own pane is offered once the run holds
  /// a grant, and it ends the grant. It cannot prove the pane's chrome shows the item.
  func testRevokeOnAGrouplessDriversPaneEndsItsClipboardGrant() async throws {
    let fixture = try makeFixture()
    let clipboard = MemoryClipboard(text: "synthetic clipboard")

    fixture.windows.clipboard = clipboard

    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let message = #"{"type":"clipboard-write","text":"from the driver"}"#

    try controller.declareExecDriver(fixture.declaration("script", [message]), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    let writeTitle = ControllerPermissionText.write

    try await waitUntil("the write waits") { self.row(fixture, writeTitle) != nil }

    XCTAssertFalse(
      controller.canRevokeController(pane), "a question nobody answered offered a revoke")

    fixture.windows.permissionRequests.decide(
      try XCTUnwrap(row(fixture, writeTitle)?.id), .allowForSession)

    XCTAssertEqual(controller.execAttachments[pane]?.clipboardGrants, [.clipboardWrite])
    XCTAssertTrue(controller.paneArea.tree.groups.isEmpty, "the driver owns a group")
    XCTAssertTrue(controller.canRevokeController(pane), "the driver's grant has no revoke")

    controller.revokeController(pane)

    XCTAssertEqual(controller.execAttachments[pane]?.clipboardGrants, [])
    XCTAssertEqual(controller.execAttachments[pane]?.revoked, true)
    XCTAssertFalse(controller.canRevokeController(pane), "a revoke is offered twice")
  }

  /// Catches a row that keeps showing the first of two waiting writes after Allow once released
  /// it, so the next Allow once writes text the user never saw. The row always shows the oldest
  /// operation that waits, which is the one Allow once releases.
  func testARowShowsTheWriteAllowOnceReleasesNext() async throws {
    let fixture = try makeFixture()
    let clipboard = MemoryClipboard(text: "synthetic clipboard")

    fixture.windows.clipboard = clipboard

    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let requests = fixture.windows.permissionRequests

    try controller.declareExecDriver(
      fixture.declaration(
        "script",
        [
          #"{"type":"clipboard-write","text":"synthetic first"}"#,
          #"{"type":"clipboard-write","text":"synthetic second"}"#,
        ]), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    try await waitUntil("both writes wait in one row") { requests.rows.first?.waiting == 2 }

    XCTAssertEqual(requests.rows.count, 1)
    XCTAssertTrue(requests.rows[0].detail.contains("synthetic first"), requests.rows[0].detail)
    XCTAssertFalse(requests.rows[0].detail.contains("synthetic second"), requests.rows[0].detail)

    requests.decide(requests.rows[0].id, .allowOnce)

    XCTAssertEqual(clipboard.text, "synthetic first")

    let next = try XCTUnwrap(requests.rows.first)

    XCTAssertTrue(next.detail.contains("synthetic second"), "the row hides the next write")

    requests.decide(next.id, .allowOnce)

    XCTAssertEqual(clipboard.text, "synthetic second")
  }

  /// Catches a waiting driver request that outlives its run: the pane closing answers it, and
  /// nothing reaches the clipboard.
  func testClosingADriversPaneDropsItsWaitingRequest() async throws {
    let fixture = try makeFixture()
    let clipboard = MemoryClipboard(text: "synthetic clipboard")

    fixture.windows.clipboard = clipboard

    let controller = try fixture.openWindow()

    controller.openPane(.terminalShell, axis: .row)

    let pane = controller.focusedPane

    try controller.declareExecDriver(
      fixture.declaration("script", [#"{"type":"clipboard-read"}"#]), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    try await waitUntil("the read waits") { !fixture.windows.permissionRequests.rows.isEmpty }

    controller.closePane(pane, appletEnded: false)

    XCTAssertTrue(fixture.windows.permissionRequests.rows.isEmpty)
    XCTAssertEqual(clipboard.reads, 0)
  }

  // MARK: A terminal's OSC 52 question

  /// Catches a program that floods the user with OSC 52 questions, a session answer that claims a
  /// controller's identity, and a denial that asks again before the user's local retry. One
  /// question waits however many requests arrive. After a denial, requests of that scope are
  /// refused with no question until Ask Again.
  func testATerminalsQuestionsShareOneRowAndADenialHoldsUntilAskAgain() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let applet = try XCTUnwrap(controller.paneArea.applet(for: controller.focusedPane))
    let requests = fixture.windows.permissionRequests
    let request = AppletPermissionRequest(
      title: "Allow a program to replace your clipboard?", detail: "synthetic",
      subject: "tab 1", sessionTitle: "Allow Writes in This Tab", scope: "tab 1 write generation 3")

    let answers = (0..<5).map { _ in
      Task { await controller.applet(applet, askPermission: request) }
    }

    try await waitUntil("the questions wait") { requests.rows.first?.waiting == 5 }

    XCTAssertEqual(requests.rows.count, 1)
    XCTAssertEqual(requests.rows.first?.sessionTitle, "Allow Writes in This Tab")
    XCTAssertTrue(requests.rows.first?.subject.hasPrefix("Programs in") == true)

    requests.decide(try XCTUnwrap(requests.rows.first?.id), .allowOnce)

    XCTAssertEqual(requests.rows.first?.waiting, 4, "Allow once answered more than one request")

    requests.decide(try XCTUnwrap(requests.rows.first?.id), .deny)

    var results: [AppletPermissionAnswer] = []

    for answer in answers {
      results.append(try await bounded("each question is answered") { await answer.value })
    }

    XCTAssertEqual(results.filter { $0 == .allowOnce }.count, 1)
    XCTAssertEqual(results.filter { $0 == .deny }.count, 4)

    // A denied scope must answer at once. Should it ask instead, the question is answered here so
    // the test fails rather than waits.
    let laterDone = AnsweredFlag()
    let later = Task {
      let answer = await controller.applet(applet, askPermission: request)

      laterDone.value = true

      return answer
    }

    try await waitUntil("the denied request is answered or asks", timeout: 5) {
      !requests.rows.isEmpty || laterDone.value
    }

    XCTAssertTrue(requests.rows.isEmpty, "a denied scope asked again")

    for row in requests.rows { requests.decide(row.id, .allowOnce) }

    let laterAnswer = try await bounded("the denied request is answered") { await later.value }

    XCTAssertEqual(laterAnswer, .deny)

    requests.askAgain(try XCTUnwrap(requests.denials.first?.id))

    let retried = Task { await controller.applet(applet, askPermission: request) }

    try await waitUntil("the retry asks") { !requests.rows.isEmpty }
    requests.decide(try XCTUnwrap(requests.rows.first?.id), .allowForSession)

    let retriedAnswer = try await bounded("the retry is answered") { await retried.value }

    XCTAssertEqual(retriedAnswer, .allowForSession)
  }

  /// Catches one program filling every row of the panel, so no other program can ask. Each
  /// question with no scope asks on its own, and one requester holds at most a bounded share of
  /// the rows. A question past it is refused at once.
  func testOneRequesterCannotFillThePanel() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let applet = try XCTUnwrap(controller.paneArea.applet(for: controller.focusedPane))
    let requests = fixture.windows.permissionRequests
    let limit = PermissionRequests.maxRowsPerRequester
    let request = AppletPermissionRequest(
      title: "Allow a program to read your clipboard?", detail: "synthetic",
      subject: "tab 1", sessionTitle: "Allow Reads in This Tab")

    let answers = (0..<limit).map { _ in
      Task { await controller.applet(applet, askPermission: request) }
    }

    try await waitUntil("the questions wait") { requests.rows.count == limit }

    let refused = try await bounded("a question past the bound is answered") {
      await controller.applet(applet, askPermission: request)
    }

    XCTAssertEqual(refused, .deny)
    XCTAssertEqual(requests.rows.count, limit, "one requester took more than its share")

    for row in requests.rows { requests.decide(row.id, .allowOnce) }

    for answer in answers {
      _ = try await bounded("each question is answered") { await answer.value }
    }
  }

  // MARK: The Pending Requests panel

  /// Catches a panel that keeps a selection by its index while its rows change. A row above the
  /// selected one goes, the selection then names the next row, and Allow Once answers a question
  /// the user never chose. The selection follows the row the user chose.
  func testThePanelKeepsTheChosenRowSelectedWhenRowsAboveItGo() throws {
    let fixture = try makeFixture()
    let requests = fixture.windows.permissionRequests
    var answers: [String: PermissionRequests.Answer] = [:]

    for (requester, name) in [(1, "first"), (2, "second"), (3, "third")] {
      let outcome = requests.ask(
        PermissionRequests.Key(requester: .connection(UInt64(requester)), power: "clipboard-read"),
        subject: "synthetic \(name)", title: "Read the clipboard", detail: "synthetic \(name)",
        sessionTitle: "Allow for This Connection"
      ) { answers[name] = $0 }

      XCTAssertEqual(outcome, .waiting)
    }

    let panel = PendingRequestsWindowController(scriptHost: nil, windows: fixture.windows)

    addTeardownBlock { @MainActor in panel.close() }

    let content = try XCTUnwrap(panel.window?.contentView)
    let table = try XCTUnwrap(content.firstDescendant(identifier: "pending-requests-table"))
    let allowOnce = try XCTUnwrap(
      content.firstDescendant(identifier: "pending-requests-allow-once"))

    guard let table = table as? NSTableView, let allowOnce = allowOnce as? NSButton else {
      return XCTFail("the panel has no table or no Allow Once button")
    }

    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    requests.end(.connection(1))

    XCTAssertEqual(answers["first"], .withdrawn)

    allowOnce.performClick(nil)

    XCTAssertEqual(answers["second"], .allowOnce, "Allow Once missed the chosen question")
    XCTAssertNil(answers["third"], "Allow Once answered a question the user did not choose")
  }

  // MARK: Host launches

  /// Lays out a notes pane with an exec driver beside the window's first pane, for connection 1,
  /// and returns the new pane.
  private func ownedExecPane(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController
  ) async throws -> NodeID {
    let pane = controller.focusedPane
    let argv = ExecTestDriver.arguments("stall", type: NotesFixture.typeID)
      .map { "\"\($0)\"" }.joined(separator: ",")

    controller.enableRemoteControl(pane)

    let reply = try await bounded("the layout is answered") {
      try await fixture.scripting.requestLayout(
        anchor: .pane(
          ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)),
        layout:
          #"{"split":"row","children":[{"pane":\#(pane.rawValue)},"#
          + #"{"open":"fixture-notes","exec":{"argv":[\#(argv)]}}]}"#,
        caller: fixture.caller(controller, pane), stillAllowed: {})
    }

    guard case .record(let fields) = reply, case .array(let panes)? = fields["panes"],
      case .record(let created)? = panes.last, case .integer(let id)? = created["pane"]
    else {
      XCTFail("no new pane in \(reply)")
      throw ScriptCallError.notFound("no new pane")
    }

    return NodeID(rawValue: id)
  }

  /// Catches a remembered policy reaching a launch through a path, and not through the live run
  /// that owns the pane. The owning run's approval starts the driver with no question. The same
  /// program in a pane no run owns still asks, and a launch that waits is withdrawn when its
  /// owner's authority ends.
  func testOnlyTheLiveRunThatOwnsThePaneCoversItsLaunch() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let authority = FakeControllerAuthority()

    controller.controllerAuthority = authority

    let outside = controller.focusedPane
    let member = try await ownedExecPane(fixture, controller)
    let declaration = try XCTUnwrap(controller.execAttachments[member]?.declaration)
    let home = try XCTUnwrap(controller.execEnvironment?.home)

    // The run is asked with the launch's folder resolved.
    authority.launches[1] = [
      declaration.executable + " in " + (HostLaunchScope.resolved(home) ?? home)
    ]

    // Two covered runs with other arguments and other values each start with no question, and
    // neither value reaches the saved window.
    for (argument, value) in [("first", "synthetic-value-1"), ("second", "synthetic-value-2")] {
      try controller.declareExecDriver(
        ExecDeclaration(
          arguments: declaration.arguments + [argument], directory: nil,
          environmentKeys: ["TOKEN"]), for: member)
      fixture.values = ["TOKEN": value]
      controller.runExecDriver(member)

      try await waitUntil("the covered run starts") {
        controller.execAttachments[member]?.channel != nil
      }

      XCTAssertTrue(fixture.windows.launchAuthority.requests.isEmpty, "a covered launch asked")

      controller.execAttachments[member]?.channel?.close()

      try await waitUntil("the covered run ends") {
        if case .ended? = controller.execAttachments[member]?.state { return true }
        return false
      }
    }

    let saved = try LayoutCodec.encode(
      SavedLayout(windows: [try XCTUnwrap(controller.savedWindow())]))

    XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("synthetic-value"))

    try controller.declareExecDriver(declaration, for: outside)
    controller.runExecDriver(outside)

    XCTAssertEqual(
      fixture.windows.launchAuthority.requests.count, 1,
      "the same program ran in a pane no run owns")

    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .deny)

    authority.launches = [:]
    controller.runExecDriver(member)

    try await waitUntil("the uncovered launch asks") {
      fixture.windows.launchAuthority.requests.count == 1
    }

    controller.controllerEnded(1)

    XCTAssertTrue(
      fixture.windows.launchAuthority.requests.isEmpty,
      "a launch the ended controller staged still waits")
  }

  /// Catches remembered trust that enables a restored pane, adopts a restored group, or runs its
  /// driver. A live run whose approval would cover the launch acts in the window, and still the
  /// restored panes stay disconnected and unowned, nothing runs, and Run asks.
  func testRememberedTrustNeverEnablesAdoptsOrRuns() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let member = try await ownedExecPane(fixture, controller)
    let declaration = try XCTUnwrap(controller.execAttachments[member]?.declaration)
    let saved = try XCTUnwrap(controller.savedWindow())
    let restored = try fixture.windows.open(restoring: RestoredWindow(saved: saved))
    let authority = FakeControllerAuthority()

    fixture.prepare(restored)
    restored.controllerAuthority = authority
    authority.acting = [restored.scriptWindowID: [1]]
    let restoredHome = restored.execEnvironment?.home ?? NSHomeDirectory()

    authority.launches[1] = [
      declaration.executable + " in " + (HostLaunchScope.resolved(restoredHome) ?? restoredHome)
    ]
    restored.refreshControlMarks()

    XCTAssertFalse(restored.paneArea.tree.groups.isEmpty)
    XCTAssertTrue(restored.paneArea.tree.groups.allSatisfy { $0.owner == nil })

    for pane in restored.paneIDs {
      XCTAssertEqual(restored.control(of: pane).access, .disconnected)
      XCTAssertNil(restored.execAttachments[pane]?.channel, "a restored driver ran")
    }

    XCTAssertTrue(fixture.windows.launchAuthority.requests.isEmpty)

    let first = try XCTUnwrap(restored.paneIDs.first)

    do {
      _ = try await bounded("the command is answered") {
        try await fixture.command(restored, first, "show-slide", #"{"index":0}"#)
      }
      XCTFail("a trusted connection drove a disconnected restored pane")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused, error.text)
    }

    let restoredMember = try XCTUnwrap(
      restored.paneIDs.first { restored.execAttachments[$0] != nil })

    restored.runExecDriver(restoredMember)

    XCTAssertEqual(
      fixture.windows.launchAuthority.requests.count, 1,
      "a policy started a restored driver no run owns")
    XCTAssertNil(restored.execAttachments[restoredMember]?.channel)
  }
}

/// The titles a clipboard question carries, as the permissions name them.
enum ControllerPermissionText {
  static let read = "Read the clipboard"
  static let write = "Replace the clipboard"
}

/// Set once an awaited answer arrives, so a wait can tell an answer from a question.
@MainActor
final class AnsweredFlag {
  var value = false
}

/// Polls until a condition holds. Past the deadline it fails the test and throws, so the test
/// stops before it reaches a wait that has no deadline of its own.
@MainActor
func waitOrFail(
  _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
  _ condition: () -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)

  while !condition() {
    guard Date() < deadline else {
      XCTFail("timed out waiting until \(what)", file: file, line: line)

      throw WaitTimedOut(what: what)
    }

    try? await Task.sleep(for: .milliseconds(10))
  }
}

/// Runs an operation and waits at most `timeout` for its result. An operation the product never
/// answers fails the test instead of hanging it. Closing the windows at teardown withdraws what
/// still waits, so the operation ends too.
@MainActor
func bounded<T: Sendable>(
  _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
  _ operation: @escaping @MainActor () async throws -> T
) async throws -> T {
  let outcome = Outcome<T>()
  let task = Task { @MainActor in
    do {
      outcome.result = .success(try await operation())
    } catch {
      outcome.result = .failure(error)
    }
  }

  do {
    try await waitOrFail(what, timeout: timeout, file: file, line: line) {
      outcome.result != nil
    }
  } catch {
    task.cancel()

    throw error
  }

  return try XCTUnwrap(outcome.result, file: file, line: line).get()
}

/// What a bounded operation returned or threw, once it has.
@MainActor
private final class Outcome<T> {
  var result: Result<T, any Error>?
}

extension NSView {
  /// The first view in this one's subtree, itself included, with this accessibility identifier.
  func firstDescendant(identifier: String) -> NSView? {
    if accessibilityIdentifier() == identifier { return self }

    for view in subviews {
      if let found = view.firstDescendant(identifier: identifier) { return found }
    }

    return nil
  }
}

/// A wait that passed its deadline.
struct WaitTimedOut: Error, CustomStringConvertible {
  let what: String

  var description: String { "timed out waiting until \(what)" }
}
