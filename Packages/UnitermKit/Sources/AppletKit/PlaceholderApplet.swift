import AppKit
import Theme

/// Stands in for an applet whose saved description could not be restored: unknown type, newer
/// version, or unreadable bytes.
///
/// It runs nothing. It keeps the exact bytes the layout file held and returns them as its
/// description, so saving the layout writes the pane back unchanged and a build that understands it
/// can still restore it.
@MainActor
public final class PlaceholderApplet: Applet {
  public let typeID = "placeholder"
  public let view: NSView
  public let title = "Unavailable pane"
  public let segments: [AppletSegment] = []
  public let isRunningSomething = false
  public weak var host: (any AppletHost)?

  public let publishedTabs: AppletTabList

  private let kept: AppletDescription
  private let reason: String
  private let panel: PlaceholderView

  /// `kept` carries the file bytes to write back. `reason` says why the pane could not be restored.
  public init(keeping kept: AppletDescription, reason: String) {
    self.kept = kept
    self.reason = reason
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: "Unavailable pane"))

    let panel = PlaceholderView(reason: reason, detail: Self.detail(of: kept))
    self.panel = panel
    view = panel
  }

  public func start(origin: StartOrigin) {}
  public func close() {}

  public func focus() {
    view.window?.makeFirstResponder(view)
  }

  public func describe() -> AppletDescription {
    kept
  }

  public func apply(_ palette: ThemePalette) {
    panel.apply(palette)
  }

  private static func detail(of description: AppletDescription) -> String {
    description.type.isEmpty ? "" : "Saved as \u{201C}\(description.type)\u{201D}"
  }
}

@MainActor
private final class PlaceholderView: NSView {
  private let heading = NSTextField(labelWithString: "This pane could not be restored")
  private let reasonLabel: NSTextField
  private let detailLabel: NSTextField
  private let stack = NSStackView()

  override var isFlipped: Bool { true }

  override var acceptsFirstResponder: Bool { true }

  init(reason: String, detail: String) {
    reasonLabel = NSTextField(wrappingLabelWithString: reason)
    detailLabel = NSTextField(labelWithString: detail)

    super.init(frame: .zero)

    wantsLayer = true

    heading.font = .systemFont(ofSize: 13, weight: .semibold)
    heading.alignment = .center
    reasonLabel.font = .systemFont(ofSize: 12)
    reasonLabel.alignment = .center
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.alignment = .center

    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(heading)
    stack.addArrangedSubview(reasonLabel)
    stack.addArrangedSubview(detailLabel)
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("placeholder-pane")
    apply(.latte)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(_ palette: ThemePalette) {
    layer?.backgroundColor = palette[.base].cgColor
    heading.textColor = palette[.text].nsColor
    reasonLabel.textColor = palette[.subtext1].nsColor
    detailLabel.textColor = palette[.subtext0].nsColor
  }
}
