import AppKit
import AppletKit
import PaneModel
import XCTest

@testable import WindowKit

/// Tab search in a window with fake applets: what the palette lists, how it follows the tabs
/// while it shows, and what Return acts on. The real terminal, the field editor, and focus in a
/// live window need the app, so the UI tests cover them.
@MainActor
final class TabSearchTests: XCTestCase {
  private var fixture: WindowFixture!
  private var wake: WakeScheduler!
  private var controller: MainWindowController { fixture.controller }
  private var palette: CommandPaletteView { controller.contentController.commandPalette }

  override func setUp() async throws {
    fixture = try WindowFixture()
    wake = WakeScheduler()

    let wake = wake!
    controller.paletteWake = { delay, action in _ = wake.schedule(delay, action) }
  }

  override func tearDown() async throws {
    fixture.cleanUp()
  }

  private func applet(_ pane: NodeID) throws -> FakeApplet {
    try XCTUnwrap(controller.paneArea.applet(for: pane) as? FakeApplet)
  }

  private func type(_ text: String) {
    palette.field.stringValue = text
    palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  }

  private func pressReturn() {
    _ = palette.control(
      palette.field, textView: NSTextView(),
      doCommandBy: #selector(NSResponder.insertNewline(_:)))
  }

  private func tabEntries() -> [PaletteEntry] {
    palette.entries.filter { $0.kind == .tab }
  }

  private func entry(pane: NodeID, tab: AppletTabID) -> PaletteEntry? {
    palette.entries.first { $0.id == .tab(pane: pane, tab: tab) }
  }

  /// Two panes: the first holds three tabs, the second one.
  private func twoPanes() throws -> (first: NodeID, second: NodeID) {
    let first = controller.focusedPane
    let firstApplet = try applet(first)
    firstApplet.title = "shell"
    firstApplet.tabCount = 3
    firstApplet.tabTitles = ["shell", "vim notes", "htop"]

    let second = try XCTUnwrap(controller.openPane(.terminalShell, axis: .row))
    try applet(second).title = "logs"

    return (first, second)
  }

  /// Catches a walk that skips a pane, or a tab other than the selected one.
  func testEveryTabOfEveryPaneAppearsAsATab() throws {
    let (first, second) = try twoPanes()
    controller.showCommandPalette()

    let ids =
      try applet(first).publishedTabs.all.map(\.id) + applet(second).publishedTabs.all.map(\.id)

    XCTAssertEqual(tabEntries().count, 4)
    XCTAssertEqual(Set(tabEntries().map(\.id)).count, 4)
    XCTAssertEqual(
      Set(tabEntries().map(\.id)),
      Set(
        ids.enumerated().map { index, id in
          .tab(pane: index < 3 ? first : second, tab: id)
        }))
    XCTAssertEqual(Set(tabEntries().map(\.title)), ["shell", "vim notes", "htop", "logs"])
  }

  /// Catches a choice that selects the tab but leaves the keyboard on the pane that had it, or
  /// focuses the pane but leaves another tab showing.
  func testChoosingATabFocusesItsPaneAndSelectsTheTab() throws {
    let (first, second) = try twoPanes()
    let firstApplet = try applet(first)

    XCTAssertEqual(controller.focusedPane, second)
    controller.showCommandPalette()

    let target = try XCTUnwrap(entry(pane: first, tab: firstApplet.tabID(2)))
    palette.onChoose?(target)

    XCTAssertTrue(palette.isHidden)
    XCTAssertEqual(controller.focusedPane, first)
    XCTAssertEqual(firstApplet.selectedTabIndex, 2)
  }

  /// Catches a list that re-sorts while the user reads it. A tab that newly matches adds no row, a
  /// listed tab takes its new title where its row stands, and Return goes to the tab that was
  /// highlighted.
  func testARetitledTabUpdatesInPlaceAndNoRowMoves() throws {
    let (first, _) = try twoPanes()
    let firstApplet = try applet(first)
    controller.showCommandPalette()
    type("vim")

    let highlighted = try XCTUnwrap(palette.selection)
    let before = palette.entries.map(\.id)
    XCTAssertEqual(highlighted, .tab(pane: first, tab: firstApplet.tabID(1)))

    firstApplet.tabTitles = ["vim", "vim notes 2", "htop"]
    firstApplet.tabsChanged()
    wake.fire()

    XCTAssertEqual(palette.entries.map(\.id), before)
    XCTAssertNil(entry(pane: first, tab: firstApplet.tabID(0)))
    XCTAssertEqual(entry(pane: first, tab: firstApplet.tabID(1))?.title, "vim notes 2")
    XCTAssertEqual(palette.selection, highlighted)

    pressReturn()

    XCTAssertEqual(firstApplet.selectedTabIndex, 1)
    XCTAssertEqual(controller.focusedPane, first)
  }

  /// Catches a re-sort that never happens. Once the user types, the retitled tab ranks by its new
  /// title.
  func testTypingAfterARetitleSortsTheListAfresh() throws {
    let (first, _) = try twoPanes()
    let firstApplet = try applet(first)
    controller.showCommandPalette()
    type("vim")

    firstApplet.tabTitles = ["vim", "vim notes", "htop"]
    firstApplet.tabsChanged()
    wake.fire()
    type("vi")

    XCTAssertEqual(palette.entries.first?.id, .tab(pane: first, tab: firstApplet.tabID(0)))
  }

  /// Catches a refresh per title change, which would stall typing, or one that moves the
  /// highlight. A burst of 500 changes schedules one refresh, and the selection stays put.
  func testABurstOfTitleChangesCostsOneRefreshAndKeepsTheSelection() throws {
    let (first, _) = try twoPanes()
    let firstApplet = try applet(first)
    controller.showCommandPalette()
    type("vim")

    let before = palette.selection

    for count in 0..<500 {
      firstApplet.tabTitles = ["shell", "vim \(count)", "htop"]
      firstApplet.tabsChanged()
    }

    XCTAssertEqual(wake.pending.count, 1)
    XCTAssertEqual(wake.pending.values.first?.delay, MainWindowController.paletteRefreshInterval)
    XCTAssertEqual(palette.selection, before)

    XCTAssertEqual(tabEntries().first?.title, "vim notes", "the list rebuilt per change")

    wake.fire()

    XCTAssertEqual(tabEntries().first?.title, "vim 499")
    XCTAssertEqual(palette.selection, before)
    XCTAssertTrue(wake.pending.isEmpty)
  }

  /// Catches a stale entry that acts on a tab that closed. The palette stays up, the row stays
  /// where it was, and a message says why nothing happened.
  func testChoosingATabThatIsGoneKeepsTheRowAndPostsAMessage() async throws {
    let (first, second) = try twoPanes()
    let firstApplet = try applet(first)
    controller.showCommandPalette()

    let stale = try XCTUnwrap(entry(pane: first, tab: firstApplet.tabID(1)))
    let before = palette.entries.map(\.id)
    firstApplet.removeTab(at: 1)

    palette.onChoose?(stale)

    XCTAssertFalse(palette.isHidden)
    XCTAssertEqual(palette.entries.map(\.id), before)
    XCTAssertEqual(controller.focusedPane, second)
    XCTAssertEqual(fixture.center.history.last?.text, "\u{201C}vim notes\u{201D} has closed.")
  }

  /// Catches an applet that lists a tab but refuses to select it. The palette must not hide with the
  /// keyboard going nowhere and no message. It stays up, keeps its rows, and says why.
  func testChoosingATabTheAppletRefusesKeepsThePaletteUpAndPostsAMessage() throws {
    let (first, second) = try twoPanes()
    let firstApplet = try applet(first)
    controller.showCommandPalette()

    let chosen = try XCTUnwrap(entry(pane: first, tab: firstApplet.tabID(1)))
    firstApplet.refusesTabSelection = true

    palette.onChoose?(chosen)

    XCTAssertFalse(palette.isHidden)
    XCTAssertEqual(controller.focusedPane, second)
    XCTAssertTrue(fixture.center.history.last?.text.contains("vim notes") == true)
  }

  /// Catches the same for a pane that is gone.
  func testChoosingATabOfAClosedPaneKeepsTheRowAndPostsAMessage() throws {
    let (first, second) = try twoPanes()
    controller.showCommandPalette()

    let stale = try XCTUnwrap(tabEntries().first { $0.title == "logs" })
    controller.closePane(second, appletEnded: true)

    palette.onChoose?(stale)

    XCTAssertFalse(palette.isHidden)
    XCTAssertNotNil(tabEntries().first { $0.title == "logs" })
    XCTAssertEqual(controller.focusedPane, first)
    XCTAssertEqual(fixture.center.history.last?.text, "\u{201C}logs\u{201D} has closed.")
  }

  // MARK: Ranking in the window

  /// Catches an empty query that lists the current tab as the first choice. With panes focused in
  /// the order first, second, first, the list reads current, previous, older, and Return goes to
  /// the previous one.
  func testAnEmptyQueryHighlightsTheMostRecentTabOtherThanTheCurrentOne() throws {
    let (first, second) = try twoPanes()
    controller.paneArea.focus(first, keyboard: false)
    controller.showCommandPalette()

    let order = tabEntries().prefix(2).map(\.id)
    let firstApplet = try applet(first)

    XCTAssertEqual(order[0], .tab(pane: first, tab: firstApplet.tabID(0)))
    XCTAssertEqual(order[1], .tab(pane: second, tab: try applet(second).tabID(0)))
    XCTAssertEqual(palette.selection, order[1])
  }

  /// Catches the empty-query order that ignores kinds. Tabs focused before come first, then the
  /// commands run before, then the tabs never focused, then the other commands by title.
  func testAnEmptyQueryOrdersRecentTabsThenRecentCommandsThenTheRest() throws {
    let (first, _) = try twoPanes()
    controller.paneArea.focus(first, keyboard: false)

    let context = CommandContext(controller: controller, pane: first)
    XCTAssertTrue(controller.commands.run(.fakeActualSize, in: context))

    controller.showCommandPalette()

    let kinds = palette.entries.map { entry -> String in
      switch entry.id {
      case .tab(let pane, _): return entry.title.isEmpty ? "" : "tab:\(pane == first ? 1 : 2)"
      case .command(let id): return id == .fakeActualSize ? "recent-command" : "command"
      case .filterKeyword, .filter, .notice: return "filter"
      }
    }

    XCTAssertEqual(Array(kinds.prefix(4)), ["tab:1", "tab:2", "recent-command", "tab:1"])
    XCTAssertEqual(kinds[4], "tab:1")
    XCTAssertEqual(kinds[5], "command")
  }

  /// Catches a tab that is found only by its directory outranking one found by its title.
  func testATitleMatchOutranksAMatchInTheWorkingDirectory() throws {
    let (first, _) = try twoPanes()
    let firstApplet = try applet(first)
    firstApplet.tabTitles = ["alpha", "zebra build", "htop"]
    firstApplet.tabDetails = [0: ["/src/build"]]

    controller.showCommandPalette()
    type("build")

    let titles = tabEntries().map(\.title)
    XCTAssertEqual(titles, ["zebra build", "alpha"])
  }

  /// Catches a recent scattered match that beats an exact prefix. Recency adds a bounded boost.
  func testAPrefixTitleOutranksARecentScatteredMatch() throws {
    let (first, _) = try twoPanes()
    let firstApplet = try applet(first)
    firstApplet.tabTitles = ["build", "b-u-i-l-d x", "htop"]

    controller.paneArea.focus(first, keyboard: false)
    firstApplet.selectedTabIndex = 1
    controller.recordFocusedTab()
    controller.showCommandPalette()
    type("bui")

    XCTAssertEqual(tabEntries().map(\.title).first, "build")
  }

  // MARK: Display

  /// Catches a program title that passes for a command, or forges a row with a newline, or
  /// reorders what follows it with a bidirectional override.
  func testTitlesAndDetailsShowWithControlAndBidiCharactersNeutralized() throws {
    let (first, _) = try twoPanes()
    let firstApplet = try applet(first)
    firstApplet.tabTitles = ["Close\nWindow\u{202E}x\u{1B}[2J", "b", "c"]
    firstApplet.tabDetails = [0: ["/tmp/\u{2066}evil\u{0007}\t/dir"]]

    controller.showCommandPalette()

    let shown = try XCTUnwrap(entry(pane: first, tab: firstApplet.tabID(0)))
    XCTAssertEqual(shown.title, "Close Windowx [2J")
    XCTAssertEqual(shown.detail, "/tmp/evil /dir")
    XCTAssertEqual(shown.kind, .tab)
    XCTAssertEqual(
      palette.entries.first { $0.id == .command(.splitRight) }?.label, "Command")
  }

  /// Catches several applet types' commands that read alike, such as each viewer's "Open in This Pane…". A
  /// command an applet type declares names that type on its row, from the type's declaration.
  /// uniterm's own commands still read "Command".
  func testACommandRowNamesTheAppletTypeThatDeclaresIt() throws {
    controller.showCommandPalette()

    let fake = try XCTUnwrap(palette.entries.first { $0.id == .command(.fakeNewTab) })
    XCTAssertEqual(fake.kind, .command)
    XCTAssertEqual(fake.label, WindowFixture.fakeType.displayName)

    let own = try XCTUnwrap(palette.entries.first { $0.id == .command(.splitRight) })
    XCTAssertEqual(own.label, "Command")
  }

  /// Catches a command row that takes its applet name from anywhere but a declaration. With no
  /// declaration for its type, an applet's command reads as a plain command.
  func testACommandOfAnUndeclaredTypeReadsAsACommand() throws {
    fixture.cleanUp()
    fixture = try WindowFixture(appletTypes: [])

    controller.showCommandPalette()

    let fake = try XCTUnwrap(palette.entries.first { $0.id == .command(.fakeNewTab) })
    XCTAssertEqual(fake.label, "Command")
  }

  /// Catches a tab row that does not name its applet, or that takes the name from anywhere but the
  /// type's declaration. A program title can say anything, so only the declaration may name the
  /// applet. A type with no declaration, such as the launcher, reads as a plain tab.
  func testATabRowNamesItsAppletFromTheDeclaration() throws {
    let (first, _) = try twoPanes()
    try applet(first).tabTitles = ["Browser", "b", "c"]
    let launcher = try XCTUnwrap(controller.openLauncher(axis: .row))

    controller.showCommandPalette()

    let shown = try XCTUnwrap(entry(pane: first, tab: applet(first).tabID(0)))
    XCTAssertEqual(shown.label, "Fake")
    XCTAssertEqual(shown.symbolName, WindowFixture.fakeType.symbolName)

    let plain = try XCTUnwrap(tabEntries().first { $0.id.pane == launcher })
    XCTAssertEqual(plain.label, "Tab")
    XCTAssertNil(plain.symbolName)

    let command = try XCTUnwrap(palette.entries.first { $0.id == .command(.splitRight) })
    XCTAssertEqual(command.symbolName, PaletteEntry.commandSymbol)
  }

  /// Catches an applet with one implicit tab that reads as nothing. A launcher shows by its title.
  func testALauncherReadsByItsTitle() throws {
    let launcher = try XCTUnwrap(controller.openLauncher(axis: .row))
    controller.showCommandPalette()

    XCTAssertTrue(
      tabEntries().contains { $0.title == "New pane" && $0.id.pane == launcher })
  }

  /// Catches a first choice that is the current tab. A query of only spaces ranks as empty, so
  /// it highlights as empty too. Clearing typed text goes back to the first choice, not to the
  /// row that was highlighted while typing.
  func testAnEmptyOrBlankQueryHighlightsTheMostRecentOtherTab() throws {
    let (first, second) = try twoPanes()
    controller.paneArea.focus(first, keyboard: false)
    controller.showCommandPalette()

    let expected = PaletteEntryID.tab(pane: second, tab: try applet(second).tabID(0))
    XCTAssertEqual(palette.selection, expected)

    type("vim")
    XCTAssertNotEqual(palette.selection, expected)

    type("")
    XCTAssertEqual(palette.selection, expected, "clearing the text kept the old highlight")

    type("vim")
    type("  ")
    XCTAssertEqual(palette.selection, expected, "a blank query highlighted by the wrong rule")
  }

  /// Catches a cap that counts grapheme clusters. One letter with thousands of combining marks is
  /// one Character, so the title stays unbounded.
  func testATitleOfManyCombiningMarksIsBounded() throws {
    let (first, _) = try twoPanes()
    let firstApplet = try applet(first)
    firstApplet.tabTitles = ["a" + String(repeating: "\u{0301}", count: 5000), "b", "c"]

    controller.showCommandPalette()

    let shown = try XCTUnwrap(entry(pane: first, tab: firstApplet.tabID(0)))
    XCTAssertLessThanOrEqual(shown.title.unicodeScalars.count, PaletteText.maximumLength)
  }

  /// Catches a title of invisible characters that shows as a blank row instead of the fallback.
  func testATitleOfInvisibleCharactersReadsAsUntitled() throws {
    let (first, _) = try twoPanes()
    let firstApplet = try applet(first)
    firstApplet.tabTitles = ["\u{200B}\u{2060}\u{FEFF}\u{200D}\u{00A0}", "b", "c"]

    controller.showCommandPalette()

    let shown = try XCTUnwrap(entry(pane: first, tab: firstApplet.tabID(0)))
    XCTAssertEqual(shown.title, "Untitled")
  }
}

extension PaletteEntry {
  fileprivate var tabID: AppletTabID? {
    if case .tab(_, let tab) = id { return tab }

    return nil
  }
}

extension PaletteEntryID {
  fileprivate var pane: NodeID? {
    if case .tab(let pane, _) = self { return pane }

    return nil
  }
}
