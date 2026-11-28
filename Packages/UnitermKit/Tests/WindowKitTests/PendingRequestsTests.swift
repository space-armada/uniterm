import AppKit
import DefaultsTestSupport
import FileRouting
import Preferences
import ScriptHost
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost
@testable import WindowKit

@MainActor
final class PendingRequestsTests: XCTestCase {
  fileprivate let testDefaults = TestDefaults(prefix: "uniterm-pending-requests-test")
  fileprivate var windows: WindowSet!
  private var indicator: PendingRequestsIndicator!

  override func setUp() async throws {
    let store = SettingsStore(defaults: testDefaults.defaults)
    let appearance = AppearanceController(store: store)

    windows = WindowSet(
      visibleFrame: { _ in NSRect(x: 0, y: 0, width: 4000, height: 3000) },
      makeRestoredController: { identifier, restored in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, restoring: restored,
          restoreApplet: { _ in FakeApplet() }, makeApplet: { _, _ in FakeApplet() }
        ).detachFromRealScreen()
      },
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          makeApplet: { _, _ in FakeApplet() }
        ).detachFromRealScreen()
      })

    _ = try windows.open()
    indicator = PendingRequestsIndicator(windows: windows, scriptHost: { nil })
  }

  override func tearDown() async throws {
    for controller in windows.controllers { controller.window?.close() }

    testDefaults.discard()
    windows = nil
    indicator = nil
  }

  private var postedTexts: [String] {
    windows.activeController?.statusCenter.history.map(\.text) ?? []
  }

  fileprivate func ask(_ power: String, subject: String = "build.janet, PID 42") {
    _ = windows.permissionRequests.ask(
      .init(requester: .terminal(window: 1, pane: 1), power: power), subject: subject,
      title: "Read the clipboard", detail: "", sessionTitle: "Allow for This Run",
      answer: { _ in })
  }

  /// Catches a request line that puts a program's self-reported name under uniterm's own label with
  /// no marker, when the system cannot say which executable the program is. It cannot prove that the
  /// panel's column and the pane alert mark the name too.
  func testARequestWithNoExecutablePathMarksItsSelfReportedNameUnverified() {
    let unknown = ScriptHost.PendingRequest(
      id: 1, pid: 77, executablePath: nil, name: "Trusted Backup", timestamp: Date())
    let known = ScriptHost.PendingRequest(
      id: 2, pid: 78, executablePath: "/usr/local/bin/tool", name: "Trusted Backup",
      timestamp: Date())

    XCTAssertEqual(
      PendingRequestsIndicator.sentence(for: unknown),
      "Trusted Backup (unverified script), PID 77, asks for a pane.")
    XCTAssertEqual(
      PendingRequestsIndicator.sentence(for: known), "tool, PID 78, asks for a pane.")
  }

  /// Catches a slot without a count, a count that includes a row's repeated operations, an arrival
  /// that posts nothing, and a refresh that posts the same row again. Each new row posts once.
  /// Asking again under the same row, or refreshing with nothing new, posts nothing.
  func testEachNewRowPostsOnceAndTheSlotCountsRows() throws {
    ask("clipboard-read")
    indicator.refresh()

    XCTAssertEqual(windows.windowStates.label(of: .pendingPermissions), "1 request")
    XCTAssertEqual(
      postedTexts, ["Pending request: build.janet, PID 42 asks: Read the clipboard."])

    ask("clipboard-read")
    indicator.refresh()
    indicator.refresh()

    XCTAssertEqual(windows.windowStates.label(of: .pendingPermissions), "1 request")
    XCTAssertEqual(postedTexts.count, 1, "a repeated question posted again")

    ask("clipboard-write")
    indicator.refresh()

    XCTAssertEqual(windows.windowStates.label(of: .pendingPermissions), "2 requests")
    XCTAssertEqual(postedTexts.count, 2)
  }

  /// Catches a slot that stays once nothing waits, or that counts a denial. A denial is listed in
  /// the panel but asks nothing.
  func testTheSlotClearsWhenTheLastRowIsAnsweredAndADenialIsNotCounted() throws {
    ask("clipboard-read")
    indicator.refresh()

    let row = try XCTUnwrap(windows.permissionRequests.rows.first)
    windows.permissionRequests.decide(row.id, .deny)
    indicator.refresh()

    XCTAssertFalse(windows.permissionRequests.denials.isEmpty)
    XCTAssertNil(windows.windowStates.text(of: .pendingPermissions))
  }

  // MARK: Panel buttons

  private func makePanel() throws -> (panel: PendingRequestsWindowController, table: NSTableView) {
    let panel = PendingRequestsWindowController(scriptHost: nil, windows: windows)
    let content = try XCTUnwrap(panel.window?.contentView)

    content.layoutSubtreeIfNeeded()

    return (panel, try XCTUnwrap(content.firstDescendant(of: NSTableView.self)))
  }

  /// The titles of the panel's buttons that show, in the order they sit.
  fileprivate func shownButtons(_ panel: PendingRequestsWindowController) throws -> [String] {
    let content = try XCTUnwrap(panel.window?.contentView)

    return content.descendants(of: NSButton.self)
      .filter { !$0.isHiddenOrHasHiddenAncestor && $0.bezelStyle != .helpButton }
      .map(\.title)
  }

  private func detailText(_ panel: PendingRequestsWindowController) throws -> String {
    let content = try XCTUnwrap(panel.window?.contentView)
    let detail = content.descendants(of: NSTextField.self)
      .first { $0.accessibilityIdentifier() == "pending-requests-detail" }

    return try XCTUnwrap(detail).stringValue
  }

  /// Catches buttons that show for a row kind they cannot answer, or that show disabled with
  /// nothing selected. An empty panel and an unselected row show no button, and the detail says
  /// what to do. A question shows its own answers, and nothing else, every one of them live.
  func testThePanelShowsOnlyTheSelectedRowsButtons() throws {
    let (panel, table) = try makePanel()

    XCTAssertEqual(try shownButtons(panel), [])
    XCTAssertEqual(try detailText(panel), "Nothing waits for your answer.")

    ask("clipboard-read")

    XCTAssertEqual(try shownButtons(panel), [])
    XCTAssertEqual(try detailText(panel), "Select a request to answer it.")

    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    XCTAssertEqual(try shownButtons(panel), ["Allow Once", "Allow for This Run", "Deny"])

    let content = try XCTUnwrap(panel.window?.contentView)
    let shown = content.descendants(of: NSButton.self).filter { !$0.isHiddenOrHasHiddenAncestor }
    XCTAssertTrue(shown.allSatisfy(\.isEnabled), "a shown button is disabled")

    let row = try XCTUnwrap(windows.permissionRequests.rows.first)
    windows.permissionRequests.decide(row.id, .deny)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    XCTAssertEqual(try shownButtons(panel), ["Ask Again"])
  }
}

/// A helper that takes every peer for the bundle's command, so a raw peer can play it.
private struct AcceptingHelper: ControllerHelperIdentity {
  func refusal(forPeer token: AuditToken) -> String? { nil }
}

extension PendingRequestsTests {
  /// Catches a review that arrives above the chosen row moving the user's selection. Reviews list
  /// first, so one that arrives while the user has a question selected lands above it. The
  /// selection must stay on the question, with its own buttons, so no key answers a row the user
  /// did not choose.
  func testAReviewArrivingAboveTheSelectionLeavesTheSelectionOnItsRow() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let store = SettingsStore(defaults: testDefaults.defaults)

    store.set(.unsafe, for: .scriptFileMode)

    let center = StatusCenter()
    let host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) },
      controllers: ControllerSettings(
        runsRoot: directory.appendingPathComponent("runs"), helper: AcceptingHelper()),
      permissionRequests: windows.permissionRequests, settings: store)

    host.start()

    defer {
      host.stop()
      try? FileManager.default.removeItem(at: directory)
    }

    let panel = PendingRequestsWindowController(scriptHost: host, windows: windows)
    let content = try XCTUnwrap(panel.window?.contentView)

    content.layoutSubtreeIfNeeded()

    let table = try XCTUnwrap(content.firstDescendant(of: NSTableView.self))

    ask("clipboard-read")
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    XCTAssertEqual(try shownButtons(panel), ["Allow Once", "Allow for This Run", "Deny"])

    let socket = try UnixSocket.connect(path: host.instanceAddress)

    defer { socket.shutdownAndClose() }

    try socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    try socket.send(
      ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "arrives.janet")).frame())

    var waited = 0

    while host.undeclaredReviews.isEmpty, waited < 300 {
      try await Task.sleep(for: .milliseconds(50))
      waited += 1
    }

    XCTAssertEqual(host.undeclaredReviews.count, 1, "the review never arrived")

    // The window's slot counts what the panel lists, so a review it left out would never show.
    let counted = PendingRequestsIndicator(windows: windows, scriptHost: { host })

    XCTAssertTrue(
      counted.waitingItems().contains { $0.sentence.contains("arrives.janet") },
      "the pending slot does not count an undeclared review")
    XCTAssertEqual(table.numberOfRows, 2)
    XCTAssertEqual(table.selectedRow, 1, "the selection moved off the question")
    XCTAssertEqual(try shownButtons(panel), ["Allow Once", "Allow for This Run", "Deny"])
  }
}

extension NSView {
  fileprivate func descendants<T: NSView>(of type: T.Type) -> [T] {
    subviews.flatMap { ($0 as? T).map { [$0] } ?? [] }
      + subviews.flatMap { $0.descendants(of: type) }
  }

  fileprivate func firstDescendant<T: NSView>(of type: T.Type) -> T? {
    descendants(of: type).first
  }
}
