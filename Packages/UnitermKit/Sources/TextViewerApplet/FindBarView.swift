import AppKit
import TextViewerModel
import Theme

/// The viewer's one find bar: the query, a line about the matches, and next, previous, and close.
///
/// The field keeps its query in the pane. It has no autosave name for its recents and nothing here
/// touches the system find pasteboard.
@MainActor
final class FindBarView: NSView, NSSearchFieldDelegate {
  let field = NSSearchField()
  let countLabel = NSTextField(labelWithString: "")
  private let previousButton = NSButton()
  private let nextButton = NSButton()
  private let closeButton = NSButton(title: "Done", target: nil, action: nil)

  /// The query changed, whether by typing or by the pane setting it.
  var onQuery: ((String) -> Void)?

  /// Return or a button asks for the next match, Shift-Return or a button for the previous.
  var onStep: ((Bool) -> Void)?

  /// Escape or Done closes the bar.
  var onClose: (() -> Void)?

  init() {
    super.init(frame: .zero)

    setAccessibilityIdentifier("text-viewer-find-bar")

    field.placeholderString = "Find in document"
    field.sendsWholeSearchString = false
    field.sendsSearchStringImmediately = true
    field.target = self
    field.action = #selector(queryChanged)
    field.delegate = self
    field.setAccessibilityIdentifier("text-viewer-find")

    countLabel.font = .systemFont(ofSize: 11)
    countLabel.alignment = .right
    countLabel.setContentHuggingPriority(.required, for: .horizontal)
    countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    countLabel.setAccessibilityIdentifier("text-viewer-find-count")

    configure(previousButton, symbol: "chevron.up", label: "Previous match", id: "previous")
    configure(nextButton, symbol: "chevron.down", label: "Next match", id: "next")
    previousButton.action = #selector(previousPressed)
    nextButton.action = #selector(nextPressed)

    closeButton.bezelStyle = .rounded
    closeButton.controlSize = .small
    closeButton.target = self
    closeButton.action = #selector(closePressed)
    closeButton.setAccessibilityIdentifier("text-viewer-find-close")

    let row = NSStackView(views: [field, countLabel, previousButton, nextButton, closeButton])
    row.orientation = .horizontal
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    row.translatesAutoresizingMaskIntoConstraints = false

    addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
    ])

    isHidden = true
    update(FindState())
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configure(_ button: NSButton, symbol: String, label: String, id: String) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.bezelStyle = .texturedRounded
    button.isBordered = true
    button.controlSize = .small
    button.target = self
    button.setAccessibilityLabel(label)
    button.setAccessibilityIdentifier("text-viewer-find-\(id)")
  }

  var query: String {
    get { field.stringValue }
    set { field.stringValue = newValue }
  }

  /// Opens the bar, puts the keyboard in the field, and selects the query so typing replaces it.
  func open() {
    isHidden = false
    window?.makeFirstResponder(field)
    field.selectText(nil)
  }

  /// Shows the bar without taking the keyboard, as Use Selection for Find does.
  func reveal() {
    isHidden = false
  }

  func close() {
    isHidden = true
    field.stringValue = ""
  }

  func update(_ state: FindState) {
    countLabel.stringValue = state.status
    countLabel.isHidden = state.status.isEmpty
    previousButton.isEnabled = state.hasMatch
    nextButton.isEnabled = state.hasMatch
  }

  func apply(_ palette: ThemePalette) {
    countLabel.textColor = palette.secondaryText.nsColor
    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
  }

  @objc private func queryChanged() {
    onQuery?(field.stringValue)
  }

  @objc private func previousPressed() { onStep?(false) }

  @objc private func nextPressed() { onStep?(true) }

  @objc private func closePressed() { onClose?() }

  /// Return steps to the next match, Shift-Return to the previous one, and Escape closes the bar.
  /// Both return true so the field does not also send its own action.
  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    guard control === field else { return false }

    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
      return true

    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true

    default:
      return false
    }
  }
}
