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

/// The find actions a view's own find machinery would take. The pane takes them instead, so the
/// viewer's find bar answers and the system find pasteboard stays untouched.
enum BuiltInFindAction {
  case show
  case next
  case previous
  case useSelection

  /// Reads the `NSTextFinder.Action` tag a find menu item or `performFindPanelAction` carries.
  @MainActor
  init?(sender: Any?) {
    guard let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag else { return nil }

    switch NSTextFinder.Action(rawValue: tag) {
    case .showFindInterface?: self = .show
    case .nextMatch?: self = .next
    case .previousMatch?: self = .previous
    case .setSearchString?: self = .useSelection
    default: return nil
    }
  }
}

/// A PDF view that gives file drops to the pane instead of taking them.
final class DropThroughPDFView: PDFView {
  /// Called with an action the link policy refused, so the pane can say so.
  var onRefusedAction: ((PDFAction) -> Void)?

  /// Called for a find action sent down the responder chain.
  var onFindAction: ((BuiltInFindAction) -> Void)?

  @objc func performFindPanelAction(_ sender: Any?) {
    guard let action = BuiltInFindAction(sender: sender) else { return }

    onFindAction?(action)
  }

  override func performTextFinderAction(_ sender: Any?) {
    performFindPanelAction(sender)
  }

  /// Scrolls so `y` on `page` sits about a third of the way down the view. Going to the point
  /// itself puts it flush with the top edge, where it is clipped. With `clampedToPage`, a point near
  /// the top of the page shows the page top, so the reader sees the page from its start.
  func show(page: PDFPage, at y: CGFloat, clampedToPage: Bool) {
    let box = page.bounds(for: .cropBox)
    let margin = bounds.height * 0.33 / max(scaleFactor, 0.01)
    let top = clampedToPage ? min(y + margin, box.maxY) : y + margin

    go(to: PDFDestination(page: page, at: CGPoint(x: box.minX, y: top)))
  }

  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

  override func perform(_ action: PDFAction) {
    guard LinkPolicy.allows(action) else {
      onRefusedAction?(action)
      return
    }

    super.perform(action)
  }
}

/// Holds the document views. It reports each layout pass after its own subviews have a frame, so
/// the pane can place a restored anchor once the document view has a size.
final class BodyHostView: NSView {
  var onLayout: (() -> Void)?

  override func layout() {
    super.layout()
    onLayout?()
  }
}

/// A text view that gives file drops to the pane instead of taking them.
final class DropThroughTextView: NSTextView {
  /// Called for a find action sent down the responder chain.
  var onFindAction: ((BuiltInFindAction) -> Void)?

  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

  override func performFindPanelAction(_ sender: Any?) {
    guard let action = BuiltInFindAction(sender: sender) else { return }

    onFindAction?(action)
  }

  override func performTextFinderAction(_ sender: Any?) {
    performFindPanelAction(sender)
  }
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

  /// Called after each layout pass of the body, so the pane can place a restored anchor once the
  /// document view has a size.
  var onLayout: (() -> Void)? {
    get { bodyHost.onLayout }
    set { bodyHost.onLayout = newValue }
  }

  let pdfView = DropThroughPDFView()
  let scrollView = NSScrollView()
  let textView: DropThroughTextView
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(title: "Open\u{2026}", target: nil, action: nil)
  private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
  private(set) var markdownView: MarkdownView?
  private let messageStack = NSStackView()
  private(set) var body = TextViewerBody.message("", offersOpen: false, offersReload: false)

  let findBar = FindBarView()
  let sidebar = ContentsSidebarView()

  /// Holds the document views and the message. The find bar sits above it and the sidebar beside it.
  private let bodyHost = BodyHostView()
  private let mainColumn = NSStackView()
  private let layoutRow = NSStackView()

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

    bodyHost.translatesAutoresizingMaskIntoConstraints = false
    bodyHost.addSubview(pdfView)
    bodyHost.addSubview(scrollView)
    bodyHost.addSubview(messageStack)

    NSLayoutConstraint.activate([
      pdfView.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
      pdfView.topAnchor.constraint(equalTo: bodyHost.topAnchor),
      pdfView.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: bodyHost.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor),
      messageStack.centerXAnchor.constraint(equalTo: bodyHost.centerXAnchor),
      messageStack.centerYAnchor.constraint(equalTo: bodyHost.centerYAnchor),
      messageStack.leadingAnchor.constraint(
        greaterThanOrEqualTo: bodyHost.leadingAnchor, constant: 24),
      messageStack.trailingAnchor.constraint(
        lessThanOrEqualTo: bodyHost.trailingAnchor, constant: -24),
    ])

    findBar.translatesAutoresizingMaskIntoConstraints = false
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    sidebar.isHidden = true

    mainColumn.orientation = .vertical
    mainColumn.spacing = 0
    mainColumn.alignment = .leading
    mainColumn.distribution = .fill
    mainColumn.translatesAutoresizingMaskIntoConstraints = false
    mainColumn.addArrangedSubview(findBar)
    mainColumn.addArrangedSubview(bodyHost)

    layoutRow.orientation = .horizontal
    layoutRow.spacing = 0
    layoutRow.alignment = .top
    layoutRow.distribution = .fill
    layoutRow.translatesAutoresizingMaskIntoConstraints = false
    layoutRow.addArrangedSubview(sidebar)
    layoutRow.addArrangedSubview(mainColumn)

    addSubview(layoutRow)

    NSLayoutConstraint.activate([
      layoutRow.leadingAnchor.constraint(equalTo: leadingAnchor),
      layoutRow.trailingAnchor.constraint(equalTo: trailingAnchor),
      layoutRow.topAnchor.constraint(equalTo: topAnchor),
      layoutRow.bottomAnchor.constraint(equalTo: bottomAnchor),
      sidebar.heightAnchor.constraint(equalTo: layoutRow.heightAnchor),
      mainColumn.heightAnchor.constraint(equalTo: layoutRow.heightAnchor),
      findBar.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
      findBar.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
      bodyHost.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
      bodyHost.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
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

    bodyHost.addSubview(view, positioned: .below, relativeTo: messageStack)

    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
      view.topAnchor.constraint(equalTo: bodyHost.topAnchor),
      view.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor),
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
    findBar.apply(palette)
    sidebar.apply(palette)
  }

  /// Shows or hides the contents sidebar.
  func setSidebar(visible: Bool) {
    sidebar.isHidden = !visible
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
