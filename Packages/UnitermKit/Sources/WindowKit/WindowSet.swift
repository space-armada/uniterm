import AppKit
import AppletKit
import LayoutKit
import StatusKit

/// Where a new window lands when it cascades from an existing one.
enum WindowCascade {
  /// How far each cascaded window moves right and down.
  static let step: CGFloat = 28

  /// The top-left corner for a window of `size` that follows `anchor`. The window moves one step
  /// right and down. When that would push it past the right or bottom edge of `visible`, it wraps
  /// to the top-left corner of `visible`. Without a visible frame there is no edge to hit.
  static func topLeft(after anchor: NSRect, size: NSSize, in visible: NSRect?) -> NSPoint {
    let x = anchor.minX + step
    let y = anchor.maxY - step

    guard let visible else { return NSPoint(x: x, y: y) }

    if x + size.width <= visible.maxX, y - size.height >= visible.minY {
      return NSPoint(x: x, y: y)
    }

    return NSPoint(x: visible.minX, y: visible.maxY)
  }
}

/// The part of a window that bringing it forward touches. A test replaces the window with a fake
/// that reports itself minimized.
@MainActor
protocol ForwardableWindow {
  var isMiniaturized: Bool { get }

  func deminiaturize(_ sender: Any?)
  func makeKeyAndOrderFront(_ sender: Any?)
}

extension NSWindow: ForwardableWindow {}

public enum WindowSetError: Error, Equatable {
  case cannotRestore
  case cannotRoute
}

/// The open main windows, in the order they were opened.
///
/// Each window has its own controller, so its own pane tree, status bar, and status center. The
/// set creates a window, cascades it from the active one, and lets go of its controller when the
/// window closes. Closing the last window leaves the set empty and ends nothing.
@MainActor
public final class WindowSet {
  /// Makes the controller for one window. The identifier names the window to accessibility. The
  /// directory is where the window's first pane starts, taken from the active window's focused
  /// pane. It is nil when there is no active window or its pane reports none.
  public typealias Factory =
    @MainActor (_ identifier: String, _ directory: String?) throws -> MainWindowController

  /// The open windows' controllers, oldest first. A window leaves the list the moment it closes.
  public private(set) var controllers: [MainWindowController] = []

  /// Makes the controller for a window of a saved layout. The controller restores its panes from
  /// the saved window.
  public typealias RestoringFactory =
    @MainActor (_ identifier: String, _ restored: RestoredWindow) throws -> MainWindowController

  /// Makes the controller for a window that holds one routed pane. The pane is the window's only
  /// pane. No shell starts beside it, and no directory comes from another window.
  public typealias RoutedFactory =
    @MainActor (_ identifier: String, _ applet: any Applet) throws -> MainWindowController

  private let makeController: Factory
  private let makeRestoredController: RestoringFactory?
  private let makeRoutedController: RoutedFactory?
  private let visibleFrame: @MainActor (NSWindow) -> NSRect?
  private let screens: @MainActor () -> [ScreenArea]
  private var serial = 0
  private var windowIDs: WindowIDSource

  /// Messages posted while no window was open, oldest first.
  private var held: [(level: StatusLevel, text: String)] = []

  /// What the held list gave up to stay within its limit, and the most severe level among it.
  private var heldDropped = 0
  private var heldDroppedLevel = StatusLevel.info

  /// Controllers whose windows have closed. The window that is closing still calls into its
  /// controller, so the set keeps it alive until the next turn of the main actor.
  private var closing: [MainWindowController] = []

  private let confirmer: CloseConfirmer
  private let unsavedConfirmer: UnsavedConfirmer

  /// Runs when a window opens or closes, and when anything a saved layout holds changes in one.
  public var onLayoutChange: (() -> Void)?

  /// The states that belong to the window rather than to a pane, as the instance sees them.
  /// Every window shows them, including one that opens later. They live here, above any one
  /// window, and the set never writes them to the layout file.
  public private(set) var windowStates = WindowStates()

  /// Marks `kind` as holding in every window of the instance, and in each window that opens
  /// later.
  public func setWindowState(_ kind: WindowStateKind, text: String) {
    windowStates.set(kind, text: text)
    publishWindowStates()
  }

  /// Ends `kind` in every window.
  public func clearWindowState(_ kind: WindowStateKind) {
    windowStates.clear(kind)
    publishWindowStates()
  }

  private func publishWindowStates() {
    for controller in controllers {
      controller.windowStates = windowStates
    }
  }

  /// The visible frame decides where a cascade wraps. It defaults to the window's screen. The
  /// confirmer asks before a quit that would end something running.
  ///
  /// The screens place a restored window. They default to the screens attached now, the main one
  /// first. A restored window comes from `makeRestoredController`, and without one a saved window
  /// cannot be opened.
  public init(
    visibleFrame: @escaping @MainActor (NSWindow) -> NSRect? = { window in
      (window.screen ?? NSScreen.main)?.visibleFrame
    },
    screens: @escaping @MainActor () -> [ScreenArea] = WindowSet.attachedScreens,
    confirmer: @escaping CloseConfirmer = CloseDialog.present,
    unsavedConfirmer: @escaping UnsavedConfirmer = UnsavedDialog.present,
    makeRestoredController: RestoringFactory? = nil,
    makeRoutedController: RoutedFactory? = nil,
    windowIDs: WindowIDSource = WindowIDSource(),
    makeController: @escaping Factory
  ) {
    self.windowIDs = windowIDs
    self.visibleFrame = visibleFrame
    self.screens = screens
    self.confirmer = confirmer
    self.unsavedConfirmer = unsavedConfirmer
    self.makeRestoredController = makeRestoredController
    self.makeRoutedController = makeRoutedController
    self.makeController = makeController
  }

  /// The screens attached now. The first is the main screen.
  public static let attachedScreens: @MainActor () -> [ScreenArea] = {
    NSScreen.screens.map { ScreenArea(frame: $0.frame, visibleFrame: $0.visibleFrame) }
  }

  /// Everything running in any window. Quitting ends all of it.
  public var runningTabLabels: [String] {
    controllers.flatMap { $0.runningTabLabels }
  }

  /// Asks before a quit that would lose unsaved work or end something running. Unsaved work comes
  /// first, and Save saves each pane in window order. Returns true when the app may quit.
  public func shouldQuit() async -> Bool {
    let unsaved = controllers.flatMap(\.unsavedLabels)

    if !unsaved.isEmpty {
      let question = UnsavedQuestion(
        title: "Save changes before quitting?",
        detail: "Your changes are lost if you don\u{2019}t save them.", labels: unsaved)

      switch await unsavedConfirmer(question, activeController?.window) {
      case .cancel:
        return false

      case .discard:
        break

      case .save:
        for controller in controllers {
          for applet in controller.paneArea.applets where applet.unsavedWork != nil {
            guard await applet.saveUnsavedWork() else { return false }
          }
        }
      }
    }

    let labels = runningTabLabels

    guard !labels.isEmpty else { return true }

    let request = CloseConfirmation(
      title: "Quit uniterm?",
      detail: "Quitting ends everything that is running in every window.", labels: labels,
      confirmTitle: "Quit", cancelTitle: "Cancel")

    return await confirmer(request, activeController?.window)
  }

  /// The identifier of the nth window ever opened. The first keeps the plain name. A number is
  /// never reused, so two open windows never share an identifier.
  static func identifier(forSerial serial: Int) -> String {
    serial == 1 ? "main-window" : "main-window-\(serial)"
  }

  /// The window that menu actions and new windows follow: the key window, else the main one, else
  /// the one opened last.
  public var activeController: MainWindowController? {
    controllers.last { $0.window?.isKeyWindow == true }
      ?? controllers.last { $0.window?.isMainWindow == true }
      ?? controllers.last
  }

  /// The open windows that have been key, least recently key first. It survives the app going to
  /// the background, since no window is key then.
  private var keyOrder: [MainWindowController] = []

  /// The controller whose window was key most recently, among the windows still open.
  public var mostRecentlyKey: MainWindowController? { keyOrder.last }

  /// The controller a Launch Services open anchors to: the window that was key last, else the
  /// newest window.
  public var launchAnchorController: MainWindowController? {
    mostRecentlyKey ?? controllers.last
  }

  /// Records that a window became key.
  func noteKey(_ controller: MainWindowController) {
    guard controllers.contains(where: { $0 === controller }) else { return }

    keyOrder.removeAll { $0 === controller }
    keyOrder.append(controller)
  }

  /// The focused pane of the window that was key last. Nil when no window is open.
  public func launchAnchor() -> RouteAnchor? {
    guard let controller = launchAnchorController else { return nil }

    return RouteAnchor(controller: controller, pane: controller.focusedPane)
  }

  /// Brings a window forward, unminimized, and activates the app.
  public func bringForward(_ controller: MainWindowController) {
    guard let window = controller.window else { return }

    Self.bringForward(window)
    NSApp.activate()
  }

  /// Restores a minimized window, then makes it key and frontmost.
  static func bringForward(_ window: some ForwardableWindow) {
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }

    window.makeKeyAndOrderFront(nil)
  }

  /// Opens a window, shows it, and returns its controller. It cascades from the active window, and
  /// the first window is centered. Its first pane starts in the directory the active window's
  /// focused pane reports. When the factory throws, nothing opens and no number is used.
  @discardableResult
  public func open() throws -> MainWindowController {
    let anchor = activeController?.window
    let directory = activeController?.focusedDirectory

    let number = serial + 1
    let controller = try makeController(Self.identifier(forSerial: number), directory)
    serial = number

    register(controller)

    if let anchor, let window = controller.window {
      let corner = WindowCascade.topLeft(
        after: anchor.frame, size: window.frame.size, in: visibleFrame(anchor))
      window.setFrameTopLeftPoint(corner)
    }

    show(controller)
    return controller
  }

  /// Opens a window whose only pane is `applet`, and returns its controller. It cascades from the
  /// active window like any new window, and it takes no directory from it. When the factory
  /// throws, nothing opens, no number is used, and the applet stays the caller's to close.
  @discardableResult
  public func open(routing applet: any Applet) throws -> MainWindowController {
    guard let makeRoutedController else {
      throw WindowSetError.cannotRoute
    }

    let anchor = activeController?.window

    let number = serial + 1
    let controller = try makeRoutedController(Self.identifier(forSerial: number), applet)
    serial = number

    register(controller)

    if let anchor, let window = controller.window {
      let corner = WindowCascade.topLeft(
        after: anchor.frame, size: window.frame.size, in: visibleFrame(anchor))
      window.setFrameTopLeftPoint(corner)
    }

    show(controller)
    return controller
  }

  /// Opens a window of a saved layout where it was, moved onto a screen that exists now. When the
  /// factory throws, nothing opens and no number is used.
  @discardableResult
  public func open(restoring restored: RestoredWindow) throws -> MainWindowController {
    guard let makeRestoredController else {
      throw WindowSetError.cannotRestore
    }

    let number = serial + 1
    let controller = try makeRestoredController(Self.identifier(forSerial: number), restored)
    serial = number

    register(controller)

    if let window = controller.window {
      let minimum = window.frameRect(
        forContentRect: NSRect(origin: .zero, size: window.contentMinSize)
      ).size

      let frame = FrameClamp.clamp(
        restored.saved.frame, savedScreen: restored.saved.screen, screens: screens(),
        minimumSize: minimum)

      window.setFrame(frame, display: false)
      controller.refreshMinimumSize()
    }

    show(controller)
    return controller
  }

  /// The open window a script's ID names. An ID from another launch, or of a window that closed,
  /// names nothing.
  func controller(forScriptWindow id: UInt64) -> MainWindowController? {
    controllers.first { $0.scriptWindowID == id }
  }

  private func register(_ controller: MainWindowController) {
    controller.scriptWindowID = windowIDs.next()
    controller.onClose = { [weak self] controller in
      self?.windowDidClose(controller)
    }
    controller.onLayoutChange = { [weak self] in
      self?.onLayoutChange?()
    }
    controller.onBecomeKey = { [weak self] controller in
      self?.noteKey(controller)
    }
    controller.visibleFrameProvider = visibleFrame
    controller.windowStates = windowStates
    controller.refreshMinimumSize()
    controllers.append(controller)
  }

  private func show(_ controller: MainWindowController) {
    if heldDropped > 0 {
      let noun = heldDropped == 1 ? "message was" : "messages were"
      controller.statusCenter.post(
        level: heldDroppedLevel, text: "\(heldDropped) \(noun) dropped while no window was open.")
      heldDropped = 0
      heldDroppedLevel = .info
    }

    for message in held {
      controller.statusCenter.post(level: message.level, text: message.text)
    }
    held.removeAll()

    controller.showWindow(nil)
    onLayoutChange?()
  }

  /// The layout as a file holds it. Windows are listed oldest first.
  func savedLayout() -> SavedLayout {
    SavedLayout(windows: controllers.compactMap { $0.savedWindow() })
  }

  /// Opens a window when no main window is open, and says whether it did. A Dock click calls it.
  /// Only the set's own windows count, so the Settings window never stands in for a main one.
  public func openIfNone() throws -> Bool {
    guard controllers.isEmpty else { return false }

    try open()
    return true
  }

  /// Posts to the active window. With no window open, the message waits and goes to the next
  /// window that opens. The wait is bounded. Past the limit, the oldest info or warning goes
  /// first, and an error goes only when every held message is one. What goes is counted, and the
  /// next window shows one message that says so, at the most severe level lost.
  ///
  /// The message carries the host's identity. A caller cannot name another source.
  public func post(level: StatusLevel, text: String) {
    guard let controller = activeController else {
      if held.count >= Self.heldLimit {
        let index = held.firstIndex { $0.level != .error } ?? 0
        heldDroppedLevel = max(heldDroppedLevel, held[index].level)
        heldDropped += 1
        held.remove(at: index)
      }

      held.append(
        (level, StatusText.bounded(text, maximumBytes: StatusPolicy.standard.maximumTextBytes)))
      return
    }

    controller.statusCenter.post(level: level, text: text)
  }

  /// The most messages the set holds while no window is open. The oldest go first.
  static let heldLimit = 32

  /// Issues a non-pane producer an identity that no other producer shares. The identity belongs to
  /// the active window's center, so it is not valid in another window.
  public func issueProducer(kind: StatusProducerKind, name: String) -> StatusProducer? {
    activeController?.statusCenter.issueProducer(kind: kind, name: name)
  }

  private func windowDidClose(_ controller: MainWindowController) {
    controllers.removeAll { $0 === controller }

    keyOrder.removeAll { $0 === controller }
    closing.append(controller)
    onLayoutChange?()

    Task { @MainActor [weak self] in
      self?.closing.removeAll { $0 === controller }
    }
  }
}
