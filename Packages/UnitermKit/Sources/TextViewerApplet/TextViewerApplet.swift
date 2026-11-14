import AppKit
import AppletKit
import BrowserApplet
import DocumentWire
import FileWatching
import HelperHost
import PDFKit
import SourceAccess
import StatusKit
@_exported import TextViewerModel
import Theme
import UniformTypeIdentifiers

/// Shows one PDF, RTF, or Word document, read-only.
///
/// Every load goes through `replaceSource`. The open panel, a drop, the router, and a restore all
/// reach the same path, which finds the file off the main thread. A PDF reads in full off the main
/// thread and parses in the app, as ADR-07 allows when isolation is not possible. RTF and Word
/// parse only in a sandboxed helper that the pane starts for the load and ends with it.
///
/// The description holds the file's path, bookmark, and view anchor, never the file's contents.
/// `describe()` reads memory only.
///
/// The pane watches the file it shows and reloads when it changes. A reload runs the same load as
/// an open and swaps in only when that load succeeds, so a file that fails to parse leaves the
/// last good render on screen. A file caught half written can still parse, and the next write
/// reloads again. A reload reads the stored path alone and never follows the bookmark, since
/// an editor's save can move the path away for a moment.
@MainActor
public final class TextViewerApplet: Applet, SourceReplacing {
  public let typeID = TextViewerDescription.typeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public private(set) var title = TextViewerApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  private static let untitled = "Text viewer"

  let content: TextViewerView
  let finder: FindCoordinator

  /// The contents the shown document carries. The sidebar lists it.
  private(set) var contents = Contents.empty
  private var record: TextViewerDescription
  private var opening: Task<Void, Never>?
  private var openGeneration = 0
  private var job: DocumentHelperJob?
  private var resolvedNotice: String?
  private var posted = AppletNotices()
  private var alerts = AppletAlerts()
  private var loadOrigin = LoadOrigin.user
  private var restoreWaitsForStart: Bool
  private var describesFromRecord: Bool

  /// The watch on the shown file, and the path it follows. The watch is made once a load finds the
  /// file, so it follows the path a restore found through the bookmark.
  private var watcher: FileWatcher?
  private var watchedPath: String?

  /// What the watch last saw of the path. A load that finishes after the file went away must not
  /// clear the Moved or deleted segment.
  private var watchedExists = true
  private var fileGone = false

  /// True while a load that began as a reload has a render to keep. A failure then leaves the render
  /// in place and posts a warning.
  private var keepsRender = false
  private var reloadNotice: String?

  /// A change that arrived while a load ran. The load's end starts one more reload, so a file that
  /// is rewritten without pause is never starved by loads that each get cancelled. The last write
  /// is always the one shown.
  private var reloadQueued = false

  /// The latest change that arrived while the pane was detached, held for reattach.
  private var heldChange: FileSignature?

  /// How the watch merges events. Tests shorten the windows.
  var watchPolicy = WatchPolicy.document

  /// False from the moment a document shows until its anchor is back in place, so a layout save
  /// in between describes the anchor it restores, not the top of the page.
  private var anchorApplied = true
  private var pendingAnchor: TextViewerAnchor?

  /// A PDF shown with no anchor starts at the top of the document. PDFKit does not put a document
  /// there on its own. Which scroll position it picks depends on whether the view already had a size
  /// when the document arrived, so a restore and a fresh open could differ.
  private var scrollsToTop = false
  private var closed = false
  private var palette = ThemePalette.latte
  private var pageObserver: (any NSObjectProtocol)?
  private let links: LinkHandler
  private let settings: DocumentHelperSettings
  private let opener: any URLOpening

  /// The message the pane shows now, for tests.
  private(set) var messageText: String?

  /// How many helper processes this pane has started. A PDF pane starts none.
  private(set) var helperStarts = 0

  /// The helper decoding now, if one is.
  var activeHelperProcessID: pid_t? { job?.processID }

  /// How many characters the shown RTF or Word document holds.
  private var textLength: Int?

  /// An empty pane that starts in `startDirectory`. The directory is explicit, and the applet never
  /// reads it from another pane.
  public convenience init(startDirectory: String?) {
    self.init(
      startDirectory: startDirectory, settings: .bundled, opener: WorkspaceURLOpener())
  }

  /// Restores a pane from its description. The file is found and read when the pane starts, so
  /// restoring touches nothing on disk. A description this build cannot read is refused.
  public convenience init(restoring description: AppletDescription) throws {
    try self.init(
      restoring: description, settings: .bundled, opener: WorkspaceURLOpener())
  }

  init(startDirectory: String?, settings: DocumentHelperSettings, opener: any URLOpening) {
    record = TextViewerDescription(startDirectory: startDirectory)
    restoreWaitsForStart = false
    describesFromRecord = false
    self.settings = settings
    self.opener = opener

    content = TextViewerView()
    finder = FindCoordinator(content: content)
    links = LinkHandler(opener: opener)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    showMessage(Self.emptyText, offersOpen: true)
    refresh()
  }

  init(
    restoring description: AppletDescription, settings: DocumentHelperSettings,
    opener: any URLOpening
  ) throws {
    record = try TextViewerDescription.decode(description)
    restoreWaitsForStart = record.path != nil
    describesFromRecord = true
    self.settings = settings
    self.opener = opener

    content = TextViewerView()
    finder = FindCoordinator(content: content)
    links = LinkHandler(opener: opener)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    showMessage(
      record.path == nil ? Self.emptyText : "Opening\u{2026}", offersOpen: record.path == nil)
    refresh()
  }

  /// The factory behind the router and the launcher: a pane that starts in `startDirectory` and
  /// opens `file`.
  public static func opening(_ file: URL, startDirectory: String) throws -> TextViewerApplet {
    let applet = TextViewerApplet(startDirectory: startDirectory)
    try applet.replaceSource(with: file, startDirectory: startDirectory)

    return applet
  }

  public var view: NSView { content }

  public var currentDirectory: String? {
    if let path = record.path {
      let folder = (path as NSString).deletingLastPathComponent

      if Self.isDirectory(folder) { return folder }
    }

    if let start = record.startDirectory, Self.isDirectory(start) { return start }

    return nil
  }

  public var openPanelContentTypes: [UTType]? { TextFormatRule.openPanelTypes }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false

    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func wire() {
    content.onOpen = { [weak self] in self?.showOpenPanel() }
    content.onReload = { [weak self] in self?.reload() }
    content.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
    content.onLayout = { [weak self] in self?.applyPendingAnchor() }
    content.textView.delegate = links
    content.pdfView.delegate = links
    content.setSidebar(visible: false)

    content.findBar.onQuery = { [weak self] query in self?.finder.queryChanged(query) }
    content.findBar.onStep = { [weak self] forward in self?.finder.step(forward: forward) }
    content.findBar.onClose = { [weak self] in self?.closeFind() }
    content.sidebar.onSelect = { [weak self] entry in self?.go(to: entry) }

    let builtIn: (BuiltInFindAction) -> Void = { [weak self] action in self?.perform(action) }

    content.textView.onFindAction = builtIn
    content.pdfView.onFindAction = builtIn

    links.onRefused = { [weak self] url in
      guard let self else { return }

      alerts.deliver(
        .warning,
        "uniterm opens only http, https, and mailto links. It did not open \(url.absoluteString).",
        from: self, to: host)
    }

    content.pdfView.onRefusedAction = { [weak self] _ in
      guard let self else { return }

      alerts.deliver(
        .warning, "uniterm did not run a link in this PDF that leaves the document.", from: self,
        to: host)
    }

    pageObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewPageChanged, object: content.pdfView, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  // MARK: Source

  /// Shows `file` in place of what the pane shows. The load before it stops. Nothing here touches
  /// the disk, so a missing or unreadable file shows its message in the pane.
  public func replaceSource(with file: URL, startDirectory: String) throws {
    record = TextViewerDescription(
      startDirectory: startDirectory, path: file.path, sidebarShown: record.sidebarShown)
    describesFromRecord = false
    restoreWaitsForStart = false

    open(path: file.path, bookmark: nil, anchor: nil, origin: .user)
  }

  /// Starts a load. A reload keeps the render on screen until the new one is ready, and reads the
  /// stored path alone.
  private func open(
    path: String, bookmark: Data?, anchor: TextViewerAnchor?, origin: LoadOrigin,
    reloading: Bool = false
  ) {
    cancelLoad()
    openGeneration += 1
    loadOrigin = origin
    resolvedNotice = nil
    reloadNotice = nil
    reloadQueued = false
    posted.reset()
    alerts.replaceLoad()

    if !reloading {
      unwatch()
      fileGone = false
    }

    if case .message = content.body {
      keepsRender = false
    } else {
      keepsRender = reloading
    }

    let generation = openGeneration
    let followed = reloading ? nil : bookmark

    if !keepsRender { showMessage("Opening\u{2026}", offersOpen: false) }

    opening = Task { [weak self] in
      let result = await SourceResolver.resolve(path: path, bookmark: followed)

      guard let self, generation == self.openGeneration, !self.closed else { return }

      switch result {
      case .success(let resolved):
        self.record.bookmark = resolved.bookmark

        if let movedFrom = resolved.movedFrom {
          self.record.path = movedFrom
          self.resolvedNotice = "Moved. Found at \(movedFrom)."
        }

        self.watch(self.record.path ?? path)
        await self.watcher?.whenArmed()

        guard generation == self.openGeneration, !self.closed else { return }

        await self.load(file: resolved.file, anchor: anchor, generation: generation)

      case .failure(let error):
        self.describesFromRecord = false
        self.fail(error.errorDescription ?? "The file could not be opened.")
      }
    }
  }

  // MARK: Watching

  private func watch(_ path: String) {
    if watcher != nil, watchedPath == path { return }

    watcher?.stop()
    watchedPath = path
    watchedExists = true
    watcher = FileWatcher(url: URL(fileURLWithPath: path), policy: watchPolicy) {
      [weak self] signature in
      self?.fileChanged(signature)
    }
  }

  private func unwatch() {
    watcher?.stop()
    watcher = nil
    watchedPath = nil
    watchedExists = true
    heldChange = nil
  }

  /// The watch saw the path change. A detached pane holds the latest change for reattach.
  func fileChanged(_ signature: FileSignature) {
    guard !closed, record.path != nil else { return }

    watchedExists = signature.exists

    if alerts.isDetached {
      heldChange = signature
      return
    }

    applyChange(signature)
  }

  private func applyChange(_ signature: FileSignature) {
    guard signature.exists else {
      guard !fileGone else { return }

      fileGone = true
      refresh()

      return
    }

    if opening != nil {
      reloadQueued = true
      return
    }

    reload(origin: .reload)
  }

  /// The current load is over. A change that came during it starts one more.
  private func settleLoad() {
    guard reloadQueued, !closed else { return }

    reloadQueued = false
    reload(origin: .reload)
  }

  /// A load succeeded, so the pane shows what the file holds. The segment stays when the file went
  /// away while the load ran.
  private func loadSucceeded() {
    keepsRender = false
    reloadNotice = nil
    fileGone = !watchedExists
  }

  private func cancelLoad() {
    opening?.cancel()
    opening = nil
    job?.cancel()
    job = nil
  }

  private func load(file: URL, anchor: TextViewerAnchor?, generation: Int) async {
    let name = file.lastPathComponent
    let format = TextFormatRule.format(of: file)
    let limits = settings.limits

    switch format {
    case .pdf:
      let result = await PDFLoading.load(path: file.path, limit: limits.maxPDFBytes)

      guard generation == openGeneration, !closed else { return }

      switch result {
      case .success(let loaded):
        show(pdf: loaded.document, anchor: anchor)

      case .failure(.read(.access(let error))):
        fail(error.errorDescription ?? "The file could not be opened.")

      case .failure(.read(.tooLarge(_, let bytes, _))):
        fail(limits.tooLargeMessage(fileName: name, bytes: bytes, format: format))

      case .failure(.notAPDF):
        fail("\u{201C}\(name)\u{201D} is not a PDF that macOS can open.")

      case .failure(.locked):
        fail("\u{201C}\(name)\u{201D} is password-protected, which the text viewer does not open.")
      }

    case .rtf, .word97, .wordXML:
      guard let kind = format.documentKind else { return }

      await loadDocument(
        file: file, kind: kind, format: format, anchor: anchor, generation: generation)

    case .markdown:
      await loadMarkdown(file: file, anchor: anchor, generation: generation)

    case .unsupported(let description):
      fail(TextFormatRule.unsupportedMessage(fileName: name, description: description))
    }
  }

  private func loadDocument(
    file: URL, kind: DocumentKind, format: TextFormat, anchor: TextViewerAnchor?, generation: Int
  ) async {
    let name = file.lastPathComponent
    let limits = settings.limits
    let path = file.path

    let opened = await Self.openForHelper(path: path)

    guard generation == openGeneration, !closed else { return }

    let source: OpenedDocumentFile

    switch opened {
    case .failure(let error):
      fail(error.errorDescription ?? "The file could not be opened.")
      return

    case .success(let file):
      source = file
    }

    guard source.size <= limits.fileLimit(for: format) else {
      fail(limits.tooLargeMessage(fileName: name, bytes: source.size, format: format))
      return
    }

    let current = DocumentHelperJob(settings: settings)
    job = current
    helperStarts += 1

    let outcome = await current.run(kind: kind, file: source)

    if job === current { job = nil }

    guard generation == openGeneration, !closed else { return }

    switch outcome {
    case .failure(let end):
      fail(Self.message(for: end, fileName: name, limits: limits))

    case .success(let reply):
      let decoded = await DocumentReplyDecoder.decode(reply, limits: limits)

      guard generation == openGeneration, !closed else { return }

      switch decoded {
      case .success(let document):
        show(text: document.text, contents: document.contents, anchor: anchor)

      case .failure(.overCap(let violation)):
        fail(violation.message(fileName: name))

      case .failure(.misbehaved):
        fail(
          "The document reader sent something uniterm could not trust, so \u{201C}\(name)\u{201D} was not opened."
        )
      }
    }
  }

  private func loadMarkdown(file: URL, anchor: TextViewerAnchor?, generation: Int) async {
    let name = file.lastPathComponent
    let limits = settings.limits
    let result = await MarkdownLoading.load(path: file.path, limit: limits.maxMarkdownBytes)

    guard generation == openGeneration, !closed else { return }

    switch result {
    case .failure(.access(let error)):
      fail(error.errorDescription ?? "The file could not be opened.")

    case .failure(.tooLarge(_, let bytes, _)):
      fail(limits.tooLargeMessage(fileName: name, bytes: bytes, format: .markdown))

    case .success(let document):
      guard let view = await markdownView(limits: limits) else {
        if generation == openGeneration, !closed {
          fail("The Markdown viewer could not start, so \u{201C}\(name)\u{201D} was not opened.")
        }

        return
      }

      guard generation == openGeneration, !closed else {
        if content.markdownView !== view { view.close() }
        return
      }

      show(markdown: view, document: document, anchor: anchor)
    }
  }

  /// The pane's Markdown page. It is built when the first Markdown document opens and stays until
  /// the pane shows something else. A pane that never shows Markdown starts no web content process.
  private func markdownView(limits: TextViewerLimits) async -> MarkdownView? {
    if let existing = content.markdownView { return existing }

    guard case .success(let assets) = MarkdownAssets.shared else { return nil }

    return await MarkdownView.make(assets: assets, limits: limits)
  }

  @concurrent
  private static func openForHelper(path: String) async -> Result<
    OpenedDocumentFile, SourceAccessError
  > {
    OpenedDocumentFile.open(path: path)
  }

  static func message(for end: DocumentDecodeEnd, fileName name: String, limits: TextViewerLimits)
    -> String
  {
    let quoted = "\u{201C}\(name)\u{201D}"

    switch end {
    case .cancelled:
      return "Opening \(quoted) was cancelled."

    case .declined(_, let text):
      return "\(quoted) could not be read. \(text)"

    case .helper(.crashed):
      return "\(quoted) could not be read. The document reader stopped while reading it."

    case .helper(.unresponsive):
      return "\(quoted) could not be read. The document reader stopped answering."

    case .helper(.overranTimeBound):
      let seconds = Int(limits.decodeTimeBound.components.seconds)

      return "\(quoted) took more than \(seconds) seconds to read, so uniterm stopped."

    case .helper(.overFootprint):
      return
        "\(quoted) needs more memory than the text viewer allows, so uniterm stopped reading it."

    case .helper(.misbehaved):
      return
        "The document reader sent something uniterm could not trust, so \(quoted) was not opened."

    case .helper(.versionMismatch):
      return DocumentProtocol.mismatchText

    case .helper(.unavailable(let text)):
      return text
    }
  }

  // MARK: Showing

  private func show(
    markdown view: MarkdownView, document: MarkdownDocument, anchor: TextViewerAnchor?
  ) {
    opening = nil
    messageText = nil
    textLength = nil
    loadSucceeded()
    content.pdfView.document = nil
    content.textView.textStorage?.setAttributedString(NSAttributedString())
    finder.documentChanged()
    setContents(.empty)

    if content.markdownView !== view {
      view.onRendered = { [weak self] in self?.markdownRendered() }
      view.onFailed = { [weak self] reason in self?.markdownFailed(reason) }
      view.onTerminated = { [weak self] in self?.markdownTerminated() }
      view.onLink = { [weak self] url in self?.links.handle(url) }
      view.onFindAction = { [weak self] action in self?.perform(action) }

      content.install(markdown: view)
      view.apply(palette)
    }

    content.show(.markdown)

    pendingAnchor = nil
    scrollsToTop = false
    anchorApplied = anchor == nil

    if anchor == nil { describesFromRecord = false }

    let start = anchor?.sourceLine.map {
      MarkdownAnchor(line: $0, fraction: anchor?.fraction ?? 0)
    }

    view.show(document: document, anchor: start)
    refresh()
    settleLoad()
  }

  private func markdownRendered() {
    anchorApplied = true
    describesFromRecord = false
    setContents(
      ContentsBuilders.markdown(
        content.markdownView?.headings ?? [], cut: content.markdownView?.headingsCut ?? false)
    )
    content.sidebar.isReady = true
    finder.documentReady()
    refresh()
  }

  private func markdownFailed(_ reason: String) {
    let name = record.path.map { ($0 as NSString).lastPathComponent } ?? Self.untitled
    let detail = reason.isEmpty ? "" : " \(reason)"

    fail("\u{201C}\(name)\u{201D} could not be shown.\(detail)")
  }

  /// WebKit's content process ended. The pane keeps the last position in its description, says
  /// what happened, and offers Reload.
  private func markdownTerminated() {
    if let anchor = content.markdownView?.anchor {
      record.anchor = .markdown(line: anchor.line, fraction: anchor.fraction)
    }

    describesFromRecord = true
    anchorApplied = true

    let text = "The page for this document stopped. Reload to show it again."

    finder.documentChanged()
    setContents(.empty)

    showMessage(text, offersOpen: false, offersReload: true)
    messageText = text
    refresh()
  }

  private func show(pdf document: PDFDocument, anchor: TextViewerAnchor?) {
    content.removeMarkdown()
    opening = nil
    messageText = nil
    textLength = nil
    loadSucceeded()
    content.pdfView.document = document
    content.show(.pdf)
    finder.documentChanged()
    setContents(ContentsBuilders.pdf(document))
    content.sidebar.isReady = true
    pendingAnchor = anchor
    scrollsToTop = anchor == nil
    anchorApplied = anchor == nil

    if anchor == nil { describesFromRecord = false }

    refresh()
    applyPendingAnchor()
    finder.documentReady()
    settleLoad()
  }

  func show(text: NSAttributedString, contents found: Contents, anchor: TextViewerAnchor?) {
    content.removeMarkdown()
    opening = nil
    messageText = nil
    textLength = text.length
    loadSucceeded()
    content.pdfView.document = nil
    content.textView.textStorage?.setAttributedString(text)
    content.show(.text)
    finder.documentChanged()
    setContents(found)
    content.sidebar.isReady = true
    pendingAnchor = anchor
    scrollsToTop = false
    anchorApplied = anchor == nil

    if anchor == nil { describesFromRecord = false }

    refresh()
    applyPendingAnchor()
    finder.documentReady()
    settleLoad()
  }

  /// Puts a restored anchor in place once the view has a size to lay out in. A pane restored while
  /// off screen waits for its first layout. Until then `describe()` returns the anchor it holds.
  private func applyPendingAnchor() {
    guard pendingAnchor != nil || scrollsToTop, content.bounds.width > 0, content.bounds.height > 0
    else { return }

    // A layout pass inside this method calls it again. Reading the anchor once keeps the outer call
    // on the anchor it started with, however far the inner call got.
    let anchor = pendingAnchor

    switch content.body {
    case .pdf:
      guard let document = content.pdfView.document else { return }

      // The body sits inside stack views, so the document view has a frame only after a layout pass.
      content.layoutSubtreeIfNeeded()
      content.pdfView.layoutDocumentView()

      if let anchor {
        if let index = anchor.page, index < document.pageCount, let page = document.page(at: index)
        {
          let point = CGPoint(x: anchor.x ?? 0, y: anchor.y ?? page.bounds(for: .cropBox).maxY)

          content.pdfView.go(to: PDFDestination(page: page, at: point))
        }
      } else if let documentView = content.pdfView.documentView {
        // The document view is not flipped, so its top is its largest y.
        documentView.scroll(NSPoint(x: 0, y: documentView.bounds.maxY))
      }

    case .text:
      content.layoutSubtreeIfNeeded()
      scrollText(toCharacter: anchor?.characterIndex ?? 0)

    case .markdown, .message:
      return
    }

    pendingAnchor = nil
    scrollsToTop = false
    anchorApplied = true
    describesFromRecord = false
    refresh()
  }

  private func fail(_ text: String) {
    defer { settleLoad() }

    if keepsRender {
      keepsRender = false
      opening = nil
      fileGone = !watchedExists

      if !fileGone { reloadNotice = text }

      refresh()
      return
    }

    content.removeMarkdown()
    finder.documentChanged()
    setContents(.empty)
    opening = nil
    describesFromRecord = false
    anchorApplied = true
    pendingAnchor = nil
    scrollsToTop = false
    content.pdfView.document = nil
    content.textView.textStorage?.setAttributedString(NSAttributedString())
    textLength = nil

    showMessage(text, offersOpen: true)
    messageText = text
    refresh()
  }

  private func showMessage(_ text: String, offersOpen: Bool, offersReload: Bool = false) {
    messageText = nil
    content.pdfView.document = nil
    content.show(.message(text, offersOpen: offersOpen, offersReload: offersReload))
  }

  static let emptyText = "Open a PDF, Markdown, RTF, or Word document, or drop one here."

  // MARK: Anchor

  private func scrollText(toCharacter index: Int) {
    let textView = content.textView

    guard let layout = textView.layoutManager, let container = textView.textContainer,
      textView.textStorage?.length ?? 0 > 0
    else { return }

    let length = textView.textStorage?.length ?? 0
    let location = min(max(index, 0), length - 1)
    // Non-contiguous layout estimates the height of text it has not laid out, and a position taken
    // from an estimate moves when the text above it is laid out. Laying out up to the target first
    // makes the position final.
    layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: location + 1))

    let glyphs = layout.glyphRange(
      forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)

    textView.scroll(NSPoint(x: 0, y: max(0, rect.minY + textView.textContainerInset.height)))
  }

  private func currentAnchor() -> TextViewerAnchor? {
    switch content.body {
    case .pdf:
      let pdfView = content.pdfView

      guard let destination = pdfView.currentDestination, let page = destination.page,
        let document = pdfView.document
      else { return nil }

      let point = destination.point

      return .pdf(
        page: document.index(for: page), x: Double(point.x), y: Double(point.y))

    case .text:
      let textView = content.textView

      guard let layout = textView.layoutManager, let container = textView.textContainer,
        textView.textStorage?.length ?? 0 > 0
      else { return nil }

      let top = content.scrollView.contentView.bounds.minY
      let point = NSPoint(x: 0, y: max(0, top - textView.textContainerInset.height))
      let index = layout.characterIndex(
        for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)

      return .text(characterIndex: index)

    case .markdown:
      guard let anchor = content.markdownView?.anchor else { return nil }

      return .markdown(line: anchor.line, fraction: anchor.fraction)

    case .message:
      return nil
    }
  }

  // MARK: Drop and open

  /// A drop of one file replaces the pane's file. Several files are refused with a message, and the
  /// pane keeps what it showed.
  func handleDrop(_ urls: [URL]) -> Bool {
    guard let file = urls.first else { return false }

    guard urls.count == 1 else {
      alerts.deliver(
        .warning, "Drop one file at a time. The text viewer shows one file in a pane.",
        from: self, to: host)
      return false
    }

    do {
      try replaceSource(with: file, startDirectory: SourceStartDirectory.of(file))
      return true
    } catch {
      alerts.deliver(
        .warning,
        "\u{201C}\(file.lastPathComponent)\u{201D} could not be opened: \(error.localizedDescription)",
        from: self, to: host)
      return false
    }
  }

  private func showOpenPanel() {
    Task { @MainActor [weak self] in
      guard let self else { return }

      await SourceOpening.open(self, picker: SystemOpenPanel.pick)
    }
  }

  // MARK: Find and contents

  /// True while a document is on screen for the find commands to search.
  var canFind: Bool { !closed && finder.canFind }

  func showFind() {
    guard canFind else { return }

    finder.show()
  }

  func stepFind(forward: Bool) {
    finder.step(forward: forward)
  }

  func useSelectionForFind() {
    Task { @MainActor [weak self] in await self?.finder.useSelection() }
  }

  private func closeFind() {
    finder.close()
    content.focusBody()
  }

  private func perform(_ action: BuiltInFindAction) {
    switch action {
    case .show: showFind()
    case .next: stepFind(forward: true)
    case .previous: stepFind(forward: false)
    case .useSelection: useSelectionForFind()
    }
  }

  /// Show Contents is off for a document with no outline, unless the sidebar is already showing,
  /// since the command is also how the sidebar is hidden.
  var canShowContents: Bool {
    guard !closed, finder.canFind else { return false }

    return record.sidebarShown || !contents.isEmpty
  }

  var sidebarShown: Bool { record.sidebarShown }

  func toggleContents() {
    guard canShowContents else { return }

    record.sidebarShown.toggle()
    updateSidebar()
    host?.appletDidChange(self)
  }

  private func setContents(_ found: Contents) {
    contents = found
    content.sidebar.show(found)
    content.sidebar.isReady = false
    updateSidebar()
  }

  private func updateSidebar() {
    content.setSidebar(visible: record.sidebarShown && finder.canFind)
  }

  private func go(to entry: ContentsEntry) {
    switch entry.target {
    case .pdf(let index, _, let y):
      guard let document = content.pdfView.document, index < document.pageCount,
        let page = document.page(at: index)
      else { return }

      content.pdfView.show(page: page, at: y, clampedToPage: true)

    case .text(let index):
      scrollText(toCharacter: index)

    case .markdown(let heading):
      guard let view = content.markdownView else { return }

      Task { await view.scrollToHeading(heading) }
    }
  }

  // MARK: Applet

  public func start(origin: StartOrigin) {
    guard restoreWaitsForStart, let path = record.path else { return }

    restoreWaitsForStart = false
    open(path: path, bookmark: record.bookmark, anchor: record.anchor, origin: origin.loadOrigin)
  }

  /// Reads the file again and shows it at the position the pane holds. A pane whose web content
  /// process ended comes back this way, with its images fetched afresh.
  public func reload() {
    reload(origin: .user)
  }

  /// Whether the pane watches its file, for tests.
  var isWatching: Bool { watcher != nil }

  /// Whether a load is running, for tests.
  var isLoading: Bool { opening != nil }

  /// True when the pane has a file to read again.
  var canReload: Bool { !closed && record.path != nil }

  private func reload(origin: LoadOrigin) {
    guard let path = record.path else { return }

    let anchor = content.markdownView?.anchor.map {
      TextViewerAnchor.markdown(line: $0.line, fraction: $0.fraction)
    }

    open(
      path: path, bookmark: record.bookmark, anchor: anchor ?? currentAnchor() ?? record.anchor,
      origin: origin, reloading: true)
  }

  public func close() {
    closed = true
    unwatch()
    alerts.discard()
    cancelLoad()
    finder.documentChanged()
    content.removeMarkdown()

    if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }

    pageObserver = nil
    content.pdfView.document = nil
    content.textView.textStorage?.setAttributedString(NSAttributedString())
  }

  public func detach() {
    alerts.detach()
  }

  public func reattach() {
    alerts.reattach(from: self, to: host)

    if let held = heldChange {
      heldChange = nil
      applyChange(held)
    }
  }

  public func focus() {
    content.focusBody()
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette
    content.apply(palette)
  }

  public func describe() -> AppletDescription {
    var description = record

    if !describesFromRecord, anchorApplied, let anchor = currentAnchor() {
      description.anchor = anchor
    }

    // The payload always encodes. The fields are plain values, so a failure is a programming error.
    return (try? description.appletDescription())
      ?? AppletDescription(
        type: TextViewerDescription.typeID, version: TextViewerDescription.currentVersion,
        payload: .object([:]))
  }

  // MARK: Display

  private func refresh() {
    guard !closed else { return }

    updateSidebar()

    let newTitle = record.path.map { ($0 as NSString).lastPathComponent } ?? Self.untitled
    let newSegments = segmentsForState()
    let titleChanged = newTitle != title

    postNotices()

    guard titleChanged || newSegments != segments else { return }

    title = newTitle
    segments = newSegments

    if titleChanged {
      publishedTabs = AppletTabList(first: AppletTab(id: publishedTabs.first.id, title: newTitle))
      host?.appletTabsDidChange(self)
    }

    host?.appletDidChange(self)
  }

  /// Delivers each notice about the load once. A failure is explained by the pane itself, so it
  /// goes to the history only.
  private func postNotices() {
    var notices: [AppletNotice] = []

    if let messageText {
      notices.append(AppletNotice(.warning, messageText, delivery: .historyOnly))
    }

    if let resolvedNotice {
      notices.append(AppletNotice(.info, resolvedNotice))
    }

    if let reloadNotice {
      notices.append(AppletNotice(.warning, reloadNotice))
    }

    if fileGone {
      let name = record.path.map { ($0 as NSString).lastPathComponent } ?? Self.untitled

      notices.append(
        AppletNotice(
          .warning,
          "\u{201C}\(name)\u{201D} was moved or deleted. The pane keeps the last version it read."
        ))
    }

    for notice in posted.unposted(notices) {
      alerts.deliver(notice, origin: loadOrigin, from: self, to: host)
    }
  }

  private func segmentsForState() -> [AppletSegment] {
    var segments = bodySegments()

    if fileGone {
      segments.append(
        AppletSegment(
          symbolName: "exclamationmark.triangle", text: "Moved or deleted", style: .warning))
    }

    return segments
  }

  private func bodySegments() -> [AppletSegment] {
    switch content.body {
    case .pdf:
      guard let document = content.pdfView.document else { return [] }

      let page = content.pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1

      return [
        AppletSegment(
          symbolName: "doc.richtext", text: "Page \(page) of \(document.pageCount.formatted())")
      ]

    case .text:
      guard let textLength else { return [] }

      return [
        AppletSegment(
          symbolName: "doc.text", text: "\(textLength.formatted()) characters")
      ]

    case .markdown:
      guard let view = content.markdownView, view.isRendered else { return [] }

      return [
        AppletSegment(symbolName: "text.alignleft", text: "\(view.lineCount.formatted()) lines")
      ]

    case .message:
      return []
    }
  }
}

/// Answers the link clicks of the text view and the PDF view. Only the safe schemes open.
@MainActor
final class LinkHandler: NSObject, NSTextViewDelegate, @preconcurrency PDFViewDelegate {
  private let opener: any URLOpening
  var onRefused: ((URL) -> Void)?

  init(opener: any URLOpening) {
    self.opener = opener
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    handle(LinkPolicy.url(from: link))

    return true
  }

  func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
    handle(url)
  }

  func handle(_ url: URL?) {
    guard let url else { return }

    guard LinkPolicy.isOpenable(url) else {
      onRefused?(url)
      return
    }

    _ = opener.open(url)
  }
}
