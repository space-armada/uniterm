import AppKit
import AppletKit
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

    /// A program-mode tab restored from a description. It has no session until the user runs it.
    var awaitingRun = false

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

  private static let defaultTitle = "Terminal"

  public let typeID = TerminalDescription.typeID
  public let view: NSView

  public weak var host: (any AppletHost)?

  public private(set) var segments: [AppletSegment] = []

  private let container = TerminalContainerView()
  private let tabBar = AppletTabBar()
  private let runPrompt = TerminalRunPrompt()
  private let engine: any TerminalEngine
  private let mode: TerminalDescription.Mode
  private let commandLine: String?
  private let shellEnvironment: [String: String]
  private let directoryExists: (String) -> Bool
  private let home: String
  private var tabs: [Tab]
  private var selectedIndex: Int
  private var started = false
  private var closingTab = false

  /// The most closed tabs the applet remembers. A policy value with no setting, equal to the
  /// window's pane undo depth.
  static let closedTabDepth = 20

  /// The tabs the user closed, newest first. They live in memory with the window's undo state and
  /// ride in the description's undo-only part, so a reopened pane brings them back.
  private var closedTabs: [TerminalDescription.ClosedTab] = []

  /// Notifications reach the status bar through this. It records them in the history when they
  /// arrive and holds them back while the applet is detached.
  private var alerts = AppletAlerts()

  /// A shell in one tab, with the launch as given.
  public convenience init(engine: any TerminalEngine, launch: TerminalLaunch) {
    self.init(
      engine: engine, mode: .shell, commandLine: nil, shellEnvironment: launch.environment,
      launches: [launch], selected: 0, directoryExists: RestoreDirectory.isLocalDirectory,
      home: NSHomeDirectory())
  }

  /// A shell in one tab. It starts in the given directory when that is an absolute path and still
  /// a directory here. Otherwise it starts in the home directory. The launch always carries an
  /// explicit directory, so the terminal engine never picks one on its own.
  public convenience init(
    engine: any TerminalEngine, workingDirectory: String? = nil,
    directoryExists: @escaping (String) -> Bool = RestoreDirectory.isLocalDirectory,
    home: String = NSHomeDirectory()
  ) {
    let directory = RestoreDirectory.resolve(
      reported: workingDirectory, starting: nil, home: home, exists: directoryExists)

    self.init(
      engine: engine, mode: .shell, commandLine: nil, shellEnvironment: [:],
      launches: [.loginShell(workingDirectory: directory)], selected: 0,
      directoryExists: directoryExists, home: home)
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
  public convenience init(
    engine: any TerminalEngine, restoring description: AppletDescription,
    directoryExists: @escaping (String) -> Bool = RestoreDirectory.isLocalDirectory,
    home: String = NSHomeDirectory()
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
        selected: decoded.selectedTab, directoryExists: directoryExists, home: home)

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
        selected: decoded.selectedTab, directoryExists: directoryExists, home: home)

      for tab in tabs { tab.awaitingRun = true }
      refreshTabs()
    }

    closedTabs = Array(carried.prefix(Self.closedTabDepth))
  }

  private init(
    engine: any TerminalEngine, mode: TerminalDescription.Mode, commandLine: String?,
    shellEnvironment: [String: String], launches: [TerminalLaunch], selected: Int,
    directoryExists: @escaping (String) -> Bool, home: String
  ) {
    self.engine = engine
    self.directoryExists = directoryExists
    self.home = home
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
    container.addSubview(runPrompt)
    runPrompt.isHidden = true
    runPrompt.onRun = { [weak self] in self?.runPendingProgram() }
    container.onResize = { [weak self] in self?.layoutContents() }

    tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
    tabBar.onNew = { [weak self] in self?.openTab() }
    tabBar.onClose = { [weak self] index in
      Task { @MainActor [weak self] in _ = await self?.closeTab(at: index) }
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
      AppletTab(
        id: tab.id, title: tab.title,
        details: tab.workingDirectory.map { [$0] } ?? [])
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
    alerts.discard()

    for tab in tabs {
      tab.session?.view.removeFromSuperview()
      tab.session?.close()
      tab.session = nil
    }
  }

  /// A terminal makes no sound and plays no video, so it pauses no output. It holds back what the
  /// user would notice but cannot see: notifications from OSC 9 and OSC 777 are recorded in the
  /// history when they arrive and are not shown. The bell raises no alert here, so there is
  /// nothing to hold. A shell keeps running whether or not anyone can see it, as a user expects.
  ///
  /// The applet keeps a bounded number of held notifications, and `reattach` shows them. When the
  /// bound drops some, one more message counts them. A pane that closes while detached keeps its
  /// history records.
  public func detach() {
    alerts.detach()
  }

  public func reattach() {
    alerts.reattach(from: self, to: host)
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

  public func describe() -> AppletDescription {
    let description = TerminalDescription(
      mode: mode, command: commandLine,
      tabs: tabs.map {
        TerminalDescription.Tab(
          workingDirectory: $0.workingDirectory, startDirectory: $0.launch.workingDirectory)
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

    guard tabs.indices.contains(index), !closingTab else { return .declined }

    let tab = tabs[index]

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

  /// Keeps a closed tab for reopening. The stamp and the index are taken now, after any close
  /// question was answered, so both describe the tab as it left.
  private func recordClosed(_ tab: Tab, at index: Int) {
    guard let host else { return }

    closedTabs.insert(
      TerminalDescription.ClosedTab(
        stamp: host.issueCloseStamp(), index: index, title: tab.title,
        tab: TerminalDescription.Tab(
          workingDirectory: tab.workingDirectory, startDirectory: tab.launch.workingDirectory)),
      at: 0)

    if closedTabs.count > Self.closedTabDepth {
      closedTabs.removeLast(closedTabs.count - Self.closedTabDepth)
    }
  }

  public var closedTabStamps: [UInt64] {
    closedTabs.map(\.stamp)
  }

  /// Starts a fresh shell from the closed tab's description, in the directory it last reported
  /// when that is absolute and still exists, else its start directory, else home. The tab goes
  /// back to its former index, clamped to the tab count, and is selected.
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
    let session = try engine.makeSession(launch: tab.launch)
    tab.session = session
    session.onEvent = { [weak self, weak tab] event in
      guard let self, let tab else { return }

      self.handle(event, in: tab)
    }

    session.view.isHidden = true
    container.addSubview(session.view)
  }

  private var hasFocus: Bool {
    guard let responder = view.window?.firstResponder as? NSView else { return false }

    return responder.isDescendant(of: view)
  }

  /// Shows the selected tab's terminal and hides the others, then updates the bar and the layout.
  private func refreshTabs() {
    for (index, tab) in tabs.enumerated() {
      let shown = index == selectedIndex

      tab.session?.view.isHidden = !shown

      if !shown {
        tab.session?.setFocused(false)
      }

      tab.session?.setVisible(shown)
    }

    tabBar.update(
      titles: tabs.map { $0.title }, selected: selectedIndex, canOpenTab: canOpenTab)
    tabBar.isHidden = tabs.count < 2

    runPrompt.command = commandLine ?? ""
    runPrompt.isHidden = !isAwaitingRun
    layoutContents()
  }

  private func layoutContents() {
    let bounds = container.bounds
    let barHeight = tabBar.isHidden ? 0 : AppletTabBar.height

    tabBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: AppletTabBar.height)

    let content = NSRect(
      x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))

    runPrompt.frame = content

    for tab in tabs {
      tab.session?.view.frame = content
    }
  }

  // MARK: Events

  private func handle(_ event: TerminalEvent, in tab: Tab) {
    let isSelected = tab === selectedTab

    switch event {
    case .titleChanged(let value):
      let cleaned = Self.sanitized(value, limit: 80)
      tab.title = cleaned.isEmpty ? Self.defaultTitle : cleaned
      tabBar.update(
        titles: tabs.map { $0.title }, selected: selectedIndex, canOpenTab: canOpenTab)

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

    case .commandFinished(let exitCode, _):
      tab.failedExitCode = exitCode.flatMap { $0 != 0 ? $0 : nil }

      if isSelected { rebuildSegments() }

    case .notification(let title, let body):
      let text = [title, body].map { Self.sanitized($0) }.filter { !$0.isEmpty }.joined(
        separator: ": ")
      guard !text.isEmpty else { return }

      alerts.deliver(.info, text, from: self, to: host)

    case .clipboardRequest(let request):
      confirm(request)

    case .bell:
      break

    case .exited:
      guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }

      if tabs.count == 1 {
        host?.appletDidExit(self)
      } else {
        recordClosed(tab, at: index)
        removeTab(at: index)
      }
    }
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

  /// A request is never answered without the user's say. With no host to ask, it is refused.
  private func confirm(_ request: TerminalClipboardRequest) {
    guard let host else {
      request.resolve(allow: false)
      return
    }

    let confirmation: AppletConfirmation

    switch request.kind {
    case .read:
      confirmation = AppletConfirmation(
        title: "Allow a program to read your clipboard?",
        detail:
          "A program in this pane asked for the clipboard with an escape sequence. It would receive: \(Self.preview(request.text))",
        confirmTitle: "Allow", cancelTitle: "Deny")

    case .unsafePaste:
      confirmation = AppletConfirmation(
        title: "Paste text that could run commands?",
        detail:
          "The text holds control characters or a newline. It would be pasted as: \(Self.preview(request.text))",
        confirmTitle: "Paste", cancelTitle: "Cancel")
    }

    Task { @MainActor [weak self] in
      guard let self else {
        request.resolve(allow: false)
        return
      }

      let allowed = await host.applet(self, confirm: confirmation)
      request.resolve(allow: allowed)
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
