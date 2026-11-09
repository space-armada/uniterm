import AppKit
import AppletKit
import LayoutKit
import PaneModel
import PlaceSearch
import Preferences
import StatusKit
import Theme

/// Makes the applet that a new pane runs. The directory is where the new pane starts, taken from
/// the pane it was opened from. It is nil for the first pane of a window, and the factory picks
/// the start then. The factory throws when it cannot start the choice. The window controller owns
/// what it returns.
public typealias AppletFactory = @MainActor (AppletChoice, String?) throws -> any Applet

/// Makes an applet from the description of a closed pane. It throws when the description is
/// unknown, newer than this build, or unreadable. The applet must start nothing until the window
/// starts it, and a restored program waits for the user to run it.
public typealias AppletRestorer = @MainActor (AppletDescription) throws -> any Applet

/// Hosts one window with a full-size content view. Content extends under the title bar, and the
/// standard traffic lights stay. The content area holds a tree of panes, and each pane runs one
/// applet.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate {
  /// The window's message queue. Anything in the window may post to it.
  public let statusCenter: StatusCenter

  let contentController: MainContentViewController
  let paneArea: PaneAreaView
  private let appearance: AppearanceController
  private let placement: StatusBarPlacement
  private let palettePlacement: PalettePlacement
  private let makeApplet: AppletFactory
  private let places: PlaceServices
  private let restoreApplet: AppletRestorer
  private var appearanceToken: UUID?
  private var statusToken: UUID?
  private var started = Set<ObjectIdentifier>()

  /// The applets the launch restore built. Each starts once with the restore origin. Everything
  /// else starts with the user origin.
  private var launchRestored = Set<ObjectIdentifier>()
  private var panesClosed = false
  private(set) var historyVisible = false

  /// The ID scripts name this window by. The set that opened the window assigns it.
  var scriptWindowID: UInt64 = 0

  /// The numbers scripts name this window's tabs by.
  var scriptTabNumbers = ScriptTabNumbers()

  private struct HostEntry {
    weak var applet: (any Applet)?
    let host: PaneStatusHost
  }

  /// Each applet's host, keyed by the applet. The applet holds its host weakly.
  private var hosts: [ObjectIdentifier: HostEntry] = [:]

  /// The commands the window runs. One registry serves every window of the app.
  let commands: CommandRegistry

  /// The applet types the app ships. The palette names each tab's applet from them. A pane whose
  /// type has no declaration, such as the launcher, shows its tabs as plain tabs.
  let appletTypes: [AppletTypeDeclaration]

  /// The pane that had focus when the palette showed, nil while it is hidden. It is the pane that
  /// every command run from the palette targets. It is fixed when the palette shows, so a command
  /// never reads the focus that the palette itself holds.
  var paletteTarget: NodeID?

  var isPaletteVisible: Bool { paletteTarget != nil }

  /// Who owns the groups of panes a controller drives. The window asks it nothing yet, and tells
  /// it about every ordinary split. A routed split is never reported, so a routed pane joins no
  /// group.
  var paneGroups: any PaneGroupOwnership = NoPaneGroups()

  /// The tabs that took focus, newest first. It lives in memory only. A tab ID is never reused,
  /// so an entry for a tab that closed is harmless and the palette prunes it when it lists.
  var tabRecency: [PaletteTabKey] = []

  static let maximumRecentTabs = 64

  /// How long a burst of tab changes waits before the palette lists again. Typing refreshes the
  /// list at once, so only changes from the applets are held back.
  static let paletteRefreshInterval: TimeInterval = 0.1

  /// True while a held-back refresh is waiting. A change that arrives meanwhile joins it.
  var paletteRefreshPending = false

  /// Starts a wake after a delay. Tests replace it with one they fire by hand.
  var paletteWake: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      action()
    }
  }

  /// The window's closed panes, as descriptions. No closed applet is kept alive.
  private(set) var ledger: CloseUndoLedger

  /// The last stamp issued. One counter orders the closes of panes and of every applet's tabs. It
  /// counts closes and never reads the clock.
  private var lastCloseStamp: UInt64 = 0

  /// Asks the user before something is ended that undo cannot bring back. Tests replace it.
  var confirmer: CloseConfirmer = CloseDialog.present

  /// Asks before a close would lose unsaved work. Tests replace it.
  var unsavedConfirmer: UnsavedConfirmer = UnsavedDialog.present

  /// The question the window is asking now, if any. A second question is not stacked on it.
  private(set) var pendingGuard: Task<Void, Never>?

  /// Applets that ended on their own and are still in the tree, such as a last pane left behind by
  /// a cancelled window question. Closing one adds no undo entry.
  private var exitedApplets = Set<ObjectIdentifier>()

  /// Runs once, when the window closes. The set of windows uses it to let go of the controller.
  var onClose: ((MainWindowController) -> Void)?

  /// Runs when the window becomes key. The set of windows uses it to remember which was key last.
  var onBecomeKey: ((MainWindowController) -> Void)?

  /// The description of each pane as of the last snapshot of the window.
  private var savedDescriptions: [NodeID: AppletDescription] = [:]

  /// Runs when something a saved layout holds changes: the pane tree, the focus, the window's frame,
  /// or an applet's description.
  var onLayoutChange: (() -> Void)?

  /// The visible area of the screen the window is on. A window never asks for more room than that.
  /// Tests replace it.
  var visibleFrameProvider: @MainActor (NSWindow) -> NSRect? = { window in
    (window.screen ?? NSScreen.main)?.visibleFrame
  }

  /// The settings store supplies the status bar position, which is global to every window. The
  /// identifier names the window to accessibility, so it must differ between open windows.
  ///
  /// The undo policy sets how many closes the window remembers.
  ///
  /// A restored window takes its pane tree and its applets from the saved layout, and `makeApplet`
  /// is not called for the first pane. A routed window holds `routed` as its only pane, starts no
  /// shell beside it, and takes no directory from anywhere. Otherwise the first pane starts in
  /// `directory`.
  public init(
    appearance: AppearanceController, settings: SettingsStore,
    statusCenter: StatusCenter = StatusCenter(),
    identifier: String = "main-window",
    undoPolicy: CloseUndoPolicy = .standard,
    startingIn directory: String? = nil,
    commands: CommandRegistry = CommandRegistry(),
    appletTypes: [AppletTypeDeclaration] = [],
    restoring restored: RestoredWindow? = nil,
    startingWith routed: (any Applet)? = nil,
    restoreApplet: @escaping AppletRestorer = { _ in
      throw AppletRestoreError.unsupported("this window cannot reopen a closed pane")
    },
    places: PlaceServices = .none,
    makeApplet: @escaping AppletFactory
  ) throws {
    self.places = places
    self.appearance = appearance
    self.statusCenter = statusCenter
    self.makeApplet = makeApplet
    self.restoreApplet = restoreApplet
    self.commands = commands
    self.appletTypes = appletTypes
    ledger = CloseUndoLedger(policy: undoPolicy)
    placement = StatusBarPlacement(store: settings, statusCenter: statusCenter)
    palettePlacement = PalettePlacement(store: settings, statusCenter: statusCenter)

    let panes = try restored.map { try PaneRestoration.restore($0, restorer: restoreApplet) }

    if let panes {
      launchRestored = Set(panes.applets.values.map { ObjectIdentifier($0) })
      paneArea = PaneAreaView(restoring: panes.tree, applets: panes.applets, focus: panes.focus)
    } else if let routed {
      paneArea = PaneAreaView(firstApplet: routed)
    } else {
      paneArea = PaneAreaView(firstApplet: try makeApplet(.terminalShell, directory))
    }

    contentController = MainContentViewController(
      paneView: paneArea, statusBarEdge: DockEdge(placement.position),
      palette: palettePlacement.value)

    let window = MainWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    window.title = "uniterm"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.setAccessibilityIdentifier(identifier)
    window.contentViewController = contentController
    window.setContentSize(NSSize(width: 960, height: 640))
    window.center()

    super.init(window: window)

    window.delegate = self

    for pane in paneArea.tree.paneIDs {
      if let applet = paneArea.applet(for: pane) { bindHost(of: applet, to: pane) }
    }

    for applet in paneArea.applets { adopt(applet) }

    paneArea.onAppletPlaced = { [weak self] applet, pane in
      self?.bindHost(of: applet, to: pane)
    }

    paneArea.onTreeChange = { [weak self] in
      self?.updateMinimumSize()
      self?.refreshCommandPalette()
      self?.commands.menu?.sync()
    }
    paneArea.onLayoutChange = { [weak self] in
      self?.onLayoutChange?()
      self?.schedulePaletteRefresh()
    }
    paneArea.onFocusChange = { [weak self] in
      self?.refreshStatusBar()
      self?.recordFocusedTab()
      self?.commands.menu?.sync()
    }
    contentController.onLayout = { [weak self] in self?.updateMinimumSize() }
    contentController.statusBar.onActivate = { [weak self] in self?.dispatch(.toggleMessageHistory)
    }
    contentController.statusBar.onDismiss = { [weak self] in self?.dispatch(.dismissMessage) }
    wireCommandPalette()
    wireHistory()
    recordFocusedTab()
    placement.onChange = { [weak self] position in
      self?.contentController.move(.statusBar, to: DockEdge(position))
    }
    palettePlacement.onChange = { [weak self] value in
      self?.paletteSettingsDidChange(to: value)
    }
    updateMinimumSize()

    appearanceToken = appearance.addObserver { [weak self] palette in
      self?.apply(palette)
    }

    statusToken = statusCenter.addObserver { [weak self] in
      self?.statusDidChange()
    }

    refreshStatusBar()

    if let panes, panes.placeholders > 0 {
      let noun = panes.placeholders == 1 ? "pane" : "panes"
      statusCenter.post(
        level: .warning,
        text: "\(panes.placeholders) saved \(noun) could not be restored and kept as they were.")
    }
  }

  isolated deinit {
    if let appearanceToken {
      appearance.removeObserver(appearanceToken)
    }

    if let statusToken {
      statusCenter.removeObserver(statusToken)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  public override func showWindow(_ sender: Any?) {
    super.showWindow(sender)

    contentController.view.layoutSubtreeIfNeeded()
    startPendingApplets()
    paneArea.focus(paneArea.focusedPane)
  }

  private func apply(_ palette: ThemePalette) {
    window?.backgroundColor = palette[.base].nsColor
    contentController.apply(palette)
    paneArea.apply(palette)
  }

  // MARK: Status bar

  /// The window states the bar shows, one compact slot each. The window set owns them and pushes
  /// each change here.
  var windowStates = WindowStates() {
    didSet {
      if windowStates != oldValue { refreshStatusBar() }
    }
  }

  /// The segments the bar shows now. The window owns the message area, the unseen-error
  /// indicator, and a slot for each window state. The applet of the focused pane fills the rest.
  /// The pane model decides which pane that is, not the first responder, so the segments stay put
  /// while the keyboard is in the Settings window or a sheet.
  var statusBarSegments: [BarSegment] {
    StatusBarContent.segments(
      display: statusCenter.display, hasUnseenError: statusCenter.hasUnseenError,
      hasUnseenWarning: statusCenter.hasUnseenWarning, windowStates: windowStates,
      applet: paneArea.applet(for: paneArea.focusedPane)?.segments ?? [])
  }

  private func refreshStatusBar() {
    contentController.statusBar.show(statusBarSegments)
  }

  private func statusDidChange() {
    refreshStatusBar()

    if historyVisible {
      showHistory()
    }
  }

  /// Opens or closes the history. Opening it acknowledges only the rows it shows.
  func setHistoryVisible(_ visible: Bool) {
    guard visible != historyVisible else { return }

    historyVisible = visible

    if !visible {
      contentController.history.releaseKeyboard()
    }

    contentController.setHistoryVisible(visible)

    if visible {
      contentController.view.layoutSubtreeIfNeeded()
      showHistory()
    }
  }

  private func showHistory() {
    contentController.history.show(
      statusCenter.history, loss: statusCenter.loss,
      panes: statusCenter.queue.historyPanes())
  }

  private func wireHistory() {
    let history = contentController.history

    history.isPaneOpen = { [weak self] id in
      self?.contains(pane: NodeID(rawValue: id)) ?? false
    }
    history.onExposed = { [weak self] ids in
      self?.statusCenter.acknowledge(ids: ids)
    }
    history.onAcknowledgeLoss = { [weak self] in
      self?.statusCenter.acknowledgeLoss()
    }
    history.onFocusPane = { [weak self] id in
      self?.focusPaneFromHistory(id) ?? false
    }
    history.onReleaseKeyboard = { [weak self] in
      guard let self else { return }

      paneArea.focus(paneArea.focusedPane, keyboard: !isPaletteVisible)
    }
    history.isObserved = { [weak self] in
      self?.windowShowsContent() ?? false
    }

    NotificationCenter.default.addObserver(
      self, selector: #selector(windowOcclusionChanged),
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
  }

  /// Replaces the window check in tests, which never show their windows.
  var windowShowsContentOverride: (() -> Bool)?

  /// Says whether the window can show its content to the user. A minimized window and one that
  /// other windows cover cannot, so the history acknowledges nothing in it.
  func windowShowsContent() -> Bool {
    if let windowShowsContentOverride { return windowShowsContentOverride() }

    guard let window else { return false }

    return !window.isMiniaturized && window.occlusionState.contains(.visible)
  }

  /// A window that becomes visible again shows its history rows, so they count as read now.
  @objc private func windowOcclusionChanged() {
    if historyVisible {
      contentController.history.reportExposure()
    }
  }

  /// Opens the history if it is closed, then gives it the keyboard. The user asked for this, so it
  /// is the one way the panel takes the keyboard from a pane.
  func focusHistory() {
    setHistoryVisible(true)
    contentController.history.engageKeyboard()
  }

  /// Moves focus to the pane a history row came from. The ID is resolved again here, so a pane that
  /// closed since the row was drawn is not reached. This never reopens a pane or runs anything.
  /// Returns false when the pane is gone.
  @discardableResult
  func focusPaneFromHistory(_ id: UInt64) -> Bool {
    let pane = NodeID(rawValue: id)

    guard contains(pane: pane) else { return false }

    paneArea.focus(pane, keyboard: !isPaletteVisible)
    return true
  }

  func refreshMinimumSize() {
    updateMinimumSize()
  }

  /// The window never shrinks below what the tree needs. The tree's minimum is for the pane area
  /// alone, so the title bar and the docked regions add to it.
  private func updateMinimumSize() {
    guard let window else { return }

    let tree = paneArea.minimumSize
    var minimum = NSSize(
      width: tree.width, height: tree.height + contentController.chromeHeight)

    // A tree that needs more than the screen offers still opens. The layout holds each pane at its
    // minimum and overflows, and the user closes panes or moves focus by keyboard.
    if let visible = visibleFrameProvider(window) {
      let room = window.contentRect(forFrameRect: visible).size
      minimum = NSSize(
        width: min(minimum.width, room.width), height: min(minimum.height, room.height))
    }

    if window.contentMinSize != minimum {
      window.contentMinSize = minimum
    }
  }

  private func startPendingApplets() {
    for applet in paneArea.applets where started.insert(ObjectIdentifier(applet)).inserted {
      applet.start(
        origin: launchRestored.remove(ObjectIdentifier(applet)) != nil ? .restore : .user)
    }
  }

  // MARK: Panes

  /// The panes in reading order. Tests and the UI read it.
  var paneIDs: [NodeID] { paneArea.tree.paneIDs }

  var focusedPane: NodeID { paneArea.focusedPane }

  /// Hands the applet a host bound to its pane, as the pane takes the applet. The host keeps the
  /// pane's ID for good, so the applet's messages keep their origin after the pane closes. A
  /// launcher swap gives the new applet a host bound to the same pane.
  ///
  /// The window holds each host for as long as its applet lives. Entries for applets that are gone
  /// are dropped here, so the table stays as small as the applets that can still post.
  private func bindHost(of applet: any Applet, to pane: NodeID) {
    hosts = hosts.filter { $0.value.applet != nil }

    let host = PaneStatusHost(pane: pane, applet: applet, window: self)
    hosts[ObjectIdentifier(applet)] = HostEntry(applet: applet, host: host)
    applet.host = host
  }

  /// Makes the applet ready for the window. A launcher also learns how to open its choice, and gets
  /// the place search the app gave the window.
  private func adopt(_ applet: any Applet) {
    if let launcher = applet as? LauncherApplet {
      launcher.launcher.offerPlaces(places)

      launcher.onChoose = { [weak self, weak launcher] choice in
        guard let self, let launcher else { return }

        try replace(launcher, with: choice)
      }
    }
  }

  /// The directory the focused pane's applet reports, for a pane opened from it.
  var focusedDirectory: String? {
    directory(of: focusedPane)
  }

  /// The directory a pane's applet reports, for a pane opened from it.
  func directory(of pane: NodeID) -> String? {
    paneArea.applet(for: pane)?.currentDirectory
  }

  /// Splits `pane` and starts the chosen applet in the new one, in the directory `pane` reports.
  /// Returns nil when the pane is too small, or the applet could not start. Either way the status
  /// bar says why.
  @discardableResult
  func openPane(_ choice: AppletChoice, axis: Axis, from pane: NodeID) -> NodeID? {
    openPane(choice, axis: axis, from: pane, directory: directory(of: pane))
  }

  /// As `openPane(_:axis:from:)`, with the directory the new pane starts in named by the caller.
  /// A nil directory leaves the start to the applet's factory.
  @discardableResult
  func openPane(
    _ choice: AppletChoice, axis: Axis, from pane: NodeID, directory: String?
  ) -> NodeID? {
    contentController.view.layoutSubtreeIfNeeded()

    let applet: any Applet
    do {
      applet = try makeApplet(choice, directory)
    } catch {
      statusCenter.post(
        level: .error,
        text: "The pane did not open: \(error.localizedDescription)"
      )
      return nil
    }

    return place(applet, axis: axis, from: pane)
  }

  // MARK: Routed panes

  /// True when a routed pane may split this window. A window with a sheet attached holds the
  /// user's attention, so it counts as having no room.
  public var acceptsRoutedPane: Bool { paneActionsEnabled }

  /// True when the pane is in this window.
  public func contains(pane: NodeID) -> Bool {
    paneArea.tree.paneIDs.contains(pane)
  }

  /// The pane with the largest area, the first in reading order on a tie.
  public func largestPane() -> NodeID? {
    contentController.view.layoutSubtreeIfNeeded()

    let frames = paneArea.tree.layout(in: paneArea.bounds.size).frames
    var best: (pane: NodeID, area: CGFloat)?

    for pane in paneArea.tree.paneIDs {
      guard let frame = frames[pane] else { continue }

      let area = frame.width * frame.height

      if area > (best?.area ?? -1) {
        best = (pane, area)
      }
    }

    return best?.pane
  }

  /// The axis a split of `pane` uses, or nil when no axis has room. A requested axis is used only
  /// when it fits. Without one, a wide pane splits side by side and a tall one is stacked, and the
  /// other axis is the fallback.
  func splitAxis(for pane: NodeID, requested: Axis?) -> Axis? {
    contentController.view.layoutSubtreeIfNeeded()

    if let requested { return paneArea.canSplit(pane, requested) ? requested : nil }

    let frame = paneArea.tree.layout(in: paneArea.bounds.size).frames[pane]
    let wide = (frame?.width ?? 0) >= (frame?.height ?? 0)
    let axes: [Axis] = wide ? [.row, .column] : [.column, .row]

    return axes.first { paneArea.canSplit(pane, $0) }
  }

  /// Splits `pane` and puts a routed applet in the new pane, which takes focus. The new pane is
  /// disconnected: it joins no group a controller owns, and no pane's source is replaced.
  ///
  /// Returns nil, and leaves the applet untouched for the caller, when the window has a sheet, the
  /// pane is not here, or there is no room in either direction.
  @discardableResult
  public func placeRouted(_ applet: any Applet, beside pane: NodeID) -> NodeID? {
    guard paneActionsEnabled, contains(pane: pane) else { return nil }

    contentController.view.layoutSubtreeIfNeeded()

    let frame = paneArea.tree.layout(in: paneArea.bounds.size).frames[pane]
    let wide = (frame?.width ?? 0) >= (frame?.height ?? 0)
    let axes: [Axis] = wide ? [.row, .column] : [.column, .row]

    guard let axis = axes.first(where: { paneArea.canSplit(pane, $0) }) else { return nil }

    adopt(applet)

    let created: NodeID
    do {
      created = try paneArea.split(pane, axis, adding: applet)
    } catch {
      applet.host = nil
      hosts[ObjectIdentifier(applet)] = nil
      return nil
    }

    startPendingApplets()
    paneArea.focus(created)
    return created
  }

  /// Splits the pane with the largest area in the current layout and puts a routed applet in the
  /// new pane. A nil return means the window refused: it has a sheet, or the largest pane has no
  /// room to split. The applet is untouched then, and the caller keeps it.
  @discardableResult
  public func placeRoutedInLargestPane(_ applet: any Applet) -> NodeID? {
    guard let pane = largestPane() else { return nil }

    return placeRouted(applet, beside: pane)
  }

  /// Splits `pane` and puts a launcher in the new one, which takes the keyboard. The launcher
  /// remembers the directory `pane` reports and starts what it opens there.
  @discardableResult
  func openLauncher(axis: Axis, from pane: NodeID) -> NodeID? {
    contentController.view.layoutSubtreeIfNeeded()

    return place(LauncherApplet(directory: directory(of: pane)), axis: axis, from: pane)
  }

  private func place(_ applet: any Applet, axis: Axis, from pane: NodeID) -> NodeID? {
    adopt(applet)

    let created: NodeID
    do {
      created = try paneArea.split(pane, axis, adding: applet)
    } catch {
      applet.close()
      postNoRoom()
      return nil
    }

    paneGroups.paneSplit(created, from: pane)
    startPendingApplets()
    paneArea.focus(created)
    return created
  }

  /// Runs the choice in the launcher's pane. The pane keeps its ID and its place, and the launcher
  /// closes. It throws before anything changes when the choice cannot start, so the launcher stays
  /// and shows the reason.
  private func replace(_ launcher: LauncherApplet, with choice: AppletChoice) throws {
    guard let pane = paneArea.paneID(for: launcher) else { return }

    let applet = try makeApplet(choice, launcher.currentDirectory)
    adopt(applet)

    guard let replaced = paneArea.replace(pane, with: applet) else {
      applet.close()
      return
    }

    started.remove(ObjectIdentifier(replaced))
    replaced.close()

    startPendingApplets()
    paneArea.focus(pane)
    refreshStatusBar()
  }

  private func postNoRoom() {
    statusCenter.post(
      level: .warning, text: "There is not enough room to split this pane.")
  }

  /// A sheet, such as a close question or a clipboard question, holds the window's attention. Pane
  /// actions wait until it is answered. Cmd-W does not cancel a sheet, and Escape does.
  var paneActionsEnabled: Bool {
    window?.attachedSheet == nil
  }

  /// Splits `pane`, or says there is no room. The new pane holds a launcher.
  func requestSplit(_ axis: Axis, from pane: NodeID?) {
    guard paneActionsEnabled, let pane else { return }

    contentController.view.layoutSubtreeIfNeeded()

    guard paneArea.canSplit(pane, axis) else {
      postNoRoom()
      return
    }

    openLauncher(axis: axis, from: pane)
  }

  // MARK: Closing panes

  /// Closes one pane. Its space goes to its neighbors. The last pane closes the window.
  ///
  /// A close is a close, however it happens. A pane the user closes and a pane whose applet ended
  /// on its own both end the applet at once and put its description on the reopen list. Only a
  /// pane the user closes while it holds unsaved work, or runs something, asks first. A launcher
  /// has nothing to reopen.
  func closePane(_ pane: NodeID, appletEnded: Bool) {
    guard let applet = paneArea.applet(for: pane) else { return }

    guard paneArea.paneCount > 1 else {
      closeLastPane()
      return
    }

    if applet is LauncherApplet {
      discard(pane)
    } else if appletEnded || exitedApplets.contains(ObjectIdentifier(applet)) {
      describeAndClose(pane)
    } else if applet.unsavedWork != nil {
      askAboutUnsaved(pane, applet: applet)
    } else if applet.isRunningSomething {
      askBeforeClosing(pane, applet: applet)
    } else {
      describeAndClose(pane)
    }
  }

  /// Asks Save, Don't Save, or Cancel for one pane. Once the work is saved or let go, the close
  /// goes on as any other, asking about a running program when there is one.
  private func askAboutUnsaved(_ pane: NodeID, applet: any Applet) {
    guard pendingGuard == nil, let label = applet.unsavedWork?.label else { return }

    let question = UnsavedQuestion(
      title: "Save changes before closing this pane?",
      detail: "Your changes are lost if you don\u{2019}t save them.", labels: [label])

    pendingGuard = Task { @MainActor [weak self] in
      guard let self else { return }

      let mayClose = await settleUnsaved([applet], question: question)
      pendingGuard = nil

      guard mayClose, paneArea.applet(for: pane) === applet else { return }

      if applet.isRunningSomething {
        askBeforeClosing(pane, applet: applet)
      } else if paneArea.paneCount > 1 {
        describeAndClose(pane)
      } else {
        window?.close()
      }
    }
  }

  /// What in this window holds unsaved work, as a dialog names it.
  public var unsavedLabels: [String] {
    paneArea.applets.compactMap { $0.unsavedWork?.label }
  }

  /// Asks about the unsaved work in `applets`, and saves it when the user says so. Returns true
  /// when the close may go ahead: nothing was unsaved, the user let it go, or every save worked.
  func settleUnsaved(_ applets: [any Applet], question: UnsavedQuestion) async -> Bool {
    let holding = applets.filter { $0.unsavedWork != nil }

    guard !holding.isEmpty else { return true }

    switch await unsavedConfirmer(question, window) {
    case .cancel:
      return false

    case .discard:
      return true

    case .save:
      for applet in holding where applet.unsavedWork != nil {
        guard await applet.saveUnsavedWork() else { return false }
      }

      return true
    }
  }

  /// Asks about every pane's unsaved work before the window closes, then about what is running.
  private func askAboutUnsavedThenCloseWindow() {
    guard pendingGuard == nil else { return }

    let question = UnsavedQuestion(
      title: "Save changes before closing this window?",
      detail: "Your changes are lost if you don\u{2019}t save them.", labels: unsavedLabels)

    pendingGuard = Task { @MainActor [weak self] in
      guard let self else { return }

      let mayClose = await settleUnsaved(paneArea.applets, question: question)
      pendingGuard = nil

      guard mayClose else { return }

      let labels = runningTabLabels

      if labels.isEmpty {
        window?.close()
      } else {
        askToCloseWindow(labels: labels)
      }
    }
  }

  private func askBeforeClosing(_ pane: NodeID, applet: any Applet) {
    let request = CloseConfirmation(
      title: "Close this pane?",
      detail:
        "Closing this pane ends what is running in it. Reopening the pane puts it back in the same place, but not the running session.",
      labels: applet.runningLabels, confirmTitle: "Close Pane", cancelTitle: "Cancel")

    ask(request) { [weak self] in
      guard let self, paneArea.applet(for: pane) === applet else { return }

      if paneArea.paneCount > 1 {
        describeAndClose(pane)
      } else {
        window?.close()
      }
    }
  }

  /// Ends the pane's applet at once and puts its description on the undo stack.
  private func describeAndClose(_ pane: NodeID) {
    guard let applet = paneArea.applet(for: pane), let removed = try? paneArea.remove(pane)
    else { return }

    let closed = ClosedPane(
      stamp: issueCloseStamp(), placement: removed.placement, description: applet.describe(),
      title: applet.title)

    started.remove(ObjectIdentifier(applet))
    exitedApplets.remove(ObjectIdentifier(applet))
    applet.close()
    statusCenter.paneClosed(id: pane.rawValue)

    if let next = removed.refocus {
      paneArea.focus(next, keyboard: !isPaletteVisible)
    }

    ledger.push(closed)
  }

  /// Closes a launcher's pane. A launcher holds nothing to reopen.
  private func discard(_ pane: NodeID) {
    guard let applet = paneArea.applet(for: pane), let removed = try? paneArea.remove(pane)
    else { return }

    started.remove(ObjectIdentifier(applet))
    exitedApplets.remove(ObjectIdentifier(applet))
    applet.close()
    statusCenter.paneClosed(id: pane.rawValue)

    if let next = removed.refocus {
      paneArea.focus(next, keyboard: !isPaletteVisible)
    }
  }

  /// What is running in this window. Closing the window or quitting ends all of it.
  public var runningTabLabels: [String] {
    paneArea.applets.flatMap { $0.runningLabels }
  }

  /// The last pane closes the window. When something is running in it, the user is asked first,
  /// and Cancel keeps the window. A pane whose applet ended while the question is open is not
  /// asked about again. It stays after a Cancel, and closing it then needs no question.
  private func closeLastPane() {
    guard pendingGuard == nil else { return }

    guard unsavedLabels.isEmpty else {
      askAboutUnsavedThenCloseWindow()
      return
    }

    let labels = runningTabLabels

    guard !labels.isEmpty else {
      window?.close()
      return
    }

    askToCloseWindow(labels: labels)
  }

  private func askToCloseWindow(labels: [String]) {
    let request = CloseConfirmation(
      title: "Close this window?",
      detail: "Closing the window ends everything that is running in it.", labels: labels,
      confirmTitle: "Close Window", cancelTitle: "Cancel")

    ask(request) { [weak self] in
      self?.window?.close()
    }
  }

  /// Shows a question and runs `onConfirm` when the user agrees. Declining does nothing. A second
  /// question is dropped while the first is open.
  private func ask(_ request: CloseConfirmation, onConfirm: @escaping @MainActor () -> Void) {
    guard pendingGuard == nil else { return }

    pendingGuard = Task { @MainActor [weak self] in
      guard let self else { return }

      let confirmed = await confirmer(request, window)
      pendingGuard = nil

      if confirmed {
        onConfirm()
      }
    }
  }

  /// Opens a pane from a closed pane's description, in the same place with the same kind of applet.
  /// The pane gets a new ID, and the applet starts fresh. A description this build cannot restore
  /// opens as a placeholder, which keeps its bytes.
  ///
  /// The fit is checked before the applet is built. A pane that does not fit keeps its entry and
  /// builds nothing. Only the reopened pane's own entry leaves the ledger.
  private func reopenPane(_ closed: ClosedPane) -> Bool {
    guard paneArea.canInsert(at: closed.placement) else { return false }

    let restored = PaneRestoration.applet(for: closed.description, restorer: restoreApplet)
    let applet = restored.applet

    adopt(applet)

    let id: NodeID
    do {
      id = try paneArea.insert(applet, at: closed.placement)
    } catch {
      applet.close()
      return false
    }

    ledger.remove(stamp: closed.stamp)
    startPendingApplets()
    paneArea.focus(id)

    if restored.isPlaceholder {
      statusCenter.post(
        level: .warning,
        text:
          "The pane \u{201C}\(closed.title)\u{201D} could not be restored. It is kept as it was.")
    }

    return true
  }

  // MARK: Reopening

  /// One close the window can undo: a pane in the ledger, or a tab an applet holds.
  private enum Close {
    case pane(ClosedPane)
    case tab(pane: NodeID, applet: any Applet, stamp: UInt64)

    var stamp: UInt64 {
      switch self {
      case .pane(let closed): return closed.stamp
      case .tab(_, _, let stamp): return stamp
      }
    }
  }

  /// Every close in the window, newest first. The applets keep their own tab lists, so the window
  /// asks them each time and holds no copy.
  private func closes() -> [Close] {
    var all = ledger.entries.map(Close.pane)

    for pane in paneArea.tree.paneIDs {
      guard let applet = paneArea.applet(for: pane) else { continue }

      all += applet.closedTabStamps.map { Close.tab(pane: pane, applet: applet, stamp: $0) }
    }

    return all.sorted { $0.stamp > $1.stamp }
  }

  /// True when Reopen Closed has something to try.
  var hasReopenableClose: Bool {
    !ledger.entries.isEmpty
      || paneArea.applets.contains { !$0.closedTabStamps.isEmpty }
  }

  /// Reopens the newest close in the window, a tab or a pane. It walks the closes newest first and
  /// stops at the first that comes back. A close that fails keeps its entry and its place, and the
  /// walk goes on to the next older one. One message says what failed, why, what to do, and what
  /// reopened instead.
  func reopenClosed() {
    guard paneActionsEnabled else { return }

    var failures: [String] = []

    for close in closes() {
      switch close {
      case .tab(let pane, let applet, let stamp):
        switch applet.reopenTab(stamp: stamp) {
        case .reopened(let title):
          paneArea.focus(pane)
          postReopenFailures(failures, reopened: "tab \u{201C}\(title)\u{201D}")
          return

        case .missing:
          continue

        case .failed(let title, let reason):
          let ended = reason.hasSuffix(".") ? reason : reason + "."
          failures.append("The tab \u{201C}\(title)\u{201D} could not be reopened: \(ended)")
        }

      case .pane(let closed):
        if reopenPane(closed) {
          postReopenFailures(failures, reopened: "pane \u{201C}\(closed.title)\u{201D}")
          return
        }

        failures.append(
          "The pane \u{201C}\(closed.title)\u{201D} does not fit in the window. "
            + "Make the window larger, then try again.")
      }
    }

    if failures.isEmpty {
      statusCenter.post(
        level: .info, text: "There is no closed tab or pane to reopen.")
    } else {
      postReopenFailures(failures, reopened: nil)
    }
  }

  private func postReopenFailures(_ failures: [String], reopened: String?) {
    guard !failures.isEmpty else { return }

    let outcome = reopened.map { "Reopened the \($0) instead." } ?? "Nothing was reopened."

    statusCenter.post(
      level: .warning, text: (failures + [outcome]).joined(separator: " "))
  }

  // MARK: Saved layout

  /// The window as a saved layout holds it. The undo stack is not part of it. The IDs of closed
  /// panes stay below the layout's high-water mark.
  ///
  /// A pane with no applet cannot happen while the window is consistent. If it did, the pane is
  /// left out, so the rest of the layout still saves. A window with no pane left is not saved.
  func savedWindow() -> SavedWindow? {
    guard let window else { return nil }

    var described: [NodeID: AppletDescription] = [:]

    guard let tree = savedNode(paneArea.tree.root, described: &described) else { return nil }

    savedDescriptions = described

    return SavedWindow(
      frame: window.frame, screen: window.screen?.frame, tree: tree,
      focusedPane: paneArea.focusedPane, highWaterMark: paneArea.tree.highWaterMark)
  }

  private func savedNode(_ node: Node, described: inout [NodeID: AppletDescription]) -> SavedNode? {
    switch node {
    case .pane(let pane):
      guard let applet = paneArea.applet(for: pane.id) else { return nil }

      let description = applet.describe().withoutUndoState
      described[pane.id] = description
      return .pane(id: pane.id, applet: description)

    case .split(let split):
      var children: [SavedChild] = []

      for child in split.children {
        if let saved = savedNode(child.node, described: &described) {
          children.append(SavedChild(node: saved, weight: child.weight))
        }
      }

      switch children.count {
      case 0: return nil
      case 1: return children[0].node
      default: return .split(id: split.id, axis: split.axis, children: children)
      }
    }
  }

  /// A title or segment change that leaves the saved description the same, such as a spinner in a
  /// title, is not a layout change. Only a description that differs from the last saved one is.
  /// The undo-only part never counts, since a layout file does not hold it.
  private func notifyLayoutIfDescriptionChanged(_ applet: any Applet) {
    guard let pane = paneArea.paneID(for: applet),
      let saved = savedDescriptions[pane], saved == applet.describe().withoutUndoState
    else {
      onLayoutChange?()
      return
    }
  }

  // MARK: Window

  /// The red button and Cmd-Q on the last window end here. When a pane holds unsaved work, or
  /// something is running in the window, the sheet asks and the close waits for the answer.
  public func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard unsavedLabels.isEmpty else {
      askAboutUnsavedThenCloseWindow()
      return false
    }

    let labels = runningTabLabels

    guard !labels.isEmpty else { return true }

    askToCloseWindow(labels: labels)
    return false
  }

  public func windowDidMove(_ notification: Notification) {
    onLayoutChange?()
  }

  public func windowDidResize(_ notification: Notification) {
    onLayoutChange?()
  }

  /// Closing the window ends every applet in it and lets go of the undo stack. Undoing a closed
  /// window is out of scope.
  public func windowWillClose(_ notification: Notification) {
    guard !panesClosed else { return }

    panesClosed = true

    for applet in paneArea.applets { applet.close() }

    ledger.removeAll()

    let handler = onClose
    onClose = nil
    handler?(self)
  }

  // MARK: Applet host

  public func issueCloseStamp() -> UInt64 {
    lastCloseStamp += 1
    return lastCloseStamp
  }

  /// A pane whose applet ended closes, and goes on the reopen list like any other close.
  public func appletDidExit(_ applet: any Applet) {
    if let pane = paneArea.paneID(for: applet) {
      exitedApplets.insert(ObjectIdentifier(applet))
      closePane(pane, appletEnded: true)
    }
  }

  /// Only the focused pane's applet shows in the bar, so a change in any other applet is not
  /// the bar's business until that pane takes focus.
  public func appletDidChange(_ applet: any Applet) {
    notifyLayoutIfDescriptionChanged(applet)

    guard applet === paneArea.applet(for: paneArea.focusedPane) else { return }

    refreshStatusBar()
  }

  /// Records the tab as recent when it is the focused pane's. A tab that changes in the
  /// background never counts as recent. Then the palette lists again, a moment later.
  public func appletTabsDidChange(_ applet: any Applet) {
    if applet === paneArea.applet(for: paneArea.focusedPane) {
      recordFocusedTab()
    }

    schedulePaletteRefresh()
  }

  public func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool {
    let question = CloseConfirmation(
      title: request.title, detail: "Pane \u{201C}\(applet.title)\u{201D}. \(request.detail)",
      confirmTitle: request.confirmTitle, cancelTitle: request.cancelTitle)

    return await confirmer(question, window)
  }
}
