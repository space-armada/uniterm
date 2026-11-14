import AppKit
import AppletKit
import DocumentTestSupport
import PDFKit
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// The find bar's engines, one for each format, through the pane the way a reader drives them.
@MainActor
final class FindTests: XCTestCase {
  private var windows: [NSWindow] = []

  private func host(_ applet: TextViewerApplet) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.contentView = applet.content
    windows.append(window)
  }

  private func open(_ name: String, _ data: Data, in scratch: Scratch) async throws
    -> TextViewerApplet
  {
    let file = try scratch.write(name, data)
    let applet = Harness.applet(startDirectory: scratch.url.path)

    host(applet)
    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let done = await Harness.settled(applet)
    XCTAssertTrue(done, name)

    return applet
  }

  private func openText(_ body: String, in scratch: Scratch) async throws -> TextViewerApplet {
    try await open("a.rtf", try DocumentFixtures.rtf(body: body), in: scratch)
  }

  private func openMarkdown(_ text: String, in scratch: Scratch) async throws -> TextViewerApplet {
    let applet = try await open("README.md", Data(text.utf8), in: scratch)
    let rendered = await Harness.eventually { applet.content.markdownView?.isRendered == true }

    XCTAssertTrue(rendered)

    return applet
  }

  private func search(_ applet: TextViewerApplet, _ query: String, count: Int? = nil) async -> Bool
  {
    applet.content.findBar.query = query
    applet.finder.queryChanged(query)

    return await Harness.eventually {
      !applet.finder.state.isSearching
        && (count.map { applet.finder.state.matchCount == $0 } ?? true)
    }
  }

  // MARK: Text

  /// Catches a text search that misses a case or diacritic variant, one that does not move the
  /// selection to the match, and a step that does not wrap.
  func testTheTextEngineFoldsCaseAndDiacriticsSelectsAndWraps() async throws {
    let scratch = try Scratch(self)
    let applet = try await openText("Café and cafe and CAFÉ", in: scratch)
    let textView = applet.content.textView

    let found = await search(applet, "cafe", count: 3)

    XCTAssertTrue(found, "\(applet.finder.state)")
    XCTAssertEqual(applet.finder.state.current, 0)
    XCTAssertEqual(applet.finder.state.status, "1 of 3")
    XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "Café")

    applet.stepFind(forward: true)
    applet.stepFind(forward: true)

    XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "CAFÉ")

    applet.stepFind(forward: true)

    XCTAssertEqual(applet.finder.state.current, 0)

    applet.stepFind(forward: false)

    XCTAssertEqual(applet.finder.state.current, 2)

    let layout = try XCTUnwrap(textView.layoutManager)
    let shade = layout.temporaryAttribute(
      .backgroundColor, atCharacterIndex: textView.selectedRange().location, effectiveRange: nil)

    XCTAssertNotNil(shade, "every match is highlighted")
  }

  /// Catches a query that reaches the system find pasteboard, in any format. The find pasteboard's
  /// change count moves with every write, so a search, a step, and Use Selection must leave it.
  func testNoFormatWritesTheSystemFindPasteboard() async throws {
    let scratch = try Scratch(self)
    let before = NSPasteboard(name: .find).changeCount
    let text = try await openText("alpha beta alpha", in: scratch)
    let pdf = try await open(
      "a.pdf", DocumentFixtures.pdf(pages: ["alpha beta alpha"]), in: scratch)
    let markdown = try await openMarkdown("alpha beta alpha\n", in: scratch)

    for applet in [text, pdf, markdown] {
      let found = await search(applet, "alpha", count: 2)
      XCTAssertTrue(found)

      applet.stepFind(forward: true)

      applet.content.findBar.query = ""
      await applet.finder.useSelection()
    }

    XCTAssertEqual(NSPasteboard(name: .find).changeCount, before)
  }

  /// Catches Use Selection for Find that reads the system find pasteboard or leaves the query
  /// alone. The selection becomes the pane's query, and the match that is the selection is current.
  func testUseSelectionSetsThePanesQueryOnly() async throws {
    let scratch = try Scratch(self)
    let applet = try await openText("one two two three", in: scratch)
    let before = NSPasteboard(name: .find).changeCount

    applet.content.textView.setSelectedRange(NSRange(location: 4, length: 3))
    await applet.finder.useSelection()

    XCTAssertEqual(applet.content.findBar.query, "two")
    XCTAssertEqual(applet.finder.state.query, "two")
    XCTAssertFalse(applet.content.findBar.isHidden)

    let counted = await Harness.eventually { applet.finder.state.matchCount == 2 }

    XCTAssertTrue(counted)
    XCTAssertEqual(applet.finder.state.current, 0, "the match inside the selection is current")
    XCTAssertEqual(applet.content.textView.selectedRange(), NSRange(location: 4, length: 3))
    XCTAssertEqual(NSPasteboard(name: .find).changeCount, before)
  }

  /// Catches a text search that runs on the main thread. A decoded document may hold four million
  /// characters, and a search of one must leave the main actor free. The pane's own find runs the
  /// search while the main actor counts its turns, and a search on the main actor would let none
  /// through.
  func testSearchingTheDecodedCapNeverBlocksTheMainThread() async throws {
    let limit = TextViewerLimits.standard.maxDecodedLength
    let filler = String(repeating: "lorem ipsum dolor ", count: limit / 18)
    let text = filler + "needle"

    XCTAssertGreaterThan(text.utf16.count, limit - 20)

    let applet = Harness.applet()

    host(applet)
    applet.show(
      text: NSAttributedString(string: text), contents: .empty, anchor: nil)

    applet.content.findBar.query = "NEEDLE"
    applet.finder.queryChanged("NEEDLE")

    var turns = 0

    while applet.finder.state.isSearching {
      turns += 1
      await Task.yield()
    }

    XCTAssertEqual(applet.finder.state.matchCount, 1)
    XCTAssertGreaterThan(turns, 100, "the main actor ran while the search did")
  }

  /// Catches old matches that survive a reload. A search that is still running when another
  /// document shows ends without effect, and a query held across a reload searches the new text
  /// without moving the view.
  func testAReloadDiscardsOldMatchesAndSearchesTheNewText() async throws {
    let scratch = try Scratch(self)
    let applet = try await openText("alpha alpha", in: scratch)

    applet.showFind()

    let two = await search(applet, "alpha", count: 2)
    XCTAssertTrue(two)

    let file = try scratch.write("a.rtf", try DocumentFixtures.rtf(body: "alpha alpha alpha alpha"))
    applet.reload()

    let four = await Harness.eventually {
      applet.finder.state.matchCount == 4 && !applet.finder.state.isSearching
    }

    XCTAssertTrue(four, "\(applet.finder.state)")
    XCTAssertNil(applet.finder.state.current, "a reload keeps the reader's place")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

    // One yield lets the search start off the main thread. It finishes while the main thread is held,
    // so its result is waiting when the document changes, and only the generation check can drop it.
    applet.finder.queryChanged("alpha")

    let search = try XCTUnwrap(applet.finder.lastSearch)

    await Task.yield()
    usleep(200_000)
    applet.finder.documentChanged()
    await search.value

    XCTAssertEqual(applet.finder.state.matchCount, 0)
    XCTAssertFalse(applet.finder.state.isSearching)
    XCTAssertNil(
      applet.content.textView.layoutManager?.temporaryAttribute(
        .backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
  }

  // MARK: PDF

  /// Catches a PDF search that ignores diacritics, or one that never ends.
  func testThePDFEngineFoldsDiacriticsAndEnds() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      "a.pdf", DocumentFixtures.pdf(pages: ["Café one", "cafe two", "none"]), in: scratch)

    let found = await search(applet, "CAFE", count: 2)

    XCTAssertTrue(found, "\(applet.finder.state)")
    XCTAssertEqual(applet.finder.state.current, 0)
    XCTAssertEqual(applet.content.pdfView.currentSelection?.string?.lowercased().first, "c")

    applet.stepFind(forward: true)

    XCTAssertEqual(applet.finder.state.current, 1)
  }

  /// Catches matches from a cancelled search reaching the bar. The document is long enough that the
  /// search is still running when another document replaces it, and every callback queued behind
  /// the cancel must be dropped.
  func testACancelledPDFSearchReportsNothingMore() async throws {
    let scratch = try Scratch(self)
    let pages = Array(repeating: "cafe cafe cafe cafe", count: 300)
    let applet = try await open("long.pdf", DocumentFixtures.pdf(pages: pages), in: scratch)
    let document = try XCTUnwrap(applet.content.pdfView.document)

    applet.content.findBar.query = "cafe"
    applet.finder.queryChanged("cafe")
    applet.finder.documentChanged()

    let ended = await Harness.eventually { !document.isFinding }
    XCTAssertTrue(ended, "a cancel ends PDFKit's search")

    for _ in 0..<2 {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }

    XCTAssertEqual(applet.finder.state.matchCount, 0)
    XCTAssertFalse(applet.finder.state.isSearching)
    XCTAssertNil(applet.content.pdfView.highlightedSelections)
  }

  /// Catches a current PDF match scrolled flush against the top of the view, where the find
  /// indicator and the bar's edge clip it. The match sits with room above it.
  func testTheCurrentPDFMatchIsPlacedWithRoomAboveIt() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      "a.pdf", DocumentFixtures.pdf(pages: ["first page", "Alpha second page"]), in: scratch)
    let pdfView = applet.content.pdfView

    pdfView.layoutDocumentView()

    let found = await search(applet, "second", count: 1)
    XCTAssertTrue(found)

    let selection = try XCTUnwrap(pdfView.currentSelection)
    let page = try XCTUnwrap(selection.pages.first)
    let inView = pdfView.convert(selection.bounds(for: page), from: page)
    let fromTop = pdfView.isFlipped ? inView.minY : pdfView.bounds.height - inView.maxY

    XCTAssertGreaterThan(
      fromTop, pdfView.bounds.height * 0.15, "the match is \(fromTop) from the top")
    XCTAssertLessThan(inView.maxY, pdfView.bounds.height + 1)
  }

  // MARK: Markdown

  /// Catches a Markdown search that misses text spanning inline elements, one that joins two
  /// blocks, and one that treats a query's quotes or markup as code.
  func testTheMarkdownEngineSpansInlineElementsAndTakesTheQueryLiterally() async throws {
    let scratch = try Scratch(self)
    let applet = try await openMarkdown(
      """
      foo **bar** and _baz_ end

      tail

      head

      He said "hi" and `</script>` and \\ ' end
      """, in: scratch)
    let view = try XCTUnwrap(applet.content.markdownView)

    let spanning = await search(applet, "foo bar and baz end", count: 1)
    XCTAssertTrue(spanning)

    let blocks = await search(applet, "tailhead", count: 0)
    XCTAssertTrue(blocks, "a match never spans two blocks")

    let literal = await search(applet, "\"hi\" and </script> and \\ '", count: 1)
    XCTAssertTrue(literal, "\(applet.finder.state)")

    let marked = await view.run("return document.querySelectorAll('mark.um-find').length")

    XCTAssertGreaterThan((marked as? NSNumber)?.intValue ?? 0, 0)
    XCTAssertEqual(applet.content.body, .markdown)
  }

  /// Catches the `<details>` rule coming apart: a match inside a closed details counts, and it
  /// opens that details only when it becomes the current match.
  func testAMatchInsideAClosedDetailsCountsAndOpensItWhenCurrent() async throws {
    let scratch = try Scratch(self)
    let applet = try await openMarkdown(
      """
      <details><summary>More</summary>

      hidden needle here

      </details>

      <details><summary>Other</summary>

      other body

      </details>
      """, in: scratch)
    let view = try XCTUnwrap(applet.content.markdownView)

    let found = await search(applet, "needle", count: 1)
    XCTAssertTrue(found)

    let selected = await Harness.eventually { applet.finder.state.current == 0 }
    XCTAssertTrue(selected)

    await view.selectMatch(0)

    let value = await view.run(
      "return Array.from(document.querySelectorAll('details')).map(d => d.open)")
    let state = (value as? [Bool]) ?? []

    XCTAssertEqual(state, [true, false])
  }

  /// Catches the engines disagreeing about what matches. The Markdown page folds text in
  /// JavaScript, and each pair is judged the same way Foundation judges it for the other formats.
  /// The page's real find runs on each text, so a match that starts or ends inside a character that
  /// folds to several is judged too.
  func testMarkdownAndFoundationAgreeOnTheFoldingRule() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let shown = await rig.show("placeholder\n")
    XCTAssertTrue(shown)

    let pairs: [(String, String)] = [
      ("Straße", "STRASSE"), ("STRASSE", "straße"), ("ﬁne", "fine"), ("fine", "ﬁ"),
      ("İstanbul", "istanbul"), ("ΣΊΣΥΦΟΣ", "σίσυφος"), ("σίσυφος", "ΣΊΣΥΦΟΣ"),
      ("Café", "cafe"), ("cafe", "CAFÉ"), ("e\u{301}", "e"), ("Ångström", "angstrom"),
      ("ǆ", "dž"), ("ø", "o"), ("æ", "ae"), ("Ⅳ", "iv"), ("ａｂ", "ab"), ("plain", "PLAIN"),
      ("plain", "plane"), ("ß", "s"), ("s", "ß"), ("ﬃ", "f"), ("f", "ﬃ"), ("ﬃ", "ff"),
      ("ff", "ﬃ"), ("가", "ᄀ"), ("ᄀ", "가"), ("xßy", "s"), ("xﬃy", "fi"),
    ]

    for (text, query) in pairs {
      let expected = FindMatching.search(in: text, for: query)?.ranges.isEmpty == false
      let count = await rig.number(
        """
        const root = document.getElementById('um-root');
        root.textContent = text;
        return window.umViewer.find(query).count;
        """, ["text": text, "query": query])
      let folded = (count ?? 0) > 0 ? "y" : "n"

      XCTAssertEqual(folded, expected ? "y" : "n", "\(text) / \(query)")
    }
  }

  /// Catches Use Selection for Find that ignores the page's selection. A selection made in the
  /// page becomes the pane's query, and the system find pasteboard does not move.
  func testUseSelectionTakesTheMarkdownPagesSelection() async throws {
    let scratch = try Scratch(self)
    let applet = try await openMarkdown("first line\n\nsecond **bold** line\n", in: scratch)
    let view = try XCTUnwrap(applet.content.markdownView)
    let before = NSPasteboard(name: .find).changeCount

    _ = await view.run(
      "const p = document.querySelectorAll('p')[1]; window.getSelection().selectAllChildren(p)")
    await applet.finder.useSelection()

    XCTAssertEqual(applet.finder.state.query, "second bold line")
    XCTAssertEqual(applet.content.findBar.query, "second bold line")

    let counted = await Harness.eventually { applet.finder.state.matchCount == 1 }

    XCTAssertTrue(counted)
    XCTAssertEqual(NSPasteboard(name: .find).changeCount, before)
  }

  // MARK: Use Selection across lines

  /// A document the selection spans several lines of, with a table, so a cell boundary lies inside
  /// the span.
  private func tableRTF() throws -> Data {
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
    let text = NSMutableAttributedString(string: "Intro line\n", attributes: body)
    let table = NSTextTable()
    table.numberOfColumns = 2

    for (row, column, label) in [(0, 0, "Name"), (0, 1, "Value"), (1, 0, "alpha"), (1, 1, "one")] {
      let block = NSTextTableBlock(
        table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
      let style = NSMutableParagraphStyle()

      style.textBlocks = [block]
      text.append(
        NSAttributedString(
          string: label + "\n", attributes: body.merging([.paragraphStyle: style]) { $1 }))
    }

    text.append(NSAttributedString(string: "Closing line\n", attributes: body))

    return try text.data(
      from: NSRange(location: 0, length: text.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
  }

  /// Catches Use Selection for Find that yields a query the document does not hold, such as the
  /// lines of a selection joined by spaces. A selection across lines and table cells in RTF gives a
  /// query that matches, and the current match lies inside the selection.
  func testUseSelectionAcrossLinesAndCellsMatchesInsideTheSelectionInRTF() async throws {
    let scratch = try Scratch(self)
    let applet = try await open("t.rtf", try tableRTF(), in: scratch)
    let textView = applet.content.textView
    let whole = textView.string as NSString
    let start = whole.range(of: "Intro line").location
    let selection = NSRange(
      location: start, length: NSMaxRange(whole.range(of: "alpha")) - start)

    textView.setSelectedRange(selection)
    await applet.finder.useSelection()

    let counted = await Harness.eventually {
      !applet.finder.state.isSearching && applet.finder.state.matchCount >= 1
    }

    XCTAssertTrue(counted, "query \(applet.finder.state.query.debugDescription)")

    let current = textView.selectedRange()

    XCTAssertEqual(applet.finder.state.current, 0)
    XCTAssertGreaterThan(current.length, 0)
    XCTAssertGreaterThanOrEqual(current.location, selection.location)
    XCTAssertLessThanOrEqual(NSMaxRange(current), NSMaxRange(selection))
  }

  func testUseSelectionAcrossLinesMatchesInsideTheSelectionInAPDF() async throws {
    let scratch = try Scratch(self)
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(
      consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!

    context.beginPDFPage(nil)

    for (index, line) in ["first line here", "second line here", "third line here"].enumerated() {
      context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(index) * 40)
      CTLineDraw(
        CTLineCreateWithAttributedString(
          NSAttributedString(
            string: line, attributes: [.font: NSFont.systemFont(ofSize: 24)])), context)
    }

    context.endPDFPage()
    context.closePDF()

    let applet = try await open("m.pdf", data as Data, in: scratch)
    let pdfView = applet.content.pdfView
    let page = try XCTUnwrap(pdfView.document?.page(at: 0))
    let span = try XCTUnwrap(
      page.selection(for: CGRect(x: 60, y: 600, width: 400, height: 140)))

    XCTAssertTrue((span.string ?? "").contains("\n"), "the span covers several lines")

    pdfView.setCurrentSelection(span, animate: false)
    await applet.finder.useSelection()

    let counted = await Harness.eventually {
      !applet.finder.state.isSearching && applet.finder.state.matchCount >= 1
        && applet.finder.state.current != nil
    }

    XCTAssertTrue(counted, "query \(applet.finder.state.query.debugDescription)")

    let current = try XCTUnwrap(pdfView.currentSelection)
    let inside = span.bounds(for: page).insetBy(dx: -2, dy: -2)

    XCTAssertTrue(inside.contains(current.bounds(for: page)))
  }

  func testUseSelectionAcrossBlocksAndCellsMatchesInsideTheSelectionInMarkdown() async throws {
    let scratch = try Scratch(self)
    let applet = try await openMarkdown(
      """
      before the table

      | Name | Value |
      |------|-------|
      | alpha | one |

      after the table
      """, in: scratch)
    let view = try XCTUnwrap(applet.content.markdownView)

    _ = await view.run(
      "window.getSelection().selectAllChildren(document.querySelector('table'))")
    await applet.finder.useSelection()

    let counted = await Harness.eventually {
      !applet.finder.state.isSearching && applet.finder.state.matchCount >= 1
        && applet.finder.state.current != nil
    }

    XCTAssertTrue(counted, "query \(applet.finder.state.query.debugDescription)")

    await view.selectMatch(applet.finder.state.current ?? 0)

    let inside = await view.run(
      """
      const marks = document.querySelectorAll('mark.um-find-current');
      return marks.length > 0 && Array.from(marks).every(m => m.closest('table') !== null);
      """)

    XCTAssertEqual(inside as? Bool, true)
  }

  // MARK: Built-in find

  /// Catches a view whose own find machinery answers a find action. A find action sent down the
  /// responder chain opens the pane's bar and does not touch the system find pasteboard.
  func testFindActionsSentToTheViewsReachThePanesBar() async throws {
    let scratch = try Scratch(self)
    let before = NSPasteboard(name: .find).changeCount
    let text = try await openText("alpha", in: scratch)
    let pdf = try await open("a.pdf", DocumentFixtures.pdf(pages: ["alpha"]), in: scratch)

    for (applet, view) in [
      (text, text.content.textView as NSResponder), (pdf, pdf.content.pdfView as NSResponder),
    ] {
      let item = NSMenuItem()
      item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)

      XCTAssertTrue(applet.content.findBar.isHidden)
      view.tryToPerform(NSSelectorFromString("performFindPanelAction:"), with: item)
      XCTAssertFalse(applet.content.findBar.isHidden)
    }

    XCTAssertEqual(NSPasteboard(name: .find).changeCount, before)
  }
}
