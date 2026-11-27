import AppKit
import AppletKit
import QuestionForm
import StatusKit
import Theme

/// The pane that shows the forms programs ask. Each requester has one tab, and the tab bar shows
/// even for one.
///
/// A host opens a form through `open`, with the requester it established and a callback for the
/// outcome. The applet draws the requester's header itself, so a form's script never writes it. A
/// form's answer is checked as the user fills it, and the callback hears each form once.
///
/// The description holds nothing. A restored or reopened pane has no tab and says so. A form is
/// never restored, since the program waiting for it is gone.
///
/// A tab that closes, however it closes, leaves the pane as a tab the user closes does. The pane
/// closes with its last tab. An open form in a tab that closes is dismissed. Closing it never asks,
/// since it is not work that a close would lose.
@MainActor
public final class QuestionsApplet: Applet {
  /// The type of the description this applet writes and restores.
  public nonisolated static let descriptionTypeID = QuestionsDescription.typeID

  /// Why a form did not open. The host reports each as the wire's `busy` failure, except
  /// `unavailable`, which means the pane itself is gone.
  public enum Busy: Equatable, Sendable {
    /// The requester has an open form already.
    case requesterHasOpenForm

    /// Every tab the pane may hold holds an open form.
    case paneFull

    /// The pane is closed.
    case unavailable
  }

  public enum OpenResult: Equatable, Sendable {
    /// The form is open in `tab`. `reusedTab` says whether the requester's earlier tab took it.
    case opened(tab: AppletTabID, reusedTab: Bool)

    case busy(Busy)
  }

  public let typeID = QuestionsApplet.descriptionTypeID
  public weak var host: (any AppletHost)?

  public private(set) var title = QuestionsApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  private static let untitled = "Questions"

  let content = QuestionsView()

  private final class Tab {
    let id: AppletTabID
    var requester: QuestionsRequester
    var panel: FormPanelView
    var resolved: (@MainActor (FormOutcome) -> Void)?

    init(
      id: AppletTabID, requester: QuestionsRequester, panel: FormPanelView,
      resolved: @escaping @MainActor (FormOutcome) -> Void
    ) {
      self.id = id
      self.requester = requester
      self.panel = panel
      self.resolved = resolved
    }
  }

  private var book: QuestionsBook
  private var tabs: [AppletTabID: Tab] = [:]
  private var palette = ThemePalette.latte
  private let emptyTabID = AppletTabID.make()
  private var started = false
  private(set) var closed = false

  private struct Shown: Equatable {
    var title: String
    var segments: [AppletSegment]
    var tabIDs: [AppletTabID]
    var titles: [String]
    var selected: AppletTabID?
  }

  private var lastShown: Shown?

  /// The most tabs, and so the most open forms, a pane holds unless its host says otherwise.
  public static let defaultCap = QuestionsBook.defaultCap

  /// A pane with no tab. `cap` is the most tabs, and so the most open forms, the pane holds.
  public init(cap: Int = QuestionsApplet.defaultCap) {
    book = QuestionsBook(cap: cap)
    publishedTabs = AppletTabList(first: AppletTab(id: emptyTabID, title: Self.untitled))

    wire()
    refresh()
  }

  /// Restores a pane from its description. The pane has no tab, since no form is ever restored.
  public convenience init(restoring description: AppletDescription) throws {
    _ = try QuestionsDescription.decode(description)

    self.init()
  }

  public var view: NSView { content }

  /// An open form is not work a close would lose. The program that asked is told the form was
  /// dismissed, and nothing but the unsent answers is gone.
  public var isRunningSomething: Bool { false }

  private func wire() {
    content.tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
    content.tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
  }

  // MARK: Forms

  /// True once the pane has closed. A host that holds a pane opens a new one instead.
  public var isClosed: Bool { closed }

  /// How many forms are open now.
  public var openFormCount: Int { book.openCount }

  /// The tab a requester holds, if it holds one.
  public func tab(forRequester key: String) -> AppletTabID? {
    book.entry(forRequester: key)?.id
  }

  /// Whether the requester's tab holds an open form.
  public func hasOpenForm(forRequester key: String) -> Bool {
    book.entry(forRequester: key)?.isOpen ?? false
  }

  /// The tabs, in the order the bar shows them, as requester keys.
  public var requesterKeys: [String] { book.entries.map(\.requesterKey) }

  /// The selected tab's requester key.
  public var selectedRequesterKey: String? {
    book.selected.flatMap { book.entry($0)?.requesterKey }
  }

  /// Opens a requester's form.
  ///
  /// A requester with a tab that holds a resolved form reuses it, and a requester with an open
  /// form is refused. A new requester gets a new tab, and when the pane is at its cap, the oldest
  /// resolved tab that is not selected gives way. The form's tab is selected and takes the
  /// keyboard, and its fields take keys at once.
  ///
  /// `resolved` runs once, on the main actor, when the form ends. It never runs from inside this
  /// call.
  @discardableResult
  public func open(
    _ spec: FormSpec, for requester: QuestionsRequester,
    resolved: @escaping @MainActor (FormOutcome) -> Void
  ) -> OpenResult {
    guard !closed else { return .busy(.unavailable) }

    let id: AppletTabID
    let reused: Bool

    switch book.admission(forRequester: requester.key) {
    case .refused(.requesterBusy):
      return .busy(.requesterHasOpenForm)

    case .refused(.paneFull):
      return .busy(.paneFull)

    case .reuse(let existing):
      id = existing
      reused = true

      let tab = tabs[existing]
      tab?.panel.tearDown()
      tab?.panel = makePanel(spec, requester: requester, tab: existing)
      tab?.requester = requester
      tab?.resolved = resolved

    case .new(let evicting):
      if let evicting { removeTab(evicting) }

      id = .make()
      reused = false

      tabs[id] = Tab(
        id: id, requester: requester,
        panel: makePanel(spec, requester: requester, tab: id), resolved: resolved)
    }

    book.open(requesterKey: requester.key, id: id)

    showSelected()
    refresh()

    host?.applet(self, post: .info, text: "\(requester.name) is asking you a question.")

    if content.window != nil { focus() }

    return .opened(tab: id, reusedTab: reused)
  }

  private func makePanel(_ spec: FormSpec, requester: QuestionsRequester, tab: AppletTabID)
    -> FormPanelView
  {
    let panel = FormPanelView(spec: spec, requester: requester, palette: palette)

    panel.onFinish = { [weak self] outcome in self?.finish(tab: tab, with: outcome) }

    return panel
  }

  /// The user pressed a button that ended the form.
  private func finish(tab id: AppletTabID, with outcome: FormOutcome) {
    resolve(id, outcome)
    refresh()
  }

  /// Ends an open form with `outcome`, shows it in the tab, and tells the asker once.
  private func resolve(_ id: AppletTabID, _ outcome: FormOutcome) {
    guard let tab = tabs[id], book.resolve(id) else { return }

    let callback = tab.resolved

    tab.resolved = nil
    tab.panel.showOutcome(outcome)

    callback?(outcome)
  }

  /// The program ended: its run ended, its authority was revoked, or its connection closed. An open
  /// form ends with nothing submitted, and the tab closes as a tab the user closes does.
  public func end(requester key: String) {
    guard !closed, let entry = book.entry(forRequester: key) else { return }

    resolve(entry.id, .ended)
    removeAndSettle(entry.id)
  }

  /// The program let go of its form. An open form ends with nothing submitted. The tab stays and
  /// says so, until the requester's next form reuses it or the user closes it.
  @discardableResult
  public func discard(tab id: AppletTabID) -> Bool {
    guard !closed, book.entry(id)?.isOpen == true else { return false }

    resolve(id, .ended)
    refresh()

    return true
  }

  /// The pane that asked closed. The header says so, and never points at another pane.
  public func askingPaneDidClose(forRequester key: String) {
    guard !closed, let entry = book.entry(forRequester: key) else { return }

    markAskingPaneGone(of: entry.id)
  }

  /// A pane closed. Every tab whose form it asked says so. The label is the pane's stable name,
  /// which no later pane reuses.
  public func askingPaneDidClose(label: String) {
    guard !closed else { return }

    for entry in book.entries where tabs[entry.id]?.requester.askingPane == .open(label: label) {
      markAskingPaneGone(of: entry.id)
    }
  }

  private func markAskingPaneGone(of id: AppletTabID) {
    guard let tab = tabs[id] else { return }

    switch tab.requester.askingPane {
    case .open(let label), .gone(let label):
      tab.requester.askingPane = .gone(label: label)

    case .none:
      return
    }

    tab.panel.updateRequester(tab.requester)
  }

  // MARK: Tabs

  public var tabCount: Int { book.entries.count }

  public var selectedTabIndex: Int { book.selectedIndex ?? 0 }

  private var hasFocus: Bool {
    guard let responder = content.window?.firstResponder as? NSView else { return false }

    return responder.isDescendant(of: content)
  }

  func selectTab(at index: Int) {
    guard !closed, book.entries.indices.contains(index) else { return }

    let id = book.entries[index].id

    guard id != book.selected else { return }

    let hadFocus = hasFocus

    book.select(id)
    showSelected()
    refresh()

    if hadFocus { focus() }
  }

  public func selectTab(id: AppletTabID) -> Bool {
    if book.isEmpty || closed { return id == emptyTabID }

    guard let index = book.entries.firstIndex(where: { $0.id == id }) else { return false }

    selectTab(at: index)

    return true
  }

  func selectTab(number: Int) {
    selectTab(at: number == 9 ? book.entries.count - 1 : number - 1)
  }

  func step(by step: Int) {
    guard !closed, book.entries.count > 1, let current = book.selectedIndex else { return }

    selectTab(at: (current + step + book.entries.count) % book.entries.count)
  }

  /// Closes the tab at `index`, as the user does. An open form is dismissed.
  func closeTab(at index: Int) {
    guard !closed, book.entries.indices.contains(index) else { return }

    let id = book.entries[index].id

    resolve(id, .dismissed)
    removeAndSettle(id)
  }

  /// Closes the selected tab. The last tab never closes here. That is a pane close, which the host
  /// owns, and the pane's close dismisses the form.
  public func closeCurrentTab() async -> TabCloseResult {
    guard !closed, book.entries.count > 1, let index = book.selectedIndex else {
      return .nothingToClose
    }

    closeTab(at: index)

    return .closed
  }

  /// Removes a tab, hands the selection on, and closes the pane when none is left.
  private func removeAndSettle(_ id: AppletTabID) {
    let hadFocus = hasFocus

    removeTab(id)

    if book.isEmpty {
      refresh()
      host?.appletDidExit(self)

      return
    }

    showSelected()
    refresh()

    if hadFocus { focus() }
  }

  private func removeTab(_ id: AppletTabID) {
    tabs[id]?.panel.tearDown()
    tabs[id] = nil

    book.remove(id)
  }

  private func showSelected() {
    let tab = book.selected.flatMap { tabs[$0] }
    let titles = book.entries.map { tabs[$0.id]?.requester.name ?? "" }

    content.show(titles: titles, selected: book.selectedIndex ?? 0, panel: tab?.panel)
  }

  // MARK: Lifecycle

  public func start(origin: StartOrigin) {
    started = true
  }

  /// The pane is closing. Every open form is dismissed, and the asker hears it.
  public func close() {
    guard !closed else { return }

    closed = true

    for entry in book.entries { resolve(entry.id, .dismissed) }

    for tab in tabs.values { tab.panel.tearDown() }

    for entry in book.entries { book.remove(entry.id) }

    content.show(titles: [], selected: 0, panel: nil)

    tabs = [:]
    content.tabBar.onSelect = nil
    content.tabBar.onClose = nil
  }

  public func focus() {
    guard !closed else { return }

    guard let tab = book.selected.flatMap({ tabs[$0] }) else {
      content.window?.makeFirstResponder(content)

      return
    }

    tab.panel.focusFirst()
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette

    content.apply(palette)

    for tab in tabs.values { tab.panel.apply(palette) }
  }

  public func hostBadgeReachDidChange(_ width: CGFloat) {
    content.badgeReach = width
  }

  public func describe() -> AppletDescription {
    if let description = try? QuestionsDescription().appletDescription() { return description }

    assertionFailure("the questions description failed to encode")

    return AppletDescription(
      type: QuestionsDescription.typeID, version: QuestionsDescription.currentVersion,
      payload: .object([:]))
  }

  // MARK: Reporting

  private func refresh() {
    guard !closed else { return }

    let names = book.entries.map { tabs[$0.id]?.requester.name ?? "" }

    title = book.selected.flatMap { tabs[$0]?.requester.name } ?? Self.untitled

    let open = book.openCount

    segments =
      open > 0 ? [AppletSegment(symbolName: "questionmark.bubble", text: "\(open) open")] : []

    if book.isEmpty {
      publishedTabs = AppletTabList(first: AppletTab(id: emptyTabID, title: Self.untitled))
    } else {
      let all = book.entries.map { AppletTab(id: $0.id, title: tabs[$0.id]?.requester.name ?? "") }

      publishedTabs = AppletTabList(
        first: all[0], rest: Array(all.dropFirst()), selected: book.selected)
    }

    content.show(
      titles: names, selected: book.selectedIndex ?? 0,
      panel: book.selected.flatMap { tabs[$0]?.panel })

    let shown = Shown(
      title: title, segments: segments, tabIDs: book.entries.map(\.id), titles: names,
      selected: book.selected)

    guard shown != lastShown else { return }

    let tabsChanged =
      lastShown.map {
        $0.titles != shown.titles || $0.tabIDs != shown.tabIDs || $0.selected != shown.selected
      } ?? true

    lastShown = shown

    host?.appletDidChange(self)

    if tabsChanged { host?.appletTabsDidChange(self) }
  }
}
