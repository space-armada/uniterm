import AppKit
import Theme

/// One tab in the bar: a title, its markers, and a control that closes it.
@MainActor
final class AppletTabItem: NSView {
  private let label = NSTextField(labelWithString: "")
  private let closeButton = NSButton()
  private var markerViews: [AppletMarkerView] = []
  private var palette: ThemePalette = .latte

  /// The markers the tab shows between its title and its close button, in kind order. They sit in
  /// a region the title cannot reach, so a title cannot imitate one.
  var markers: [AppletMarker] = [] {
    didSet {
      guard markers != oldValue else { return }

      syncMarkerViews()
      needsLayout = true
    }
  }

  var index = 0 {
    didSet { refreshAccessibility() }
  }

  var title = "" {
    didSet {
      label.stringValue = title
      refreshAccessibility()
    }
  }

  var isSelected = false {
    didSet { refresh() }
  }

  var onSelect: (() -> Void)?
  var onClose: (() -> Void)?

  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true
    layer?.cornerRadius = 5

    label.lineBreakMode = .byTruncatingTail
    label.font = .systemFont(ofSize: 12)
    label.setAccessibilityElement(false)
    addSubview(label)

    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
    closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    closeButton.imagePosition = .imageOnly
    closeButton.isBordered = false
    closeButton.target = self
    closeButton.action = #selector(closeClicked(_:))
    addSubview(closeButton)

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    super.layout()

    let side: CGFloat = 16
    closeButton.frame = NSRect(
      x: bounds.maxX - side - 6, y: (bounds.height - side) / 2, width: side, height: side)

    var slotEdge = closeButton.frame.minX

    for view in markerViews.reversed() {
      let size = AppletMarkerView.size
      slotEdge -= size.width + Self.markerGap
      view.frame = NSRect(
        x: slotEdge, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    let height = label.intrinsicContentSize.height
    label.frame = NSRect(
      x: 10, y: (bounds.height - height) / 2, width: max(0, slotEdge - 14), height: height)
  }

  private static let markerGap: CGFloat = 2

  private func syncMarkerViews() {
    while markerViews.count > markers.count {
      markerViews.removeLast().removeFromSuperview()
    }

    while markerViews.count < markers.count {
      let view = AppletMarkerView(markers[markerViews.count], palette: palette)
      addSubview(view)
      markerViews.append(view)
    }

    for (view, marker) in zip(markerViews, markers) {
      view.configure(marker)
    }

    refreshAccessibility()
  }

  override func mouseDown(with event: NSEvent) {
    onSelect?()
  }

  var markerFrames: [NSRect] { markerViews.map(\.frame) }

  override func accessibilityPerformPress() -> Bool {
    onSelect?()
    return true
  }

  @objc private func closeClicked(_ sender: Any?) {
    onClose?()
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    refresh()
  }

  private func refresh() {
    layer?.backgroundColor = isSelected ? palette[.base].cgColor : NSColor.clear.cgColor
    label.textColor = (isSelected ? palette[.text] : palette[.subtext0]).nsColor
    closeButton.contentTintColor = palette[.overlay1].nsColor

    for view in markerViews { view.apply(palette) }

    refreshAccessibility()
  }

  private func refreshAccessibility() {
    setAccessibilityIdentifier("tab-\(index)")
    setAccessibilityLabel(title)
    setAccessibilityValue(isSelected ? "selected" : "unselected")
    closeButton.setAccessibilityIdentifier("tab-close-\(index)")
    closeButton.setAccessibilityLabel("Close \(title)")

    for (view, marker) in zip(markerViews, markers) {
      view.setAccessibilityIdentifier("tab-\(index)-marker-\(marker.kind.rawValue)")
    }
  }
}

/// The strip of tabs above an applet's content. It hides itself below two tabs, by the rule every
/// applet shares. When the tabs do not fit it scrolls sideways, and it shows a fade at each edge
/// that has more tabs past it.
@MainActor
public final class AppletTabBar: NSView {
  public static let height: CGFloat = 28

  private static let gap: CGFloat = 2
  private static let inset: CGFloat = 4
  private static let narrowest: CGFloat = 80
  private static let widest: CGFloat = 200
  private static let fadeWidth: CGFloat = 14

  private var items: [AppletTabItem] = []
  private let scrollView = AppletTabScrollView()
  private let strip = NSView()
  private let leadingFade = AppletTabBarFade(leading: true)
  private let trailingFade = AppletTabBarFade(leading: false)
  private let newButton = NSButton()
  private var palette: ThemePalette = .latte

  private var selectedIndex = 0
  private var shownCount = 0
  private var revealPending = false
  private var laidOutWidth: CGFloat = -1

  public var onSelect: ((Int) -> Void)?
  public var onClose: ((Int) -> Void)?
  public var onNew: (() -> Void)?

  /// How far in from the trailing edge the host's control badge reaches. The tabs and the new-tab
  /// button stay clear of it, and the bar's background still runs under it.
  public var trailingReserve: CGFloat = 0 {
    didSet {
      guard trailingReserve != oldValue else { return }

      revealPending = true
      needsLayout = true
    }
  }

  override public var isFlipped: Bool { true }

  override public var mouseDownCanMoveWindow: Bool { false }

  override public init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true

    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = false
    scrollView.verticalScrollElasticity = .none
    scrollView.horizontalScrollElasticity = .allowed
    scrollView.borderType = .noBorder
    scrollView.documentView = strip
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.setAccessibilityElement(false)
    scrollView.onShiftScroll = { [weak self] delta in self?.scroll(by: delta) }
    addSubview(scrollView)
    addSubview(leadingFade)
    addSubview(trailingFade)

    NotificationCenter.default.addObserver(
      self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)

    newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
    newButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    newButton.imagePosition = .imageOnly
    newButton.isBordered = false
    newButton.target = self
    newButton.action = #selector(newClicked(_:))
    newButton.setAccessibilityIdentifier("new-tab")
    newButton.setAccessibilityLabel("New tab")
    addSubview(newButton)

    refreshColors()
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Shows one item for each tab, with its markers, and marks the selected one. The bar hides
  /// itself while it has fewer than two tabs. The new-tab control shows only when the applet can
  /// open a tab. A selection that changed, or a tab that opened, scrolls the selected tab into
  /// view.
  public func update(tabs: [AppletTab], selected: Int, canOpenTab: Bool) {
    while items.count > tabs.count {
      items.removeLast().removeFromSuperview()
    }

    while items.count < tabs.count {
      let item = AppletTabItem(frame: .zero)
      item.apply(palette)
      strip.addSubview(item)
      items.append(item)
    }

    for (index, item) in items.enumerated() {
      item.index = index
      item.title = tabs[index].title
      item.markers = tabs[index].markers.ordered
      item.isSelected = index == selected
      item.onSelect = { [weak self] in self?.onSelect?(index) }
      item.onClose = { [weak self] in self?.onClose?(index) }
    }

    if selected != selectedIndex || tabs.count != shownCount {
      revealPending = true
    }

    selectedIndex = selected
    shownCount = tabs.count
    isHidden = !AppletTabList.barShows(forTabCount: tabs.count)
    newButton.isHidden = !canOpenTab
    needsLayout = true
  }

  /// How far the tabs are scrolled in from the leading edge.
  var scrollOffset: CGFloat { scrollView.contentView.bounds.minX }

  /// The frame of a tab, in the bar's own coordinates, with the scroll applied.
  func frame(ofTab index: Int) -> NSRect {
    convert(items[index].frame, from: strip)
  }

  /// The visible part of the bar, in its own coordinates. Tabs and their markers show only here.
  var viewport: NSRect { scrollView.frame }

  var frameOfNewButton: NSRect { newButton.frame }

  func markerFrames(inTab index: Int) -> [NSRect] {
    items[index].markerFrames
  }

  var isLeadingFadeShowing: Bool { !leadingFade.isHidden }
  var isTrailingFadeShowing: Bool { !trailingFade.isHidden }

  /// Scrolls the tabs sideways by this much, as a wheel or a trackpad does.
  func scroll(by delta: CGFloat) {
    setScrollOffset(scrollOffset + delta)
  }

  override public func layout() {
    super.layout()

    let side: CGFloat = 22
    let trailing = newButton.isHidden ? 0 : side + Self.inset
    let viewportWidth = max(0, bounds.width - 2 * Self.inset - trailing - trailingReserve)
    let count = CGFloat(max(items.count, 1))
    let width = min(
      Self.widest, max(Self.narrowest, (viewportWidth - Self.gap * (count - 1)) / count))

    var x: CGFloat = 0
    let itemHeight = bounds.height - 6

    for item in items {
      item.frame = NSRect(x: x, y: 3, width: width, height: itemHeight)
      x += width + Self.gap
    }

    let contentWidth = max(0, x - Self.gap)

    scrollView.frame = NSRect(x: Self.inset, y: 0, width: viewportWidth, height: bounds.height)
    strip.frame = NSRect(x: 0, y: 0, width: max(contentWidth, viewportWidth), height: bounds.height)

    newButton.frame = NSRect(
      x: Self.inset + min(contentWidth + Self.gap, viewportWidth + Self.inset),
      y: (bounds.height - side) / 2, width: side, height: side)

    leadingFade.frame = NSRect(
      x: scrollView.frame.minX, y: 0, width: Self.fadeWidth, height: bounds.height)
    trailingFade.frame = NSRect(
      x: scrollView.frame.maxX - Self.fadeWidth, y: 0, width: Self.fadeWidth, height: bounds.height)

    let resized = bounds.width != laidOutWidth
    laidOutWidth = bounds.width

    if revealPending || resized {
      revealPending = false
      revealSelected()
    }

    setScrollOffset(scrollOffset)
    refreshFades()
  }

  /// Scrolls the selected tab fully into view, clear of the fade at an edge that has more tabs
  /// past it.
  private func revealSelected() {
    guard items.indices.contains(selectedIndex) else { return }

    let item = items[selectedIndex].frame
    let width = scrollView.frame.width
    var offset = scrollOffset

    let leadingMargin = selectedIndex > 0 ? Self.fadeWidth : 0
    let trailingMargin = selectedIndex < items.count - 1 ? Self.fadeWidth : 0

    if item.maxX + trailingMargin > offset + width {
      offset = item.maxX + trailingMargin - width
    }

    if item.minX - leadingMargin < offset {
      offset = item.minX - leadingMargin
    }

    setScrollOffset(offset)
  }

  private func setScrollOffset(_ offset: CGFloat) {
    let limit = max(0, strip.frame.width - scrollView.frame.width)
    let clamped = min(max(0, offset), limit)

    guard clamped != scrollView.contentView.bounds.minX else { return }

    scrollView.contentView.scroll(to: NSPoint(x: clamped, y: 0))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func refreshFades() {
    let limit = strip.frame.width - scrollView.frame.width

    leadingFade.isHidden = scrollOffset <= 0.5
    trailingFade.isHidden = scrollOffset >= limit - 0.5
  }

  @objc private func scrolled(_ note: Notification) {
    refreshFades()
  }

  @objc private func newClicked(_ sender: Any?) {
    onNew?()
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette

    for item in items { item.apply(palette) }

    refreshColors()
  }

  private func refreshColors() {
    layer?.backgroundColor = palette[.mantle].cgColor
    newButton.contentTintColor = palette[.overlay1].nsColor
    leadingFade.color = palette[.mantle].nsColor
    trailingFade.color = palette[.mantle].nsColor
  }
}

/// The scroll view behind the tabs. A trackpad's sideways swipe scrolls it as AppKit does. A wheel
/// turned with Shift held has no sideways part, so it scrolls the tabs by its up and down part.
@MainActor
private final class AppletTabScrollView: NSScrollView {
  var onShiftScroll: ((CGFloat) -> Void)?

  override func scrollWheel(with event: NSEvent) {
    guard event.modifierFlags.contains(.shift), event.scrollingDeltaX == 0,
      event.scrollingDeltaY != 0
    else { return super.scrollWheel(with: event) }

    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10

    onShiftScroll?(-delta)
  }
}

/// A gradient over one edge of the scrolling tabs. It says that more tabs lie past that edge, and
/// it never takes a click.
@MainActor
private final class AppletTabBarFade: NSView {
  private let gradient = CAGradientLayer()
  private let leading: Bool

  var color: NSColor = .clear {
    didSet { refresh() }
  }

  init(leading: Bool) {
    self.leading = leading
    super.init(frame: .zero)

    wantsLayer = true
    isHidden = true
    gradient.startPoint = CGPoint(x: leading ? 0 : 1, y: 0.5)
    gradient.endPoint = CGPoint(x: leading ? 1 : 0, y: 0.5)
    layer?.addSublayer(gradient)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()

    gradient.frame = bounds
  }

  private func refresh() {
    gradient.colors = [color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0).cgColor]
  }
}
