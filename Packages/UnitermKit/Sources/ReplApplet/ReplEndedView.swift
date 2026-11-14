import AppKit
import Theme

/// The strip a REPL shows at the bottom of its pane after its helper has gone. It says why, and
/// offers a restart that only the user can press. The helper's last output stays visible above it.
@MainActor
final class ReplEndedView: NSView {
  static let height: CGFloat = 40

  private let label = NSTextField(labelWithString: "")
  private let button = NSButton()

  var onRestart: (() -> Void)?

  var message = "" {
    didSet { label.stringValue = message }
  }

  /// The Restart button, so the applet can give it the keyboard.
  var restartButton: NSView { button }

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true

    label.font = .systemFont(ofSize: 12)
    label.lineBreakMode = .byTruncatingTail
    label.setAccessibilityIdentifier("repl-ended-message")

    button.title = "Restart"
    button.bezelStyle = .rounded
    button.target = self
    button.action = #selector(restartPressed(_:))
    button.setAccessibilityIdentifier("repl-restart-button")

    addSubview(label)
    addSubview(button)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("repl-ended")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    super.layout()

    let buttonSize = button.fittingSize
    let buttonWidth = max(buttonSize.width, 80)

    button.frame = NSRect(
      x: bounds.width - buttonWidth - 12, y: (bounds.height - buttonSize.height) / 2,
      width: buttonWidth, height: buttonSize.height)

    let labelHeight = label.fittingSize.height

    label.frame = NSRect(
      x: 12, y: (bounds.height - labelHeight) / 2,
      width: max(0, button.frame.minX - 24), height: labelHeight)
  }

  func apply(_ palette: ThemePalette) {
    layer?.backgroundColor = palette[.mantle].cgColor
    label.textColor = palette[.text].nsColor
  }

  /// Presses the button as the user would.
  func restart() {
    onRestart?()
  }

  @objc private func restartPressed(_ sender: Any?) {
    restart()
  }
}
