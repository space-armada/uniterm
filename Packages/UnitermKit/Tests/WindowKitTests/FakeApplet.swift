import AppKit
import AppletKit
import StatusKit
import Theme

@testable import WindowKit

/// Stands in for any applet. It holds one tab and cannot open another, as a plain applet would,
/// until a test says otherwise.
@MainActor
class FakeApplet: Applet {
  let typeID = "fake"
  let view = NSView()
  var title = "Fake"
  var segments: [AppletSegment] = []
  var isRunningSomething = false
  weak var host: (any AppletHost)?

  /// What the applet reports as its current directory. Nil says nothing.
  var currentDirectory: String?
  var started = false
  var closed = false
  var detachCount = 0
  var reattachCount = 0

  /// Unsaved work the applet reports, and what its save answers.
  var unsavedWork: AppletUnsavedWork?
  var saveSucceeds = true
  var saves = 0

  func saveUnsavedWork() async -> Bool {
    saves += 1

    if saveSucceeds { unsavedWork = nil }

    return saveSucceeds
  }

  /// What a dialog calls the running parts. Without it, a running applet names its title.
  var labels: [String]?

  var runningLabels: [String] {
    isRunningSomething ? (labels ?? [title]) : []
  }

  /// Each tab's ID and title, in order. A test sets `tabCount` or `tabTitles` and the tabs follow.
  private var tabIDs: [AppletTabID] = [.make()]
  var tabTitles: [String] = []
  var tabDetails: [Int: [String]] = [:]

  var tabCount: Int {
    get { tabIDs.count }
    set {
      while tabIDs.count < newValue { tabIDs.append(.make()) }
      tabIDs.removeLast(tabIDs.count - max(newValue, 1))
    }
  }

  var selectedTabIndex = 0

  /// The first tab shows the applet's title, and the rest show their own or a numbered name.
  var publishedTabs: AppletTabList {
    let tabs = tabIDs.enumerated().map { index, id in
      let title =
        index < tabTitles.count
        ? tabTitles[index] : (index == 0 ? self.title : "\(self.title) \(index + 1)")
      return AppletTab(id: id, title: title, details: tabDetails[index] ?? [])
    }

    return AppletTabList(
      first: tabs[0], rest: Array(tabs.dropFirst()), selected: tabIDs[selectedTabIndex])
  }

  /// A tab that closed without telling the host, so the palette's list is stale.
  func removeTab(at index: Int) {
    tabIDs.remove(at: index)
    selectedTabIndex = min(selectedTabIndex, tabIDs.count - 1)
  }

  /// Every tab becomes a new tab, as when an applet is restored from its description.
  func renewTabIDs() {
    tabIDs = tabIDs.map { _ in .make() }
  }

  /// The ID of the tab at an index, for a test that aims at it.
  func tabID(_ index: Int) -> AppletTabID { tabIDs[index] }

  /// Tells the host the tab list changed, as an applet would.
  func tabsChanged() { host?.appletTabsDidChange(self) }

  /// Makes `selectTab(id:)` return false even for a tab the applet lists.
  var refusesTabSelection = false

  func selectTab(id: AppletTabID) -> Bool {
    guard !refusesTabSelection, let index = tabIDs.firstIndex(of: id) else { return false }

    selectedTabIndex = index
    return true
  }

  var canOpenTab = false

  /// Whether the applet's tabs start in a directory, as a terminal's do and a browser's do not.
  var tabsStartInDirectory = true

  /// The directory each tab opened through the tab-opening capability was asked to start in.
  var openedTabDirectories: [String?] = []
  var openedTabs = 0
  var tabsClosed = 0

  func openTab() {
    openedTabs += 1
    tabIDs.append(.make())
    selectedTabIndex = tabCount - 1
  }

  func selectTab(at index: Int) {
    guard (0..<tabCount).contains(index) else { return }

    selectedTabIndex = index
  }

  /// When set, the applet answers a tab close with this and changes nothing. A test uses it to stand
  /// in for a dialog the user declined.
  var tabCloseOverride: TabCloseResult?
  var tabCloseRequests = 0

  func closeCurrentTab() async -> TabCloseResult {
    tabCloseRequests += 1

    if let tabCloseOverride { return tabCloseOverride }

    guard tabCount > 1 else { return .nothingToClose }

    tabsClosed += 1

    if let host {
      closedTabs.insert(
        ClosedTab(stamp: host.issueCloseStamp(), title: "\(title) tab \(selectedTabIndex + 1)"),
        at: 0)
    }

    tabIDs.remove(at: selectedTabIndex)
    tabTitles = tabTitles.enumerated().filter { $0.offset != selectedTabIndex }.map(\.element)
    selectedTabIndex = min(selectedTabIndex, tabCount - 1)
    return .closed
  }

  struct ClosedTab: Equatable {
    let stamp: UInt64
    let title: String
  }

  /// The tabs the applet closed, newest first.
  var closedTabs: [ClosedTab] = []

  /// Stamps whose reopen fails, as a session that does not start would.
  var failingReopens: Set<UInt64> = []

  /// The stamps reopened, oldest first.
  var reopened: [UInt64] = []

  var closedTabStamps: [UInt64] { closedTabs.map(\.stamp) }

  func reopenTab(stamp: UInt64) -> TabReopenResult {
    guard let closed = closedTabs.first(where: { $0.stamp == stamp }) else { return .missing }

    if failingReopens.contains(stamp) {
      return .failed(title: closed.title, reason: "the session did not start")
    }

    closedTabs.removeAll { $0.stamp == stamp }
    reopened.append(stamp)
    tabIDs.append(.make())
    selectedTabIndex = tabCount - 1
    return .reopened(title: closed.title)
  }

  /// The text actions the applet performed, oldest first.
  var textActions: [String] = []
  var canPerformText = true

  /// Whether the fake's Find command is on, and how often it ran.
  var canFind = true
  var finds = 0

  func start(origin: StartOrigin) {
    started = true
    startOrigin = origin
  }

  /// What the host said built the applet when it started it.
  var startOrigin: StartOrigin?
  func close() { closed = true }
  func detach() { detachCount += 1 }
  func reattach() { reattachCount += 1 }
  var focusCount = 0

  func focus() { focusCount += 1 }

  /// The palettes the host handed over, oldest first.
  var palettes: [ThemePalette] = []

  func apply(_ palette: ThemePalette) { palettes.append(palette) }

  /// When set, the description stays fixed while the title changes, as a terminal's does.
  var fixedDescription: AppletDescription?

  /// The sources the pane-local Open handed the applet, and the error it throws, when set.
  var replacedSources: [(file: URL, start: String)] = []
  var replaceFailure: Error?

  /// The description carries the title, so a test can tell which applet a reopened pane came from.
  func describe() -> AppletDescription {
    fixedDescription
      ?? AppletDescription(type: "fake", version: 1, payload: .string(title), undoState: undoState)
  }

  /// The undo-only part of the description: the closed tabs, newest first, as a terminal carries
  /// them.
  var undoState: JSONValue? {
    guard !closedTabs.isEmpty else { return nil }

    return .array(
      closedTabs.map {
        .object(["stamp": .number(Double($0.stamp)), "title": .string($0.title)])
      })
  }

  /// Takes the closed tabs back from a description, as a reopened pane does.
  func restoreClosedTabs(from description: AppletDescription) {
    guard case .array(let entries)? = description.undoState else { return }

    closedTabs = entries.compactMap { entry in
      guard case .object(let fields) = entry, case .number(let stamp)? = fields["stamp"],
        case .string(let title)? = fields["title"]
      else { return nil }

      return ClosedTab(stamp: UInt64(stamp), title: title)
    }
  }
}

extension FakeApplet {
  /// Commands shaped like the terminal's, so the window's tab and text size paths have something
  /// to run. The type is `fake`, so the IDs are `fake.new-tab` and so on.
  static let commandSet: AppletCommandSet = {
    @MainActor func fake(_ applet: any Applet) -> FakeApplet? { applet as? FakeApplet }

    @MainActor func several(_ applet: any Applet) -> Bool { (fake(applet)?.tabCount ?? 1) > 1 }

    @MainActor func text(
      _ name: String, _ title: String, _ key: KeyChord?, _ home: AppletMenuHome = .view
    )
      -> AppletCommand
    {
      AppletCommand(
        name: name, title: title, key: key, home: home,
        isAvailable: { fake($0)?.canPerformText == true },
        run: { fake($0)?.textActions.append(name) })
    }

    var commands = [
      AppletCommand(
        name: "new-tab", title: "New Tab", key: KeyChord("t"), home: .file, section: 1,
        isAvailable: { fake($0)?.canOpenTab == true }, run: { fake($0)?.openTab() }),
      AppletCommand(
        name: "next-tab", title: "Select Next Tab", home: .window, section: 1,
        isAvailable: several,
        run: { fake($0)?.step(by: 1) }),
      AppletCommand(
        name: "previous-tab", title: "Select Previous Tab", home: .window, section: 1,
        isAvailable: several,
        run: { fake($0)?.step(by: -1) }),
      text("bigger-text", "Bigger Text", KeyChord("+")),
      text("actual-size", "Actual Size", KeyChord("0")),
      text("clear", "Clear Screen", KeyChord("l"), .applet),
      AppletCommand(
        name: "find", title: "Find\u{2026}", key: KeyChord("f"), home: .editFind,
        isAvailable: { fake($0)?.canFind == true }, run: { fake($0)?.finds += 1 }),
    ]

    for number in 1...9 {
      commands.append(
        AppletCommand(
          name: number == 9 ? "last-tab" : "tab-\(number)", title: "Select Tab \(number)",
          key: KeyChord(String(number)), home: .window, section: 1, listedInPalette: false,
          isAvailable: several,
          run: { fake($0)?.selectTab(at: number == 9 ? (fake($0)?.tabCount ?? 1) - 1 : number - 1) }
        ))
    }

    return AppletCommandSet(typeID: "fake", menuTitle: "Fake", commands: commands)
  }()

  fileprivate func step(by step: Int) {
    selectedTabIndex = (selectedTabIndex + step + tabCount) % tabCount
  }
}

extension CommandRegistry {
  /// A registry with the fake applet's commands, for windows whose panes are fake applets.
  static func testing() -> CommandRegistry {
    let registry = CommandRegistry()
    registry.register(FakeApplet.commandSet)
    return registry
  }
}

extension CommandID {
  static let fakeNewTab: CommandID = "fake.new-tab"
  static let fakeNextTab: CommandID = "fake.next-tab"
  static let fakePreviousTab: CommandID = "fake.previous-tab"
  static let fakeBiggerText: CommandID = "fake.bigger-text"
  static let fakeActualSize: CommandID = "fake.actual-size"
  static let fakeClear: CommandID = "fake.clear"
  static let fakeFind: CommandID = "fake.find"

  static func fakeTab(_ number: Int) -> CommandID {
    CommandID(number == 9 ? "fake.last-tab" : "fake.tab-\(number)")
  }
}

extension FakeApplet {
  /// Posts through the host the window handed this applet, as a real applet does.
  func say(_ level: StatusLevel, _ text: String) {
    host?.applet(self, post: level, text: text)
  }

  /// Records in the history through the host, as a real applet does.
  func note(_ level: StatusLevel, _ text: String) {
    host?.applet(self, recordInHistory: level, text: text)
  }
}

extension AppletHost {
  /// Records `text` in the window's history without a turn on the bar and without an unseen
  /// signal. Returns the record's ID.
  @discardableResult
  func applet(
    _ applet: any Applet, recordInHistory level: StatusLevel, text: String
  ) -> StatusRecordID? {
    self.applet(applet, send: .historyOnly, level: level, text: text, presenting: nil)
  }
}

extension FakeApplet: TabOpening {
  func openTab(startingIn directory: String?) -> AppletTabID? {
    guard canOpenTab else { return nil }

    openedTabDirectories.append(directory)
    openTab()

    return tabID(tabCount - 1)
  }
}

/// An applet that owns its input and could also take a source, as a REPL that shows a transcript
/// would. It proves the refusal is the declared property and not a missing capability.
@MainActor
final class OwnedInputApplet: FakeApplet, InputOwning {}
