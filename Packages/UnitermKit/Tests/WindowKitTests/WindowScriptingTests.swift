import AppKit
import AppletKit
import PaneModel
import Preferences
import ScriptHost
import ScriptWire
import XCTest

@testable import WindowKit

/// Real windows and panes, with fake applets, behind the window side of the host API. Each test
/// builds its own set, so a window's ID and its panes' IDs are the ones a script would see.
///
/// Unless a test says otherwise, the script acts for the first window's first pane, which the user
/// has made remote-controlled. The fake applet type and the launcher declare remote control here,
/// so a test can make any of its panes a source or a member.
@MainActor
final class ScriptingFixture {
  let suite = "uniterm-scripting-test-\(UUID().uuidString)"
  let defaults: UserDefaults
  let store: SettingsStore
  let windows: WindowSet
  let scripting: WindowScripting

  /// The choices the factory was asked for, oldest first.
  private(set) var choices: [AppletChoice] = []

  /// The directory each applet was asked to start in, oldest first.
  private(set) var requested: [String?] = []

  /// The applets made, oldest first.
  private(set) var made: [FakeApplet] = []

  /// Makes the applet for the next request. A test replaces it to hand out a different stand-in.
  var make: @MainActor () -> FakeApplet = { FakeApplet() }

  /// Who the calls come from. `openWindow` sets it to the first window's first pane.
  var caller = ScriptCaller(connection: 1, window: 0, pane: NodeID(rawValue: 0))

  static let declarations = [
    AppletTypeDeclaration(
      typeID: "fake", displayName: "Fake", symbolName: "questionmark", opens: [],
      controlSupport: [.remoteControlled]),
    AppletTypeDeclaration(
      typeID: LauncherApplet.identifier, displayName: "Launcher", symbolName: "plus", opens: [],
      controlSupport: [.remoteControlled]),
    AppletTypeDeclaration(
      typeID: "terminal", displayName: "Terminal", symbolName: "terminal", opens: [],
      controlSupport: [.remoteControlled]),
    AppletTypeDeclaration(
      typeID: "data-viewer", displayName: "Data Viewer", symbolName: "tablecells", opens: []),
    AppletTypeDeclaration(
      typeID: "viewer", displayName: "Viewer", symbolName: "doc", opens: [],
      controlSupport: [.remoteControlled]),
  ]

  init(
    windowIDs: WindowIDSource = WindowIDSource(),
    directoryExists: @escaping @Sendable (String) -> Bool = { _ in true }
  ) {
    let defaults = UserDefaults(suiteName: suite)!
    let store = SettingsStore(defaults: defaults)
    let appearance = AppearanceController(store: store)

    self.defaults = defaults
    self.store = store

    var factory: AppletFactory = { _, _ in FakeApplet() }

    windows = WindowSet(
      visibleFrame: { _ in NSRect(x: 0, y: 0, width: 4000, height: 3000) },
      makeRestoredController: { identifier, restored in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier,
          appletTypes: ScriptingFixture.declarations, restoring: restored,
          restoreApplet: { _ in FakeApplet() },
          makeApplet: { choice, directory in try factory(choice, directory) }
        ).detachFromRealScreen()
      },
      windowIDs: windowIDs,
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          appletTypes: ScriptingFixture.declarations,
          makeApplet: { choice, directory in try factory(choice, directory) }
        ).detachFromRealScreen()
      })

    scripting = WindowScripting(windows: windows, directoryExists: directoryExists)

    factory = { [unowned self] choice, directory in
      choices.append(choice)
      requested.append(directory)

      let applet = make()
      made.append(applet)

      return applet
    }
  }

  func cleanUp() {
    for controller in windows.controllers {
      controller.window?.close()
    }

    defaults.removePersistentDomain(forName: suite)
  }

  /// Opens a window and returns its controller and a reference to its first pane. The first
  /// window's first pane becomes the caller's, remote-controlled.
  func openWindow(enabled: Bool = true) throws -> (MainWindowController, ScriptPaneReference) {
    let controller = try windows.open()
    let pane = ScriptPaneReference(
      window: controller.scriptWindowID, pane: controller.focusedPane.rawValue)

    controller.window?.contentView?.layoutSubtreeIfNeeded()

    if windows.controllers.count == 1 {
      caller = ScriptCaller(connection: 1, window: pane.window, pane: controller.focusedPane)

      if enabled { controller.enableRemoteControl(controller.focusedPane) }
    }

    return (controller, pane)
  }

  // The calls as a script makes them, from `caller` unless a test names another.

  func listWindows(as who: ScriptCaller? = nil) throws -> ScriptValue {
    try scripting.listWindows(caller: who ?? caller)
  }

  func listPanes(window: UInt64, as who: ScriptCaller? = nil) throws -> ScriptValue {
    try scripting.listPanes(window: window, caller: who ?? caller)
  }

  func openPane(
    kind: String, beside: ScriptPaneReference, axis: ScriptAxis?, directory: String?,
    access: ScriptPaneAccess = .disconnected, as who: ScriptCaller? = nil,
    stillAllowed: @MainActor () throws -> Void = {}
  ) async throws -> ScriptValue {
    try await openPane(
      kind: kind, target: .pane(beside), axis: axis, directory: directory, access: access, as: who,
      stillAllowed: stillAllowed)
  }

  func openPane(
    kind: String, target: ScriptTarget, axis: ScriptAxis? = nil, directory: String? = nil,
    access: ScriptPaneAccess = .disconnected, as who: ScriptCaller? = nil,
    stillAllowed: @MainActor () throws -> Void = {}
  ) async throws -> ScriptValue {
    try await scripting.openPane(
      kind: kind, beside: target, axis: axis, directory: directory, access: access,
      caller: who ?? caller, stillAllowed: stillAllowed)
  }

  func openTab(
    pane: ScriptPaneReference, directory: String?, as who: ScriptCaller? = nil,
    stillAllowed: @MainActor () throws -> Void = {}
  ) async throws -> ScriptValue {
    try await scripting.openTab(
      pane: .pane(pane), directory: directory, caller: who ?? caller, stillAllowed: stillAllowed)
  }

  @discardableResult
  func prepareSend(to pane: ScriptPaneReference, as who: ScriptCaller? = nil) throws
    -> ScriptPaneReference
  {
    try scripting.prepareSend(to: .pane(pane), caller: who ?? caller)
  }

  func send(to pane: ScriptPaneReference, file: URL, as who: ScriptCaller? = nil) throws
    -> ScriptValue
  {
    try scripting.send(to: pane, file: file, caller: who ?? caller)
  }

  /// Opens a pane the caller owns, remote-controlled, beside `pane`, and returns its ID.
  func openOwned(beside pane: ScriptPaneReference, as who: ScriptCaller? = nil) async throws
    -> NodeID
  {
    let reply = try await openPane(
      kind: "terminal", beside: pane, axis: nil, directory: nil, access: .remoteControlled,
      as: who)

    guard case .record(let fields) = reply, case .integer(let id)? = fields["pane"] else {
      throw ScriptCallError.failed("no pane in \(reply)")
    }

    return NodeID(rawValue: id)
  }
}

@MainActor
final class WindowScriptingTests: XCTestCase {
  private func makeFixture(
    windowIDs: WindowIDSource = WindowIDSource(),
    directoryExists: @escaping @Sendable (String) -> Bool = { _ in true }
  ) -> ScriptingFixture {
    let fixture = ScriptingFixture(windowIDs: windowIDs, directoryExists: directoryExists)
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func record(_ value: ScriptValue) throws -> [String: ScriptValue] {
    guard case .record(let fields) = value else {
      XCTFail("expected a record, got \(value)")
      return [:]
    }

    return fields
  }

  private func array(_ value: ScriptValue) throws -> [ScriptValue] {
    guard case .array(let elements) = value else {
      XCTFail("expected an array, got \(value)")
      return []
    }

    return elements
  }

  private func assertError(
    _ kind: ScriptFailureKind, _ fragment: String? = nil, file: StaticString = #filePath,
    line: UInt = #line, _ body: () async throws -> Any
  ) async {
    do {
      let value = try await body()
      XCTFail("the call succeeded with \(value)", file: file, line: line)
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, kind, error.text, file: file, line: line)

      if let fragment {
        XCTAssertTrue(error.text.contains(fragment), error.text, file: file, line: line)
      }
    } catch {
      XCTFail("the call threw \(error)", file: file, line: line)
    }
  }

  // MARK: Lists

  /// Catches a caller that learns about windows other than its own, or a window ID that is not
  /// the one the window answers to. The caller's binding names its own pane and its control.
  func testListWindowsReportsOnlyTheCallersOwnWindow() async throws {
    let fixture = makeFixture()
    let (first, pane) = try fixture.openWindow()
    _ = try fixture.openWindow()

    first.window?.title = "Synthetic first"

    let listed = try array(try fixture.listWindows())

    XCTAssertEqual(listed.count, 1)

    let entry = try record(listed[0])

    XCTAssertEqual(entry["window"], .integer(first.scriptWindowID))
    XCTAssertEqual(entry["pane"], .integer(pane.pane))
    XCTAssertEqual(entry["control"], .string("remote-controlled"))
    XCTAssertEqual(entry["title"], .string("Synthetic first"))
    XCTAssertNotNil(entry["key"])
    XCTAssertTrue(first.scriptWindowID > 0 && first.scriptWindowID <= ScriptProtocol.maxID)
  }

  /// Catches a pane listing that leaves out the applet type, the control, the title, the directory
  /// the applet reports, or a tab, and a directory that shows up for an applet that reports none. A
  /// tab keeps its number from one listing to the next. A pane the user opened is not the
  /// caller's, so it is left out.
  func testListPanesReportsTypeTitleDirectoryAndTabs() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.title = "Synthetic title"
      applet.currentDirectory = "/synthetic/here"
      applet.tabCount = 2
      return applet
    }

    let (controller, pane) = try fixture.openWindow()

    fixture.make = { FakeApplet() }

    let second = try await fixture.openOwned(beside: pane)
    _ = try XCTUnwrap(controller.openPane(.dataViewer, axis: .row))

    let panes = try array(try fixture.listPanes(window: pane.window))

    XCTAssertEqual(panes.count, 2)

    let first = try record(panes[0])

    XCTAssertEqual(first["pane"], .integer(pane.pane))
    XCTAssertEqual(first["window"], .integer(pane.window))
    XCTAssertEqual(first["applet"], .string("fake"))
    XCTAssertEqual(first["control"], .string("remote-controlled"))
    XCTAssertEqual(first["title"], .string("Synthetic title"))
    XCTAssertEqual(first["directory"], .string("/synthetic/here"))

    let tabs = try array(try XCTUnwrap(first["tabs"]))

    XCTAssertEqual(tabs.count, 2)
    XCTAssertEqual(try record(tabs[0])["selected"], .bool(true))
    XCTAssertEqual(try record(tabs[1])["selected"], .bool(false))

    XCTAssertNil(try record(panes[1])["directory"])
    XCTAssertEqual(try record(panes[1])["pane"], .integer(second.rawValue))

    let again = try array(try fixture.listPanes(window: pane.window))
    let againTabs = try array(try XCTUnwrap(try record(again[0])["tabs"]))

    XCTAssertEqual(againTabs, tabs, "a tab changed its number between two listings")
  }

  /// Catches a listing of a window that is gone, or never was, that answers with panes. It must
  /// answer nothing.
  func testListPanesOfAWindowThatIsNotOpenIsNil() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    controller.window?.close()

    XCTAssertEqual(try fixture.listPanes(window: pane.window), .null)
    XCTAssertEqual(try fixture.listPanes(window: 12345), .null)
    XCTAssertEqual(try fixture.listPanes(window: UInt64.max), .null)
  }

  // MARK: Opening panes

  /// Catches a pane that starts anywhere but the directory the call names, such as the neighbour's.
  func testAPaneOpenedByAScriptStartsInTheDirectoryTheCallNames() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.currentDirectory = "/synthetic/neighbour"
      return applet
    }

    let (controller, pane) = try fixture.openWindow()

    fixture.make = { FakeApplet() }

    let created = try record(
      try await fixture.openPane(
        kind: "data-viewer", beside: pane, axis: nil, directory: "/synthetic/named"))

    XCTAssertEqual(fixture.requested.last, "/synthetic/named")
    XCTAssertEqual(fixture.choices.last, .dataViewer)
    XCTAssertEqual(controller.paneIDs.count, 2)

    guard case .integer(let id)? = created["pane"] else { return XCTFail("no pane in \(created)") }

    XCTAssertTrue(controller.contains(pane: NodeID(rawValue: id)))
    XCTAssertEqual(created["window"], .integer(pane.window))
  }

  /// Catches a pane that starts in the working directory of whatever runs the script, or that
  /// ignores the directory its neighbour reports through the applet contract.
  func testAPaneOpenedWithNoDirectoryStartsWhereItsNeighbourReports() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.currentDirectory = "/synthetic/neighbour"
      return applet
    }

    let (_, pane) = try fixture.openWindow()

    fixture.make = { FakeApplet() }

    _ = try await fixture.openPane(
      kind: "terminal", beside: pane, axis: nil, directory: nil)

    XCTAssertEqual(fixture.requested.last, "/synthetic/neighbour")
    XCTAssertEqual(fixture.choices.last, .terminalShell)
  }

  /// Catches a neighbour that reports no directory being replaced by the app's own working
  /// directory. No directory flows in, and the factory picks the start.
  func testANeighbourWithNoDirectoryLeavesTheStartToTheFactory() async throws {
    let fixture = makeFixture()
    let (_, pane) = try fixture.openWindow()

    _ = try await fixture.openPane(
      kind: "terminal", beside: pane, axis: nil, directory: nil)

    XCTAssertEqual(fixture.requested.count, 2)

    let asked = try XCTUnwrap(fixture.requested.last)

    XCTAssertNil(asked)
  }

  /// Catches a kind or directory the app accepts that it should refuse, and a pane that opens
  /// anyway. A refusal for a bad argument opens nothing.
  func testOpenPaneRefusesBadArgumentsAndOpensNothing() async throws {
    let fixture = makeFixture(directoryExists: { $0 == "/synthetic/exists" })
    let (controller, pane) = try fixture.openWindow()
    let made = fixture.made.count

    await assertError(.badArgument, "kind is not known") {
      try await fixture.openPane(kind: "bogus", beside: pane, axis: nil, directory: nil)
    }

    await assertError(.badArgument, "kind is not known") {
      try await fixture.openPane(
        kind: "launcher", beside: pane, axis: nil, directory: nil)
    }

    for directory in ["relative", "", "./here", "/synthetic/missing", "/a\u{0}b"] {
      await assertError(.badArgument, "directory") {
        try await fixture.openPane(
          kind: "terminal", beside: pane, axis: nil, directory: directory)
      }
    }

    await assertError(.badArgument, "browser has no directory") {
      try await fixture.openPane(
        kind: "browser", beside: pane, axis: nil, directory: "/synthetic/exists")
    }

    XCTAssertEqual(fixture.made.count, made)
    XCTAssertEqual(controller.paneIDs.count, 1)
  }

  /// Catches an axis that the app ignores. Both axes split the pane when there is room.
  func testOpenPaneHonorsTheRequestedAxis() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    for axis in ScriptAxis.allCases {
      _ = try await fixture.openPane(
        kind: "terminal", beside: pane, axis: axis, directory: nil)
    }

    XCTAssertEqual(controller.paneIDs.count, 3)

    let frames = controller.paneArea.tree.layout(in: controller.paneArea.bounds.size).frames
    let first = try XCTUnwrap(frames[pane.pane.nodeID])
    let created = controller.paneIDs.dropFirst().compactMap { frames[$0] }

    XCTAssertEqual(created.count, 2)
    XCTAssertTrue(created.contains { $0.minX >= first.maxX - 1 }, "no pane sits beside the first")
    XCTAssertTrue(
      created.contains { $0.minY != first.minY || $0.maxY != first.maxY },
      "no pane is stacked with the first")
  }

  /// Catches a script-opened pane that leaves focus where it was. A program's split is the same
  /// split the user makes, so the new pane takes focus and its applet the keyboard. It cannot prove
  /// the first responder of a real window.
  func testAScriptOpenedPaneTakesFocusLikeTheUsersSplit() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let before = controller.focusedPane
    let made = fixture.made.count

    _ = try await fixture.openPane(kind: "terminal", beside: pane, axis: nil, directory: nil)

    XCTAssertEqual(controller.paneIDs.count, 2)
    let created = try XCTUnwrap(controller.paneIDs.first { $0 != before })
    XCTAssertEqual(controller.focusedPane, created)

    let opened = try XCTUnwrap(fixture.made.dropFirst(made).first)
    XCTAssertEqual(opened.focusCount, 1)
  }

  /// Catches a pane or tab opened for a caller whose authority ended while its directory was
  /// checked. The authority check runs after the directory check and before the layout changes,
  /// and a refusal from it leaves the window as it was.
  func testACallerRefusedAfterTheDirectoryCheckOpensNoPaneAndNoTab() async throws {
    let checked = DirectoryCheckLog()
    let fixture = makeFixture(directoryExists: { _ in
      checked.record()
      return true
    })

    fixture.make = {
      let applet = FakeApplet()
      applet.canOpenTab = true
      return applet
    }

    let (controller, pane) = try fixture.openWindow()
    let applet = try XCTUnwrap(fixture.made.first)
    var checksSeen: [Int] = []
    let refuse: @MainActor () throws -> Void = {
      checksSeen.append(checked.count)
      throw ScriptCallError.refused("synthetic refusal")
    }

    await assertError(.refused, "synthetic refusal") {
      try await fixture.openPane(
        kind: "terminal", beside: pane, axis: nil, directory: "/synthetic", stillAllowed: refuse)
    }

    await assertError(.refused, "synthetic refusal") {
      try await fixture.openTab(
        pane: pane, directory: "/synthetic", stillAllowed: refuse)
    }

    XCTAssertEqual(checksSeen, [1, 2], "the authority check ran before the directory check")
    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertEqual(applet.openedTabDirectories, [])
  }

  // MARK: Opening tabs

  /// Catches a tab opened in the wrong place or with the wrong directory, and a reference that does
  /// not name the new tab. The reference's tab number must resolve to the tab the applet made.
  func testOpenTabStartsInTheNamedDirectoryAndReturnsTheNewTab() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.canOpenTab = true
      applet.currentDirectory = "/synthetic/pane"
      return applet
    }

    let (controller, pane) = try fixture.openWindow()
    let applet = try XCTUnwrap(fixture.made.first)

    let named = try record(
      try await fixture.openTab(pane: pane, directory: "/synthetic/tab"))
    let plain = try record(try await fixture.openTab(pane: pane, directory: nil))

    XCTAssertEqual(applet.openedTabDirectories, ["/synthetic/tab", "/synthetic/pane"])
    XCTAssertEqual(applet.tabCount, 3)
    XCTAssertEqual(named["window"], .integer(pane.window))
    XCTAssertEqual(named["pane"], .integer(pane.pane))

    guard case .integer(let number)? = named["tab"], case .integer(let other)? = plain["tab"]
    else { return XCTFail("a tab reference has no tab number") }

    XCTAssertNotEqual(number, other)
    XCTAssertEqual(
      controller.scriptTabNumbers.tab(for: number), applet.tabID(1),
      "the first new tab's number names another tab")
  }

  /// Catches a tab whose start is left to the applet while the pane reports a directory. The host
  /// passes the pane's reported directory itself, as open-pane does. When the pane reports none, the
  /// host passes none, and the applet's own default applies. A terminal's is the home directory.
  func testOpenTabPassesNoDirectoryWhenThePaneReportsNone() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.canOpenTab = true
      return applet
    }

    let (_, pane) = try fixture.openWindow()
    let applet = try XCTUnwrap(fixture.made.first)

    _ = try await fixture.openTab(pane: pane, directory: nil)

    XCTAssertEqual(applet.openedTabDirectories, [nil])
  }

  /// Catches an open-tab that works on an applet with no tabs, a terminal that runs one program,
  /// or a browser asked for a directory it has no use for.
  func testOpenTabRefusesWhereTheAppletHasNoTabToOpen() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let applet = try XCTUnwrap(fixture.made.first)

    applet.canOpenTab = false

    await assertError(.refused, "cannot open another tab") {
      try await fixture.openTab(pane: pane, directory: nil)
    }

    XCTAssertEqual(applet.tabCount, 1)

    applet.canOpenTab = true
    applet.tabsStartInDirectory = false

    await assertError(.badArgument, "no directory") {
      try await fixture.openTab(pane: pane, directory: "/synthetic/tab")
    }

    _ = try await fixture.openTab(pane: pane, directory: nil)

    let launcher = try XCTUnwrap(controller.openLauncher(axis: .row))
    let plain = ScriptPaneReference(window: pane.window, pane: launcher.rawValue)
    let fromLauncher = ScriptCaller(connection: 2, window: pane.window, pane: launcher)

    controller.enableRemoteControl(launcher)

    await assertError(.refused, "no tabs to open") {
      try await fixture.openTab(pane: plain, directory: nil, as: fromLauncher)
    }

    await assertError(.badArgument, "absolute path") {
      try await fixture.openTab(pane: pane, directory: "relative")
    }
  }

  // MARK: Sending

  /// Catches a send that never reaches the viewer, or that starts it in the private folder where
  /// the content waits. A split from that viewer would then start there too.
  func testSendHandsTheFileToAViewerAndStartsItInTheViewersDirectory() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.currentDirectory = "/synthetic/viewer"
      return applet
    }

    let (_, pane) = try fixture.openWindow()
    let applet = try XCTUnwrap(fixture.made.first)
    let file = URL(fileURLWithPath: "/private/synthetic/spool/report.csv")

    try fixture.prepareSend(to: pane)
    XCTAssertEqual(try fixture.send(to: pane, file: file), .null)

    XCTAssertEqual(applet.replacedSources.map(\.file), [file])
    XCTAssertEqual(applet.replacedSources.map(\.start), ["/synthetic/viewer"])

    applet.currentDirectory = nil

    _ = try fixture.send(to: pane, file: file)

    XCTAssertEqual(applet.replacedSources.last?.start, NSHomeDirectory())
  }

  /// Catches a send that reaches an applet that owns its input, even one that could also take a
  /// source. The refusal is the declared property, so it holds before the source check. A second
  /// applet that is not a source at all gets the other refusal.
  func testSendIsRefusedForAnAppletThatOwnsItsInputAndForOneThatShowsNoSource() async throws {
    let fixture = makeFixture()
    fixture.make = { OwnedInputApplet() }

    let (controller, pane) = try fixture.openWindow()
    let owned = try XCTUnwrap(fixture.made.first)
    let file = URL(fileURLWithPath: "/private/synthetic/spool/a.txt")

    await assertError(.refused, "owns this pane's input") {
      try fixture.prepareSend(to: pane)
      return 0
    }

    await assertError(.refused, "owns this pane's input") {
      try fixture.send(to: pane, file: file)
    }

    XCTAssertTrue(owned.replacedSources.isEmpty)

    let launcher = try XCTUnwrap(controller.openLauncher(axis: .row))
    let plain = ScriptPaneReference(window: pane.window, pane: launcher.rawValue)
    let fromLauncher = ScriptCaller(connection: 2, window: pane.window, pane: launcher)

    controller.enableRemoteControl(launcher)

    await assertError(.refused, "cannot show sent content") {
      try fixture.prepareSend(to: plain, as: fromLauncher)
      return 0
    }
  }

  /// Catches an applet's own failure to open the content being reported as success.
  func testSendReportsAnAppletThatCannotOpenTheContent() async throws {
    let fixture = makeFixture()
    let (_, pane) = try fixture.openWindow()
    let applet = try XCTUnwrap(fixture.made.first)

    applet.replaceFailure = NSError(domain: "synthetic", code: 1)

    await assertError(.failed, "could not open the content") {
      try fixture.send(to: pane, file: URL(fileURLWithPath: "/private/synthetic/b.txt"))
    }
  }

  /// Catches a send that swaps a pane's source while a sheet is up. A sheet can be the pane's own
  /// Save question, so the pane must not change under it. The refusal is the one open-pane gives.
  func testSendIsRefusedWhileASheetIsUp() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let applet = try XCTUnwrap(fixture.made.first)
    let window = try XCTUnwrap(controller.window)

    window.orderFrontRegardless()

    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.beginSheet(sheet, completionHandler: nil)
    XCTAssertNotNil(window.attachedSheet)

    let file = URL(fileURLWithPath: "/private/synthetic/spool/a.txt")

    await assertError(.refused, "waiting for an answer") {
      try fixture.prepareSend(to: pane)
      return 0
    }

    await assertError(.refused, "waiting for an answer") {
      try fixture.send(to: pane, file: file)
    }

    await assertError(.refused, "waiting for an answer") {
      try await fixture.openPane(
        kind: "terminal", beside: pane, axis: nil, directory: nil)
    }

    XCTAssertTrue(applet.replacedSources.isEmpty)

    window.endSheet(sheet)
  }

  /// Catches an open-tab that adds a tab while a sheet is up. The sheet can be the pane's own Save
  /// question, so open-tab waits as open-pane and send do. Without the gate the tab opens.
  func testOpenTabIsRefusedWhileASheetIsUp() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.canOpenTab = true
      return applet
    }

    let (controller, pane) = try fixture.openWindow()
    let applet = try XCTUnwrap(fixture.made.first)
    let window = try XCTUnwrap(controller.window)

    window.orderFrontRegardless()

    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.beginSheet(sheet, completionHandler: nil)
    XCTAssertNotNil(window.attachedSheet)

    await assertError(.refused, "waiting for an answer") {
      try await fixture.openTab(pane: pane, directory: nil)
    }

    XCTAssertEqual(applet.tabCount, 1)

    window.endSheet(sheet)

    _ = try await fixture.openTab(pane: pane, directory: nil)

    XCTAssertEqual(applet.tabCount, 2, "the tab did not open once the sheet was answered")
  }

  // MARK: Directory check

  private final class ThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checked: [Bool] = []

    func record() {
      lock.lock()
      checked.append(Thread.isMainThread)
      lock.unlock()
    }

    var onMain: [Bool] {
      lock.lock()
      defer { lock.unlock() }
      return checked
    }
  }

  /// Catches a directory check that runs on the main thread, where a stat on a hung network mount
  /// would freeze every window.
  func testTheDirectoryCheckRunsOffTheMainThread() async throws {
    let probe = ThreadProbe()
    let fixture = makeFixture(directoryExists: {
      _ in
      probe.record()
      return true
    })

    fixture.make = {
      let applet = FakeApplet()
      applet.canOpenTab = true
      return applet
    }

    let (_, pane) = try fixture.openWindow()

    _ = try await fixture.openPane(
      kind: "terminal", beside: pane, axis: nil, directory: "/synthetic/x")
    _ = try await fixture.openTab(pane: pane, directory: "/synthetic/y")

    XCTAssertEqual(probe.onMain, [false, false], "a directory check ran on the main thread")
  }

  /// Catches a pane that was looked up before the directory check and used after it. The window
  /// closes while the check waits, and the call must find the pane gone.
  func testAPaneThatClosesDuringTheDirectoryCheckIsNotFound() async throws {
    let gate = DispatchSemaphore(value: 0)
    let fixture = makeFixture(directoryExists: { _ in
      _ = gate.wait(timeout: .now() + 10)
      return true
    })

    let (controller, pane) = try fixture.openWindow()
    let made = fixture.made.count

    let call = Task { @MainActor in
      try await fixture.openPane(
        kind: "terminal", beside: pane, axis: nil, directory: "/synthetic/x")
    }

    await Task.yield()
    controller.window?.close()
    gate.signal()

    do {
      _ = try await call.value
      XCTFail("the call opened a pane in a closed window")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .notFound)
    }

    XCTAssertEqual(fixture.made.count, made)
  }

  // MARK: Reported text

  /// Catches program text that reaches a script with C1 controls or bidirectional overrides, which
  /// the status bar already strips, and text that is not cut to the bound.
  func testReportedTextIsCleanedLikeStatusText() {
    let dirty = "a\u{0085}b\u{009B}c\u{202E}d\u{2066}e\u{0007}f\u{200F}g"

    XCTAssertEqual(WindowScripting.reported(dirty), "a b c" + "de f" + "g")

    let long = String(repeating: "\u{00E9}", count: 1000)

    XCTAssertLessThanOrEqual(WindowScripting.reported(long).utf8.count, 256)
  }

  // MARK: Open panes

  /// Catches a pane that a script sees as open after it closed. The host keeps a sent file only
  /// while its pane is open.
  func testIsOpenFollowsThePane() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    XCTAssertTrue(fixture.scripting.isOpen(pane))
    XCTAssertFalse(
      fixture.scripting.isOpen(ScriptPaneReference(window: pane.window, pane: pane.pane + 99)))

    controller.window?.close()

    XCTAssertFalse(fixture.scripting.isOpen(pane))
  }

  // MARK: Stale references

  /// Catches a reference from an earlier launch that lands on a pane of this one. Pane IDs restart
  /// at the same numbers in every launch, so only the window ID can tell the launches apart. The
  /// second launch holds a pane with the same number, and the old reference must still name nothing.
  func testAReferenceFromAnEarlierLaunchResolvesToNothing() async throws {
    let earlier = makeFixture(windowIDs: WindowIDSource(draw: { 0x1111 }))
    let later = makeFixture(windowIDs: WindowIDSource(draw: { 0x2222 }))

    let (_, old) = try earlier.openWindow()
    let (_, current) = try later.openWindow()

    XCTAssertEqual(old.pane, current.pane, "the fixture must reuse the pane number")
    XCTAssertNotEqual(old.window, current.window)

    await assertError(.notFound) {
      try await later.openPane(kind: "terminal", beside: old, axis: nil, directory: nil)
    }

    await assertError(.notFound) {
      try await later.openTab(pane: old, directory: nil)
    }

    await assertError(.notFound) {
      try later.prepareSend(to: old)
      return 0
    }

    XCTAssertEqual(try later.listPanes(window: old.window), .null)
    XCTAssertEqual(later.made.count, 1, "an earlier launch's reference opened something")
  }

  /// Catches a reference to a closed pane, a closed window, or an ID that was never issued that
  /// resolves to anything, and an ID at the edges of the range that traps.
  func testReferencesToWhatIsNotOpenNameNothing() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let created = try record(
      try await fixture.openPane(
        kind: "terminal", beside: pane, axis: nil, directory: nil))

    guard case .integer(let closedID)? = created["pane"] else { return XCTFail("no pane ID") }

    controller.closePane(NodeID(rawValue: closedID), appletEnded: true)

    let closed = ScriptPaneReference(window: pane.window, pane: closedID)

    await assertError(.notFound, "pane is not open") {
      try await fixture.openTab(pane: closed, directory: nil)
    }

    let edges: [UInt64] = [0, ScriptProtocol.maxID, ScriptProtocol.maxID + 1, UInt64.max]

    for edge in edges {
      await assertError(.notFound) {
        try await fixture.openTab(
          pane: ScriptPaneReference(window: pane.window, pane: edge), directory: nil)
      }

      await assertError(.notFound, "window is not open") {
        try await fixture.openTab(
          pane: ScriptPaneReference(window: edge, pane: pane.pane), directory: nil)
      }
    }

    controller.window?.close()

    await assertError(.notFound, "window is not open") {
      try await fixture.openTab(pane: pane, directory: nil)
    }
  }

  /// Catches a tab reference that names a tab it should not: a number that was never issued, a tab
  /// that closed, and a tab of another pane.
  func testATabReferenceNamesOnlyAnOpenTabOfThatPane() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.canOpenTab = true
      applet.tabCount = 2
      return applet
    }

    let (_, pane) = try fixture.openWindow()
    let other = try await fixture.openOwned(beside: pane)
    let applet = try XCTUnwrap(fixture.made.first)

    let listed = try array(try fixture.listPanes(window: pane.window))
    let tabs = try array(try XCTUnwrap(try record(listed[0])["tabs"]))
    let numbers = try tabs.map { entry -> UInt64 in
      guard case .integer(let number)? = try record(entry)["tab"] else { return 0 }
      return number
    }

    func reference(tab: UInt64?, in paneID: UInt64 = pane.pane) -> ScriptPaneReference {
      ScriptPaneReference(window: pane.window, pane: paneID, tab: tab)
    }

    XCTAssertNoThrow(try fixture.prepareSend(to: reference(tab: numbers[0])))

    await assertError(.notFound, "tab is not open") {
      try await fixture.openTab(pane: reference(tab: 9999), directory: nil)
    }

    await assertError(.notFound, "tab is not open") {
      try await fixture.openTab(
        pane: reference(tab: numbers[0], in: other.rawValue), directory: nil)
    }

    applet.removeTab(at: 1)

    await assertError(.notFound, "tab is not open") {
      try await fixture.openTab(pane: reference(tab: numbers[1]), directory: nil)
    }

    let fresh = try record(
      try await fixture.openTab(pane: reference(tab: nil), directory: nil))

    guard case .integer(let freshNumber)? = fresh["tab"] else { return XCTFail("no tab number") }

    XCTAssertFalse(numbers.contains(freshNumber), "a closed tab's number was reused")
  }
}

extension UInt64 {
  fileprivate var nodeID: NodeID { NodeID(rawValue: self) }
}

/// Counts the directory checks, which run off the main actor.
private final class DirectoryCheckLog: @unchecked Sendable {
  private let lock = NSLock()
  private var checks = 0

  func record() {
    lock.lock()
    checks += 1
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }

    return checks
  }
}
