import AppKit
import Theme

/// What a marker says about a tab. Each kind has one look and one meaning, so two applets cannot
/// word a kind differently. The declaration order is the order a slot draws the kinds in.
public enum AppletMarkerKind: String, Sendable, CaseIterable, Comparable {
  /// A granted controller's command to this tab would be accepted now.
  case authority

  /// A controller acts for this tab: its session is where a controller runs, or a driver drives
  /// it. The names of the controllers ride on the marker.
  case chip

  /// A run ended and left this tab, whose code may still run in it.
  case runEnded

  public static func < (lhs: Self, rhs: Self) -> Bool {
    allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
  }

  /// The SF Symbol the marker draws. The run-end kind draws a slash over the same symbol, since no
  /// slashed gear exists.
  public var symbolName: String {
    switch self {
    case .authority, .runEnded: return "gearshape.2.fill"
    case .chip: return "cpu"
    }
  }

  /// True when the kind draws a slash over its symbol.
  public var isSlashed: Bool { self == .runEnded }

  /// What the marker means, as its tooltip and the heading of its actions.
  public var meaning: String {
    switch self {
    case .authority: return "A controller can act on this tab"
    case .chip: return "A controller acts for this tab"
    case .runEnded: return "A finished run's code may still run in this tab"
    }
  }

  /// What VoiceOver reads for the marker.
  public var accessibilityLabel: String {
    switch self {
    case .authority: return "Controller can act on this tab"
    case .chip: return "Controller acts for this tab"
    case .runEnded: return "Finished run may still run in this tab"
    }
  }

  /// The actions the kind can offer, in menu order.
  public var possibleActions: [AppletMarkerAction] {
    switch self {
    case .authority, .chip: return []
    case .runEnded: return [.rebuildTab]
    }
  }
}

/// A thing a marker's kind lets the user do to its tab. A click on a marker never runs one. The
/// tab's menu offers them.
public enum AppletMarkerAction: String, Sendable, Hashable {
  case rebuildTab

  public var title: String {
    switch self {
    case .rebuildTab: return "Rebuild Tab"
    }
  }
}

/// One marker on a tab. It carries its kind and which of the kind's actions are available now.
/// Nothing an applet or a page supplies, such as a title, rides on it.
public struct AppletMarker: Sendable, Equatable {
  public let kind: AppletMarkerKind

  /// The kind's actions that can run now. Actions the kind does not have are dropped.
  public let actions: [AppletMarkerAction]

  /// The grants the marker stands for, as the host identified them. Only the authority kind has
  /// any.
  public let owners: Set<AppletCaller>

  /// What the host calls each controller the marker stands for, in the order it gave them. Only the
  /// chip has any. They are the names the pane's badge shows, passed through unchanged.
  public let controllers: [String]

  public init(
    kind: AppletMarkerKind, actions: [AppletMarkerAction] = [], owners: Set<AppletCaller> = [],
    controllers: [String] = []
  ) {
    self.kind = kind
    self.actions = kind.possibleActions.filter(actions.contains)
    self.owners = kind == .authority ? owners : []
    self.controllers = kind == .chip ? controllers : []
  }

  /// What the marker's tooltip says: its meaning, then a line for each controller it names.
  public var toolTip: String {
    ([kind.meaning] + controllers.map { "Controller: \($0)" }).joined(separator: "\n")
  }
}

/// The markers on one tab, one at most for each kind.
public struct AppletMarkerSet: Sendable, Equatable {
  private var byKind: [AppletMarkerKind: AppletMarker] = [:]

  public init(_ markers: [AppletMarker] = []) {
    for marker in markers { byKind[marker.kind] = marker }
  }

  /// The markers in the order a slot draws them: by kind.
  public var ordered: [AppletMarker] {
    byKind.values.sorted { $0.kind < $1.kind }
  }

  public var isEmpty: Bool { byKind.isEmpty }

  public subscript(kind: AppletMarkerKind) -> AppletMarker? { byKind[kind] }

  /// Puts the marker in, replacing any of its kind.
  public mutating func insert(_ marker: AppletMarker) {
    byKind[marker.kind] = marker
  }

  public mutating func remove(_ kind: AppletMarkerKind) {
    byKind[kind] = nil
  }
}

/// A marker's picture: its symbol in peach, with a slash drawn over it for the run-end kind. The
/// tab bar and the host's pane chrome both use it, so a marker looks the same in either place.
@MainActor
public final class AppletMarkerView: NSView {
  /// The smallest a marker draws. At 10 points the chip reads as a plain square.
  public static let symbolSize: CGFloat = 12

  /// The size of the view a marker draws in. The filled gears are 19 by 15 points at 12 points.
  public static let size = NSSize(width: 20, height: 16)

  public private(set) var marker: AppletMarker
  private var palette: ThemePalette

  /// True when a click passes to the view behind, so a marker in a tab selects the tab. A marker
  /// outside a tab swallows its click instead.
  public var forwardsClicks = true

  override public var isFlipped: Bool { true }

  override public var mouseDownCanMoveWindow: Bool { false }

  public var kind: AppletMarkerKind { marker.kind }

  public init(_ marker: AppletMarker, palette: ThemePalette = .latte) {
    self.marker = marker
    self.palette = palette
    super.init(frame: NSRect(origin: .zero, size: Self.size))

    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  public func configure(_ marker: AppletMarker) {
    guard marker != self.marker else { return }

    self.marker = marker
    refresh()
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette
    needsDisplay = true
  }

  private func refresh() {
    toolTip = marker.toolTip
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel(kind.accessibilityLabel)
    setAccessibilityValue(
      marker.controllers.isEmpty ? nil : marker.controllers.joined(separator: ", "))
    needsDisplay = true
  }

  override public func mouseDown(with event: NSEvent) {
    guard forwardsClicks else { return }

    super.mouseDown(with: event)
  }

  override public func draw(_ dirtyRect: NSRect) {
    Self.image(for: kind, color: palette[.peach].nsColor, size: bounds.size).draw(in: bounds)
  }

  /// The marker's picture at a size, in a color. The slash is cut out of the symbol with a gap,
  /// then drawn in the color, so it shows on any background.
  static func image(for kind: AppletMarkerKind, color: NSColor, size: NSSize) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
      .applying(.init(paletteColors: [color]))

    let symbol = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)

    return NSImage(size: size, flipped: true) { rect in
      let symbolRect = symbol.map {
        NSRect(
          x: (rect.width - $0.size.width) / 2, y: (rect.height - $0.size.height) / 2,
          width: $0.size.width, height: $0.size.height)
      }

      if let symbol, let symbolRect { symbol.draw(in: symbolRect) }

      guard kind.isSlashed else { return true }

      let span = (symbolRect ?? rect).insetBy(dx: 1.5, dy: 0.5)
      let slash = NSBezierPath()
      slash.move(to: NSPoint(x: span.minX, y: span.minY))
      slash.line(to: NSPoint(x: span.maxX, y: span.maxY))
      slash.lineCapStyle = .round

      NSGraphicsContext.current?.compositingOperation = .destinationOut
      slash.lineWidth = 3.5
      NSColor.black.setStroke()
      slash.stroke()

      NSGraphicsContext.current?.compositingOperation = .sourceOver
      slash.lineWidth = 1.5
      color.setStroke()
      slash.stroke()

      return true
    }
  }
}
