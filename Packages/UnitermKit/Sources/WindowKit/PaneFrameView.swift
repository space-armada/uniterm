import AppKit
import AppletKit
import PaneModel
import Theme

/// What the pane's control badge shows. The window builds it from its own control table and the
/// pane tree, never from the applet.
struct PaneControlMark: Equatable {
  var access: PaneAccessMode
  var driver: PaneDriverKind

  /// What pane chrome calls the controller that owns a group the pane is a member of. Nil when no
  /// live controller owns one.
  var owner: String?

  /// The pane is a member of a group that no live controller owns now.
  var inUnownedGroup: Bool

  /// What pane chrome calls each controller with authority over the pane, the ones acting from it
  /// included. Revoke Controller ends all of them.
  var controllers: [String] = []

  /// The control the pane had when the layout was saved. It is inactive until the user enables it.
  var savedIntent: PaneAccessMode?

  var enableAvailable: Bool
  var revokeAvailable: Bool

  /// One controller with authority over the pane, with what its process is doing. Only a REPL
  /// helper or a driver that uniterm started has a target. A controller started from a shell has
  /// none, and shows only that its shell stopped it.
  struct ControllerLine: Equatable {
    enum State: Equatable {
      case running
      case suspended
      case stoppedByShell
    }

    var name: String
    var target: SuspendTarget?
    var state: State

    /// True when Resume has a stop to continue.
    var canResume: Bool
  }

  /// What each controller that has authority over the pane is doing, for the suspend items and the
  /// lines under the summary.
  var controllerLines: [ControllerLine] = []

  /// A live controller the user may give the pane's group to, when the pane is a member of a group
  /// with no owner.
  struct Adoption: Equatable {
    let owner: GroupOwner
    let name: String
  }

  /// The controllers the badge offers the pane's unowned group to. It is empty when the pane is in
  /// no such group, or no controller acts in the window.
  var adoptions: [Adoption] = []

  /// The badge shows only on a pane that is not in the default state. A controller acting from the
  /// pane keeps it out of that state, so Revoke Controller stays in pane chrome after the user
  /// disconnects the pane.
  var isShown: Bool {
    access != .disconnected || driver != .none || owner != nil || inUnownedGroup
      || !controllers.isEmpty || savedIntent != nil
  }

  /// The lines the badge's menu and tooltip show: the mode, the owner, and the driver.
  var summary: [String] {
    var lines: [String] = []

    switch access {
    case .remoteControlled: lines.append("Remote-controlled")
    case .disconnected: lines.append("Disconnected")
    }

    if let owner {
      lines.append("Owner: \(owner)")
    } else if inUnownedGroup {
      lines.append("Owner: none, the controller is gone")
    }

    for controller in controllers where controller != owner {
      lines.append("Controller: \(controller)")
    }

    lines.append(driver == .none ? "Driver: none" : "Driver: \(driver.rawValue)")

    for line in controllerLines {
      switch line.state {
      case .running: break
      case .suspended: lines.append(SuspensionWording.suspended(line.name))
      case .stoppedByShell: lines.append(SuspensionWording.stoppedByShell(line.name))
      }
    }

    if let savedIntent, access == .disconnected {
      lines.append("Saved as \(savedIntent.rawValue). Enable it again to resume.")
    }

    return lines
  }

  /// The value accessibility reads, and the UI tests with it.
  var accessibilityValue: String {
    [access.rawValue, owner.map { "owned by \($0)" }].compactMap { $0 }.joined(separator: ", ")
  }
}

/// What the pane's exec strip shows: where its driver stands, and the action the user can take.
/// The window builds it from the pane's exec attachment, never from the applet or the driver.
struct PaneExecStatus: Equatable {
  var text: String

  /// Run, Restart, or Resume, or nil while nothing can be started.
  var action: String?

  /// True while the driver is suspended. The strip is the banner then, and its action is Resume.
  var isSuspended = false
}

/// The control actions the badge's menu offers. The window runs each one for this pane.
enum PaneControlAction: Equatable {
  case enable
  case disconnect
  case revoke

  /// Stops one controller uniterm started.
  case suspend(SuspendTarget)

  /// Continues one controller that is stopped.
  case resume(SuspendTarget)

  /// Gives the unowned group the pane is a member of to a live controller.
  case adopt(GroupOwner)
}

/// Hosts one applet's view inside a pane. A gutter around the applet holds the focus marker.
@MainActor
final class PaneFrameView: NSView {
  static let gutter: CGFloat = 2

  /// The badge's side, in points.
  static let badgeSize: CGFloat = 20

  let paneID: NodeID
  private(set) var applet: any Applet

  private var palette: ThemePalette = .latte

  /// The width last told to the applet, so it hears only changes.
  private var reportedBadgeReach: CGFloat = 0

  /// The host's own badge, above the applet's view. It opens the pane's control actions with the
  /// mouse, so they stay reachable when the applet takes every key.
  let controlBadge = NSButton()

  /// The host's marker for a pane whose program waits for the user's answer in the Questions pane.
  /// It sits beside the control badge and never takes a click.
  let askingBadge = NSImageView()

  /// The markers of the pane's one tab, drawn leading of the control badge. They show only while
  /// the pane has no tab bar, so the host sets none otherwise.
  var paneMarkers: [AppletMarker] = [] {
    didSet {
      guard paneMarkers != oldValue else { return }

      syncMarkerViews()
    }
  }

  private var markerViews: [AppletMarkerView] = []

  var askingMark: PaneAskingMark? {
    didSet {
      if askingMark != oldValue { refreshAskingBadge() }
    }
  }

  var controlMark: PaneControlMark? {
    didSet {
      if controlMark != oldValue { refreshBadge() }
    }
  }

  /// The host's strip at the pane's foot, for a pane that declares an exec driver. Its button is
  /// the only way to start the driver, so a run is always the user's own action.
  let execStrip = NSView()
  private let execLabel = NSTextField(labelWithString: "")
  private let execButton = NSButton(title: "Run", target: nil, action: nil)

  static let execStripHeight: CGFloat = 28

  var execStatus: PaneExecStatus? {
    didSet {
      if execStatus != oldValue { refreshExecStrip() }
    }
  }

  var onExecAction: (() -> Void)?

  /// Runs a control action the user chose from the badge's menu.
  var onControlAction: ((PaneControlAction) -> Void)?

  /// Builds the badge's mark from the window's live state. The menu reads it as it opens, so it
  /// never shows a controller that has gone or misses one that has come.
  var currentControlMark: (() -> PaneControlMark?)?

  var isFocused = false {
    didSet { refresh() }
  }

  /// A lone pane has no neighbor to tell apart from, so it shows no marker.
  var showsFocusMarker = false {
    didSet { refresh() }
  }

  override var wantsUpdateLayer: Bool { true }

  override var isFlipped: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  /// `frame` is the pane's frame, so the applet's view starts at its size.
  init(paneID: NodeID, applet: any Applet, frame: NSRect = .zero) {
    self.paneID = paneID
    self.applet = applet
    super.init(frame: frame)

    wantsLayer = true
    applet.view.frame = innerFrame
    addSubview(applet.view)

    controlBadge.isBordered = false
    controlBadge.bezelStyle = .regularSquare
    controlBadge.imagePosition = .imageOnly
    controlBadge.image = NSImage(
      systemSymbolName: "antenna.radiowaves.left.and.right",
      accessibilityDescription: "Pane control")
    controlBadge.wantsLayer = true
    controlBadge.layer?.cornerRadius = 4
    controlBadge.target = self
    controlBadge.action = #selector(showControlMenu(_:))
    controlBadge.setAccessibilityIdentifier("pane-control-\(paneID)")
    controlBadge.setAccessibilityLabel("Pane control")
    controlBadge.isHidden = true
    addSubview(controlBadge)

    askingBadge.image = NSImage(
      systemSymbolName: "questionmark.bubble.fill", accessibilityDescription: "Asking")
    askingBadge.imageScaling = .scaleProportionallyDown
    askingBadge.wantsLayer = true
    askingBadge.layer?.cornerRadius = 4
    askingBadge.setAccessibilityElement(true)
    askingBadge.setAccessibilityRole(.image)
    askingBadge.setAccessibilityIdentifier("pane-asking-\(paneID)")
    askingBadge.isHidden = true
    addSubview(askingBadge)

    execStrip.wantsLayer = true
    execStrip.isHidden = true
    execStrip.setAccessibilityElement(true)
    execStrip.setAccessibilityRole(.group)
    execStrip.setAccessibilityIdentifier("pane-exec-\(paneID)")
    execLabel.lineBreakMode = .byTruncatingTail
    execLabel.font = .systemFont(ofSize: 11)
    execLabel.setAccessibilityIdentifier("pane-exec-status-\(paneID)")
    execButton.controlSize = .small
    execButton.bezelStyle = .push
    execButton.target = self
    execButton.action = #selector(runExecAction)
    execButton.setAccessibilityIdentifier("pane-exec-run-\(paneID)")
    execStrip.addSubview(execLabel)
    execStrip.addSubview(execButton)
    addSubview(execStrip)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("pane-\(paneID)")
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Puts another applet in this pane. The old applet's view leaves, and the caller closes it.
  func replaceApplet(_ replacement: any Applet) {
    applet.view.removeFromSuperview()
    applet = replacement

    replacement.view.frame = innerFrame
    addSubview(replacement.view, positioned: .below, relativeTo: controlBadge)
    replacement.apply(palette)
    reportedBadgeReach = 0
    reportBadgeReach()
  }

  private var innerFrame: NSRect {
    var frame = Self.appletFrame(in: bounds)

    if execStatus != nil {
      frame.size.height = max(0, frame.height - Self.execStripHeight)
    }

    return frame
  }

  /// The applet's frame for a pane with these bounds: the bounds less the gutter on every side.
  /// It is the bounds inset by hand on purpose. Core Graphics returns the null rect, with an
  /// infinite origin, for bounds smaller than the inset, and a pane is zero size before its
  /// first layout.
  static func appletFrame(in bounds: NSRect) -> NSRect {
    NSRect(
      x: bounds.minX + gutter, y: bounds.minY + gutter,
      width: max(0, bounds.width - 2 * gutter), height: max(0, bounds.height - 2 * gutter))
  }

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    applet.view.frame = innerFrame
    layoutBadges()
    layoutExecStrip()
    reportBadgeReach()
  }

  /// How far the shown badge reaches in from the applet's trailing edge, with a gap. The applet
  /// keeps its top bar's trailing controls clear of it.
  static func badgeReach(badge: NSRect, appletFrame: NSRect) -> CGFloat {
    max(0, appletFrame.maxX - badge.minX) + 4
  }

  private func reportBadgeReach() {
    let leading = ([controlBadge, askingBadge] + markerViews).filter { !$0.isHidden }
      .map(\.frame.minX).min()

    let reach =
      leading.map {
        Self.badgeReach(
          badge: NSRect(x: $0, y: 0, width: 0, height: 0), appletFrame: applet.view.frame)
      } ?? 0

    guard reach != reportedBadgeReach else { return }

    reportedBadgeReach = reach
    applet.hostBadgeReachDidChange(reach)
  }

  private func layoutExecStrip() {
    let inner = Self.appletFrame(in: bounds)

    execStrip.frame = NSRect(
      x: inner.minX, y: max(inner.minY, inner.maxY - Self.execStripHeight), width: inner.width,
      height: min(inner.height, Self.execStripHeight))

    let button = execButton.isHidden ? 0 : min(execStrip.bounds.width / 3, 90)

    execButton.frame = NSRect(
      x: execStrip.bounds.width - button - 6, y: 3, width: button, height: 22)
    execLabel.frame = NSRect(
      x: 8, y: 6, width: max(0, execStrip.bounds.width - button - 20), height: 16)
  }

  private func refreshExecStrip() {
    guard let status = execStatus else {
      execStrip.isHidden = true
      applet.view.frame = innerFrame
      return
    }

    execStrip.isHidden = false
    execLabel.stringValue = status.text
    execLabel.toolTip = status.text
    execButton.isHidden = status.action == nil
    execButton.title = status.action ?? ""
    execStrip.layer?.backgroundColor =
      (status.isSuspended ? palette[.surface0] : palette[.mantle]).cgColor
    applet.view.frame = innerFrame
    layoutExecStrip()
  }

  @objc private func runExecAction() {
    onExecAction?()
  }

  /// The badge sits in the pane's top right corner, inside the gutter.
  static func badgeFrame(in bounds: NSRect) -> NSRect {
    NSRect(
      x: max(0, bounds.maxX - gutter - badgeSize - 4), y: bounds.minY + gutter + 4,
      width: badgeSize, height: badgeSize)
  }

  /// The control badge sits in the corner. The pane's markers sit leading of it, or take the corner
  /// when it is hidden, so they move only when the badge's visibility changes. The asking badge
  /// sits leading of both, and takes the corner when neither shows.
  private func layoutBadges() {
    let corner = Self.badgeFrame(in: bounds)
    let gap: CGFloat = 4

    controlBadge.frame = corner

    var edge = controlBadge.isHidden ? corner.maxX : corner.minX - gap

    for view in markerViews.reversed() {
      view.frame = NSRect(
        x: edge - Self.badgeSize, y: corner.minY, width: Self.badgeSize, height: Self.badgeSize)
      edge = view.frame.minX - gap
    }

    var asking = corner

    if !controlBadge.isHidden || !markerViews.isEmpty { asking.origin.x = edge - Self.badgeSize }

    askingBadge.frame = asking
  }

  private func syncMarkerViews() {
    while markerViews.count > paneMarkers.count {
      markerViews.removeLast().removeFromSuperview()
    }

    while markerViews.count < paneMarkers.count {
      let view = AppletMarkerView(paneMarkers[markerViews.count], palette: palette)

      view.forwardsClicks = false
      view.wantsLayer = true
      view.layer?.cornerRadius = 4
      addSubview(view)
      markerViews.append(view)
    }

    for (view, marker) in zip(markerViews, paneMarkers) {
      view.configure(marker)
      view.apply(palette)
      view.layer?.backgroundColor = palette[.surface0].cgColor
      view.setAccessibilityIdentifier("pane-marker-\(marker.kind.rawValue)-\(paneID)")
    }

    layoutBadges()
    reportBadgeReach()
  }

  private func refreshAskingBadge() {
    guard let mark = askingMark else {
      askingBadge.isHidden = true
      reportBadgeReach()
      return
    }

    askingBadge.isHidden = false
    layoutBadges()
    askingBadge.toolTip = mark.summary
    askingBadge.setAccessibilityLabel(mark.summary)
    askingBadge.contentTintColor = palette[.blue].nsColor
    askingBadge.layer?.backgroundColor = palette[.surface0].cgColor
    reportBadgeReach()
  }

  private func refreshBadge() {
    guard let mark = controlMark, mark.isShown else {
      controlBadge.isHidden = true
      layoutBadges()
      reportBadgeReach()
      return
    }

    let active = mark.access == .remoteControlled || mark.driver != .none

    controlBadge.isHidden = false
    layoutBadges()
    controlBadge.toolTip = mark.summary.joined(separator: "\n")
    controlBadge.setAccessibilityValue(mark.accessibilityValue)
    controlBadge.contentTintColor = active ? palette[.peach].nsColor : palette[.overlay1].nsColor
    controlBadge.layer?.backgroundColor = palette[.surface0].cgColor
    reportBadgeReach()
  }

  /// The menu names the mode, the owner, and the driver, then offers the actions that apply.
  func controlMenu() -> NSMenu {
    let menu = NSMenu()
    let mark = controlMark

    for line in mark?.summary ?? [] {
      let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let actions: [(String, PaneControlAction, Bool, String)] = [
      ("Enable Remote Control", .enable, mark?.enableAvailable == true, "enable"),
      ("Disconnect", .disconnect, mark?.access == .remoteControlled, "disconnect"),
      ("Revoke Controller", .revoke, mark?.revokeAvailable == true, "revoke"),
    ]

    menu.autoenablesItems = false

    for (title, action, enabled, name) in actions {
      let item = NSMenuItem(
        title: title, action: #selector(runControlAction(_:)), keyEquivalent: "")
      item.setAccessibilityIdentifier("pane-control-\(name)")
      item.target = self
      item.representedObject = action
      item.isEnabled = enabled
      menu.addItem(item)
    }

    let suspendable = (mark?.controllerLines ?? []).filter { $0.target != nil }

    if !suspendable.isEmpty { menu.addItem(.separator()) }

    for (index, line) in suspendable.enumerated() {
      guard let target = line.target else { continue }

      let resuming = line.state == .suspended || line.canResume
      let item = NSMenuItem(
        title: "\(resuming ? "Resume" : "Suspend") \(line.name)",
        action: #selector(runControlAction(_:)), keyEquivalent: "")

      item.setAccessibilityIdentifier("pane-control-\(resuming ? "resume" : "suspend")-\(index)")
      item.target = self
      item.representedObject = resuming ? PaneControlAction.resume(target) : .suspend(target)
      menu.addItem(item)
    }

    let adoptions = mark?.adoptions ?? []

    if !adoptions.isEmpty { menu.addItem(.separator()) }

    for (index, adoption) in adoptions.enumerated() {
      let item = NSMenuItem(
        title: "Give Group to \(adoption.name)", action: #selector(runControlAction(_:)),
        keyEquivalent: "")
      item.setAccessibilityIdentifier("pane-control-adopt-\(index)")
      item.target = self
      item.representedObject = PaneControlAction.adopt(adoption.owner)
      menu.addItem(item)
    }

    return menu
  }

  @objc private func showControlMenu(_ sender: NSButton) {
    if let mark = currentControlMark?() { controlMark = mark }

    controlMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }

  @objc private func runControlAction(_ item: NSMenuItem) {
    guard let action = item.representedObject as? PaneControlAction else { return }

    onControlAction?(action)
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    applet.apply(palette)
    refresh()
    refreshBadge()
    refreshAskingBadge()
    syncMarkerViews()
    refreshExecStrip()
  }

  private func refresh() {
    setAccessibilityValue(isFocused ? "focused" : "unfocused")
    needsDisplay = true
  }

  override func updateLayer() {
    guard let layer else { return }

    layer.backgroundColor = palette[.base].cgColor
    layer.borderWidth = isFocused && showsFocusMarker ? Self.gutter : 0
    layer.borderColor = palette[.blue].cgColor
  }
}
