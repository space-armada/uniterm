import AppKit
import AppletKit
import PaneModel
import XCTest

@testable import WindowKit

@MainActor
private final class KeyCatcher: NSView {
  var keysSeen = 0

  override var acceptsFirstResponder: Bool { true }

  /// Stands in for a terminal that would take a Control chord as input.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    keysSeen += 1
    return true
  }
}

@MainActor
private final class MenuProbe: NSObject {
  var fired: [String] = []

  @objc func fire(_ sender: NSMenuItem) {
    fired.append(sender.title)
  }
}

/// The palette's behavior in a window: what it targets, how it hides, and which keys reach the
/// menu before a view. The real menu, the field editor, and App Shortcuts remaps need the app, so
/// the UI tests cover them.
@MainActor
final class CommandPaletteTests: XCTestCase {
  private var fixture: WindowFixture!
  private var controller: MainWindowController { fixture.controller }
  private var palette: CommandPaletteView { controller.contentController.commandPalette }
  private var savedMenu: NSMenu?
  private var installed: CommandMenu?

  override func setUp() async throws {
    fixture = try WindowFixture()
    savedMenu = NSApp.mainMenu
  }

  override func tearDown() async throws {
    NSApp.mainMenu = savedMenu
    fixture.cleanUp()
  }

  private func applet(_ pane: NodeID) throws -> FakeApplet {
    try XCTUnwrap(controller.paneArea.applet(for: pane) as? FakeApplet)
  }

  private func type(_ text: String) {
    palette.field.stringValue = text
    palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  }

  private func rowValues() -> [String?] {
    palette.entries.indices.map { row in
      palette.tableView(NSTableView(), viewFor: nil, row: row)?.accessibilityValue() as? String
    }
  }

  private func entry(_ id: CommandID) -> PaletteEntry? {
    palette.entries.first { $0.id == .command(id) }
  }

  private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
  }

  /// The app's menu, built from the controller's registry, with the key window fixed to the test's
  /// window so the test needs no key window. A probe item on a Control chord stands in for a menu
  /// item that a user's remap put on a key.
  private func installMenu(probe: MenuProbe? = nil) {
    let commandMenu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    commandMenu.keyController = { [controller] in controller }
    commandMenu.install()
    installed = commandMenu

    if let probe {
      let extra = NSMenuItem(
        title: "Probe", action: #selector(MenuProbe.fire(_:)), keyEquivalent: "a")
      extra.keyEquivalentModifierMask = .control
      extra.target = probe
      commandMenu.menu.items[1].submenu?.addItem(extra)
    }
  }

  // MARK: Showing and hiding

  /// Catches a palette that never takes the keyboard, or one that forgets which pane to return to.
  func testShowingTakesTheKeyboardAndRecordsThePaneToReturnTo() throws {
    controller.showCommandPalette()

    XCTAssertFalse(palette.isHidden)
    XCTAssertEqual(controller.paletteTarget, controller.focusedPane)
    XCTAssertTrue(controller.window?.firstResponder === palette.field.currentEditor())

    controller.hideCommandPalette(restoringFocus: true)

    XCTAssertTrue(palette.isHidden)
    XCTAssertNil(controller.paletteTarget)
  }

  /// Catches a toggle that shows the palette again, or runs something, when pressed while shown.
  func testTheToggleKeyHidesAShowingPaletteAndNothingElse() throws {
    installMenu()
    controller.showCommandPalette()

    let window = try XCTUnwrap(controller.window)
    XCTAssertTrue(window.performKeyEquivalent(with: try key("k", .command)))

    XCTAssertTrue(palette.isHidden)

    XCTAssertTrue(window.performKeyEquivalent(with: try key("k", .command)))
    XCTAssertFalse(palette.isHidden)
  }

  /// Catches Cmd-W that closes a pane or tab while the field has focus. It must only dismiss.
  func testCommandWDismissesThePaletteAndClosesNothing() throws {
    installMenu()
    controller.openPane(.terminalShell, axis: .row)
    let focused = controller.focusedPane
    let fake = try applet(focused)
    fake.tabCount = 2

    controller.showCommandPalette()

    let window = try XCTUnwrap(controller.window)
    XCTAssertTrue(window.performKeyEquivalent(with: try key("w", .command)))

    XCTAssertTrue(palette.isHidden)
    XCTAssertEqual(controller.paneIDs.count, 2)
    XCTAssertEqual(fake.tabsClosed, 0)
  }

  /// Catches a binding that runs on the palette's field or on the wrong pane. Cmd-T hides the
  /// palette, then opens the tab in the pane that had focus before.
  func testAnotherBindingDismissesThenRunsOnThePriorPane() throws {
    installMenu()
    controller.openPane(.terminalShell, axis: .row)
    let prior = controller.focusedPane
    let other = try XCTUnwrap(controller.paneIDs.first { $0 != prior })
    try applet(prior).canOpenTab = true
    try applet(other).canOpenTab = true

    controller.showCommandPalette()

    let window = try XCTUnwrap(controller.window)
    XCTAssertTrue(window.performKeyEquivalent(with: try key("t", .command)))

    XCTAssertTrue(palette.isHidden)
    XCTAssertEqual(try applet(prior).openedTabs, 1)
    XCTAssertEqual(try applet(other).openedTabs, 0)
  }

  /// Catches Escape that leaves the keyboard in a hidden field.
  func testEscapeHidesAndReturnsTheKeyboardToThePane() throws {
    controller.showCommandPalette()

    XCTAssertTrue(
      palette.control(
        palette.field, textView: NSTextView(),
        doCommandBy: #selector(NSResponder.cancelOperation(_:))))

    XCTAssertTrue(palette.isHidden)
    XCTAssertFalse(controller.window?.firstResponder === palette.field.currentEditor())
  }

  /// Catches a hide that pulls the keyboard back from something that took it meanwhile, such as a
  /// sheet, the applet chooser, or another window.
  func testHidingNeverTakesTheKeyboardBackFromWhatTookIt() throws {
    let window = try XCTUnwrap(controller.window)
    controller.showCommandPalette()

    let taker = KeyCatcher()
    try applet(controller.focusedPane).view.addSubview(taker)
    XCTAssertTrue(window.makeFirstResponder(taker))

    controller.hideCommandPalette(restoringFocus: true)

    XCTAssertTrue(window.firstResponder === taker)
  }

  // MARK: Running commands

  /// Catches a palette command that acts on the palette, not on the prior pane.
  func testEnterRunsTheSelectedCommandOnThePriorPane() throws {
    controller.showCommandPalette()
    type("split right")

    XCTAssertEqual(palette.selectedEntry?.id, .command(.splitRight))
    XCTAssertTrue(
      palette.control(
        palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))
      ))

    XCTAssertTrue(palette.isHidden)
    XCTAssertEqual(controller.paneIDs.count, 2)
    XCTAssertEqual(controller.commands.recency.first, .splitRight)
  }

  /// Catches a disabled row that runs. New Tab is unavailable in an applet that cannot open tabs.
  func testAnUnavailableCommandShowsDisabledAndEnterIgnoresIt() throws {
    controller.showCommandPalette()
    type("new tab")

    XCTAssertEqual(entry(.fakeNewTab)?.isEnabled, false)
    XCTAssertNil(palette.selection)

    _ = palette.control(
      palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertFalse(palette.isHidden)
    XCTAssertEqual(try applet(controller.focusedPane).openedTabs, 0)
  }

  /// Catches the palette listing its own toggle, or the digit bindings that only duplicate tabs.
  func testTheListLeavesOutTheToggleAndTheDigitBindings() throws {
    controller.showCommandPalette()

    XCTAssertNil(entry(.showCommandPalette))
    XCTAssertNil(entry(.fakeTab(3)))
    XCTAssertNotNil(entry(.splitRight))
  }

  /// Catches a command that falls back to another pane when its pane closed under the palette.
  func testACommandWhosePaneClosedPostsAMessageInsteadOfActing() throws {
    controller.openPane(.terminalShell, axis: .row)
    let prior = controller.focusedPane

    controller.showCommandPalette()
    controller.closePane(prior, appletEnded: true)

    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertFalse(palette.isHidden)

    controller.dispatch(.splitRight)

    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertTrue(fixture.center.history.last?.text.contains("Split Right") == true)
    XCTAssertTrue(palette.isHidden)
  }

  /// Catches a command row that hides the palette and does nothing, silently, when its own check
  /// fails after the list was built. The palette stays up, the row dims where it stands with no
  /// row selected, and the status bar names the command.
  func testChoosingACommandThatBecameUnavailableKeepsThePaletteUpAndSaysWhy() throws {
    controller.showCommandPalette()
    type("clear screen")

    let chosen = try XCTUnwrap(entry(.fakeClear))
    XCTAssertTrue(chosen.isEnabled)
    XCTAssertEqual(palette.selection, chosen.id)

    let before = palette.entries.map(\.id)
    let posted = fixture.center.history.count
    try applet(controller.focusedPane).canPerformText = false

    palette.onChoose?(chosen)

    XCTAssertFalse(palette.isHidden)
    XCTAssertEqual(palette.entries.map(\.id), before)
    XCTAssertEqual(entry(.fakeClear)?.isEnabled, false)
    XCTAssertNil(palette.selection)
    XCTAssertEqual(try applet(controller.focusedPane).textActions, [])

    XCTAssertEqual(fixture.center.history.count, posted + 1)
    XCTAssertEqual(fixture.center.history.last?.level, .warning)
    XCTAssertEqual(
      fixture.center.history.last?.text,
      "\u{201C}Clear Screen\u{201D} did not run, because it is not available now.")
  }

  /// Catches a pane-gone row chosen in the palette that says so twice, or that stays up. The
  /// palette hides and the gone-pane message is the only one posted.
  func testChoosingACommandWhosePaneClosedHidesAndPostsOneMessage() throws {
    controller.openPane(.terminalShell, axis: .row)
    let prior = controller.focusedPane

    controller.showCommandPalette()
    let chosen = try XCTUnwrap(entry(.splitRight))
    let posted = fixture.center.history.count
    controller.closePane(prior, appletEnded: true)

    palette.onChoose?(chosen)

    XCTAssertTrue(palette.isHidden)
    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertEqual(fixture.center.history.count, posted + 1)
    XCTAssertTrue(fixture.center.history.last?.text.contains("has closed") == true)
  }

  /// Shows the palette with New Tab enabled and moves the selection onto its row, then makes New Tab
  /// unavailable and updates the rows in place, as a change the user did not cause does.
  private func dimSelectedNewTabInPlace() throws -> Int {
    try applet(controller.focusedPane).canOpenTab = true
    controller.showCommandPalette()

    for _ in palette.entries where palette.selection != .command(.fakeNewTab) {
      press(#selector(NSResponder.moveDown(_:)))
    }

    XCTAssertEqual(palette.selection, .command(.fakeNewTab))

    try applet(controller.focusedPane).canOpenTab = false
    controller.updateCommandPaletteInPlace()

    return try XCTUnwrap(palette.entries.firstIndex { $0.id == .command(.fakeNewTab) })
  }

  /// Catches a selection that jumps to another row when the selected row dims in place, so a
  /// second Return runs a command the user never looked at. No row is selected, and that holds
  /// through later updates. Down and Up then move from where the dimmed row stands.
  func testASelectedRowThatDimsInPlaceLeavesNoSelectionAndArrowsMoveFromIt() throws {
    let dimmed = try dimSelectedNewTabInPlace()

    XCTAssertEqual(entry(.fakeNewTab)?.isEnabled, false)
    XCTAssertNil(palette.selection)

    controller.updateCommandPaletteInPlace()
    XCTAssertNil(palette.selection)

    press(#selector(NSResponder.insertNewline(_:)))

    XCTAssertFalse(palette.isHidden)
    XCTAssertEqual(try applet(controller.focusedPane).openedTabs, 0)

    let below = try XCTUnwrap(palette.entries.dropFirst(dimmed + 1).first(where: \.isSelectable))
    XCTAssertNotEqual(below.id, palette.entries.first(where: \.isSelectable)?.id)

    press(#selector(NSResponder.moveDown(_:)))
    XCTAssertEqual(palette.selection, below.id)

    controller.hideCommandPalette(restoringFocus: true)
    XCTAssertEqual(try dimSelectedNewTabInPlace(), dimmed)

    let above = try XCTUnwrap(palette.entries.prefix(dimmed).last(where: \.isSelectable))
    XCTAssertNotEqual(above.id, palette.entries.last(where: \.isSelectable)?.id)

    press(#selector(NSResponder.moveUp(_:)))
    XCTAssertEqual(palette.selection, above.id)
  }

  /// Catches an Escape that has nowhere defined to go once the prior pane closed.
  func testEscapeAfterThePriorPaneClosedFocusesTheRemainingPane() throws {
    controller.openPane(.terminalShell, axis: .row)
    let prior = controller.focusedPane
    let remaining = try XCTUnwrap(controller.paneIDs.first { $0 != prior })

    controller.showCommandPalette()
    controller.closePane(prior, appletEnded: true)
    controller.hideCommandPalette(restoringFocus: true)

    XCTAssertEqual(controller.focusedPane, remaining)
  }

  /// Catches a registry command that reads the focused pane. The command must reach the pane
  /// the context names, not the one with focus.
  func testARegistryCommandRunsOnThePaneTheContextNames() throws {
    controller.openPane(.terminalShell, axis: .row)
    let focused = controller.focusedPane
    let other = try XCTUnwrap(controller.paneIDs.first { $0 != focused })

    controller.commands.run(
      .fakeBiggerText, in: CommandContext(controller: controller, pane: other))

    XCTAssertEqual(try applet(other).textActions, ["bigger-text"])
    XCTAssertEqual(try applet(focused).textActions, [])
  }

  // MARK: Mouse

  private func mouseDown(at point: NSPoint) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))
  }

  /// Catches a click outside that leaves the palette up, and a click inside that closes it.
  func testAClickOutsideHidesThePaletteAndAClickInsideDoesNot() throws {
    controller.showCommandPalette()
    fixture.layout()

    let inside = palette.convert(NSPoint(x: 20, y: 10), to: nil)
    XCTAssertFalse(controller.paletteWillHandleMouseDown(try mouseDown(at: inside)))
    XCTAssertFalse(palette.isHidden)

    XCTAssertTrue(controller.paletteWillHandleMouseDown(try mouseDown(at: NSPoint(x: 2, y: 2))))
    XCTAssertTrue(palette.isHidden)
  }

  // MARK: Key route

  /// Catches a view that takes a key a menu item claims. A Control chord is what a remap onto a
  /// terminal's key looks like.
  func testAMenuKeyReachesTheMenuBeforeTheFocusedView() throws {
    let probe = MenuProbe()
    installMenu(probe: probe)

    let window = try XCTUnwrap(controller.window)
    let catcher = KeyCatcher()
    try applet(controller.focusedPane).view.addSubview(catcher)
    XCTAssertTrue(window.makeFirstResponder(catcher))

    XCTAssertTrue(window.performKeyEquivalent(with: try key("a", .control)))

    XCTAssertEqual(probe.fired, ["Probe"])
    XCTAssertEqual(catcher.keysSeen, 0)
  }

  /// Catches a route that swallows a key no menu item claims.
  func testAKeyNoMenuItemClaimsReachesTheView() throws {
    installMenu()

    let window = try XCTUnwrap(controller.window)
    let catcher = KeyCatcher()
    try applet(controller.focusedPane).view.addSubview(catcher)
    XCTAssertTrue(window.makeFirstResponder(catcher))

    XCTAssertTrue(window.performKeyEquivalent(with: try key("q", .control)))

    XCTAssertEqual(catcher.keysSeen, 1)
  }

  /// Catches a keyword key that does not fill in its keyword while the palette is open, or one
  /// that the palette takes from the focused view while it is closed.
  func testKeywordKeysFillInTheirKeywordOnlyWhileThePaletteIsOpen() throws {
    let keys: [(letter: String, keyword: String, values: [String])] = [
      ("k", "kind:", ["Tabs", "Commands"]),
      ("a", "applet:", ["Fake"]),
    ]

    let window = try XCTUnwrap(controller.window)
    let catcher = KeyCatcher()
    try applet(controller.focusedPane).view.addSubview(catcher)
    XCTAssertTrue(window.makeFirstResponder(catcher))

    for (letter, _, _) in keys {
      XCTAssertTrue(window.performKeyEquivalent(with: try key(letter, .control)))
    }

    XCTAssertEqual(catcher.keysSeen, keys.count, "a closed palette took a keyword key")
    XCTAssertEqual(palette.query, "")

    controller.showCommandPalette()

    for (letter, keyword, values) in keys {
      type("zsh")

      XCTAssertTrue(window.performKeyEquivalent(with: try key(letter, .control)))
      XCTAssertEqual(palette.query, keyword)
      XCTAssertEqual(palette.entries.map(\.title), values)
    }

    XCTAssertEqual(catcher.keysSeen, keys.count)
  }

  // MARK: Filter chips

  @discardableResult
  private func press(_ selector: Selector, text: String = "") -> Bool {
    let editor = NSTextView()
    editor.string = text

    return palette.control(palette.field, textView: editor, doCommandBy: selector)
  }

  /// Catches a Tab that moves the keyboard out of the field, or one that ignores the hint.
  func testTabCompletesAKeywordHintAndKeepsTheKeyboardInTheField() {
    controller.showCommandPalette()
    type("ap")

    XCTAssertTrue(press(#selector(NSResponder.insertTab(_:))))
    XCTAssertEqual(palette.query, "applet:")
    XCTAssertEqual(palette.entries.map(\.title), ["Fake"])

    type("zsh")
    XCTAssertTrue(press(#selector(NSResponder.insertTab(_:))), "a Tab with nothing to do moved on")
    XCTAssertTrue(press(#selector(NSResponder.insertBacktab(_:))))
    XCTAssertEqual(palette.query, "zsh")
  }

  /// Catches a suggestion that runs as a command, or a chip that keeps the text that found it or
  /// lets commands through.
  func testTabOrReturnTurnsASuggestionIntoAChipThatKeepsOnlyItsTabs() throws {
    try applet(controller.focusedPane).title = "shell"
    controller.showCommandPalette()

    type("applet:fa")
    press(#selector(NSResponder.insertTab(_:)))

    XCTAssertEqual(palette.filter, .applet(PaletteAppletType(WindowFixture.fakeType)))
    XCTAssertFalse(palette.chip.isHidden)
    XCTAssertEqual(palette.chip.text, "Fake")
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.entries.map(\.kind), [.tab])
    XCTAssertTrue(controller.isPaletteVisible)

    type("kind:co")
    press(#selector(NSResponder.insertNewline(_:)))

    XCTAssertEqual(palette.filter, .commands, "the new chip did not replace the old one")
    XCTAssertTrue(controller.isPaletteVisible)
    XCTAssertTrue(palette.entries.allSatisfy { $0.kind == .command })
  }

  /// Catches a filter or notice row that VoiceOver reads with an empty kind, as ", enabled". Each
  /// row's value names its kind, as every other row's does.
  func testFilterAndNoticeRowsReadTheirKind() {
    controller.showCommandPalette()
    type("applet:fa")

    XCTAssertEqual(palette.entries.map(\.kind), [.filter])
    XCTAssertEqual(rowValues(), ["Filter, enabled"])

    type("applet:zzz")

    XCTAssertEqual(palette.entries.map(\.kind), [.notice])
    XCTAssertEqual(rowValues(), ["Notice, enabled"])
  }

  /// Catches a Backspace that removes the chip while there is text to delete, or one that never
  /// removes it.
  func testBackspaceInAnEmptyFieldRemovesTheChip() {
    controller.showCommandPalette()
    type("kind:t")
    press(#selector(NSResponder.insertTab(_:)))
    XCTAssertEqual(palette.filter, .tabs)

    XCTAssertFalse(press(#selector(NSResponder.deleteBackward(_:)), text: "x"))
    XCTAssertEqual(palette.filter, .tabs)

    XCTAssertTrue(press(#selector(NSResponder.deleteBackward(_:))))
    XCTAssertNil(palette.filter)
    XCTAssertTrue(palette.chip.isHidden)
  }

  /// Catches a chip that survives the palette hiding, so the next search would start filtered.
  func testHidingThePaletteClearsTheChip() {
    controller.showCommandPalette()
    type("kind:c")
    press(#selector(NSResponder.insertTab(_:)))
    XCTAssertEqual(palette.filter, .commands)

    controller.hideCommandPalette(restoringFocus: true)
    controller.showCommandPalette()

    XCTAssertNil(palette.filter)
    XCTAssertTrue(palette.chip.isHidden)
  }

  /// Catches a remove button that leaves the chip in place.
  func testTheChipsButtonRemovesIt() {
    controller.showCommandPalette()
    type("kind:t")
    press(#selector(NSResponder.insertTab(_:)))

    palette.chip.removeButton.performClick(nil)

    XCTAssertNil(palette.filter)
  }
}
