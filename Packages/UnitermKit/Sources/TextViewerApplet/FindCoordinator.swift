import AppKit
import PDFKit
import TextViewerModel

/// Runs one pane's find. The query lives here and in the find bar, never in the description and
/// never on the system find pasteboard.
///
/// Each format has its own engine. The text view's storage is searched off the main thread and
/// shown with temporary highlights, the selection, and the find indicator. A PDF searches through
/// PDFKit's asynchronous find and shows its matches as highlighted selections. A Markdown page
/// searches in the parser's isolated world and marks its matches in the page. Every engine folds
/// case and diacritics by `FindMatching`.
///
/// Every search carries a generation. Showing another document, closing the bar, or typing a new
/// query bumps it, and a result that arrives under an older one is dropped.
/// Where the reader's selection lay when Use Selection for Find ran, so the match inside it can be
/// the current one.
enum SelectionAnchor {
  case text(NSRange)
  case pdf(PDFSelection)
  case markdown
}

/// What a search does when it finishes.
enum FindReveal {
  /// Highlights only. The view and the selection stay.
  case none

  /// Moves to the first match.
  case first

  /// Moves to the first match inside the selection the query came from, or the first match when
  /// none lies inside it.
  case near(SelectionAnchor)
}

@MainActor
final class FindCoordinator {
  private let content: TextViewerView
  private(set) var state = FindState()
  private var generation = 0
  private var task: Task<Void, Never>? {
    didSet { if let task { lastSearch = task } }
  }

  /// The latest search started, kept after it is invalidated, so a test can wait for one that
  /// must end without effect.
  private(set) var lastSearch: Task<Void, Never>?

  private var textMatches: [NSRange] = []
  private var pdfSearch: PDFSearch?
  private var pdfMatches: [PDFSelection] = []
  private var shownPDFMatch: Int?
  private var shownTextMatch: Int?

  static let matchColor = NSColor.systemYellow.withAlphaComponent(0.55)
  static let currentColor = NSColor.systemOrange

  init(content: TextViewerView) {
    self.content = content
  }

  var isOpen: Bool { !content.findBar.isHidden }

  /// True while a document the engines can search is on screen.
  var canFind: Bool {
    switch content.body {
    case .pdf, .text, .markdown: return true
    case .message: return false
    }
  }

  // MARK: Bar

  func show() {
    content.findBar.open()
  }

  /// A new query from the bar. It starts a search that moves to the first match.
  func queryChanged(_ query: String) {
    state.query = query
    run(reveal: .first)
  }

  func step(forward: Bool) {
    guard canFind else { return }

    guard !state.query.isEmpty else {
      show()
      return
    }

    guard let index = state.stepTarget(forward: forward) else { return }

    select(index)
  }

  /// Closes the bar and drops the query and every highlight.
  func close() {
    invalidate()
    clearHighlights()
    state = FindState()
    content.findBar.close()
    content.findBar.update(state)
  }

  /// Makes the selection the query and moves to the match inside it. A selection across lines or
  /// table cells cannot be a query, since the field holds one line and the engines do not match
  /// across line breaks alike. The query is the selection's first line or cell, and the first match
  /// inside the selection is current. Only the pane's query changes.
  func useSelection() async {
    guard canFind else { return }

    let token = generation

    guard let (text, anchor) = await selection(), token == generation,
      let query = Self.firstSegment(of: text)
    else { return }

    content.findBar.query = query
    content.findBar.reveal()
    state.query = query
    run(reveal: .near(anchor))
  }

  /// The first line or cell of `text` that holds something, trimmed and cut to the query cap.
  static func firstSegment(of text: String) -> String? {
    let parts = text.split(whereSeparator: { $0.isNewline || $0 == "\t" })

    for part in parts {
      let trimmed = part.trimmingCharacters(in: .whitespaces)

      if let query = FindMatching.prepared(trimmed) { return query }
    }

    return nil
  }

  private func selection() async -> (String, SelectionAnchor)? {
    switch content.body {
    case .text:
      let range = content.textView.selectedRange()
      let length = content.textView.textStorage?.length ?? 0

      guard range.length > 0, NSMaxRange(range) <= length else { return nil }

      return ((content.textView.string as NSString).substring(with: range), .text(range))

    case .pdf:
      guard let selection = content.pdfView.currentSelection, let text = selection.string,
        let copy = selection.copy() as? PDFSelection
      else { return nil }

      return (text, .pdf(copy))

    case .markdown:
      guard let text = await content.markdownView?.selectedText() else { return nil }

      return (text, .markdown)

    case .message:
      return nil
    }
  }

  // MARK: Document changes

  /// Another document is showing, or the shown one was replaced. Old matches are gone with it.
  func documentChanged() {
    invalidate()
    clearHighlights()
    state.matchCount = 0
    state.current = nil
    state.capped = false
    state.isSearching = false
    content.findBar.update(state)
  }

  /// The new document is ready. A query the bar still holds searches it again, without moving the
  /// view.
  func documentReady() {
    guard isOpen, !state.query.isEmpty else { return }

    run(reveal: .none)
  }

  private func invalidate() {
    generation += 1
    task?.cancel()
    task = nil
    pdfSearch?.cancel()
    pdfSearch = nil
  }

  // MARK: Searching

  private func run(reveal: FindReveal) {
    invalidate()
    clearHighlights()

    state.matchCount = 0
    state.current = nil
    state.capped = false
    state.isSearching = false

    guard canFind, let query = FindMatching.prepared(state.query) else {
      publish()
      return
    }

    state.isSearching = true
    publish()

    let token = generation

    switch content.body {
    case .text: searchText(query, token: token, reveal: reveal)
    case .pdf: searchPDF(query, token: token, reveal: reveal)
    case .markdown: searchMarkdown(query, token: token, reveal: reveal)
    case .message: break
    }
  }

  private func publish() {
    content.findBar.update(state)
  }

  private func clearHighlights() {
    if let layout = content.textView.layoutManager,
      let length = content.textView.textStorage?.length, length > 0
    {
      layout.removeTemporaryAttribute(
        .backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
    }

    textMatches = []
    shownTextMatch = nil

    content.pdfView.highlightedSelections = nil
    pdfMatches = []
    shownPDFMatch = nil

    if let view = content.markdownView, view.isRendered {
      Task { await view.clearFind() }
    }
  }

  private func select(_ index: Int) {
    state.current = index
    publish()

    switch content.body {
    case .text: showText(index)
    case .pdf: showPDF(index)
    case .markdown:
      if let view = content.markdownView { Task { await view.selectMatch(index) } }
    case .message: break
    }
  }

  // MARK: Text

  private func searchText(_ query: String, token: Int, reveal: FindReveal) {
    let snapshot = content.textView.string

    task = Task { [weak self] in
      let outcome = await FindMatching.searchOffMain(in: snapshot, for: query)

      guard let self, token == generation, let outcome else { return }

      textMatches = outcome.ranges
      state.matchCount = outcome.ranges.count
      state.capped = outcome.capped
      state.isSearching = false

      if let layout = content.textView.layoutManager {
        for range in outcome.ranges {
          layout.addTemporaryAttribute(
            .backgroundColor, value: Self.matchColor, forCharacterRange: range)
        }
      }

      switch reveal {
      case .none:
        publish()

      case .first:
        outcome.ranges.isEmpty ? publish() : select(0)

      case .near(let anchor):
        guard !outcome.ranges.isEmpty else {
          publish()
          return
        }

        select(index(in: outcome.ranges, near: anchor))
      }
    }
  }

  /// The first match inside the selection the query came from, or the first match after its start.
  private func index(in ranges: [NSRange], near anchor: SelectionAnchor) -> Int {
    guard case .text(let selected) = anchor else { return 0 }

    if let inside = ranges.firstIndex(where: {
      $0.location >= selected.location && NSMaxRange($0) <= NSMaxRange(selected)
    }) {
      return inside
    }

    return ranges.firstIndex { $0.location >= selected.location } ?? 0
  }

  private func showText(_ index: Int) {
    let textView = content.textView

    guard textMatches.indices.contains(index), let layout = textView.layoutManager else { return }

    if let previous = shownTextMatch, textMatches.indices.contains(previous) {
      layout.addTemporaryAttribute(
        .backgroundColor, value: Self.matchColor, forCharacterRange: textMatches[previous])
    }

    let range = textMatches[index]

    shownTextMatch = index
    layout.addTemporaryAttribute(
      .backgroundColor, value: Self.currentColor, forCharacterRange: range)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    textView.showFindIndicator(for: range)
  }

  // MARK: PDF

  private func searchPDF(_ query: String, token: Int, reveal: FindReveal) {
    guard let document = content.pdfView.document else {
      state.isSearching = false
      publish()
      return
    }

    let search = PDFSearch(document: document)

    pdfSearch = search

    search.onMatch = { [weak self, weak search] selection in
      guard let self, let search, search === pdfSearch, token == generation else { return }

      matched(selection, reveal: reveal, search: search)
    }

    search.onEnd = { [weak self, weak search] in
      guard let self, let search, search === pdfSearch, token == generation else { return }

      state.isSearching = false
      content.pdfView.highlightedSelections = pdfMatches

      if case .near = reveal, state.current == nil, !pdfMatches.isEmpty {
        select(0)
      } else {
        publish()
      }
    }

    search.start(query)
  }

  private func matched(_ selection: PDFSelection, reveal: FindReveal, search: PDFSearch) {
    selection.color = Self.matchColor
    pdfMatches.append(selection)
    state.matchCount = pdfMatches.count

    if pdfMatches.count >= FindMatching.maxMatches {
      state.capped = true
      state.isSearching = false
      search.cancel()
      content.pdfView.highlightedSelections = pdfMatches
      publish()
      return
    }

    if pdfMatches.count % 25 == 1 { content.pdfView.highlightedSelections = pdfMatches }

    switch reveal {
    case .first where pdfMatches.count == 1:
      select(0)

    case .near(let anchor):
      if state.current == nil, case .pdf(let inside) = anchor, lies(selection, inside: inside) {
        select(pdfMatches.count - 1)
      } else {
        publish()
      }

    default:
      publish()
    }
  }

  private func lies(_ match: PDFSelection, inside anchor: PDFSelection) -> Bool {
    for page in match.pages {
      let outer = anchor.bounds(for: page).insetBy(dx: -2, dy: -2)

      if !outer.isEmpty, outer.contains(match.bounds(for: page)) { return true }
    }

    return false
  }

  private func showPDF(_ index: Int) {
    guard pdfMatches.indices.contains(index) else { return }

    if let previous = shownPDFMatch, pdfMatches.indices.contains(previous) {
      pdfMatches[previous].color = Self.matchColor
    }

    let selection = pdfMatches[index]

    shownPDFMatch = index
    selection.color = Self.currentColor
    content.pdfView.highlightedSelections = pdfMatches
    content.pdfView.setCurrentSelection(selection, animate: true)
    reveal(selection)
  }

  /// Scrolls so the match sits about a third of the way down the view. Scrolling to the selection
  /// itself puts it flush with the top edge, where the find indicator is clipped.
  private func reveal(_ selection: PDFSelection) {
    let pdfView = content.pdfView

    guard let page = selection.pages.first else {
      pdfView.go(to: selection)
      return
    }

    pdfView.show(page: page, at: selection.bounds(for: page).maxY, clampedToPage: false)
  }

  // MARK: Markdown

  private func searchMarkdown(_ query: String, token: Int, reveal: FindReveal) {
    guard let view = content.markdownView else {
      state.isSearching = false
      publish()
      return
    }

    task = Task { [weak self] in
      let outcome = await view.find(query)

      guard let self, token == generation else { return }

      state.isSearching = false

      guard let outcome else {
        publish()
        return
      }

      state.matchCount = outcome.count
      state.capped = outcome.capped

      guard outcome.count > 0 else {
        publish()
        return
      }

      switch reveal {
      case .none:
        publish()

      case .first:
        select(0)

      case .near:
        let inside = await view.matchInSelection()

        guard token == generation else { return }

        select(inside ?? 0)
      }
    }
  }
}

/// One asynchronous PDFKit find. PDFKit reports its matches to the document's delegate, and this
/// object forwards them to the main actor in order. A search that was cancelled forwards nothing
/// more.
final class PDFSearch: NSObject, PDFDocumentDelegate, @unchecked Sendable {
  private let document: PDFDocument
  @MainActor private var active = false

  @MainActor var onMatch: ((PDFSelection) -> Void)?
  @MainActor var onEnd: (() -> Void)?

  @MainActor
  init(document: PDFDocument) {
    self.document = document
  }

  @MainActor
  func start(_ query: String) {
    active = true
    document.delegate = self
    document.beginFindString(query, withOptions: FindMatching.options)
  }

  @MainActor
  func cancel() {
    active = false
    document.cancelFindString()

    if document.delegate === self { document.delegate = nil }
  }

  private struct Box: @unchecked Sendable {
    let selection: PDFSelection
  }

  func didMatchString(_ instance: PDFSelection) {
    let box = Box(selection: instance)

    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated {
        if active { onMatch?(box.selection) }
      }
    }
  }

  func documentDidEndDocumentFind(_ notification: Notification) {
    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated {
        guard active else { return }

        active = false
        onEnd?()
      }
    }
  }
}
