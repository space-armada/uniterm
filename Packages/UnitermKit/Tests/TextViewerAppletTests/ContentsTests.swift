import AppKit
import AppletKit
import DocumentTestSupport
import PDFKit
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// The contents sidebar, from each format's structure to the saved visibility.
@MainActor
final class ContentsTests: XCTestCase {
  private var windows: [NSWindow] = []

  private func host(_ applet: TextViewerApplet) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.contentView = applet.content
    windows.append(window)
  }

  private func open(
    _ name: String, _ data: Data, in scratch: Scratch,
    restoring description: TextViewerDescription? = nil
  ) async throws -> TextViewerApplet {
    let file = try scratch.write(name, data)
    let applet: TextViewerApplet

    if var description {
      description.path = file.path
      applet = try Harness.restored(description)
      host(applet)
      applet.start(origin: .restore)
    } else {
      applet = Harness.applet(startDirectory: scratch.url.path)
      host(applet)
      try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    }

    let done = await Harness.settled(applet)
    XCTAssertTrue(done, name)

    if applet.content.body == .markdown {
      let rendered = await Harness.eventually { applet.content.markdownView?.isRendered == true }
      XCTAssertTrue(rendered)
    }

    return applet
  }

  /// A PDF with an outline of `titles`, each a chapter on its own page. `children` nests that many
  /// entries under the first chapter.
  private func outlinedPDF(titles: [String], children: Int = 0) throws -> Data {
    let source = PDFDocument(data: DocumentFixtures.pdf(pages: titles))!
    let root = PDFOutline()

    for (index, title) in titles.enumerated() {
      let chapter = PDFOutline()
      chapter.label = title
      chapter.destination = PDFDestination(
        page: source.page(at: index)!, at: CGPoint(x: 72, y: 700))
      root.insertChild(chapter, at: index)

      if index == 0 {
        for nested in 0..<children {
          let child = PDFOutline()
          child.label = "Section \(nested)"
          child.destination = chapter.destination
          chapter.insertChild(child, at: nested)
        }
      }
    }

    source.outlineRoot = root

    return try XCTUnwrap(source.dataRepresentation())
  }

  // MARK: PDF

  /// Catches a PDF outline that is not listed, one that loses its nesting, and a selection that
  /// does not move to the entry's page.
  func testAPDFOutlineIsListedAndSelectingAnEntryScrollsThere() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      "a.pdf", try outlinedPDF(titles: ["Intro", "Middle", "End"], children: 2), in: scratch)

    XCTAssertEqual(
      applet.contents.entries.map(\.title), ["Intro", "Section 0", "Section 1", "Middle", "End"])
    XCTAssertEqual(applet.contents.entries.map(\.level), [1, 2, 2, 1, 1])
    XCTAssertNil(applet.contents.cut)
    XCTAssertTrue(applet.canShowContents)

    applet.toggleContents()
    XCTAssertFalse(applet.content.sidebar.isHidden)

    applet.content.layoutSubtreeIfNeeded()

    let cell = try XCTUnwrap(
      applet.content.sidebar.table.view(atColumn: 0, row: 4, makeIfNecessary: true)
        as? NSTableCellView)

    XCTAssertEqual(cell.textField?.stringValue, "End")
    XCTAssertEqual(cell.accessibilityLabel(), "End")

    applet.content.sidebar.select(row: 4)

    let moved = await Harness.eventually {
      applet.content.pdfView.currentPage.map { applet.content.pdfView.document?.index(for: $0) }
        == 2
    }

    XCTAssertTrue(moved)
  }

  /// Catches an outline jump that puts its destination flush against the top of the view, where
  /// only a sliver of the page shows. A destination near the top of its page shows the page top.
  func testAnOutlineJumpShowsThePageFromItsTopWithRoomAbove() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      "a.pdf", try outlinedPDF(titles: ["Intro", "Middle", "End"]), in: scratch)
    let pdfView = applet.content.pdfView

    applet.toggleContents()
    applet.content.layoutSubtreeIfNeeded()
    pdfView.layoutDocumentView()
    applet.content.sidebar.select(row: 2)

    let atTop = await Harness.eventually {
      pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } == 2
        && (pdfView.currentDestination?.point.y ?? 0) >= 791
    }

    XCTAssertTrue(
      atTop, "the jump landed at y \(pdfView.currentDestination?.point.y ?? -1), not the page top")
  }

  /// Catches a selected sidebar title drawn in the unselected color, which is dark on the system's
  /// blue selection. The title takes the selection text color while its row is selected.
  func testASelectedSidebarTitleUsesTheSelectionTextColor() {
    let cell = ContentsCellView()
    let label = NSTextField(labelWithString: "Title")
    let normal = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.4, alpha: 1)

    cell.textField = label
    cell.normalColor = normal

    XCTAssertEqual(label.textColor, normal)

    cell.backgroundStyle = .emphasized

    XCTAssertEqual(label.textColor, .alternateSelectedControlTextColor)

    cell.backgroundStyle = .normal

    XCTAssertEqual(label.textColor, normal)
  }

  /// Catches the strip that an empty cut message left at the bottom of the sidebar. With nothing
  /// cut, the list runs to the bottom edge.
  func testTheListRunsToTheBottomEdgeWhenNothingWasCut() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      "a.pdf", try outlinedPDF(titles: ["Intro", "End"]), in: scratch)

    applet.toggleContents()
    applet.content.layoutSubtreeIfNeeded()

    let sidebar = applet.content.sidebar
    let list = sidebar.convert(sidebar.table.enclosingScrollView?.frame ?? .zero, to: sidebar)

    XCTAssertEqual(list.minY, 0, accuracy: 1)
    XCTAssertEqual(list.height, sidebar.bounds.height, accuracy: 1)
  }

  /// Catches an enormous outline that is listed whole, and a list that does not say it was cut.
  func testAHugePDFOutlineIsCappedAndTheSidebarSaysSo() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      "a.pdf", try outlinedPDF(titles: ["One"], children: Contents.maxEntries + 100), in: scratch)

    XCTAssertEqual(applet.contents.entries.count, Contents.maxEntries)
    XCTAssertEqual(applet.contents.cut, .entryCap)

    applet.toggleContents()

    XCTAssertTrue(applet.content.sidebar.showsCutMessage)
  }

  /// Catches an outline that loops. A hand-written file whose only entry names itself as its own
  /// first child must still produce a list. PDFKit reads the loop as one entry itself, and the
  /// walker's visited set and caps are the second guard, which the model tests drive directly.
  func testACyclicPDFOutlineEnds() async throws {
    let scratch = try Scratch(self)
    let pdf = """
      %PDF-1.4
      1 0 obj << /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >> endobj
      2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
      3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj
      4 0 obj << /Type /Outlines /First 5 0 R /Last 5 0 R /Count 1 >> endobj
      5 0 obj << /Title (Loop) /Parent 4 0 R /First 5 0 R /Last 5 0 R /Count 1 /Dest [3 0 R /XYZ 0 200 0] >> endobj
      trailer << /Root 1 0 R /Size 6 >>
      %%EOF
      """

    let applet = try await open("loop.pdf", Data(pdf.utf8), in: scratch)

    XCTAssertEqual(applet.content.body, .pdf)
    XCTAssertEqual(applet.contents.entries.map(\.title), ["Loop"])
  }

  // MARK: RTF and Word

  /// Catches heading levels that never reach the list. The system readers set a level only where
  /// the file names one, so this feeds the builder a string that carries levels, as the helper's
  /// reply does, and shows it through the pane.
  func testTextHeadingsFromTheirLevelsAreListedAndSelectingScrolls() async throws {
    let applet = Harness.applet()

    host(applet)

    let text = NSMutableAttributedString()

    for index in 0..<40 {
      let style = NSMutableParagraphStyle()
      style.headerLevel = index % 3 == 0 ? 1 : 2

      text.append(
        NSAttributedString(
          string: "Heading \(index)\n",
          attributes: [.paragraphStyle: style, .font: NSFont.boldSystemFont(ofSize: 20)]))
      text.append(
        NSAttributedString(
          string: String(repeating: "Body line of text.\n", count: 12),
          attributes: [.font: NSFont.systemFont(ofSize: 13)]))
    }

    let built = ContentsBuilders.text(text)

    XCTAssertEqual(built.entries.count, 40)
    XCTAssertEqual(built.entries[0].title, "Heading 0")
    XCTAssertEqual(built.entries[0].level, 1)
    XCTAssertEqual(built.entries[1].level, 2)

    applet.show(text: text, contents: built, anchor: nil)

    XCTAssertTrue(applet.canShowContents)

    applet.toggleContents()
    applet.content.layoutSubtreeIfNeeded()
    applet.content.sidebar.select(row: 30)

    let scrolled = applet.content.scrollView.contentView.bounds.minY

    XCTAssertGreaterThan(scrolled, 100)
  }

  /// Catches a document the reader gave no heading levels getting an invented list. Nothing is
  /// inferred from fonts, so a big bold first line is not a heading.
  func testADocumentWithoutHeadingLevelsHasNoContents() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      "a.rtf", try DocumentFixtures.rtf(body: "Body", heading: "Big"), in: scratch)

    XCTAssertTrue(applet.contents.isEmpty)
    XCTAssertFalse(applet.canShowContents)

    let command = try XCTUnwrap(
      TextViewerApplet.commandSet.commands.first { $0.name == "show-contents" })

    XCTAssertFalse(command.isAvailable(applet))
  }

  // MARK: Markdown

  /// Catches Markdown headings that do not reach the list, and a selection that does not scroll the
  /// page. A heading nested in a details element must scroll by its own position, not by a line
  /// the unit shares.
  func testMarkdownHeadingsAreListedAndSelectingScrollsThePage() async throws {
    let scratch = try Scratch(self)
    let filler = String(repeating: "Some body text in a paragraph.\n\n", count: 40)
    let text = (0..<12).map { "## Part \($0)\n\n\(filler)" }.joined()
    let applet = try await open("README.md", Data(text.utf8), in: scratch)

    XCTAssertEqual(applet.contents.entries.count, 12)
    XCTAssertEqual(applet.contents.entries[3].title, "Part 3")

    applet.toggleContents()
    applet.content.sidebar.select(row: 9)

    let view = try XCTUnwrap(applet.content.markdownView)

    await view.scrollToHeading(9)

    let value = await view.run(
      "return Math.round(document.querySelectorAll('h2')[9].getBoundingClientRect().top)")
    let top = (value as? NSNumber)?.intValue ?? Int.max

    XCTAssertLessThan(abs(top), 8)
  }

  /// Catches a heading list past the page's cap that gives no sign. The page reports the cut, and
  /// the sidebar says it.
  func testMoreMarkdownHeadingsThanTheCapAreCutAndSaid() async throws {
    let scratch = try Scratch(self)
    let text = (0..<(Contents.maxEntries + 20)).map { "# H\($0)\n" }.joined(separator: "\n")
    let applet = try await open("README.md", Data(text.utf8), in: scratch)

    XCTAssertEqual(applet.contents.entries.count, Contents.maxEntries)
    XCTAssertEqual(applet.contents.cut, .entryCap)

    applet.toggleContents()

    XCTAssertTrue(applet.content.sidebar.showsCutMessage)
  }

  // MARK: Visibility

  /// Catches a sidebar whose visibility is lost over a reopen. Toggling saves the flag in the
  /// description, a restored pane shows the sidebar, and hiding saves again.
  func testTheSidebarsVisibilitySurvivesRestore() async throws {
    let scratch = try Scratch(self)
    let data = try outlinedPDF(titles: ["Intro", "End"])
    let applet = try await open("a.pdf", data, in: scratch)

    XCTAssertTrue(applet.content.sidebar.isHidden)

    applet.toggleContents()

    let described = try TextViewerDescription.decode(applet.describe())

    XCTAssertTrue(described.sidebarShown)

    let reopened = try await open("b.pdf", data, in: scratch, restoring: described)

    XCTAssertFalse(reopened.content.sidebar.isHidden)

    reopened.toggleContents()

    XCTAssertFalse(try TextViewerDescription.decode(reopened.describe()).sidebarShown)
    XCTAssertTrue(reopened.content.sidebar.isHidden)
  }

  /// Catches a shown sidebar that cannot be hidden when the next document has no outline, and a
  /// sidebar with nothing to say. It says there are no contents, and the command stays on to hide it.
  func testAShownSidebarWithNoOutlineSaysSoAndCanBeHidden() async throws {
    let scratch = try Scratch(self)
    let description = TextViewerDescription(sidebarShown: true)
    let applet = try await open(
      "a.pdf", DocumentFixtures.pdf(pages: ["plain"]), in: scratch, restoring: description)

    XCTAssertFalse(applet.content.sidebar.isHidden)
    XCTAssertTrue(applet.content.sidebar.showsEmptyMessage)
    XCTAssertTrue(applet.canShowContents)

    applet.toggleContents()

    XCTAssertTrue(applet.content.sidebar.isHidden)
    XCTAssertFalse(applet.canShowContents)
  }

  /// Catches a layout that hides the document behind the sidebar or the find bar. With both showing,
  /// the sidebar keeps its width at the left, the bar sits above the document, and the document
  /// fills the rest.
  func testTheSidebarAndFindBarLeaveRoomForTheDocument() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      "a.pdf", try outlinedPDF(titles: ["Intro", "End"]), in: scratch)
    let content = applet.content

    applet.toggleContents()
    applet.showFind()
    content.layoutSubtreeIfNeeded()

    let pdf = content.convert(content.pdfView.bounds, from: content.pdfView)

    XCTAssertEqual(content.sidebar.frame.width, ContentsSidebarView.width)
    XCTAssertEqual(content.sidebar.frame.minX, 0)
    XCTAssertGreaterThan(content.findBar.frame.height, 10)
    XCTAssertGreaterThanOrEqual(pdf.minX, ContentsSidebarView.width)
    XCTAssertGreaterThan(pdf.height, 200)
    XCTAssertEqual(pdf.maxX, content.bounds.maxX, accuracy: 1)
  }
}
