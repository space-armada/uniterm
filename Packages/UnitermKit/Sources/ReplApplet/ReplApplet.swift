import AppKit
import AppletKit
import ScriptHost
import ScriptWire
import StatusKit
import TerminalSurface
import Theme

/// What the REPL needs from the app. The closures read the app's state when they run, so a REPL
/// that a window restores at launch asks for a channel only once scripting is up.
public struct ReplServices {
  /// The `uniterm` command inside the app bundle, which runs in its REPL mode. Nil when the
  /// bundle has none.
  public var helper: @MainActor () -> URL?

  /// Issues a token and a channel for one helper, with the history it recalls. It refuses when
  /// scripting is not running, or when the REPL helpers already hold more than their budget.
  public var openChannel: @MainActor ([String]) -> ScriptReplOpening

  public init(
    helper: @escaping @MainActor () -> URL?,
    openChannel: @escaping @MainActor ([String]) -> ScriptReplOpening
  ) {
    self.helper = helper
    self.openChannel = openChannel
  }
}

/// Lays out the terminal above the strip that shows after the helper has gone.
///
/// It also sees Ctrl-C before the terminal does. The terminal still gets the key and sends it
/// through the pty. The container tells the applet too, so the app can ask the helper to stop over
/// its control channel, which does not depend on the pty's signal reaching the helper.
@MainActor
private final class ReplContainerView: NSView {
  var onResize: (() -> Void)?
  var onInterruptKey: (() -> Void)?

  override var isFlipped: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if ReplApplet.isInterruptKey(event), isFirstResponderInside {
      onInterruptKey?()
    }

    return super.performKeyEquivalent(with: event)
  }

  /// A key equivalent reaches every view of the window, so only a Ctrl-C typed into this pane
  /// counts as its interrupt.
  private var isFirstResponderInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }

    return responder.isDescendant(of: self)
  }

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    super.resizeSubviews(withOldSize: oldSize)
    onResize?()
  }
}

/// A Janet REPL in a pane.
///
/// The applet hosts a terminal session whose child is the REPL helper. The helper edits lines
/// with Janet's own line editor and reaches the app over a control channel that its single-use
/// token binds to this pane. The app keeps its own copy of the history, so saving a layout never
/// waits on the helper.
///
/// The applet owns its input, so a script's send to it is refused. It reports no current
/// directory. Nothing flows into it from the app or from another pane.
///
/// When the helper dies, the pane stays open with a message and a Restart button. Only the user
/// can restart it, and the history carries over. A closed pane ends the helper.
@MainActor
public final class ReplApplet: Applet, InputOwning {
  private static let title = "REPL"

  /// Why the helper is not running.
  private enum Phase: Equatable {
    case idle
    case running
    case ended(String)
  }

  public let typeID = ReplDescription.typeID
  public let view: NSView

  public weak var host: (any AppletHost)?

  public private(set) var segments: [AppletSegment] = []

  private let container = ReplContainerView()
  private let endedView = ReplEndedView()
  private let engine: any TerminalEngine
  private let services: ReplServices
  private let home: String
  private let tabID = AppletTabID.make()
  private var history: ReplHistory
  private var phase = Phase.idle
  private var session: (any TerminalSession)?
  private var channel: ScriptReplChannel?
  private var evaluating = false
  private var started = false

  public init(
    engine: any TerminalEngine, services: ReplServices, history: ReplHistory = ReplHistory(),
    home: String = NSHomeDirectory()
  ) {
    self.engine = engine
    self.services = services
    self.history = history
    self.home = home
    self.view = container

    container.setAccessibilityIdentifier("repl-applet")
    container.addSubview(endedView)
    endedView.isHidden = true
    endedView.onRestart = { [weak self] in self?.restart() }
    container.onResize = { [weak self] in self?.layoutContents() }
    container.onInterruptKey = { [weak self] in self?.interruptKeyPressed() }
  }

  /// Restores an applet from a description. It starts a fresh helper when the pane starts. The
  /// saved history is only recalled, and nothing in it runs.
  public convenience init(
    engine: any TerminalEngine, services: ReplServices, restoring description: AppletDescription,
    home: String = NSHomeDirectory()
  ) throws {
    let decoded = try ReplDescription.decode(description)

    self.init(
      engine: engine, services: services, history: ReplHistory(restoring: decoded.history),
      home: home)
  }

  // MARK: Applet

  public var title: String { Self.title }

  public var publishedTabs: AppletTabList {
    AppletTabList(
      first: AppletTab(id: tabID, title: Self.title, details: []), rest: [], selected: tabID)
  }

  /// True only while the helper reports a form evaluating. A REPL at its prompt holds nothing a
  /// close would lose, whatever the pty's own idea of a running program.
  public var isRunningSomething: Bool {
    phase == .running && evaluating
  }

  /// The lines the app has kept, oldest first.
  public var historyLines: [String] { history.lines }

  /// The message shown after the helper has gone, or nil while it runs.
  public var endedMessage: String? {
    if case .ended(let message) = phase { return message }

    return nil
  }

  public func start(origin: StartOrigin) {
    guard !started else { return }

    started = true

    launchHelper()
  }

  public func close() {
    stopHelper()
  }

  public func detach() {}

  public func reattach() {}

  public func focus() {
    if let session, session.view.superview != nil {
      session.view.window?.makeFirstResponder(session.view)
    } else if !endedView.isHidden {
      endedView.window?.makeFirstResponder(endedView.restartButton)
    }
  }

  public func apply(_ palette: ThemePalette) {
    endedView.apply(palette)
  }

  public func describe() -> AppletDescription {
    do {
      return try ReplDescription(history: history.lines).appletDescription()
    } catch {
      preconditionFailure("a REPL description always encodes: \(error)")
    }
  }

  // MARK: Helper

  /// True while the pane shows that its helper has gone.
  var isEnded: Bool { endedMessage != nil }

  /// Starts a fresh helper after the old one has gone. Only the user's action calls it. It does
  /// nothing while a helper runs.
  public func restart() {
    guard isEnded else { return }

    stopHelper()
    launchHelper()
    focus()
  }

  /// The words and environment of a helper launch. The token travels in the environment, the
  /// address as an argument, and the working directory is the home folder.
  public static func launch(helper: URL, channel: ScriptReplLaunch, home: String)
    -> TerminalLaunch
  {
    var words = [helper.path, "repl", "--socket", channel.address]

    #if DEBUG
      if ProcessInfo.processInfo.environment["UNITERM_REPL_TRACE_SIGINT"] == "1" {
        words.append("--trace-sigint")
      }
    #endif

    return TerminalLaunch.program(
      words, workingDirectory: home,
      environment: [ScriptProtocol.replTokenVariable: channel.token])
  }

  private func launchHelper() {
    guard let helper = services.helper() else {
      showEnded("The REPL helper is missing from this copy of uniterm. Reinstall uniterm.")

      return
    }

    let channel: ScriptReplChannel

    switch services.openChannel(history.lines) {
    case .channel(let opened):
      channel = opened

    case .refused(.scriptingOff):
      showEnded("Scripting is not running, so the REPL cannot start. Relaunch uniterm.")

      return

    case .refused(.overBudget(let used, let budget, let announce)):
      refuseForBudget(used: used, budget: budget, announce: announce)

      return
    }

    let launch = Self.launch(helper: helper, channel: channel.launch, home: home)

    let session: any TerminalSession

    do {
      session = try engine.makeSession(launch: launch)
    } catch {
      channel.end()
      showEnded("The REPL could not start: \(error.localizedDescription)")

      return
    }

    self.channel = channel
    self.session = session

    channel.onEvent = { [weak self] event in self?.handle(event) }
    session.onEvent = { [weak self] event in self?.handle(event) }
    session.view.isHidden = false

    container.addSubview(session.view, positioned: .below, relativeTo: endedView)

    phase = .running
    evaluating = false
    endedView.isHidden = true

    session.setVisible(true)
    layoutContents()
    updateSegments()
    host?.appletDidChange(self)
  }

  /// Ends the helper and lets the session go. The channel closes the connection first, which makes
  /// the helper exit, and the app kills a helper still there after a short wait.
  private func stopHelper() {
    channel?.end()
    channel = nil

    session?.onEvent = nil
    session?.view.removeFromSuperview()
    session?.close()
    session = nil

    evaluating = false
  }

  /// A Ctrl-C in the pane. The first while a form runs asks the helper to stop it. A second, after a
  /// short gap and with the form still running, ends a helper that the first request never reached.
  func interruptKeyPressed() {
    guard phase == .running, let channel else { return }

    channel.interruptPressed()
  }

  /// True for Ctrl-C alone, as a fresh press and not a held key. Command, Option, and Shift make
  /// other keys.
  static func isInterruptKey(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, !event.isARepeat else { return false }

    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    return modifiers.contains(.control) && modifiers.isDisjoint(with: [.command, .option, .shift])
      && event.charactersIgnoringModifiers == "c"
  }

  private func refuseForBudget(used: Int, budget: Int, announce: Bool) {
    showEnded(
      "Other REPLs hold \(Self.describe(bytes: used)) of the \(Self.describe(bytes: budget)) that "
        + "REPLs may use together, so this REPL did not start. Close a REPL, then press Restart "
        + "to try again.")

    guard announce else { return }

    host?.applet(
      self, post: .warning,
      text: "A REPL did not start. REPLs hold \(Self.describe(bytes: used)) of their "
        + "\(Self.describe(bytes: budget)) budget.")
  }

  /// Sizes the way a person reads them: whole GiB or MiB.
  static func describe(bytes: Int) -> String {
    let gibibyte = 1 << 30

    if bytes >= gibibyte {
      let tenths = bytes * 10 / gibibyte

      return tenths % 10 == 0 ? "\(tenths / 10) GiB" : "\(tenths / 10).\(tenths % 10) GiB"
    }

    return "\(bytes >> 20) MiB"
  }

  /// What the pane says when the app or the helper ended the helper for a reason of its own.
  static func message(for end: ScriptReplEnd) -> String {
    switch end {
    case .memoryLimit:
      return
        "The REPL used more than \(describe(bytes: ScriptProtocol.helperMemoryCap)) of memory, "
        + "so uniterm ended it. Press Restart for a fresh one. Your history is kept."

    case .overFootprint(let bytes):
      return "The REPL's process grew to \(describe(bytes: bytes)), past its limit, so uniterm "
        + "ended it. Press Restart for a fresh one. Your history is kept."

    case .unresponsive:
      return "The REPL stopped answering uniterm, so uniterm ended it. Press Restart for a fresh "
        + "one. Your history is kept."

    case .stoppedByUser:
      return "You pressed Ctrl-C twice while the REPL ignored the first, so uniterm ended it. "
        + "Press Restart for a fresh one. Your history is kept."
    }
  }

  private func handle(_ event: ScriptReplEvent) {
    switch event {
    case .attached:
      break

    case .terminated(let end):
      helperEnded(Self.message(for: end))

    case .line(let text):
      history.append(text)
      host?.appletDidChange(self)

    case .evaluating(let running):
      evaluating = running

    case .ended:
      helperEnded("The REPL's connection to uniterm closed.")
    }
  }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case .exited:
      helperEnded("The REPL ended.")

    case .clipboardRequest(let request):
      confirm(request)

    case .titleChanged, .workingDirectoryChanged, .commandFinished, .notification, .bell:
      break
    }
  }

  /// The helper is gone. The pane stays, keeps its history, and offers a restart. The helper's
  /// last output stays on screen above the message.
  private func helperEnded(_ message: String) {
    guard phase == .running else { return }

    channel?.end()
    channel = nil
    evaluating = false

    showEnded(message)
  }

  private func showEnded(_ message: String) {
    phase = .ended(message)
    endedView.message = message
    endedView.isHidden = false

    layoutContents()
    updateSegments()
    host?.appletDidChange(self)
  }

  private func updateSegments() {
    if isEnded {
      segments = [
        AppletSegment(symbolName: "exclamationmark.triangle", text: "Ended", style: .warning)
      ]
    } else {
      segments = []
    }
  }

  private func layoutContents() {
    let bounds = container.bounds
    let strip = endedView.isHidden ? 0 : ReplEndedView.height

    endedView.frame = NSRect(
      x: 0, y: max(0, bounds.height - strip), width: bounds.width, height: strip)
    session?.view.frame = NSRect(
      x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - strip))
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
        detail: "A program in this pane asked for the clipboard with an escape sequence.",
        confirmTitle: "Allow", cancelTitle: "Deny")

    case .unsafePaste:
      confirmation = AppletConfirmation(
        title: "Paste text that could run code?",
        detail: "The text holds control characters or a newline. It would run as you paste it.",
        confirmTitle: "Paste", cancelTitle: "Cancel")
    }

    Task { @MainActor [weak self] in
      guard let self else {
        request.resolve(allow: false)

        return
      }

      request.resolve(allow: await host.applet(self, confirm: confirmation))
    }
  }
}
