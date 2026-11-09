import AppKit
import PDFKit
import Theme

/// What the pane shows now.
enum TextViewerBody: Equatable {
  /// A message in place of a document. It may offer the Open button, or the Reload button for a
  /// page that stopped.
  case message(String, offersOpen: Bool, offersReload: Bool)
  case pdf
  case text
  case markdown
}

/// A PDF view that gives file drops to the pane instead of taking them.
final class DropThroughPDFView: PDFView {
  /// Called with an action the link policy refused, so the pane can say so.
  var onRefusedAction: ((PDFAction) -> Void)?

  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

  override func perform(_ action: PDFAction) {
    guard LinkPolicy.allows(action) else {
      onRefusedAction?(action)
      return
    }

    super.perform(action)
  }
}

/// A text view that gives file drops to the pane instead of taking them.
final class DropThroughTextView: NSTextView {
  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
}

/// The viewer's body: a PDF view, a text view in a scroll view, and a message that stands in for
/// them. It takes a dropped file anywhere in the pane, the PDF and the text included.
///
/// The text view uses TextKit 1, since only that layout draws `NSTextTable`. Its built-in find bar
/// and find panel are off. The pane owns find.
@MainActor
final class TextViewerView: NSView {
  var onOpen: (() -> Void)?
  var onReload: (() -> Void)?

  /// Gets the dropped files. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  /// Called after each layout pass, so the pane can place a restored anchor once the view has a size.
  var onLayout: (() -> Void)?

  let pdfView = DropThroughPDFView()
  let scrollView = NSScrollView()
  let textView: DropThroughTextView
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(title: "Open\u{2026}", target: nil, action: nil)
  private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
  private(set) var markdownView: MarkdownView?
  private let messageStack = NSStackView()
  private(set) var body = TextViewerBody.message("", offersOpen: false, offersReload: false)

  override var isFlipped: Bool { true }

  init() {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    layout.allowsNonContiguousLayout = true
    storage.addLayoutManager(layout)

    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)

    textView = DropThroughTextView(frame: .zero, textContainer: container)

    super.init(frame: .zero)

    wantsLayer = true
    registerForDraggedTypes([.fileURL])
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("text-viewer")

    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displaysPageBreaks = true
    pdfView.isHidden = true
    pdfView.translatesAutoresizingMaskIntoConstraints = false
    pdfView.setAccessibilityIdentifier("text-viewer-pdf")
    pdfView.unregisterDraggedTypes()

    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.usesFindBar = false
    textView.usesFindPanel = false
    textView.isIncrementalSearchingEnabled = false
    textView.allowsUndo = false
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 24, height: 20)
    textView.setAccessibilityIdentifier("text-viewer-text")
    textView.unregisterDraggedTypes()

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = true
    scrollView.isHidden = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.setAccessibilityIdentifier("text-viewer-scroll")

    messageLabel.alignment = .center
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.maximumNumberOfLines = 0
    messageLabel.setAccessibilityIdentifier("text-viewer-message")

    openButton.bezelStyle = .rounded
    openButton.target = self
    openButton.action = #selector(openPressed)
    openButton.setAccessibilityIdentifier("text-viewer-open")

    reloadButton.bezelStyle = .rounded
    reloadButton.target = self
    reloadButton.action = #selector(reloadPressed)
    reloadButton.setAccessibilityIdentifier("text-viewer-reload")

    messageStack.orientation = .vertical
    messageStack.alignment = .centerX
    messageStack.spacing = 12
    messageStack.translatesAutoresizingMaskIntoConstraints = false
    messageStack.addArrangedSubview(messageLabel)
    messageStack.addArrangedSubview(openButton)
    messageStack.addArrangedSubview(reloadButton)

    addSubview(pdfView)
    addSubview(scrollView)
    addSubview(messageStack)

    NSLayoutConstraint.activate([
      pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
      pdfView.topAnchor.constraint(equalTo: topAnchor),
      pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
      messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      messageStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
    ])

    show(.message("", offersOpen: false, offersReload: false))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func show(_ body: TextViewerBody) {
    self.body = body

    pdfView.isHidden = body != .pdf
    scrollView.isHidden = body != .text
    markdownView?.isHidden = body != .markdown

    if case .message(let text, let offersOpen, let offersReload) = body {
      messageStack.isHidden = false
      messageLabel.stringValue = text
      messageLabel.isHidden = text.isEmpty
      openButton.isHidden = !offersOpen
      reloadButton.isHidden = !offersReload
    } else {
      messageStack.isHidden = true
    }
  }

  /// Takes the Markdown page out and ends its web content process.
  func removeMarkdown() {
    markdownView?.close()
    markdownView?.removeFromSuperview()
    markdownView = nil
  }

  /// Puts the Markdown page in the pane. The web view is built when the first Markdown document
  /// opens, so a PDF or RTF pane never starts a web content process.
  func install(markdown view: MarkdownView) {
    markdownView?.removeFromSuperview()
    markdownView = view

    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = body != .markdown

    addSubview(view, positioned: .below, relativeTo: messageStack)

    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trailingAnchor),
      view.topAnchor.constraint(equalTo: topAnchor),
      view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func focusBody() {
    switch body {
    case .pdf: window?.makeFirstResponder(pdfView)
    case .text: window?.makeFirstResponder(textView)
    case .markdown: markdownView?.focusPage()
    case .message: break
    }
  }

  /// A document is laid out for paper, so its page stays white and keeps its own text colors. The
  /// theme colors the surround and the messages.
  func apply(_ palette: ThemePalette) {
    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
    layer?.backgroundColor = palette[.base].cgColor
    scrollView.backgroundColor = palette[.mantle].nsColor
    textView.backgroundColor = .white
    pdfView.backgroundColor = palette[.mantle].nsColor
    messageLabel.textColor = palette.secondaryText.nsColor
    markdownView?.apply(palette)
  }

  override func layout() {
    super.layout()
    onLayout?()
  }

  @objc private func openPressed() {
    onOpen?()
  }

  @objc private func reloadPressed() {
    onReload?()
  }

  // MARK: Drop

  private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
    let objects = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])

    return (objects as? [URL]) ?? []
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    droppedFiles(sender).isEmpty ? [] : .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    onDrop?(droppedFiles(sender)) ?? false
  }
}
