import AppKit
import AppletKit
import DefaultsTestSupport
import PaneModel
import Preferences
import StatusKit
import XCTest

@testable import WindowKit

@MainActor
final class UndoRecorder {
  var made: [FakeApplet] = []
  var restored: [FakeApplet] = []
  var asked: [CloseConfirmation] = []

  /// The answers to the questions, in order. A question with no answer left is declined.
  var answers: [Bool] = []
}

/// One window over fake applets and a confirmer that records what it was asked and answers from a
/// script. The applets are titled "Fake 0", "Fake 1", and so on in the order made.
@MainActor
final class UndoFixture {
  let testDefaults = TestDefaults(prefix: "uniterm-undo-test")
  let defaults: UserDefaults
  let recorder = UndoRecorder()
  let controller: MainWindowController

  init(policy: CloseUndoPolicy = .standard) throws {
    let defaults = testDefaults.defaults
    let store = SettingsStore(defaults: defaults)
    let recorder = recorder

    self.defaults = defaults

    controller = try MainWindowController(
      appearance: AppearanceController(store: store), settings: store, undoPolicy: policy,
      restoreApplet: { description in
        guard case .string(let title) = description.payload else {
          throw AppletRestoreError.corrupt("no title")
        }

        let applet = FakeApplet()
        applet.title = title
        applet.restoreClosedTabs(from: description)
        recorder.restored.append(applet)
        return applet
      },
      makeApplet: { _, _ in
        let applet = FakeApplet()
        applet.title = "Fake \(recorder.made.count)"
        recorder.made.append(applet)
        return applet
      })

    controller.confirmer = { request, _ in
      recorder.asked.append(request)
      return recorder.answers.isEmpty ? false : recorder.answers.removeFirst()
    }

    controller.window?.contentView?.layoutSubtreeIfNeeded()
  }

  func cleanUp() {
    controller.window?.close()
    testDefaults.discard()
  }

  var made: [FakeApplet] { recorder.made }

  /// Opens panes until there are `count`. The first three sit in a row, as panes 1, 2, and 4. The
  /// fourth splits pane 4 downward as pane 5, since a fourth pane in the row would be too narrow.
  func openPanes(_ count: Int) {
    precondition(count <= 4, "the window has room for four panes")

    while controller.paneIDs.count < count {
      let axis: Axis = controller.paneIDs.count < 3 ? .row : .column
      precondition(controller.openPane(.terminalShell, axis: axis) != nil, "a pane did not open")
    }
  }

  /// Waits for the question the window is asking, if any, to be answered and acted on.
  func settle() async {
    let task = controller.pendingGuard
    await task?.value
  }
}

@MainActor
final class UndoCloseTests: XCTestCase {
  private var fixtures: [UndoFixture] = []

  override func tearDown() async throws {
    for fixture in fixtures {
      fixture.cleanUp()
    }

    fixtures = []
  }

  private func makeFixture(_ policy: CloseUndoPolicy = .standard) throws -> UndoFixture {
    let fixture = try UndoFixture(policy: policy)
    fixtures.append(fixture)
    return fixture
  }

  private func id(_ value: UInt64) -> NodeID { NodeID(rawValue: value) }

  private func rootWeights(_ controller: MainWindowController) -> [Double] {
    guard case .split(let split) = controller.paneArea.tree.root else { return [] }
    return split.children.map(\.weight)
  }

  // MARK: Closing and undoing

  /// Catches a close that keeps the applet alive for undo. The closed pane's applet is closed at
  /// once, and nothing is asked for an idle pane.
  func testClosingAPaneEndsItsAppletAtOnce() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)

    fixture.controller.dispatch(.close)

    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])
    XCTAssertTrue(fixture.made[1].closed)
    XCTAssertEqual(fixture.controller.ledger.entries.count, 1)
    XCTAssertTrue(fixture.recorder.asked.isEmpty)
  }

  /// Catches an undo that brings back the old applet or reuses the old ID. Panes 1 and 2 and split 3
  /// were issued, so the reopened pane is 4. It comes from the saved description, which carries the
  /// old applet's title, and its applet starts fresh. The two panes share the row evenly again.
  func testUndoReopensFromTheDescriptionWithANewID() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.controller.dispatch(.close)

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.controller.paneIDs, [id(1), id(4)])
    XCTAssertEqual(fixture.recorder.restored.map(\.title), ["Fake 1"])
    XCTAssertTrue(fixture.controller.paneArea.applet(for: id(4)) === fixture.recorder.restored[0])
    XCTAssertTrue(fixture.recorder.restored[0].started)
    XCTAssertTrue(fixture.made[1].closed)
    XCTAssertEqual(fixture.made.count, 2)
    XCTAssertEqual(rootWeights(fixture.controller), [0.5, 0.5])
    XCTAssertEqual(fixture.controller.focusedPane, id(4))
    XCTAssertTrue(fixture.controller.ledger.entries.isEmpty)
  }

  /// Catches an undo that drops a description this build cannot restore. A placeholder closed with a
  /// newer build's bytes reopens as a placeholder that still holds them, so a later save writes
  /// them back.
  func testUndoOfADescriptionTheRestorerRefusesKeepsItsBytesInAPlaceholder() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)

    let bytes = Data(#"{"type":"fake","version":9,"payload":{"new":true}}"#.utf8)
    fixture.made[1].fixedDescription = AppletDescription(
      type: "fake", version: 9, payload: .null, verbatim: bytes)
    fixture.controller.dispatch(.close)

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.controller.paneIDs.count, 2)

    let reopened = fixture.controller.paneIDs.compactMap {
      fixture.controller.paneArea.applet(for: $0) as? PlaceholderApplet
    }

    XCTAssertEqual(reopened.count, 1)
    XCTAssertEqual(reopened.first?.describe().verbatim, bytes)
    XCTAssertTrue(fixture.controller.ledger.entries.isEmpty)
  }

  /// Catches an undo that reopens an older close first. Pane 4 closes, then pane 2. The first undo
  /// reopens pane 2's description, and the second reopens pane 4's.
  func testUndoTakesTheNewestCloseFirst() throws {
    let fixture = try makeFixture()
    fixture.openPanes(3)
    XCTAssertEqual(fixture.controller.paneIDs, [id(1), id(2), id(4)])

    fixture.controller.dispatch(.close)
    fixture.controller.dispatch(.close)
    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])

    fixture.controller.reopenClosed()
    XCTAssertEqual(fixture.recorder.restored.map(\.title), ["Fake 1"])

    fixture.controller.reopenClosed()
    XCTAssertEqual(fixture.recorder.restored.map(\.title), ["Fake 1", "Fake 2"])
    XCTAssertEqual(fixture.controller.paneIDs.count, 3)
  }

  /// Catches undo that ignores where the pane sat when the tree has changed since. Pane 2 closes,
  /// then pane 1 is split below, so pane 1 sits in a column. The reopened pane returns beside pane 1
  /// in a row, not below it. Pane 4 and split 5 went to the split, so the new pane is 6.
  func testUndoPlacesThePaneBesideItsNeighborAfterTheNeighborMoved() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.controller.dispatch(.close)
    fixture.controller.dispatch(.focusPaneLeft)
    XCTAssertNotNil(fixture.controller.openPane(.terminalShell, axis: .column))

    fixture.controller.reopenClosed()

    guard case .split(let column) = fixture.controller.paneArea.tree.root else {
      return XCTFail("the root is a pane")
    }

    XCTAssertEqual(column.axis, .column)
    guard case .split(let row) = column.children[0].node else {
      return XCTFail("pane 1 was not wrapped in a row")
    }

    XCTAssertEqual(row.axis, .row)
    XCTAssertEqual(row.children.map { $0.node.id }, [id(1), id(6)])
  }

  /// Catches an undo that cannot place a pane whose neighbor has gone. Pane 2 closes beside pane 1.
  /// Then pane 1's shell exits, which leaves only pane 4. The first reopen brings pane 1 back as
  /// pane 5, before pane 4, and the new row takes ID 6. Pane 2's neighbor is still gone, since
  /// pane 5 has a new ID. So the second reopen puts pane 2 back as pane 7 at the end of the row,
  /// on the side it was recorded on.
  func testUndoFallsBackToTheEdgeWhenTheNeighborIsGone() throws {
    let fixture = try makeFixture()
    fixture.openPanes(3)
    XCTAssertEqual(fixture.controller.paneIDs, [id(1), id(2), id(4)])
    fixture.controller.dispatch(.focusPaneLeft)
    fixture.controller.dispatch(.close)
    fixture.controller.appletDidExit(fixture.made[0])
    XCTAssertEqual(fixture.controller.paneIDs, [id(4)])

    fixture.controller.reopenClosed()
    XCTAssertEqual(fixture.controller.paneIDs, [id(5), id(4)])

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.controller.paneIDs, [id(5), id(4), id(7)])
    XCTAssertEqual(fixture.recorder.restored.map(\.title), ["Fake 0", "Fake 1"])
  }

  /// Catches a stack that grows past its depth. With a depth of 2, three closes keep the newest
  /// two, and the oldest is not undoable.
  func testTheUndoStackKeepsOnlyTheNewestCloses() throws {
    let fixture = try makeFixture(CloseUndoPolicy(stackDepth: 2))
    fixture.openPanes(4)
    var closed: [String] = []

    for _ in 0..<3 {
      let focused = fixture.controller.focusedPane
      closed.append(try XCTUnwrap(fixture.controller.paneArea.applet(for: focused)).title)
      fixture.controller.dispatch(.close)
    }

    XCTAssertEqual(fixture.controller.ledger.entries.map(\.title), Array(closed.suffix(2)))
  }

  /// Catches an undo with nothing to undo that does nothing visible. The status bar says so.
  func testUndoWithNothingClosedSaysSo() throws {
    let fixture = try makeFixture()

    fixture.controller.reopenClosed()

    XCTAssertEqual(
      fixture.controller.statusCenter.history.last?.text,
      "There is no closed tab or pane to reopen.")
  }

  /// Catches a refused reopen that eats the description. With the window too narrow for another
  /// pane, undo posts a warning and the entry stays for a larger window.
  func testAnUndoThatDoesNotFitKeepsTheEntry() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.controller.dispatch(.close)
    let window = try XCTUnwrap(fixture.controller.window)
    window.setContentSize(NSSize(width: 300, height: 640))
    window.contentView?.layoutSubtreeIfNeeded()

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])
    XCTAssertEqual(fixture.controller.ledger.entries.count, 1)
    XCTAssertEqual(
      fixture.controller.statusCenter.history.last?.text,
      "The pane \u{201C}Fake 1\u{201D} does not fit in the window. "
        + "Make the window larger, then try again. Nothing was reopened.")
    XCTAssertTrue(fixture.recorder.restored.isEmpty, "the applet was built before the fit check")
  }

  // MARK: Pane close guard

  /// Catches a close that ends a running pane with no question, and one that ends it after Cancel.
  /// The question names the running tabs and no others. Declining keeps the pane in the tree and
  /// nothing on the stack. Accepting closes the applet and keeps its description.
  func testClosingARunningPaneAsksAndCancelKeepsIt() async throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.made[1].isRunningSomething = true
    fixture.made[1].labels = ["vim notes.txt", "make test"]

    fixture.recorder.answers = [false]
    fixture.controller.dispatch(.close)
    await fixture.settle()

    XCTAssertEqual(fixture.recorder.asked.count, 1)
    XCTAssertEqual(fixture.recorder.asked[0].labels, ["vim notes.txt", "make test"])
    XCTAssertEqual(fixture.recorder.asked[0].confirmTitle, "Close Pane")
    XCTAssertEqual(fixture.controller.paneIDs, [id(1), id(2)])
    XCTAssertFalse(fixture.made[1].closed)
    XCTAssertTrue(fixture.controller.ledger.entries.isEmpty)

    fixture.recorder.answers = [true]
    fixture.controller.dispatch(.close)
    await fixture.settle()

    XCTAssertEqual(fixture.recorder.asked.count, 2)
    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])
    XCTAssertTrue(fixture.made[1].closed)
    XCTAssertFalse(fixture.made[0].closed)
    XCTAssertEqual(fixture.controller.ledger.entries.map(\.title), ["Fake 1"])
  }

  /// Catches a pane that exited while its close question was open and is closed twice. The exit
  /// closes the pane with one entry. Confirming then does nothing.
  func testAPaneThatExitsDuringItsCloseQuestionIsNotClosedAgain() async throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.made[1].isRunningSomething = true
    fixture.recorder.answers = [true]

    fixture.controller.dispatch(.close)
    XCTAssertNotNil(fixture.controller.pendingGuard)

    fixture.made[1].isRunningSomething = false
    fixture.controller.appletDidExit(fixture.made[1])
    await fixture.settle()

    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])
    XCTAssertEqual(fixture.controller.ledger.entries.map(\.title), ["Fake 1"])
  }

  /// Catches a confirmed pane close that does nothing once the pane has become the last one. Pane 2
  /// runs vim and its close is asked about. Pane 1 exits meanwhile. The user confirms, and the
  /// window closes, since nothing else is left to keep it open.
  func testConfirmingAPaneCloseThatBecameTheLastPaneClosesTheWindow() async throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    window.orderFrontRegardless()
    fixture.openPanes(2)
    fixture.made[1].isRunningSomething = true
    fixture.recorder.answers = [true]

    fixture.controller.dispatch(.close)
    fixture.controller.appletDidExit(fixture.made[0])
    await fixture.settle()

    XCTAssertEqual(fixture.recorder.asked.count, 1)
    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(fixture.made[1].closed)
  }

  /// Catches a pane whose shell exited that Cmd-Shift-T cannot bring back. A close is a close,
  /// however it happens. The exit asks nothing and leaves an entry, and reopening uses it.
  func testAPaneThatExitedOnItsOwnCanBeReopened() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)

    fixture.controller.appletDidExit(fixture.made[1])

    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])
    XCTAssertTrue(fixture.made[1].closed)
    XCTAssertEqual(fixture.controller.ledger.entries.map(\.title), ["Fake 1"])
    XCTAssertTrue(fixture.recorder.asked.isEmpty)

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.controller.paneIDs.count, 2)
    XCTAssertEqual(fixture.recorder.restored.map(\.title), ["Fake 1"])
  }

  // MARK: Window close guard

  /// Catches a window close that asks although nothing is running.
  func testClosingAnIdleWindowAsksNothing() throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)

    XCTAssertTrue(fixture.controller.windowShouldClose(window))
    XCTAssertTrue(fixture.recorder.asked.isEmpty)
  }

  /// Catches a window that closes with a program running and no question. The question names the
  /// tab. Cancel keeps the window and everything in it.
  func testClosingAWindowWithARunningTabAsksAndCancelKeepsTheWindow() async throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    window.orderFrontRegardless()
    fixture.made[0].isRunningSomething = true
    fixture.made[0].labels = ["vim notes.txt"]

    XCTAssertFalse(fixture.controller.windowShouldClose(window))
    await fixture.settle()

    XCTAssertEqual(fixture.recorder.asked.count, 1)
    XCTAssertEqual(fixture.recorder.asked[0].labels, ["vim notes.txt"])
    XCTAssertEqual(fixture.recorder.asked[0].confirmTitle, "Close Window")
    XCTAssertTrue(window.isVisible)
    XCTAssertFalse(fixture.made[0].closed)
  }

  /// Catches a confirmed close that leaves the window open.
  func testConfirmingTheWindowCloseClosesTheWindowAndItsApplets() async throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    window.orderFrontRegardless()
    fixture.made[0].isRunningSomething = true
    fixture.recorder.answers = [true]

    XCTAssertFalse(fixture.controller.windowShouldClose(window))
    await fixture.settle()

    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(fixture.made[0].closed)
  }

  /// Catches a closed pane that still counts toward the window guard. Pane 2 ran vim and was closed
  /// with the user's say. Nothing of it is alive, so the window closes with no question.
  func testAClosedPaneDoesNotCountInTheWindowCloseGuard() async throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    fixture.openPanes(2)
    fixture.made[1].isRunningSomething = true
    fixture.recorder.answers = [true]
    fixture.controller.dispatch(.close)
    await fixture.settle()
    XCTAssertEqual(fixture.recorder.asked.count, 1)

    XCTAssertTrue(fixture.controller.windowShouldClose(window))
    XCTAssertEqual(fixture.recorder.asked.count, 1)
    XCTAssertTrue(fixture.controller.runningTabLabels.isEmpty)
  }

  /// Catches a multi-tab pane that is named as one. A pane with three tabs, one running, lists the
  /// running tab alone.
  func testAMultiTabPaneIsNamedByItsRunningTabs() async throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    window.orderFrontRegardless()
    fixture.made[0].tabCount = 3
    fixture.made[0].isRunningSomething = true
    fixture.made[0].labels = ["make test"]

    XCTAssertFalse(fixture.controller.windowShouldClose(window))
    await fixture.settle()

    XCTAssertEqual(fixture.recorder.asked.map(\.labels), [["make test"]])
  }

  // MARK: Last pane

  /// Catches an idle last pane that asks, or a close that leaves the window open. Nothing is
  /// running, so the window closes at once.
  func testClosingTheLastIdlePaneClosesTheWindowWithoutAsking() throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    window.orderFrontRegardless()

    fixture.controller.dispatch(.close)

    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(fixture.recorder.asked.isEmpty)
    XCTAssertTrue(fixture.made[0].closed)
  }

  /// Catches a last-pane close that ends a running program with no question. The window-close
  /// question names the tab. Cancel keeps the window and the pane. Confirming closes the window.
  func testClosingTheLastRunningPaneAsksAndCancelKeepsTheWindow() async throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    window.orderFrontRegardless()
    fixture.made[0].isRunningSomething = true
    fixture.made[0].labels = ["vim"]

    fixture.recorder.answers = [false]
    fixture.controller.dispatch(.close)
    await fixture.settle()

    XCTAssertEqual(fixture.recorder.asked.map(\.labels), [["vim"]])
    XCTAssertEqual(fixture.recorder.asked[0].confirmTitle, "Close Window")
    XCTAssertTrue(window.isVisible)
    XCTAssertFalse(fixture.made[0].closed)

    fixture.recorder.answers = [true]
    fixture.controller.dispatch(.close)
    await fixture.settle()

    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(fixture.made[0].closed)
  }

  /// Catches a second question for a last pane that exited while the first was open. The exit is
  /// not asked about again. Cancel leaves the dead pane, and closing it then asks nothing, since
  /// nothing is running.
  func testALastPaneThatExitsWhileTheWindowQuestionIsOpenIsNotAskedAboutAgain() async throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    window.orderFrontRegardless()
    fixture.made[0].isRunningSomething = true

    fixture.controller.dispatch(.close)
    XCTAssertNotNil(fixture.controller.pendingGuard)

    fixture.made[0].isRunningSomething = false
    fixture.controller.appletDidExit(fixture.made[0])
    await fixture.settle()

    XCTAssertEqual(fixture.recorder.asked.count, 1)
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])

    fixture.controller.dispatch(.close)

    XCTAssertEqual(fixture.recorder.asked.count, 1)
    XCTAssertFalse(window.isVisible)
  }

  /// Catches a dead pane that is asked about or lost. The last pane exits while the window
  /// question is open, and Cancel leaves it. The user splits and closes the dead pane. It closes
  /// without a question and goes on the reopen list.
  func testADeadPaneClosedLaterIsReopenable() async throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    window.orderFrontRegardless()
    fixture.made[0].isRunningSomething = true

    fixture.controller.dispatch(.close)
    fixture.made[0].isRunningSomething = false
    fixture.controller.appletDidExit(fixture.made[0])
    await fixture.settle()
    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])

    XCTAssertNotNil(fixture.controller.openPane(.terminalShell, axis: .row))
    fixture.controller.paneArea.focus(id(1))
    fixture.controller.dispatch(.close)

    XCTAssertEqual(fixture.controller.paneIDs, [id(2)])
    XCTAssertTrue(fixture.made[0].closed)
    XCTAssertEqual(fixture.controller.ledger.entries.map(\.title), ["Fake 0"])
  }

  /// Catches a message from a closed applet that loses its pane. The host binds the pane's ID when
  /// the applet takes the pane, so a late post keeps it and never claims a live pane.
  func testAMessageFromAClosedAppletKeepsItsPaneID() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.controller.dispatch(.close)

    fixture.made[1].say(.info, "late")

    XCTAssertEqual(
      fixture.controller.statusCenter.history.last?.source, .pane(id: 2, name: "Fake 1"))
  }

  // MARK: Window lifecycle

  /// Catches an undo stack that outlives its window. The window closes with two descriptions on
  /// the stack. Every applet is closed and the stack is empty.
  func testClosingTheWindowClearsTheUndoStack() throws {
    let fixture = try makeFixture()
    fixture.openPanes(3)
    fixture.controller.dispatch(.close)
    fixture.controller.dispatch(.close)
    XCTAssertEqual(fixture.controller.ledger.entries.count, 2)

    fixture.controller.window?.close()

    XCTAssertTrue(fixture.made.allSatisfy(\.closed))
    XCTAssertTrue(fixture.controller.ledger.entries.isEmpty)
  }

  /// Catches a closed window that is kept alive by its undo stack. The controller is released after
  /// the window closes with descriptions on the stack.
  func testAWindowWithUndoStateIsReleasedWhenItCloses() async throws {
    weak var released: MainWindowController?

    do {
      let fixture = try UndoFixture()
      fixture.openPanes(3)
      fixture.controller.dispatch(.close)
      fixture.controller.dispatch(.close)
      released = fixture.controller

      fixture.cleanUp()
    }

    let gone = await waitUntil { released == nil }
    XCTAssertTrue(gone, "the closed window's controller was never released")
  }

  // MARK: Cmd-Z

  /// Catches Cmd-Z bound to a private selector. The menu item must send the standard undo selector,
  /// so the text controls of other windows keep their Cmd-Z.
  func testTheUndoItemSendsTheStandardUndoSelector() {
    XCTAssertEqual(#selector(MainWindow.undoEdit(_:)), NSSelectorFromString("undo:"))
  }

  private final class PlainView: NSView {
    override var acceptsFirstResponder: Bool { true }
  }

  /// Catches a Cmd-Z that touches panes. A pane is closed. With a text field being edited, the
  /// standard undo action leaves the pane closed and the menu item follows the edit's undo state.
  /// With a plain view focused, as a terminal is, the action does nothing, the item is off, and the
  /// pane stays closed.
  func testCommandZUndoesTextEditsOnlyAndNeverReopensAPane() throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window as? MainWindow)
    window.orderFrontRegardless()
    fixture.openPanes(2)
    fixture.controller.dispatch(.close)

    let field = NSTextField(string: "abc")
    field.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
    let plain = PlainView(frame: NSRect(x: 0, y: 30, width: 100, height: 20))
    window.contentView?.addSubview(field)
    window.contentView?.addSubview(plain)

    let item = NSMenuItem(
      title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")

    XCTAssertTrue(window.makeFirstResponder(field))
    XCTAssertTrue(window.firstResponder is NSText)
    XCTAssertFalse(window.validateMenuItem(item), "nothing typed, so the edit has no undo")

    window.undoEdit(nil)

    XCTAssertEqual(fixture.controller.paneIDs, [id(1)], "Cmd-Z in a text field undid a close")
    XCTAssertEqual(fixture.controller.ledger.entries.count, 1)

    XCTAssertTrue(window.makeFirstResponder(plain))
    XCTAssertFalse(window.validateMenuItem(item))
    XCTAssertEqual(item.title, "Undo")

    window.undoEdit(nil)

    XCTAssertEqual(fixture.controller.paneIDs, [id(1)], "Cmd-Z reopened a pane")
    XCTAssertEqual(fixture.controller.ledger.entries.count, 1)
  }
}
