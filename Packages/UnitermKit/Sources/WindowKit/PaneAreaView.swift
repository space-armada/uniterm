import AppKit
import AppletKit
import PaneModel
import Theme

/// Draws a pane tree. It owns the model, the pane views, and the dividers.
///
/// The model decides every frame. This view places a pane view in each frame and moves the
/// dividers the user drags. It never changes sizes itself.
@MainActor
final class PaneAreaView: NSView {
  private struct DividerKey: Hashable {
    let leading: NodeID
    let trailing: NodeID
  }

  private(set) var tree: PaneTree
  private(set) var focusedPane: NodeID {
    didSet {
      if focusedPane != oldValue {
        onFocusChange?()
        onLayoutChange?()
      }
    }
  }

  /// Runs when the focused pane changes, so the status bar can show that pane's applet.
  var onFocusChange: (() -> Void)?

  /// Runs when the tree changes shape, so the window can follow the new minimum size.
  var onTreeChange: (() -> Void)?

  /// Runs as an applet takes a pane, before anything can start it. The window binds the applet's
  /// host here, so the pane's identity is fixed at the origin of every message the applet posts.
  /// The panes the view is built with are placed before a caller can set this, so the window binds
  /// those itself.
  var onAppletPlaced: ((any Applet, NodeID) -> Void)?

  /// Runs when anything a saved layout holds about the tree changes: its shape, its weights, or
  /// the focused pane.
  var onLayoutChange: (() -> Void)?

  private var paneViews: [NodeID: PaneFrameView] = [:]
  private var dividerViews: [DividerKey: DividerView] = [:]
  private var palette: ThemePalette = .latte
  private var updateObserver: NSObjectProtocol?

  override var isFlipped: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  /// `size` is the size the view starts at, before the window lays it out. Each pane's applet
  /// takes its share of it, so no applet view joins the window at zero size.
  init(metrics: PaneMetrics = .standard, firstApplet: any Applet, size: NSSize) {
    tree = PaneTree(metrics: metrics)
    focusedPane = tree.paneIDs[0]
    super.init(frame: NSRect(origin: .zero, size: size))

    install(firstApplet, as: focusedPane)
    paneViews[focusedPane]?.isFocused = true
  }

  /// Makes the view for a restored tree. `applets` holds one applet for each pane of `tree`, and
  /// `focus` is the pane that has focus. Nothing is started here. `size` is as for a new view.
  init(restoring tree: PaneTree, applets: [NodeID: any Applet], focus: NodeID, size: NSSize) {
    self.tree = tree
    focusedPane = tree.paneIDs.contains(focus) ? focus : tree.paneIDs[0]
    super.init(frame: NSRect(origin: .zero, size: size))

    for id in tree.paneIDs {
      guard let applet = applets[id] else {
        preconditionFailure("the restored pane \(id) has no applet")
      }

      install(applet, as: id)
    }

    refreshFocusMarks()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  isolated deinit {
    if let updateObserver {
      NotificationCenter.default.removeObserver(updateObserver)
    }
  }

  // MARK: Queries

  var minimumSize: NSSize { tree.minimumSize }

  var paneCount: Int { paneViews.count }

  /// Every applet, in reading order.
  var applets: [any Applet] {
    tree.paneIDs.compactMap { paneViews[$0]?.applet }
  }

  func applet(for pane: NodeID) -> (any Applet)? {
    paneViews[pane]?.applet
  }

  func paneView(for pane: NodeID) -> PaneFrameView? {
    paneViews[pane]
  }

  var dividers: [DividerView] {
    Array(dividerViews.values)
  }

  func paneID(for applet: any Applet) -> NodeID? {
    paneViews.first { $0.value.applet === applet }?.key
  }

  func canSplit(_ pane: NodeID, _ axis: Axis) -> Bool {
    tree.canSplit(pane, axis: axis, in: bounds.size)
  }

  /// True when `insert(_:at:)` would succeed. A caller checks it before it builds an applet.
  func canInsert(at placement: PanePlacement) -> Bool {
    tree.canInsert(at: placement, in: bounds.size)
  }

  // MARK: Edits

  /// Splits `pane` and puts `applet` in the new one. Throws when the pane is too small. The caller
  /// moves focus to the new pane.
  @discardableResult
  func split(_ pane: NodeID, _ axis: Axis, adding applet: any Applet) throws -> NodeID {
    let created = try tree.split(pane, axis: axis, in: bounds.size)

    install(applet, as: created)
    changed()
    layoutSubtreeIfNeeded()
    return created
  }

  /// Splits `pane` for a controller, puts `applet` in the new pane, and makes it a member of the
  /// controller's group. Throws when the pane is too small. The caller moves focus to the new pane.
  @discardableResult
  func split(
    _ pane: NodeID, _ axis: Axis, adding applet: any Applet, for owner: GroupOwner
  ) throws -> NodeID {
    let created = try tree.split(pane, axis: axis, in: bounds.size, for: owner).pane

    install(applet, as: created)
    changed()
    layoutSubtreeIfNeeded()
    return created
  }

  /// Takes ownership away from `owner` in every group it owns, and returns the panes that were
  /// members of them. The groups stay.
  @discardableResult
  func releaseOwner(_ owner: GroupOwner) -> Set<NodeID> {
    tree.releaseOwner(owner)
  }

  /// Gives a group with no owner to `owner`. Returns false when the group is not here or has one.
  @discardableResult
  func adopt(_ group: NodeID, by owner: GroupOwner) -> Bool {
    guard tree.adopt(group, by: owner) else { return false }

    changed()
    return true
  }

  /// Lays out a controller's subtree as `plan` says, and puts each applet in the new pane of its
  /// slot. Every pane already open keeps its view and its applet. Throws, and changes nothing,
  /// when the tree refuses the layout. Focus stays where it was.
  func layOut(
    _ plan: PaneLayoutPlan, anchoredAt anchor: NodeID, for owner: GroupOwner,
    adding applets: [any Applet]
  ) throws -> PaneLayoutOutcome {
    let outcome = try tree.layOut(
      plan, anchoredAt: anchor, for: owner, slots: applets.count, in: bounds.size)

    for (applet, pane) in zip(applets, outcome.created) { install(applet, as: pane) }

    changed()
    layoutSubtreeIfNeeded()
    return outcome
  }

  /// Opens a new pane where `placement` says and puts `applet` in it. The pane gets a fresh ID.
  /// Throws when the pane does not fit. Focus stays where it was, and the caller moves it.
  @discardableResult
  func insert(_ applet: any Applet, at placement: PanePlacement) throws -> NodeID {
    let created = try tree.insert(at: placement, in: bounds.size)

    install(applet, as: created)
    changed()
    layoutSubtreeIfNeeded()
    return created
  }

  /// Removes a pane and gives its space to its neighbors. Returns nil for the last pane, which
  /// stays. The applet is returned for the caller to close. The placement says where the pane sat,
  /// so undo can bring it back.
  ///
  /// Focus moves only when the closed pane had it. Then `refocus` names the pane that takes over,
  /// and the caller gives it the keyboard. Closing any other pane leaves focus where it was.
  func remove(_ pane: NodeID) throws -> (
    applet: any Applet, refocus: NodeID?, placement: PanePlacement
  )? {
    guard let view = paneViews[pane] else { throw PaneTreeError.unknownPane(pane) }

    guard let placement = tree.placement(of: pane) else { return nil }

    guard case .closed(let focus) = try tree.close(pane) else { return nil }

    let hadFocus = pane == focusedPane

    paneViews.removeValue(forKey: pane)
    view.removeFromSuperview()

    if hadFocus {
      focusedPane = focus
    }

    changed()
    layoutSubtreeIfNeeded()

    return (view.applet, hadFocus ? focus : nil, placement)
  }

  /// Puts `applet` in an existing pane, which keeps its ID, its place, and its focus. Returns the
  /// applet it replaced for the caller to close, or nil when the pane is unknown.
  func replace(_ pane: NodeID, with applet: any Applet) -> (any Applet)? {
    guard let view = paneViews[pane] else { return nil }

    let replaced = view.applet
    view.replaceApplet(applet)
    onAppletPlaced?(applet, pane)
    changed()
    layoutSubtreeIfNeeded()
    return replaced
  }

  /// The pane view takes the frame the tree gives the pane before it joins the view, so its
  /// applet's view never enters a window at zero size. An applet's constraints cannot all hold at
  /// zero width, and AppKit would break one on the layout pass before `layout()` sizes the pane.
  private func install(_ applet: any Applet, as pane: NodeID) {
    let frame = tree.layout(in: bounds.size).frames[pane].map(snapped) ?? .zero
    let view = PaneFrameView(paneID: pane, applet: applet, frame: frame)
    view.apply(palette)
    paneViews[pane] = view
    addSubview(view)
    onAppletPlaced?(applet, pane)
  }

  private func changed() {
    refreshFocusMarks()
    needsLayout = true
    onTreeChange?()
    onLayoutChange?()
  }

  // MARK: Focus

  /// Marks a pane focused and gives its applet the keyboard. With `keyboard` false, only the mark
  /// moves, as when the palette holds the keyboard.
  func focus(_ pane: NodeID, keyboard: Bool = true) {
    guard paneViews[pane] != nil else { return }

    setFocusedPane(pane)

    if keyboard {
      paneViews[pane]?.applet.focus()
    }
  }

  func pane(after pane: NodeID) -> NodeID? {
    tree.nextPane(after: pane)
  }

  func pane(before pane: NodeID) -> NodeID? {
    tree.previousPane(before: pane)
  }

  func neighbor(of pane: NodeID, toward direction: Direction) -> NodeID? {
    tree.neighbor(of: pane, toward: direction, in: bounds.size)
  }

  private func setFocusedPane(_ pane: NodeID) {
    focusedPane = pane
    refreshFocusMarks()
  }

  /// The focused pane is marked, but only when it has a neighbor to be told apart from.
  private func refreshFocusMarks() {
    for (id, view) in paneViews {
      view.isFocused = id == focusedPane
      view.showsFocusMarker = paneViews.count > 1
    }
  }

  /// A click inside a pane's applet moves the first responder without asking this view. The
  /// window reports every event it handles, so the focus mark follows the responder from there.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if let updateObserver {
      NotificationCenter.default.removeObserver(updateObserver)
      self.updateObserver = nil
    }

    guard let window else { return }

    updateObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didUpdateNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.followResponder() }
    }
  }

  private func followResponder() {
    guard let responder = window?.firstResponder as? NSView else { return }

    for (id, view) in paneViews where responder.isDescendant(of: view) {
      if id != focusedPane { setFocusedPane(id) }
      return
    }
  }

  // MARK: Layout

  override func layout() {
    super.layout()

    let layout = tree.layout(in: bounds.size)

    for (id, view) in paneViews {
      if let frame = layout.frames[id] { view.frame = snapped(frame) }
    }

    var live = Set<DividerKey>()

    for divider in layout.dividers {
      let key = DividerKey(leading: divider.leading, trailing: divider.trailing)
      live.insert(key)

      let view = dividerViews[key] ?? makeDivider(key, axis: divider.axis)
      view.axis = divider.axis
      view.frame = snapped(divider.frame)
    }

    for key in dividerViews.keys where !live.contains(key) {
      dividerViews.removeValue(forKey: key)?.removeFromSuperview()
    }
  }

  private func makeDivider(_ key: DividerKey, axis: Axis) -> DividerView {
    let view = DividerView(leading: key.leading, trailing: key.trailing, axis: axis)
    view.apply(palette)
    view.onDrag = { [weak self] divider, point in self?.drag(divider, to: point) }
    dividerViews[key] = view
    addSubview(view)
    return view
  }

  /// Rounds a frame's edges, so neighbors share a whole-point edge and leave no seam.
  private func snapped(_ rect: CGRect) -> NSRect {
    let minX = rect.minX.rounded()
    let minY = rect.minY.rounded()
    return NSRect(
      x: minX, y: minY, width: rect.maxX.rounded() - minX, height: rect.maxY.rounded() - minY)
  }

  private func drag(_ divider: DividerView, to point: NSPoint) {
    let delta = divider.axis == .row ? point.x - divider.frame.midX : point.y - divider.frame.midY

    guard delta != 0 else { return }

    _ = try? tree.moveDivider(
      between: divider.leading, and: divider.trailing, by: delta, in: bounds.size)
    needsLayout = true
    layoutSubtreeIfNeeded()
    onLayoutChange?()
  }

  /// Moves a divider as a drag would, by points along its axis. Returns the distance it moved.
  @discardableResult
  func moveDivider(between leading: NodeID, and trailing: NodeID, by delta: CGFloat) throws
    -> CGFloat
  {
    let moved = try tree.moveDivider(
      between: leading, and: trailing, by: delta, in: bounds.size)
    needsLayout = true
    layoutSubtreeIfNeeded()
    onLayoutChange?()
    return moved
  }

  // MARK: Theme

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    for view in paneViews.values { view.apply(palette) }
    for view in dividerViews.values { view.apply(palette) }
  }
}
