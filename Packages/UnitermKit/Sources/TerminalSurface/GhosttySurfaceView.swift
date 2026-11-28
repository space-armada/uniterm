import AppKit
internal import GhosttyKit
import OSLog
import UniformTypeIdentifiers

/// One libghostty surface hosted in an NSView.
///
/// libghostty spawns the child process, owns the pty, and draws into this view. The view feeds it
/// keys, mouse events, and sizes. uniterm owns every key binding, so the view treats command-key
/// events as menu events and never as terminal bindings.
@MainActor
final class GhosttySurfaceView: NSView, TerminalSession, TerminalMenuActions, NSMenuItemValidation {
  private static let maximumAccessibilityCharacters = 65_536

  private var surface: ghostty_surface_t?
  private var markedText = NSMutableAttributedString()
  private var keyTextAccumulator: [String]?
  private var cellSize = CGSize(width: 8, height: 16)
  private var cursor = NSCursor.arrow
  private var focused = false
  private var visible = true
  private var windowObservers: [any NSObjectProtocol] = []

  /// True only while the view's own paste call runs. libghostty asks for the clipboard
  /// synchronously inside that call, which is how a read tells the user's paste apart from a read
  /// a program asked for.
  private var pasting = false

  /// How many times libghostty has applied a new config to this surface.
  private(set) var configChangeCount = 0

  /// A counter that increments each time a session starts in this view. It identifies the session
  /// instance for authority checks.
  private var sessionGeneration: UInt64 = 0

  private(set) var clipboardPolicy: TerminalClipboardPolicy

  /// The clipboard that copies, pastes, and programs' clipboard requests use. The app passes the
  /// system's. Tests pass a private one, so another program's copy cannot change what they see.
  private let pasteboard: NSPasteboard

  /// The kinds of clipboard request the user allowed for the rest of the session, under the
  /// current policy. A new policy clears them.
  private var sessionAllowed: Set<TerminalClipboardRequest.Kind> = []

  /// The kinds of program clipboard request with a prompt waiting. While one waits, a later request
  /// of that kind is denied at once and its text dropped, so a program that loops cannot queue a
  /// prompt per escape sequence or hold its data in memory.
  private var asking: Set<TerminalClipboardRequest.Kind> = []

  var onEvent: (@MainActor (TerminalEvent) -> Void)?
  private(set) var title = ""
  private(set) var workingDirectory: String?
  private(set) var hasExited = false

  /// `shellCommand` replaces the login shell with a command libghostty runs as is, quotes and all,
  /// and picks shell integration for. A program launch ignores it.
  init(
    app: ghostty_app_t, launch: TerminalLaunch, clipboardPolicy: TerminalClipboardPolicy,
    pasteboard: NSPasteboard, shellCommand: String? = nil
  ) throws {
    self.clipboardPolicy = clipboardPolicy
    self.pasteboard = pasteboard
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    setAccessibilityIdentifier("terminal")

    var config = ghostty_surface_config_new()
    let retained = Unmanaged.passRetained(self)
    config.userdata = retained.toOpaque()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
    config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
    config.font_size = 0
    config.command = nil
    config.wait_after_command = false

    var allocations: [UnsafeMutablePointer<CChar>] = []
    defer {
      for pointer in allocations {
        free(pointer)
      }
    }

    func copy(_ string: String) -> UnsafeMutablePointer<CChar> {
      let pointer = strdup(string)!
      allocations.append(pointer)
      return pointer
    }

    if let directory = launch.workingDirectory {
      config.working_directory = UnsafePointer(copy(directory))
    }

    // libghostty runs a command through `/bin/sh -c` and has no call for an argument list. Every
    // word is quoted, so the shell sees the program and its arguments exactly as uniterm has them.
    //
    // libghostty would also keep the pane open after the program ends, until a key is pressed.
    // uniterm takes the child-exited action instead and reports the exit at once.
    if let program = launch.program {
      config.command = UnsafePointer(copy(ShellWords.quote(program)))
    } else if let shellCommand {
      config.command = UnsafePointer(copy(shellCommand))
    }

    var variables = launch.environment.sorted { $0.key < $1.key }.map {
      ghostty_env_var_s(key: UnsafePointer(copy($0.key)), value: UnsafePointer(copy($0.value)))
    }

    let created = variables.withUnsafeMutableBufferPointer { buffer -> ghostty_surface_t? in
      config.env_vars = buffer.baseAddress
      config.env_var_count = buffer.count
      return ghostty_surface_new(app, &config)
    }

    guard let created else {
      retained.release()
      throw TerminalEngineError.surfaceCreateFailed
    }

    surface = created
    sessionGeneration += 1
    updateTrackingAreas()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: Session

  var view: NSView { self }

  var gridSize: TerminalGridSize {
    guard let surface else { return TerminalGridSize(columns: 0, rows: 0) }

    let size = ghostty_surface_size(surface)
    return TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
  }

  var isRunningSomething: Bool {
    guard let surface else { return false }

    return ghostty_surface_needs_confirm_quit(surface)
  }

  /// While false, nothing reaches the child. Keys, paste, and composed text are dropped where they
  /// enter. A mouse event goes to libghostty only when the child has not asked to hear the mouse,
  /// so selection and scrollback still work and no report is written. A middle click, which pastes,
  /// is dropped. The focus report waits until input is on again.
  var acceptsInput = true {
    didSet {
      guard acceptsInput, !oldValue, focusReportHeld, let surface else { return }

      focusReportHeld = false
      ghostty_surface_set_focus(surface, focused)
    }
  }

  /// True when a focus change came while input was off, so the child has not heard it yet.
  private var focusReportHeld = false

  /// True when a mouse event may go to libghostty. A child that has asked to hear the mouse would
  /// get a report, which is input.
  private var mouseMayReach: Bool {
    guard let surface else { return false }

    return acceptsInput || !ghostty_surface_mouse_captured(surface)
  }

  func send(text: String) {
    guard acceptsInput, let surface else { return }

    let length = text.utf8.count
    text.withCString { ghostty_surface_text(surface, $0, UInt(length)) }
  }

  func perform(_ action: TerminalAction) {
    if action == .paste, !acceptsInput { return }

    let name: String

    switch action {
    case .copy: name = "copy_to_clipboard"
    case .paste: name = "paste_from_clipboard"
    case .selectAll: name = "select_all"
    case .increaseFontSize: name = "increase_font_size:1"
    case .decreaseFontSize: name = "decrease_font_size:1"
    case .resetFontSize: name = "reset_font_size"
    case .clearScreen: name = "clear_screen"
    }

    pasting = action == .paste
    defer { pasting = false }

    _ = bindingAction(name)
  }

  func resize(to size: CGSize) {
    setFrameSize(size)
  }

  func setFocused(_ focused: Bool) {
    guard let surface, self.focused != focused else { return }

    self.focused = focused

    if acceptsInput {
      ghostty_surface_set_focus(surface, focused)
    } else {
      focusReportHeld = true
    }
  }

  func setVisible(_ visible: Bool) {
    guard let surface, self.visible != visible else { return }

    self.visible = visible
    ghostty_surface_set_occlusion(surface, visible)
  }

  func setClipboardPolicy(_ policy: TerminalClipboardPolicy) {
    guard policy != clipboardPolicy else { return }

    clipboardPolicy = policy
    sessionAllowed = []
    asking = []
  }

  func scrollbackText() -> String? {
    guard let surface else { return nil }

    func corner(_ coord: ghostty_point_coord_e) -> ghostty_point_s {
      ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: coord, x: 0, y: 0)
    }

    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
      top_left: corner(GHOSTTY_POINT_COORD_TOP_LEFT),
      bottom_right: corner(GHOSTTY_POINT_COORD_BOTTOM_RIGHT), rectangle: false)
    guard ghostty_surface_read_text(surface, selection, &text) else { return nil }

    defer { ghostty_surface_free_text(surface, &text) }

    guard let pointer = text.text else { return nil }

    let bytes = UnsafeBufferPointer(
      start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
      count: Int(text.text_len))
    return ScrollbackText.prepared(String(decoding: bytes, as: UTF8.self))
  }

  func close() {
    guard let surface else { return }

    self.surface = nil
    onEvent = nil

    ghostty_surface_free(surface)
    Unmanaged.passUnretained(self).release()
  }

  private func bindingAction(_ action: String) -> Bool {
    guard let surface else { return false }

    return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
  }

  /// Whether libghostty would take this key as one of its own bindings. uniterm clears them all, so
  /// this stays false. It exists so a test can prove that.
  func isLibraryBinding(keyCode: UInt16, character: Character, mods: NSEvent.ModifierFlags) -> Bool
  {
    guard let surface else { return false }

    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    key.keycode = UInt32(keyCode)
    key.mods = Self.mods(mods)
    key.consumed_mods = GHOSTTY_MODS_NONE
    key.unshifted_codepoint = character.unicodeScalars.first?.value ?? 0
    key.composing = false
    key.text = nil

    return ghostty_surface_key_is_binding(surface, key, nil)
  }

  // MARK: Callbacks

  func receive(_ notice: SurfaceNotice) {
    switch notice {
    case .title(let value):
      title = value
      onEvent?(.titleChanged(value))

    case .workingDirectory(let value):
      workingDirectory = value
      onEvent?(.workingDirectoryChanged(value))

    case .processStarted(let pid):
      // The fork has returned by the time libghostty reports the PID, so the child's record
      // exists. A child that has already exited reports no start time, and gets no identity, so
      // nothing can bind to it.
      guard let started = TerminalProcessIdentity.startTime(of: pid_t(pid)) else { return }

      onEvent?(
        .processStarted(
          TerminalProcessIdentity(
            pid: pid_t(pid), started: started, sessionGeneration: sessionGeneration)))

    case .notification(let title, let body):
      onEvent?(.notification(title: title, body: body))

    case .commandFinished(let exitCode, let nanoseconds):
      onEvent?(.commandFinished(exitCode: exitCode, duration: .nanoseconds(nanoseconds)))

    case .bell:
      onEvent?(.bell)

    case .mouseShape(let shape):
      switch shape {
      case .standard: cursor = .arrow
      case .text: cursor = .iBeam
      case .pointer: cursor = .pointingHand
      case .crosshair: cursor = .crosshair
      case .notAllowed: cursor = .operationNotAllowed
      }

      window?.invalidateCursorRects(for: self)

    case .cellSize(let width, let height):
      let scale = window?.backingScaleFactor ?? 1
      cellSize = CGSize(width: Double(width) / scale, height: Double(height) / scale)

    case .configChanged:
      configChangeCount += 1

    case .linkHovered(let text):
      onEvent?(.linkHovered(text.isEmpty ? nil : text))

    case .linkOpenRequested(let text):
      onEvent?(.linkOpenRequested(text))

    case .remoteHost(let host):
      onEvent?(.remoteHostReported(host))

    case .exited:
      guard !hasExited else { return }

      hasExited = true
      onEvent?(.exited)
    }
  }

  /// Answers a read without asking. libghostty still asks the confirm callback before it sends a
  /// program any clipboard data, so serving the text here with `confirmed` false is safe.
  ///
  /// Two kinds of read never reach that callback, so they are settled here. A paste event during
  /// the user's own paste gets the clipboard's type names. A Kitty read for anything but plain text
  /// is denied, since a Kitty read for the type names alone is sent no prompt.
  func answerClipboardRead(
    _ request: ClipboardRead, state: OpaqueToken
  ) -> ghostty_clipboard_read_result_e {
    guard let surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

    if pasting && request.isListingOnly {
      complete(state, surface: surface, text: nil, available: pasteboardMIMETypes())
      return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    guard request.isPlainText else {
      ghostty_surface_deny_clipboard_request(surface, state.pointer)
      return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    // An empty clipboard tells a program only that there is no text. libghostty answers it
    // without a prompt, so a Kitty read learns that much.
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
      return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
    }

    complete(state, surface: surface, text: text, confirmed: false)
    return GHOSTTY_CLIPBOARD_READ_STARTED
  }

  /// A read of a controlled session that the user allowed for the session is answered at once.
  /// Every other read and unsafe paste asks. A read that arrives while another read's prompt waits
  /// is denied at once.
  func askAboutClipboard(
    kind: TerminalClipboardRequest.Kind, text: String, state: OpaqueToken
  ) {
    let asked = clipboardPolicy

    if kind == .read, asked.controlled, sessionAllowed.contains(.read) {
      answerClipboard(text: text, state: state, answer: .allowOnce, asked: asked)
      return
    }

    if kind == .read {
      guard onEvent != nil, asking.insert(.read).inserted else {
        denyClipboard(state: state)
        return
      }
    }

    let request = TerminalClipboardRequest(
      kind: kind, text: text, offersSession: kind == .read && asked.controlled
    ) { [weak self] answer in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if kind == .read { self?.doneAsking(.read, under: asked) }
          self?.answerClipboard(text: text, state: state, answer: answer, asked: asked)
        }
      }
    }

    guard let onEvent else {
      denyClipboard(state: state)
      return
    }

    onEvent(.clipboardRequest(request))
  }

  /// A prompt asked under an older policy was already cleared when the policy changed, so its
  /// answer must not clear a prompt asked since.
  private func doneAsking(
    _ kind: TerminalClipboardRequest.Kind, under asked: TerminalClipboardPolicy
  ) {
    if clipboardPolicy == asked { asking.remove(kind) }
  }

  /// True when an answer given under `asked` still holds: the session is open and its policy has
  /// not changed. Anything else makes the answer a denial.
  private func stillCurrent(_ asked: TerminalClipboardPolicy) -> Bool {
    surface != nil && !hasExited && clipboardPolicy == asked
  }

  /// libghostty keeps every request until the embedder answers it. A denial sends an OSC 52 read
  /// empty data, a Kitty request an `EPERM` status, and a paste nothing.
  func denyClipboard(state: OpaqueToken) {
    guard let surface else { return }

    ghostty_surface_deny_clipboard_request(surface, state.pointer)
  }

  private func answerClipboard(
    text: String, state: OpaqueToken, answer: TerminalClipboardAnswer,
    asked: TerminalClipboardPolicy
  ) {
    guard answer != .deny, stillCurrent(asked), let surface else {
      denyClipboard(state: state)
      return
    }

    if answer == .allowForSession, asked.controlled { sessionAllowed.insert(.read) }

    complete(state, surface: surface, text: text, confirmed: true)
  }

  /// Every pointer handed to libghostty is borrowed for this call only.
  private func complete(
    _ state: OpaqueToken, surface: ghostty_surface_t, text: String?, available: [String] = [],
    confirmed: Bool = false
  ) {
    let availablePointers: [UnsafePointer<CChar>?] = available.map { UnsafePointer(strdup($0)) }
    defer {
      for pointer in availablePointers {
        free(UnsafeMutablePointer(mutating: pointer))
      }
    }

    ClipboardRead.plainText.withCString { mime in
      (text ?? "").withCString { data in
        var content = ghostty_clipboard_content_s(
          mime: mime, data: data, len: text?.utf8.count ?? 0)

        withUnsafePointer(to: &content) { contentPointer in
          availablePointers.withUnsafeBufferPointer { availableBuffer in
            var completion = ghostty_clipboard_complete_s(
              contents: text == nil ? nil : contentPointer,
              contents_len: text == nil ? 0 : 1,
              available: availableBuffer.baseAddress,
              available_len: availableBuffer.count,
              confirmed: confirmed,
              remember: false)

            ghostty_surface_complete_clipboard_request(surface, &completion, state.pointer)
          }
        }
      }
    }
  }

  /// The clipboard's types as MIME types, for a paste event. A type with no MIME equivalent is
  /// left out.
  private func pasteboardMIMETypes() -> [String] {
    var seen: Set<String> = []
    return (pasteboard.types ?? []).compactMap { type in
      guard let mime = UTType(type.rawValue)?.preferredMIMEType, seen.insert(mime).inserted
      else { return nil }

      return mime
    }
  }

  /// A copy the user made always lands. A program's OSC 52 write lands at once in an interactive
  /// session. In a controlled session it asks, unless the user allowed writes for the session. A
  /// write that arrives while another write's prompt waits is dropped. A denied or stale write
  /// leaves the clipboard as it was.
  func writeClipboard(_ text: String, fromProgram: Bool) {
    let asked = clipboardPolicy

    guard fromProgram, asked.controlled, !sessionAllowed.contains(.write) else {
      store(text)
      return
    }

    guard onEvent != nil, asking.insert(.write).inserted else { return }

    let request = TerminalClipboardRequest(kind: .write, text: text, offersSession: true) {
      [weak self] answer in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.doneAsking(.write, under: asked)
          self?.answerWrite(text: text, answer: answer, asked: asked)
        }
      }
    }

    onEvent?(.clipboardRequest(request))
  }

  private func answerWrite(
    text: String, answer: TerminalClipboardAnswer, asked: TerminalClipboardPolicy
  ) {
    guard answer != .deny, stillCurrent(asked) else { return }

    if answer == .allowForSession { sessionAllowed.insert(.write) }

    store(text)
  }

  private func store(_ text: String) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  // MARK: Menu actions

  @objc func copy(_ sender: Any?) { perform(.copy) }
  @objc func paste(_ sender: Any?) { perform(.paste) }
  @objc override func selectAll(_ sender: Any?) { perform(.selectAll) }
  @objc func increaseTerminalFontSize(_ sender: Any?) { perform(.increaseFontSize) }
  @objc func decreaseTerminalFontSize(_ sender: Any?) { perform(.decreaseFontSize) }
  @objc func resetTerminalFontSize(_ sender: Any?) { perform(.resetFontSize) }
  @objc func clearTerminalScreen(_ sender: Any?) { perform(.clearScreen) }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard let surface else { return false }

    if item.action == #selector(copy(_:)) {
      return ghostty_surface_has_selection(surface)
    }

    return true
  }

  // MARK: View

  override var acceptsFirstResponder: Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    pushSize()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()

    if let window {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.contentsScale = window.backingScaleFactor
      CATransaction.commit()
    }

    pushScale()
    pushSize()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    for token in windowObservers {
      NotificationCenter.default.removeObserver(token)
    }
    windowObservers = []

    guard let window else {
      setFocused(false)
      return
    }

    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncFocus() }
      }
      windowObservers.append(token)
    }

    let screenToken = center.addObserver(
      forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.syncDisplay() }
    }
    windowObservers.append(screenToken)

    syncDisplay()
    pushScale()
    pushSize()
    syncFocus()
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { syncFocus() }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result { setFocused(false) }
    return result
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: cursor)
  }

  override func updateTrackingAreas() {
    for area in trackingAreas {
      removeTrackingArea(area)
    }

    addTrackingArea(
      NSTrackingArea(
        rect: frame,
        options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
        owner: self, userInfo: nil))
  }

  private func syncFocus() {
    setFocused(window?.isKeyWindow == true && window?.firstResponder === self)
  }

  private func syncDisplay() {
    guard let surface, let screen = window?.screen,
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    else { return }

    ghostty_surface_set_display_id(surface, number)
  }

  private func pushScale() {
    guard let surface, frame.width > 0, frame.height > 0 else { return }

    let backing = convertToBacking(frame)
    ghostty_surface_set_content_scale(
      surface, backing.width / frame.width, backing.height / frame.height)
  }

  private func pushSize() {
    guard let surface, frame.width > 0, frame.height > 0 else { return }

    let scaled = convertToBacking(frame.size)
    ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    guard let surface else { return }

    if window?.firstResponder !== self { window?.makeFirstResponder(self) }

    guard mouseMayReach else { return }

    Self.linkLog.debug(
      "press mods=\(Self.mods(event.modifierFlags).rawValue, privacy: .public)")

    ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
  }

  override func mouseUp(with event: NSEvent) {
    guard let surface, mouseMayReach else { return }

    Self.linkLog.debug(
      "release mods=\(Self.mods(event.modifierFlags).rawValue, privacy: .public)")

    ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    ghostty_surface_mouse_pressure(surface, 0, 0)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let surface, mouseMayReach else { return super.rightMouseDown(with: event) }

    let consumed = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
    if !consumed { super.rightMouseDown(with: event) }
  }

  override func rightMouseUp(with event: NSEvent) {
    guard let surface, mouseMayReach else { return super.rightMouseUp(with: event) }

    let consumed = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
    if !consumed { super.rightMouseUp(with: event) }
  }

  override func otherMouseDown(with event: NSEvent) {
    guard let surface, acceptsInput else { return }

    ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, Self.button(event.buttonNumber),
      Self.mods(event.modifierFlags))
  }

  override func otherMouseUp(with event: NSEvent) {
    guard let surface, acceptsInput else { return }

    ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, Self.button(event.buttonNumber),
      Self.mods(event.modifierFlags))
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    reportMouse(event)
  }

  override func mouseExited(with event: NSEvent) {
    guard let surface, NSEvent.pressedMouseButtons == 0 else { return }

    ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
  }

  override func mouseMoved(with event: NSEvent) { reportMouse(event) }
  override func mouseDragged(with event: NSEvent) { reportMouse(event) }
  override func rightMouseDragged(with event: NSEvent) { reportMouse(event) }
  override func otherMouseDragged(with event: NSEvent) { reportMouse(event) }

  private func reportMouse(_ event: NSEvent) {
    guard let surface, mouseMayReach else { return }

    let position = convert(event.locationInWindow, from: nil)
    let mods = Self.mods(event.modifierFlags)
    Self.linkLog.debug(
      "pointer x=\(position.x, privacy: .public) y=\(self.frame.height - position.y, privacy: .public) mods=\(mods.rawValue, privacy: .public) type=\(event.type.rawValue, privacy: .public)"
    )
    ghostty_surface_mouse_pos(surface, position.x, frame.height - position.y, mods)
  }

  /// Debug-level only, so it costs nothing in release and is not stored. It carries positions,
  /// modifier bits, and lengths, never the text of a link.
  private static let linkLog = Logger(subsystem: "dev.uniterm.app", category: "terminal-link")

  override func scrollWheel(with event: NSEvent) {
    guard let surface, mouseMayReach else { return }

    var x = event.scrollingDeltaX
    var y = event.scrollingDeltaY
    let precise = event.hasPreciseScrollingDeltas

    if precise {
      x *= 2
      y *= 2
    }

    let momentum: Int32
    switch event.momentumPhase {
    case .began: momentum = 1
    case .stationary: momentum = 2
    case .changed: momentum = 3
    case .ended: momentum = 4
    case .cancelled: momentum = 5
    case .mayBegin: momentum = 6
    default: momentum = 0
    }

    ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
  }

  // MARK: Keyboard

  /// Command-key events are never terminal bindings, since uniterm's menu owns them. This returns
  /// false so the menu gets them, and an event that no menu item takes comes back as a plain key
  /// down.
  ///
  /// Two control combinations are rewritten, because AppKit would otherwise use them for itself.
  /// Control-Return becomes a carriage return, and Control-slash becomes Control-underscore, which
  /// stops the beep.
  ///
  /// Upstream also replays an unmatched Command-key event through the text input system, so that
  /// Command-period reaches the terminal as Escape. uniterm leaves that replay out on purpose. The
  /// plain key down still reaches the program, with the super modifier set. A program on the kitty
  /// keyboard protocol reads it, and a legacy program reads nothing.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, focused, acceptsInput else { return false }

    let equivalent: String

    switch event.charactersIgnoringModifiers {
    case "\r":
      guard event.modifierFlags.contains(.control) else { return false }

      equivalent = "\r"

    case "/":
      guard event.modifierFlags.contains(.control),
        event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
      else { return false }

      equivalent = "_"

    default:
      return false
    }

    guard
      let rewritten = NSEvent.keyEvent(
        with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
        timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
        characters: equivalent, charactersIgnoringModifiers: equivalent,
        isARepeat: event.isARepeat, keyCode: event.keyCode)
    else { return false }

    keyDown(with: rewritten)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard acceptsInput else { return }

    guard let surface else {
      interpretKeyEvents([event])
      return
    }

    let translated = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
    let translatedFlags = Self.flags(translated)

    var translationMods = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if translatedFlags.contains(flag) {
        translationMods.insert(flag)
      } else {
        translationMods.remove(flag)
      }
    }

    let translationEvent: NSEvent
    if translationMods == event.modifierFlags {
      translationEvent = event
    } else {
      translationEvent =
        NSEvent.keyEvent(
          with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
          timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
          characters: event.characters(byApplyingModifiers: translationMods) ?? "",
          charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
          isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }

    let hadMarkedText = markedText.length > 0
    let layoutBefore = hadMarkedText ? nil : KeyboardLayout.id

    interpretKeyEvents([translationEvent])

    // An event that switched the input source belongs to the input method, not to the terminal.
    if !hadMarkedText, layoutBefore != KeyboardLayout.id {
      return
    }

    syncPreedit(clearIfNeeded: hadMarkedText)

    if let texts = keyTextAccumulator, !texts.isEmpty {
      for text in texts {
        _ = sendKey(action, event: event, translationEvent: translationEvent, text: text)
      }
    } else {
      _ = sendKey(
        action, event: event, translationEvent: translationEvent,
        text: Self.characters(of: translationEvent),
        composing: markedText.length > 0 || hadMarkedText)
    }
  }

  override func keyUp(with event: NSEvent) {
    guard acceptsInput else { return }

    _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
  }

  override func flagsChanged(with event: NSEvent) {
    guard acceptsInput else { return }

    Self.linkLog.debug(
      "flags mods=\(Self.mods(event.modifierFlags).rawValue, privacy: .public) key=\(event.keyCode, privacy: .public)"
    )

    let mask: UInt32

    switch event.keyCode {
    case 0x39: mask = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: mask = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: mask = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: mask = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: mask = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }

    if markedText.length > 0 { return }

    var action = GHOSTTY_ACTION_RELEASE
    if Self.mods(event.modifierFlags).rawValue & mask != 0 {
      let rawFlags = event.modifierFlags.rawValue
      let sidePressed: Bool

      switch event.keyCode {
      case 0x3C: sidePressed = rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0
      case 0x3E: sidePressed = rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0
      case 0x3D: sidePressed = rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0
      case 0x36: sidePressed = rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0
      default: sidePressed = true
      }

      if sidePressed { action = GHOSTTY_ACTION_PRESS }
    }

    _ = sendKey(action, event: event)
  }

  /// The libghostty key event for an AppKit event, as plain numbers. Kept apart from the C struct
  /// so a test can check the translation without a surface.
  struct KeyFields: Equatable {
    var action: UInt32
    var keycode: UInt32
    var mods: UInt32
    var consumedMods: UInt32
    var unshiftedCodepoint: UInt32
    var text: String?
    var composing: Bool
  }

  /// Control and command never contribute to the text of a key, so they are not consumed. Every other
  /// modifier of the translation event is.
  static func keyFields(
    action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
    text: String? = nil, composing: Bool = false
  ) -> KeyFields {
    var unshifted: UInt32 = 0
    if event.type == .keyDown || event.type == .keyUp,
      let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
    {
      unshifted = scalar.value
    }

    let consumed = (translationEvent?.modifierFlags ?? event.modifierFlags).subtracting([
      .control, .command,
    ])

    var sendable: String?
    if let text, let first = text.utf8.first, first >= 0x20 {
      sendable = text
    }

    return KeyFields(
      action: action.rawValue, keycode: UInt32(event.keyCode),
      mods: mods(event.modifierFlags).rawValue, consumedMods: mods(consumed).rawValue,
      unshiftedCodepoint: unshifted, text: sendable, composing: composing)
  }

  private func sendKey(
    _ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
    text: String? = nil, composing: Bool = false
  ) -> Bool {
    guard let surface else { return false }

    let fields = Self.keyFields(
      action: action, event: event, translationEvent: translationEvent, text: text,
      composing: composing)

    var key = ghostty_input_key_s()
    key.action = ghostty_input_action_e(fields.action)
    key.keycode = fields.keycode
    key.mods = ghostty_input_mods_e(fields.mods)
    key.consumed_mods = ghostty_input_mods_e(fields.consumedMods)
    key.unshifted_codepoint = fields.unshiftedCodepoint
    key.composing = fields.composing
    key.text = nil

    if let text = fields.text {
      return text.withCString {
        key.text = $0
        return ghostty_surface_key(surface, key)
      }
    }

    return ghostty_surface_key(surface, key)
  }

  /// The text of a key event, without control characters and without private-use function key
  /// codes. libghostty encodes those itself.
  private static func characters(of event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }

    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      if scalar.value < 0x20 {
        return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
      }

      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
        return nil
      }
    }

    return characters
  }

  private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    let raw = flags.rawValue
    if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(mods)
  }

  private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []

    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }

    return flags
  }

  private static func button(_ number: Int) -> ghostty_input_mouse_button_e {
    switch number {
    case 2: return GHOSTTY_MOUSE_MIDDLE
    case 3: return GHOSTTY_MOUSE_FOUR
    case 4: return GHOSTTY_MOUSE_FIVE
    case 5: return GHOSTTY_MOUSE_SIX
    case 6: return GHOSTTY_MOUSE_SEVEN
    case 7: return GHOSTTY_MOUSE_EIGHT
    case 8: return GHOSTTY_MOUSE_NINE
    case 9: return GHOSTTY_MOUSE_TEN
    case 10: return GHOSTTY_MOUSE_ELEVEN
    default: return GHOSTTY_MOUSE_UNKNOWN
    }
  }

  // MARK: Text input

  func hasMarkedText() -> Bool {
    markedText.length > 0
  }

  func markedRange() -> NSRange {
    markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
  }

  func selectedRange() -> NSRange {
    NSRange()
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard acceptsInput else { return }

    switch string {
    case let value as NSAttributedString:
      markedText = NSMutableAttributedString(attributedString: value)
    case let value as String: markedText = NSMutableAttributedString(string: value)
    default: return
    }

    if keyTextAccumulator == nil {
      syncPreedit()
    }
  }

  func unmarkText() {
    if markedText.length > 0 {
      markedText.mutableString.setString("")
      syncPreedit()
    }
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  func attributedSubstring(
    forProposedRange range: NSRange, actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    nil
  }

  func characterIndex(for point: NSPoint) -> Int {
    0
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else { return .zero }

    var x = 0.0
    var y = 0.0
    var width = Double(cellSize.width)
    var height = Double(cellSize.height)
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)

    let rect = NSRect(x: x, y: frame.height - y, width: width, height: max(height, cellSize.height))
    let inWindow = convert(rect, to: nil)
    return window?.convertToScreen(inWindow) ?? inWindow
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard NSApp.currentEvent != nil, acceptsInput else { return }

    let text: String
    switch string {
    case let value as NSAttributedString: text = value.string
    case let value as String: text = value
    default: return
    }

    unmarkText()

    if var accumulator = keyTextAccumulator {
      accumulator.append(text)
      keyTextAccumulator = accumulator
      return
    }

    send(text: text)
  }

  /// A key that AppKit maps to an editing command has no text. The key event still goes to the
  /// terminal afterwards, so this only has to keep AppKit from beeping.
  override func doCommand(by selector: Selector) {}

  private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }

    if markedText.length > 0 {
      let string = markedText.string
      ghostty_surface_preedit(surface, string, UInt(string.utf8.count))
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  // MARK: Accessibility

  override func isAccessibilityElement() -> Bool { true }

  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

  /// Focused while typed keys reach this terminal: its window is key and it is first responder.
  /// UI tests check it before they type.
  override func isAccessibilityFocused() -> Bool {
    window?.isKeyWindow == true && window?.firstResponder === self
  }

  /// The visible screen text. UI tests read the terminal's output through it.
  override func accessibilityValue() -> Any? {
    guard let surface else { return nil }

    func corner(_ coord: ghostty_point_coord_e) -> ghostty_point_s {
      ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: coord, x: 0, y: 0)
    }

    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
      top_left: corner(GHOSTTY_POINT_COORD_TOP_LEFT),
      bottom_right: corner(GHOSTTY_POINT_COORD_BOTTOM_RIGHT), rectangle: false)
    guard ghostty_surface_read_text(surface, selection, &text) else { return nil }

    defer { ghostty_surface_free_text(surface, &text) }

    guard let pointer = text.text else { return nil }

    let bytes = UnsafeBufferPointer(
      start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
      count: min(Int(text.text_len), Self.maximumAccessibilityCharacters))
    return String(decoding: bytes, as: UTF8.self)
  }
}

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {}
