import AppKit
import BrowserModel
import Theme

/// One JavaScript alert, confirmation, or text prompt that waits for the user. WebKit gives the
/// page's script no answer until the completion handler runs, and it must run exactly once, so the
/// dialog owns the handler and answers it through `answer`, whichever path gets there first.
@MainActor
final class PageDialog {
  enum Kind: Equatable {
    case alert
    case confirm
    case prompt(defaultText: String)
  }

  enum Answer: Equatable {
    /// The user closed it, or the browser did: a close, a bound, a hidden pane that went away.
    case dismissed
    case accepted
    case text(String)
  }

  let kind: Kind

  /// The page's message, already cut and cleaned.
  let message: String

  /// Who asks: the host of the frame that called, cleaned.
  let source: String

  /// Whether the dialog offers to stop the page's later dialogs. The page's first dialog in a load
  /// offers nothing. Every later one does.
  let offersToStop: Bool

  weak var tab: BrowserTab?

  private var completion: (@MainActor (Answer) -> Void)?

  init(
    kind: Kind, message: String, source: String, tab: BrowserTab, offersToStop: Bool = false,
    completion: @escaping @MainActor (Answer) -> Void
  ) {
    self.kind = kind
    self.message = DialogText.bounded(message)
    self.source = AddressDisplay.bounded(source)
    self.tab = tab
    self.offersToStop = offersToStop
    self.completion = completion
  }

  var isAnswered: Bool { completion == nil }

  /// Answers WebKit, once. A second call does nothing.
  func answer(_ answer: Answer) {
    guard let completion else { return }

    self.completion = nil
    completion(answer)
  }
}

/// The dialogs a pane's pages have raised and the user has not answered, oldest first.
///
/// A dialog waits while its tab is not the selected one. The list is bounded, so a page that
/// raises dialogs in many frames cannot grow it without end. A dialog over the bound is dismissed
/// at once. The bound guards memory only. A page that keeps
/// asking is stopped by the user, through the offer on its second and later dialogs.
@MainActor
final class PageDialogs {
  /// The most dialogs held at once, across every tab. A policy value.
  static let heldLimit = 16

  private(set) var pending: [PageDialog] = []

  var isEmpty: Bool { pending.isEmpty }

  /// Holds `dialog`. False when the bound is full, and the dialog is already dismissed.
  @discardableResult
  func hold(_ dialog: PageDialog) -> Bool {
    guard pending.count < Self.heldLimit else {
      dialog.answer(.dismissed)
      return false
    }

    pending.append(dialog)
    return true
  }

  func first(for tab: BrowserTab) -> PageDialog? {
    pending.first { $0.tab === tab }
  }

  func settle(_ dialog: PageDialog, _ answer: PageDialog.Answer) {
    pending.removeAll { $0 === dialog }
    dialog.answer(answer)
  }

  /// Dismisses every dialog of `tab`, as a close of the tab does.
  func dismissAll(for tab: BrowserTab) {
    let mine = pending.filter { $0.tab === tab }

    pending.removeAll { $0.tab === tab }

    for dialog in mine { dialog.answer(.dismissed) }
  }

  /// Dismisses every dialog, as a close of the pane does.
  func dismissAll() {
    let all = pending

    pending = []

    for dialog in all { dialog.answer(.dismissed) }
  }
}

/// Shows one dialog over the page, inside the pane. It is not a window sheet, so no other pane
/// waits on it, and the pane's own tab bar and toolbar stay usable.
@MainActor
final class BrowserDialogView: NSView {
  let sourceLabel = NSTextField(wrappingLabelWithString: "")
  let messageLabel = NSTextField(wrappingLabelWithString: "")
  let field = NSTextField()
  let okButton = NSButton(title: "OK", target: nil, action: nil)
  let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  let stopButton = NSButton(
    title: "Don\u{2019}t show more from this page", target: nil, action: nil)

  private(set) var shown: PageDialog?

  /// The user answered the dialog on show.
  var onAnswer: (PageDialog, PageDialog.Answer) -> Void = { _, _ in }

  /// The user chose to stop the page's later dialogs. The dialog on show is answered as Cancel
  /// would answer it.
  var onStop: (PageDialog) -> Void = { _ in }

  private let card = NSView()
  private var palette = ThemePalette.latte

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true
    isHidden = true

    sourceLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    sourceLabel.setAccessibilityIdentifier("browser-dialog-source")

    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.isSelectable = true
    messageLabel.setAccessibilityIdentifier("browser-dialog-message")

    field.setAccessibilityIdentifier("browser-dialog-field")
    field.setAccessibilityLabel("Answer")

    okButton.bezelStyle = .rounded
    okButton.keyEquivalent = "\r"
    okButton.target = self
    okButton.action = #selector(accept)
    okButton.setAccessibilityIdentifier("browser-dialog-ok")

    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.setAccessibilityIdentifier("browser-dialog-cancel")

    stopButton.bezelStyle = .inline
    stopButton.target = self
    stopButton.action = #selector(stop)
    stopButton.setAccessibilityIdentifier("browser-dialog-stop")
    stopButton.setAccessibilityLabel("Don\u{2019}t show more dialogs from this page")
    stopButton.setAccessibilityHelp(
      "Dismisses this dialog and every later one from this page until it loads again.")
    stopButton.isHidden = true

    let buttons = NSStackView(views: [cancelButton, okButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8

    let stack = NSStackView(views: [sourceLabel, messageLabel, field, buttons, stopButton])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false

    card.wantsLayer = true
    card.layer?.cornerRadius = 10
    card.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)

    addSubview(card)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      field.widthAnchor.constraint(equalTo: stack.widthAnchor),
      messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      card.centerXAnchor.constraint(equalTo: centerXAnchor),
      card.centerYAnchor.constraint(equalTo: centerYAnchor),
      card.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
    ])

    setAccessibilityIdentifier("browser-dialog")
    setAccessibilityElement(true)
    setAccessibilityRole(.group)

    apply(palette)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  func show(_ dialog: PageDialog) {
    shown = dialog

    sourceLabel.stringValue = dialog.source.isEmpty ? "A page says" : "\(dialog.source) says"
    messageLabel.stringValue = dialog.message
    cancelButton.isHidden = dialog.kind == .alert
    stopButton.isHidden = !dialog.offersToStop

    if case .prompt(let defaultText) = dialog.kind {
      field.stringValue = DialogText.bounded(defaultText)
      field.isHidden = false
    } else {
      field.isHidden = true
    }

    setAccessibilityLabel(sourceLabel.stringValue + " " + dialog.message)
    isHidden = false
  }

  func hide() {
    shown = nil
    isHidden = true
  }

  /// What takes keyboard focus when the pane has it.
  var preferredResponder: NSView {
    shown.map { if case .prompt = $0.kind { return field } else { return okButton } } ?? okButton
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    layer?.backgroundColor = palette[.base].nsColor.withAlphaComponent(0.7).cgColor
    card.layer?.backgroundColor = palette[.mantle].cgColor
    sourceLabel.textColor = palette[.text].nsColor
    messageLabel.textColor = palette[.subtext1].nsColor
  }

  @objc func accept() {
    guard let shown else { return }

    if case .prompt = shown.kind {
      onAnswer(shown, .text(field.stringValue))
    } else {
      onAnswer(shown, .accepted)
    }
  }

  @objc func stop() {
    guard let shown, shown.offersToStop else { return }

    onStop(shown)
  }

  @objc func cancel() {
    guard let shown else { return }

    onAnswer(shown, .dismissed)
  }
}
