import AppKit
import Theme

/// The strip a REPL shows at the bottom of its pane while its helper is suspended. It says so, and
/// that page code keeps running, and offers Resume. The terminal above it still scrolls and
/// selects, and takes no input.
@MainActor
final class ReplSuspendedView: NSView {
  static let minimumHeight: CGFloat = 48

  private static let buttonMinimumWidth: CGFloat = 80
  private static let sideInset: CGFloat = 12

  private let label = NSTextField(wrappingLabelWithString: "")
  private let button = NSButton()

  var onResume: (() -> Void)?

  var message = "" {
    didSet {
      label.stringValue = message
      label.toolTip = message
    }
  }

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true

    label.font = .systemFont(ofSize: 12)
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.setAccessibilityIdentifier("repl-suspended-message")

    button.title = "Resume"
    button.bezelStyle = .rounded
    button.target = self
    button.action = #selector(resumePressed(_:))
    button.setAccessibilityIdentifier("repl-resume-button")

    addSubview(label)
    addSubview(button)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("repl-suspended")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// The height the strip needs at this width. The message wraps instead of cutting, since every
  /// suspension display must say that page code keeps running.
  func height(for width: CGFloat) -> CGFloat {
    let buttonWidth = max(button.fittingSize.width, Self.buttonMinimumWidth)
    let textWidth = max(40, width - buttonWidth - 3 * Self.sideInset)
    let cell = label.cell
    let needed =
      cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 0

    return max(Self.minimumHeight, needed + 16)
  }

  override func layout() {
    super.layout()

    let buttonSize = button.fittingSize
    let buttonWidth = max(buttonSize.width, 80)

    button.frame = NSRect(
      x: bounds.width - buttonWidth - 12, y: (bounds.height - buttonSize.height) / 2,
      width: buttonWidth, height: buttonSize.height)

    let width = max(0, button.frame.minX - 24)

    label.preferredMaxLayoutWidth = width

    let labelHeight = min(bounds.height - 4, label.fittingSize.height)

    label.frame = NSRect(
      x: 12, y: (bounds.height - labelHeight) / 2, width: width, height: labelHeight)
  }

  func apply(_ palette: ThemePalette) {
    layer?.backgroundColor = palette[.mantle].cgColor
    label.textColor = palette[.text].nsColor
  }

  /// Presses the button as the user would.
  func resume() {
    onResume?()
  }

  @objc private func resumePressed(_ sender: Any?) {
    resume()
  }
}
