import AppKit
import AppletKit
import OSLog
import StatusKit
import TerminalSurface
import Theme

/// Lays out the tab bar above the terminals. A tab's view fills the space under the bar.
@MainActor
private final class TerminalContainerView: NSView {
  var onResize: (() -> Void)?

  override var isFlipped: Bool { true }

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    super.resizeSubviews(withOldSize: oldSize)
    onResize?()
  }
}

/// The terminal applet. It talks to the terminal only through the session protocol.
///
/// Shell mode runs the user's login shell in any number of tabs. Each tab is its own session, so
/// each has its own tty. Program mode runs one program in one tab and opens no others. The tab bar
/// shows only while there is more than one tab.
@MainActor
public final class TerminalApplet: Applet, TabOpening, InputOwning {
  /// The longest notification text that reaches the status bar.
  static let maximumMessageLength = 200

  /// One tab: a session, and what the applet knows about it.
  @MainActor
  private final class Tab {
    /// Names the tab to the palette. A restored tab is a new tab, so it gets a new ID.
    let id = AppletTabID.make()
    let launch: TerminalLaunch
    var session: (any TerminalSession)?
    var title: String
    var workingDirectory: String?
    var failedExitCode: Int?
    var processIdentity: (pid: pid_t, started: Int)?

    /// The link under the pointer as of its last hover, exactly as libghostty reported it. A click
    /// opens only a link whose text equals it.
    var hoveredLink: String?

    /// True while a click's check of the file system runs. The check opens a path a program chose,
    /// and on a dead network mount it never returns. One check per tab bounds the threads a click
    /// loop can park.
    var verifyingLink = false

    /// Why this tab's output may be from another host. It is set once and lives as long as the
    /// session. libghostty cannot mark single rows, so it covers the whole tab.
    var remoteSource: RemoteSource?

    /// Looks for a remote client below the session's root process, until one is found.
    var remoteWatcher: (any RemoteClientWatching)?

    /// A program-mode tab restored from a description. It has no session until the user runs it.
    var awaitingRun = false

    /// Earlier output the tab's next session shows above its first prompt. The session takes it as
    /// it starts, so the text is not held for the tab's whole life.
    var pendingReplay: String?

    /// The ID of the scrollback this tab saved as the app quit. The tab's description names it.
    var savedScrollback: String?

    init(launch: TerminalLaunch, title: String) {
      self.launch = launch
      self.title = title
      self.workingDirectory = launch.workingDirectory
    }

    var isRunningSomething: Bool {
      guard let session, !session.hasExited else { return false }

      return session.isRunningSomething
    }
  }

  /// What made a tab's output look remote.
  enum RemoteSource: Equatable {
    /// A remote client ran below the session's root. The value is its name.
    case client(String)

    /// A program reported a working directory on another host. The value is the host.
    case host(String)
  }

  /// What the preview says in place of a target while the tab's output may be remote.
  static let remoteNotice = "This output may be from another host. A click opens nothing."

  private static let defaultTitle = "Terminal"

  /// Debug-level only. It logs outcomes and lengths, never the text of a link.
  private static let linkLog = Logger(subsystem: "dev.uniterm.app", category: "terminal-link")

  /// Logs a failed save, never the text.
  private static let scrollbackLog = Logger(subsystem: "dev.uniterm.app", category: "terminal")

  public let typeID = TerminalDescription.typeID
  public let view: NSView

  public weak var host: (any AppletHost)?

  public private(set) var segments: [AppletSegment] = []

  private let container = TerminalContainerView()

  /// Holds every session's view. Each one fills it through its autoresizing mask, so AppKit sizes
  /// every live session, hidden ones included, and a resize never walks the tab list.
  private let sessionArea = NSView()

  private let tabBar = AppletTabBar()
  private let runPrompt = TerminalRunPrompt()
  private let linkPreview = TerminalLinkPreview()
  private let engine: any TerminalEngine
  private let mode: TerminalDescription.Mode
  private let commandLine: String?
  private let shellEnvironment: [String: String]
  private let directoryExists: (String) -> Bool
  private let home: String

  /// Where shell tabs keep their scrollback from a quit to the next launch. Nil keeps none.
  private let scrollbackStore: ScrollbackStore?

  private var tabs: [Tab]
  private var selectedIndex: Int

  /// The tab and the session view that showed as of the last refresh. A refresh hides only that
  /// tab and shows only the selected one, so its work does not grow with the tab count. The view
  /// is kept too, since a tab that stays selected gains a session when its program runs.
  private weak var shownTab: Tab?
  private weak var shownView: NSView?

  private var started = false
  private var closingTab = false

  /// Makes the watcher that looks for a remote client in a session's process tree. Tests replace
  /// it.
  var makeRemoteWatcher: RemoteWatcherFactory = { root, found in
    RemoteClientWatcher(root: root, found: found)
  }

  /// Checks that a clicked path is still the file the pane showed. Tests replace it.
  var verifyLink: @Sendable (String) async -> TerminalLinkRefusal? = { path in
    await LinkClickVerifier.verify(path)
  }

  /// The check and the open of the last click on a path. A test waits on it.
  private(set) var linkClick: Task<Void, Never>?

  /// The most closed tabs the applet remembers. A policy value with no setting, equal to the
  /// window's pane undo depth.
  static let closedTabDepth = 20

  /// The tabs the user closed, newest first. They live in memory with the window's undo state and
  /// ride in the description's undo-only part, so a reopened pane brings them back.
  private var closedTabs: [TerminalDescription.ClosedTab] = []

  /// Notifications reach the status bar through this.
  private var alerts = AppletAlerts()

  /// The pane's control state, as the host last pushed it. Every session gets the clipboard policy
  /// it implies, from its creation on.
  private var control = PaneControl.disconnected

  /// What the host last said about who acts for the pane. A terminal takes neither commands nor
  /// sent content, so only the tabs a controller acts for matter here.
  private var authority = PaneAuthority.none

  private var clipboardPolicy: TerminalClipboardPolicy {
    TerminalClipboardPolicy(controlled: control.isControlled, generation: control.generation)
  }

  /// A shell in one tab, with the launch as given.
  public convenience init(
    engine: any TerminalEngine, launch: TerminalLaunch, scrollbackStore: ScrollbackStore? = nil
  ) {
    self.init(
      engine: engine, mode: .shell, commandLine: nil, shellEnvironment: launch.environment,
      launches: [launch], selected: 0, directoryExists: RestoreDirectory.isLocalDirectory,
      home: NSHomeDirectory(), scrollbackStore: scrollbackStore)
  }

  /// A shell in one tab. It starts in the given directory when that is an absolute path and still
  /// a directory here. Otherwise it starts in the home directory. The launch always carries an
  /// explicit directory, so the terminal engine never picks one on its own.
  public convenience init(
    engine: any TerminalEngine, workingDirectory: String? = nil,
    directoryExists: @escaping (String) -> Bool = RestoreDirectory.isLocalDirectory,
    home: String = NSHomeDirectory(), scrollbackStore: ScrollbackStore? = nil
  ) {
    let directory = RestoreDirectory.resolve(
      reported: workingDirectory, starting: nil, home: home, exists: directoryExists)

    self.init(
      engine: engine, mode: .shell, commandLine: nil, shellEnvironment: [:],
      launches: [.loginShell(workingDirectory: directory)], selected: 0,
      directoryExists: directoryExists, home: home, scrollbackStore: scrollbackStore)
  }

  /// One program in one tab. The line is split into words, and no shell interprets the user's
  /// text. It throws when the line is empty, has an unclosed quote, or holds shell syntax that is
  /// not quoted. The directory is chosen as for a shell.
  public convenience init(
    engine: any TerminalEngine, program line: String, workingDirectory: String? = nil,
    directoryExists: @escaping (String) -> Bool = RestoreDirectory.isLocalDirectory,
    home: String = NSHomeDirectory()
  ) throws {
    let words = try ShellWords.split(line)

    let directory = RestoreDirectory.resolve(
      reported: workingDirectory, starting: nil, home: home, exists: directoryExists)

    self.init(
      engine: engine, mode: .program, commandLine: line, shellEnvironment: [:],
      launches: [.program(words, workingDirectory: directory)], selected: 0,
      directoryExists: directoryExists, home: home)
  }

  /// Restores an applet from a description. A shell description starts a fresh shell in each tab.
  /// A program description starts nothing. It shows the command with a Run button.
  ///
  /// Each tab starts in the directory its shell reported last, when that is an absolute path that
  /// is still a directory here. Otherwise it starts in the tab's starting directory, and then in
  /// the home directory.
  ///
  /// A shell tab saved at quit shows its scrollback above its first prompt. The store's file is
  /// read and deleted here. A program tab's saved file is deleted unread, since the tab comes back
  /// waiting to run.
  public convenience init(
    engine: any TerminalEngine, restoring description: AppletDescription,
    directoryExists: @escaping (String) -> Bool = RestoreDirectory.isLocalDirectory,
    home: String = NSHomeDirectory(), scrollbackStore: ScrollbackStore? = nil
  ) throws {
    let decoded = try TerminalDescription.decode(description)
    let carried = TerminalDescription.closedTabs(in: description)

    let directories = decoded.tabs.map {
      RestoreDirectory.resolve(
        reported: $0.workingDirectory, starting: $0.startDirectory, home: home,
        exists: directoryExists)
    }

    switch decoded.mode {
    case .shell:
      self.init(
        engine: engine, mode: .shell, commandLine: nil, shellEnvironment: [:],
        launches: directories.map { .loginShell(workingDirectory: $0) },
        selected: decoded.selectedTab, directoryExists: directoryExists, home: home,
        scrollbackStore: scrollbackStore)

      for (tab, saved) in zip(tabs, decoded.tabs) {
        tab.pendingReplay = saved.scrollback.flatMap { scrollbackStore?.take($0) }
      }

    case .program:
      guard let line = decoded.command else {
        throw AppletRestoreError.corrupt("terminal description has a program with no command")
      }

      let words: [String]
      do {
        words = try ShellWords.split(line)
      } catch {
        throw AppletRestoreError.corrupt("terminal description has a command that does not parse")
      }

      self.init(
        engine: engine, mode: .program, commandLine: line, shellEnvironment: [:],
        launches: directories.map { .program(words, workingDirectory: $0) },
        selected: decoded.selectedTab, directoryExists: directoryExists, home: home,
        scrollbackStore: scrollbackStore)

      for saved in decoded.tabs {
        if let id = saved.scrollback { scrollbackStore?.remove(id) }
      }

      for tab in tabs { tab.awaitingRun = true }
      refreshTabs()
    }

    closedTabs = Array(carried.prefix(Self.closedTabDepth))
  }

  private init(
    engine: any TerminalEngine, mode: TerminalDescription.Mode, commandLine: String?,
    shellEnvironment: [String: String], launches: [TerminalLaunch], selected: Int,
    directoryExists: @escaping (String) -> Bool, home: String,
    scrollbackStore: ScrollbackStore? = nil
  ) {
    self.engine = engine
    self.directoryExists = directoryExists
    self.home = home
    self.scrollbackStore = scrollbackStore
    self.mode = mode
    self.commandLine = commandLine
    self.shellEnvironment = shellEnvironment
    self.selectedIndex = selected
    self.view = container

    tabs = launches.map { launch in
      Tab(launch: launch, title: Self.initialTitle(for: launch))
    }

    container.setAccessibilityIdentifier("terminal-applet")
    container.addSubview(tabBar)
    container.addSubview(sessionArea)
    container.addSubview(runPrompt)
    container.addSubview(linkPreview)
    runPrompt.isHidden = true
    runPrompt.onRun = { [weak self] in self?.runPendingProgram() }
    container.onResize = { [weak self] in self?.layoutContents() }

    tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
    tabBar.onNew = { [weak self] in self?.openTab() }
    tabBar.onClose = { [weak self] index in
      guard let self, self.tabs.indices.contains(index) else { return }

      let tab = self.tabs[index]
      Task { @MainActor [weak self] in _ = await self?.closeTab(tab) }
    }

    refreshTabs()
  }

  private static func initialTitle(for launch: TerminalLaunch) -> String {
    guard let first = launch.program?.first else { return defaultTitle }

    let name = (first as NSString).lastPathComponent
    return name.isEmpty ? first : sanitized(name, limit: 80)
  }

  // MARK: Applet

  private var selectedTab: Tab? {
    tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
  }

  public var title: String { selectedTab?.title ?? Self.defaultTitle }

  /// The directory the selected tab's shell last reported through OSC 7, when it is an absolute
  /// path that is still a directory here. A path from another machine after an ssh login, or one
  /// that is gone, is not reported.
  public var currentDirectory: String? {
    RestoreDirectory.local(selectedTab?.workingDirectory, exists: directoryExists)
  }

  /// Each tab with its title and the directory its shell last reported. The directory is shown as
  /// reported, even one from another machine, since it is only text to search.
  public var publishedTabs: AppletTabList {
    let published = tabs.map { tab in
      authority.applyingChip(
        to: AppletTab(
          id: tab.id, title: tab.title,
          details: tab.workingDirectory.map { [$0] } ?? []))
    }

    guard let first = published.first else {
      preconditionFailure("a terminal always holds a tab")
    }

    return AppletTabList(
      first: first, rest: Array(published.dropFirst()), selected: selectedTab?.id)
  }

  /// True when any tab is running something. A tab at an idle shell prompt is not.
  public var isRunningSomething: Bool {
    tabs.contains { $0.isRunningSomething }
  }

  /// What each tab running something is called: its title, or the command in program mode. A
  /// confirmation dialog lists them.
  public var runningTabLabels: [String] {
    tabs.filter { $0.isRunningSomething }.map { label(of: $0) }
  }

  public var runningLabels: [String] { runningTabLabels }

  public func start(origin: StartOrigin) {
    guard !started else { return }

    started = true

    var failure: (any Error)?

    for tab in tabs where tab.session == nil && !tab.awaitingRun {
      do {
        try startSession(for: tab)
      } catch {
        failure = error
      }
    }

    if let failure {
      alerts.deliver(
        AppletNotice(.warning, "The terminal could not start: \(failure)"),
        origin: origin.loadOrigin, from: self, to: host)
    }

    let live = tabs.filter { $0.session != nil || $0.awaitingRun }

    guard !live.isEmpty else {
      host?.appletDidExit(self)
      return
    }

    if live.count != tabs.count {
      let selected = selectedTab
      tabs = live
      selectedIndex = selected.flatMap { selected in tabs.firstIndex { $0 === selected } } ?? 0
    }

    refreshTabs()
    updateSegments()
    host?.appletTabsDidChange(self)
  }

  public func close() {
    for tab in tabs {
      if let identity = tab.processIdentity {
        host?.applet(self, sessionEnded: tab.id, pid: identity.pid, started: identity.started)
        tab.processIdentity = nil
      }
      tab.remoteWatcher?.stop()
      tab.remoteWatcher = nil
      tab.session?.view.removeFromSuperview()
      tab.session?.close()
      tab.session = nil
    }
  }

  public func focus() {
    if selectedTab?.awaitingRun == true {
      runPrompt.window?.makeFirstResponder(runPrompt.runButton)
      return
    }

    guard let terminalView = selectedTab?.session?.view else { return }

    terminalView.window?.makeFirstResponder(terminalView)
  }

  public func apply(_ palette: ThemePalette) {
    tabBar.apply(palette)
    runPrompt.apply(palette)
    linkPreview.apply(palette)
  }

  public func hostBadgeReachDidChange(_ width: CGFloat) {
    tabBar.trailingReserve = width
  }

  /// Every running tab takes the new clipboard policy before this returns, so a tab in the
  /// background is covered as soon as the pane is.
  public func controlDidChange(_ control: PaneControl) {
    self.control = control

    for tab in tabs {
      tab.session?.setClipboardPolicy(clipboardPolicy)
    }
  }

  public func authorityDidChange(_ authority: PaneAuthority) {
    guard authority != self.authority else { return }

    self.authority = authority
    tabBar.update(tabs: publishedTabs.all, selected: selectedIndex, canOpenTab: canOpenTab)
    host?.appletTabsDidChange(self)
  }

  /// True while the selected tab shows its command and waits for the user to run it.
  var isAwaitingRun: Bool { selectedTab?.awaitingRun == true }

  /// Runs the program of a restored program-mode tab, as the Run button does.
  func runPendingProgram() {
    guard started, let tab = selectedTab, tab.awaitingRun else { return }

    do {
      try startSession(for: tab)
    } catch {
      alerts.deliver(.warning, "The program could not start: \(error)", from: self, to: host)
      return
    }

    tab.awaitingRun = false

    refreshTabs()
    updateSegments()
    host?.appletDidChange(self)
    focus()
  }

  /// Saves each shell tab's scrollback, so the next launch shows it above the tab's first prompt.
  /// A tab whose session has not started saves the text it was going to show. A program-mode
  /// terminal saves none, since its tab comes back waiting to run.
  public func willQuit() {
    guard mode == .shell, let scrollbackStore else { return }

    for tab in tabs {
      if let previous = tab.savedScrollback {
        scrollbackStore.remove(previous)
        tab.savedScrollback = nil
      }

      guard let text = tab.session?.scrollbackText() ?? tab.pendingReplay else { continue }

      do {
        tab.savedScrollback = try scrollbackStore.write(text)
      } catch {
        Self.scrollbackLog.error("a tab's scrollback was not saved: \(String(describing: error))")
      }
    }
  }

  public func describe() -> AppletDescription {
    let description = TerminalDescription(
      mode: mode, command: commandLine,
      tabs: tabs.map {
        TerminalDescription.Tab(
          workingDirectory: $0.workingDirectory, startDirectory: $0.launch.workingDirectory,
          scrollback: $0.savedScrollback)
      },
      selectedTab: selectedIndex)

    do {
      return try description.appletDescription(closedTabs: closedTabs)
    } catch {
      preconditionFailure("a terminal description always encodes: \(error)")
    }
  }

  // MARK: Text actions

  /// False when the selected tab has no content to act on, such as a program that has not run.
  var hasSession: Bool {
    selectedTab?.session != nil
  }

  func perform(_ action: TerminalAction) {
    selectedTab?.session?.perform(action)
  }

  // MARK: Tabs

  public var tabCount: Int { tabs.count }

  public var selectedTabIndex: Int { selectedIndex }

  /// Program mode runs its one program in its one tab and never opens another.
  public var canOpenTab: Bool { mode == .shell }

  /// Opens a shell as `openTab(startingIn:)` does, with no directory named.
  public func openTab() {
    openTab(startingIn: nil)
  }

  /// Opens a shell right after the selected tab and selects it. The shell starts in the directory
  /// the caller names, which the caller has checked. With none named, it starts in the directory
  /// the selected tab last reported. A directory that does not exist locally, as after an ssh
  /// login, is not reported, so the shell starts in the home directory then. The tab's ID is nil
  /// when the applet cannot open a tab, or its session did not start.
  @discardableResult
  public func openTab(startingIn directory: String?) -> AppletTabID? {
    guard canOpenTab else { return nil }

    let launch = TerminalLaunch.loginShell(
      workingDirectory: directory ?? currentDirectory ?? home, environment: shellEnvironment)
    let tab = Tab(launch: launch, title: Self.defaultTitle)

    if started {
      do {
        try startSession(for: tab)
      } catch {
        alerts.deliver(.warning, "The tab could not open: \(error)", from: self, to: host)
        return nil
      }
    }

    let position = min(selectedIndex + 1, tabs.count)
    tabs.insert(tab, at: position)
    selectedIndex = position

    refreshTabs()
    updateSegments()
    host?.appletDidChange(self)
    host?.appletTabsDidChange(self)
    focus()

    return tab.id
  }

  public var tabsStartInDirectory: Bool { true }

  public func selectTab(at index: Int) {
    guard tabs.indices.contains(index), index != selectedIndex else { return }

    let hadFocus = hasFocus
    selectedIndex = index

    refreshTabs()
    updateSegments()
    host?.appletDidChange(self)
    host?.appletTabsDidChange(self)

    if hadFocus { focus() }
  }

  public func selectTab(id: AppletTabID) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }

    selectTab(at: index)
    return true
  }

  public func closeCurrentTab() async -> TabCloseResult {
    await closeTab(at: selectedIndex)
  }

  /// Closes a tab. It asks first when the tab is running something. A tab at an idle prompt closes
  /// at once. The last tab never closes here, since that is a pane close.
  ///
  /// A close that waits for an answer holds the applet's one question. A second request meanwhile
  /// is declined and does nothing. When the user agrees and the tab has since become the only one,
  /// there is no tab left to close, and the host's pane close asks again.
  func closeTab(at index: Int) async -> TabCloseResult {
    guard tabs.count > 1 else { return .nothingToClose }

    guard tabs.indices.contains(index) else { return .declined }

    return await closeTab(tabs[index])
  }

  /// Closes `tab` wherever it sits when the close runs. A caller that hops before closing resolves
  /// the tab first, since the tabs may shift before the hop lands.
  private func closeTab(_ tab: Tab) async -> TabCloseResult {
    guard tabs.count > 1 else { return .nothingToClose }

    guard tabs.contains(where: { $0 === tab }), !closingTab else { return .declined }

    if tab.isRunningSomething {
      guard let host else { return .declined }

      closingTab = true
      defer { closingTab = false }

      let confirmation = AppletConfirmation(
        title: "Close this tab?",
        detail: "\u{201C}\(label(of: tab))\u{201D} is running something. Closing the tab ends it.",
        confirmTitle: "Close Tab", cancelTitle: "Cancel")

      guard await host.applet(self, confirm: confirmation) else { return .declined }
    }

    guard let current = tabs.firstIndex(where: { $0 === tab }) else { return .closed }

    guard tabs.count > 1 else { return .nothingToClose }

    recordClosed(tab, at: current)
    removeTab(at: current)
    return .closed
  }

  /// Keeps a closed tab for reopening. The stamp, the index, and the scrollback are taken now, after
  /// any close question was answered, so they describe the tab as it left.
  private func recordClosed(_ tab: Tab, at index: Int) {
    guard let host else { return }

    closedTabs.insert(
      TerminalDescription.ClosedTab(
        stamp: host.issueCloseStamp(), index: index, title: tab.title,
        tab: TerminalDescription.Tab(
          workingDirectory: tab.workingDirectory, startDirectory: tab.launch.workingDirectory),
        scrollback: tab.session?.scrollbackText()),
      at: 0)

    if closedTabs.count > Self.closedTabDepth {
      closedTabs.removeLast(closedTabs.count - Self.closedTabDepth)
    }
  }

  public var closedTabStamps: [UInt64] {
    closedTabs.map(\.stamp)
  }

  /// Starts a fresh shell from the closed tab's description, in the directory it last reported
  /// when that is absolute and still exists, else its start directory, else home. The shell shows
  /// the tab's earlier output above its first prompt. The tab goes back to its former index,
  /// clamped to the tab count, and is selected.
  ///
  /// The session starts before anything changes. A session that fails to start leaves no tab, the
  /// entry stays, and the selection is as it was.
  public func reopenTab(stamp: UInt64) -> TabReopenResult {
    guard let entry = closedTabs.first(where: { $0.stamp == stamp }) else { return .missing }

    let directory = RestoreDirectory.resolve(
      reported: entry.tab.workingDirectory, starting: entry.tab.startDirectory, home: home,
      exists: directoryExists)

    let tab = Tab(
      launch: .loginShell(workingDirectory: directory, environment: shellEnvironment),
      title: Self.defaultTitle)
    tab.pendingReplay = entry.scrollback

    if started {
      do {
        try startSession(for: tab)
      } catch {
        return .failed(
          title: entry.title,
          reason: "\(error.localizedDescription). Check that the shell can start, then try again")
      }
    }

    closedTabs.removeAll { $0.stamp == stamp }

    let position = min(max(entry.index, 0), tabs.count)
    tabs.insert(tab, at: position)
    selectedIndex = position

    refreshTabs()
    updateSegments()
    host?.appletDidChange(self)
    host?.appletTabsDidChange(self)
    return .reopened(title: entry.title)
  }

  /// A tab shows its title. In program mode the one tab shows the command.
  private func label(of tab: Tab) -> String {
    if mode == .program, let commandLine { return Self.sanitized(commandLine, limit: 80) }

    return tab.title
  }

  private func removeTab(at index: Int) {
    let hadFocus = hasFocus
    let tab = tabs.remove(at: index)

    if let identity = tab.processIdentity {
      host?.applet(self, sessionEnded: tab.id, pid: identity.pid, started: identity.started)
      tab.processIdentity = nil
    }
    tab.remoteWatcher?.stop()
    tab.remoteWatcher = nil
    tab.session?.view.removeFromSuperview()
    tab.session?.close()
    tab.session = nil

    if index < selectedIndex {
      selectedIndex -= 1
    } else {
      selectedIndex = min(selectedIndex, tabs.count - 1)
    }

    refreshTabs()
    updateSegments()
    host?.appletDidChange(self)
    host?.appletTabsDidChange(self)

    if hadFocus { focus() }
  }

  private func startSession(for tab: Tab) throws {
    var launch = tab.launch
    launch.replay = tab.pendingReplay

    let session = try engine.makeSession(launch: launch, clipboardPolicy: clipboardPolicy)
    tab.pendingReplay = nil
    tab.remoteWatcher?.stop()
    tab.remoteWatcher = nil
    tab.remoteSource = nil
    tab.hoveredLink = nil
    tab.session = session
    session.onEvent = { [weak self, weak tab] event in
      guard let self, let tab else { return }

      self.handle(event, in: tab)
    }

    // A session starts hidden. The next refresh shows it when its tab is the selected one.
    session.view.isHidden = true
    session.setFocused(false)
    session.setVisible(false)

    session.view.frame = sessionArea.bounds
    session.view.autoresizingMask = [.width, .height]
    sessionArea.addSubview(session.view)
  }

  private var hasFocus: Bool {
    guard let responder = view.window?.firstResponder as? NSView else { return false }

    return responder.isDescendant(of: view)
  }

  /// Shows the selected tab's terminal and hides the others, then updates the bar and the layout.
  private func refreshTabs() {
    let selected = selectedTab

    if let previous = shownTab, previous !== selected {
      previous.session?.view.isHidden = true
      previous.session?.setFocused(false)
      previous.session?.setVisible(false)

      // The pointer may leave a hidden tab's link with no report, so its hover cannot be trusted
      // when the tab shows again. The next hover sets it.
      previous.hoveredLink = nil
    }

    if let selected, selected !== shownTab || selected.session?.view !== shownView {
      // A hover that arrived while the tab was hidden is just as untrusted.
      if selected !== shownTab { selected.hoveredLink = nil }

      selected.session?.view.isHidden = false
      selected.session?.setVisible(true)
    }

    shownTab = selected
    shownView = selected?.session?.view

    tabBar.update(tabs: publishedTabs.all, selected: selectedIndex, canOpenTab: canOpenTab)

    runPrompt.command = commandLine ?? ""
    runPrompt.isHidden = !isAwaitingRun
    updateLinkPreview()
  }

  private func layoutContents() {
    let bounds = container.bounds
    let barHeight = tabBar.isHidden ? 0 : AppletTabBar.height

    tabBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: AppletTabBar.height)

    let content = NSRect(
      x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))

    runPrompt.frame = content
    sessionArea.frame = content
    linkPreview.place(in: content)
  }

  // MARK: Events

  private func handle(_ event: TerminalEvent, in tab: Tab) {
    let isSelected = tab === selectedTab

    switch event {
    case .titleChanged(let value):
      let cleaned = Self.sanitized(value, limit: 80)
      tab.title = cleaned.isEmpty ? Self.defaultTitle : cleaned
      tabBar.update(tabs: publishedTabs.all, selected: selectedIndex, canOpenTab: canOpenTab)

      if isSelected { host?.appletDidChange(self) }

      host?.appletTabsDidChange(self)

    case .workingDirectoryChanged(let path):
      tab.workingDirectory = path
      host?.appletTabsDidChange(self)

      if isSelected {
        rebuildSegments()
      } else {
        host?.appletDidChange(self)
      }

    case .linkHovered(let text):
      Self.linkLog.debug(
        "hover received present=\(text != nil, privacy: .public) selected=\(isSelected, privacy: .public)"
      )
      tab.hoveredLink = text

      if isSelected { updateLinkPreview() }

    case .linkOpenRequested(let text):
      if let click = openLink(text, in: tab) { linkClick = click }

    case .remoteHostReported(let host):
      markRemote(.host(host), in: tab)

    case .processStarted(let identity):
      tab.processIdentity = (pid: identity.pid, started: identity.started)
      watchForRemoteClients(in: tab, root: identity.pid)
      host?.applet(
        self, sessionStarted: tab.id, pid: identity.pid, started: identity.started,
        generation: identity.sessionGeneration)

    case .commandFinished(let exitCode, _):
      tab.failedExitCode = exitCode.flatMap { $0 != 0 ? $0 : nil }

      if isSelected { rebuildSegments() }

    case .notification(let title, let body):
      let text = [title, body].map { Self.sanitized($0) }.filter { !$0.isEmpty }.joined(
        separator: ": ")
      guard !text.isEmpty else { return }

      alerts.deliver(.info, text, from: self, to: host)

    case .clipboardRequest(let request):
      confirm(request, from: tab)

    case .bell:
      break

    case .exited:
      guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }

      if let identity = tab.processIdentity {
        host?.applet(self, sessionEnded: tab.id, pid: identity.pid, started: identity.started)
        tab.processIdentity = nil
      }

      if tabs.count == 1 {
        host?.appletDidExit(self)
      } else {
        recordClosed(tab, at: index)
        removeTab(at: index)
      }
    }
  }

  // MARK: Links

  /// What the preview shows for a tab, or nil for nothing. It shows where a click would open, and
  /// only for a link that names a path. A tab that may hold remote output says so and shows no
  /// target.
  private func previewText(for tab: Tab) -> String? {
    guard let hovered = tab.hoveredLink else { return nil }

    switch TerminalLinkTarget.classify(hovered) {
    case .notAFile:
      return nil

    case .refused:
      return tab.remoteSource == nil ? nil : Self.remoteNotice

    case .file(let path):
      return tab.remoteSource == nil ? path : Self.remoteNotice
    }
  }

  private func updateLinkPreview() {
    linkPreview.text = selectedTab.flatMap { previewText(for: $0) }
    layoutContents()
  }

  /// Handles a click on a link. A click opens only a path that the preview showed, and only when
  /// the tab holds no output that may be remote. The path is then checked against the file system
  /// off the main thread, and routed as an open from this pane.
  ///
  /// Anything else says why nothing opened, except a link that is not a path, which does nothing.
  @discardableResult
  private func openLink(_ text: String, in tab: Tab) -> Task<Void, Never>? {
    let target = TerminalLinkTarget.classify(text)

    if target == .notAFile {
      Self.linkLog.debug("click outcome=not-a-file")
      return nil
    }

    guard text == tab.hoveredLink else {
      Self.linkLog.debug(
        "click outcome=changed hovered=\(tab.hoveredLink != nil, privacy: .public)")
      refuse(.changed)
      return nil
    }

    guard tab.remoteSource == nil else {
      Self.linkLog.debug("click outcome=remote")
      refuse(.remoteOutput)
      return nil
    }

    switch target {
    case .notAFile:
      return nil

    case .refused(let refusal):
      Self.linkLog.debug(
        "click outcome=refused reason=\(String(describing: refusal), privacy: .public)")
      refuse(refusal)
      return nil

    case .file(let path):
      guard !tab.verifyingLink else {
        Self.linkLog.debug("click outcome=still-checking")
        refuse(.stillChecking)
        return nil
      }

      tab.verifyingLink = true

      let id = tab.id

      return Task { @MainActor [weak self, verifyLink] in
        let refusal = await verifyLink(path)

        tab.verifyingLink = false

        guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }

        if let refusal {
          Self.linkLog.debug(
            "click outcome=verify-refused reason=\(String(describing: refusal), privacy: .public)")
          self.refuse(refusal)
          return
        }

        guard tab.remoteSource == nil else {
          Self.linkLog.debug("click outcome=remote-after-verify")
          self.refuse(.remoteOutput)
          return
        }

        Self.linkLog.debug("click outcome=open")
        self.host?.applet(self, open: URL(fileURLWithPath: path, isDirectory: false))
      }
    }
  }

  private func refuse(_ refusal: TerminalLinkRefusal) {
    alerts.deliver(.warning, refusal.message, from: self, to: host)
  }

  /// Starts looking for a remote client below the session's root. The session root is the process
  /// libghostty spawned, so the tree is exactly what this tab runs.
  private func watchForRemoteClients(in tab: Tab, root: pid_t) {
    tab.remoteWatcher?.stop()
    tab.remoteWatcher = nil

    guard tab.remoteSource == nil else { return }

    let id = tab.id

    tab.remoteWatcher = makeRemoteWatcher(root) { [weak self] client in
      Task { @MainActor in
        guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }

        self.markRemote(.client(client), in: tab)
      }
    }
  }

  /// Marks the tab's output as possibly remote for the rest of its session. The marker never
  /// clears, since the output a remote client wrote stays in the scrollback after it exits.
  private func markRemote(_ source: RemoteSource, in tab: Tab) {
    guard tab.remoteSource == nil else { return }

    tab.remoteSource = source
    tab.remoteWatcher?.stop()
    tab.remoteWatcher = nil

    if tab === selectedTab { updateLinkPreview() }
  }

  /// Whether the tab holds output that may be from another host, and why. Tests read it.
  func remoteSource(ofTabAt index: Int) -> RemoteSource? {
    tabs.indices.contains(index) ? tabs[index].remoteSource : nil
  }

  /// The terminal's state is its directory and the exit code of the last command when it failed.
  /// The directory shows as its last component, or `~` for the home folder. The selected tab
  /// supplies both.
  private func updateSegments() {
    var result: [AppletSegment] = []

    if let tab = selectedTab {
      if let workingDirectory = tab.workingDirectory {
        result.append(
          AppletSegment(
            symbolName: "folder", text: Self.directoryLabel(workingDirectory), style: .normal))
      }

      if let failedExitCode = tab.failedExitCode {
        result.append(
          AppletSegment(symbolName: "xmark.circle", text: "\(failedExitCode)", style: .error))
      }
    }

    segments = result
  }

  private func rebuildSegments() {
    updateSegments()
    host?.appletDidChange(self)
  }

  static func directoryLabel(_ path: String, home: String = NSHomeDirectory()) -> String {
    if path == home { return "~" }

    let last = (path as NSString).lastPathComponent
    return sanitized(last.isEmpty ? path : last, limit: 40)
  }

  /// A request is never answered without the user's say. With no host to ask, it is refused. The
  /// question names the tab the request came from, which need not be the selected one.
  private func confirm(_ request: TerminalClipboardRequest, from tab: Tab) {
    guard let host else {
      request.resolve(.deny)
      return
    }

    let subject = label(of: tab)

    if var permission = Self.permission(for: request, subject: subject) {
      permission.scope = "tab \(tab.id) \(request.kind) generation \(control.generation)"

      Task { @MainActor [weak self] in
        guard let self else {
          request.resolve(.deny)
          return
        }

        request.resolve(Self.answer(await host.applet(self, askPermission: permission)))
      }

      return
    }

    let confirmation: AppletConfirmation

    switch request.kind {
    case .read:
      confirmation = AppletConfirmation(
        title: "Allow a program to read your clipboard?",
        detail:
          "A program in this tab asked for the clipboard with an escape sequence. It would receive: \(Self.preview(request.text))",
        confirmTitle: "Allow", cancelTitle: "Deny", subject: subject)

    case .write:
      confirmation = AppletConfirmation(
        title: "Allow a program to replace your clipboard?",
        detail:
          "A program in this tab asked to replace the clipboard with an escape sequence. It would write: \(Self.preview(request.text))",
        confirmTitle: "Allow", cancelTitle: "Deny", subject: subject)

    case .unsafePaste:
      confirmation = AppletConfirmation(
        title: "Paste text that could run commands?",
        detail:
          "The text holds control characters or a newline. It would be pasted as: \(Self.preview(request.text))",
        confirmTitle: "Paste", cancelTitle: "Cancel", subject: subject)
    }

    Task { @MainActor [weak self] in
      guard let self else {
        request.resolve(.deny)
        return
      }

      let allowed = await host.applet(self, confirm: confirmation)
      request.resolve(allow: allowed)
    }
  }

  /// The question for a request from a controlled session, which can allow the rest of the
  /// session. Nil for a request that asks the plain question.
  ///
  /// An escape sequence names no program, so the session answer is labelled as covering every
  /// program in the tab, not the one that asked.
  static func permission(for request: TerminalClipboardRequest, subject: String)
    -> AppletPermissionRequest?
  {
    guard request.offersSession else { return nil }

    switch request.kind {
    case .read:
      return AppletPermissionRequest(
        title: "Allow a program to read your clipboard?",
        detail:
          "This pane is controlled by another program. A program in this tab asked for the clipboard with an escape sequence. It would receive: \(preview(request.text))",
        subject: subject, sessionTitle: "Allow Reads in This Tab")

    case .write:
      return AppletPermissionRequest(
        title: "Allow a program to replace your clipboard?",
        detail:
          "This pane is controlled by another program. A program in this tab asked to replace the clipboard with an escape sequence. It would write: \(preview(request.text))",
        subject: subject, sessionTitle: "Allow Writes in This Tab")

    case .unsafePaste:
      return nil
    }
  }

  static func answer(_ answer: AppletPermissionAnswer) -> TerminalClipboardAnswer {
    switch answer {
    case .deny: return .deny
    case .allowOnce: return .allowOnce
    case .allowForSession: return .allowForSession
    }
  }

  /// Removes control characters and caps the length. Text from a program is untrusted, so it must
  /// not forge a second line in the status bar.
  static func sanitized(_ text: String, limit: Int = maximumMessageLength) -> String {
    let cleaned = text.unicodeScalars.map { scalar -> Character in
      CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
        ? " " : Character(scalar)
    }

    let collapsed = String(cleaned).split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
    return String(collapsed.prefix(limit))
  }

  private static func preview(_ text: String) -> String {
    let shown = sanitized(text, limit: 120)
    return "\u{201C}\(shown)\u{201D}"
  }
}
