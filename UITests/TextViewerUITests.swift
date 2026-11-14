import AppKit
import PDFKit
import XCTest

/// Drives the text viewer in the launched app, with the real signed and sandboxed document helper.
/// Each test proves a contract that needs the real window server: the launcher entry, the open
/// panel, a document that opens through the sandboxed helper, and a layout that comes back over a
/// relaunch.
@MainActor
final class TextViewerUITests: UnitermUITestCase {
  private let closeWindowsOnQuit = ["-NSQuitAlwaysKeepsWindows", "NO"]

  private func makeFolder() throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-text-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    return folder
  }

  @discardableResult
  private func writePDF(_ name: String, pages: [String], in folder: URL) throws -> URL {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)

    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!

    for page in pages {
      context.beginPDFPage(nil)

      let text = NSAttributedString(
        string: page, attributes: [.font: NSFont.systemFont(ofSize: 24)])

      context.textPosition = CGPoint(x: 72, y: 700)
      CTLineDraw(CTLineCreateWithAttributedString(text), context)
      context.endPDFPage()
    }

    context.closePDF()

    let file = folder.appendingPathComponent(name)
    try (data as Data).write(to: file)

    return file
  }

  /// A document with a heading, body paragraphs with bold text, and a two by two table, so a
  /// screenshot shows layout.
  @discardableResult
  private func writeRTF(_ name: String, in folder: URL) throws -> URL {
    let body = NSFont.systemFont(ofSize: 14)
    let bold = NSFont.boldSystemFont(ofSize: 14)
    let text = NSMutableAttributedString()

    text.append(
      NSAttributedString(
        string: "A sample document\n",
        attributes: [.font: NSFont.boldSystemFont(ofSize: 26)]))
    text.append(
      NSAttributedString(
        string: "This paragraph has plain text and ", attributes: [.font: body]))
    text.append(NSAttributedString(string: "bold text", attributes: [.font: bold]))
    text.append(
      NSAttributedString(
        string: " in one line.\n\nA second paragraph follows, then a table.\n\n",
        attributes: [.font: body]))

    let table = NSTextTable()
    table.numberOfColumns = 2

    for (row, column, label) in [(0, 0, "Name"), (0, 1, "Value"), (1, 0, "alpha"), (1, 1, "1")] {
      let block = NSTextTableBlock(
        table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
      block.setBorderColor(.gray)
      block.setWidth(1, type: .absoluteValueType, for: .border)
      block.setWidth(4, type: .absoluteValueType, for: .padding)

      let style = NSMutableParagraphStyle()
      style.textBlocks = [block]

      text.append(
        NSAttributedString(
          string: label + "\n",
          attributes: [.font: row == 0 ? bold : body, .paragraphStyle: style]))
    }

    let data = try text.data(
      from: NSRange(location: 0, length: text.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])

    let file = folder.appendingPathComponent(name)
    try data.write(to: file)

    return file
  }

  /// A small image, so a README's relative image has pixels to draw.
  @discardableResult
  private func writePNG(_ name: String, in folder: URL) throws -> URL {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    for x in 0..<96 {
      for y in 0..<32 {
        rep.setColor(
          NSColor(calibratedRed: CGFloat(x) / 96, green: 0.4, blue: CGFloat(y) / 32, alpha: 1),
          atX: x, y: y)
      }
    }

    let file = folder.appendingPathComponent(name)
    try rep.representation(using: .png, properties: [:])!.write(to: file)

    return file
  }

  /// A README with the constructs the viewer renders: a centered raw-HTML header, a list, a code
  /// block, a table, `<details>`, `<kbd>`, and a relative image.
  @discardableResult
  private func writeREADME(in folder: URL, filler: Int = 0) throws -> URL {
    try writePNG("logo.png", in: folder)

    let padding = (0..<filler).map { "## Section \($0)\n\nParagraph \($0) of filler text.\n" }
      .joined(separator: "\n")

    let text = """
      <h1 align="center">uniterm sample</h1>

      <p align="center"><img src="logo.png" width="96" alt="logo"></p>

      ## Install

      - Build with <kbd>make</kbd>
      - Run with <kbd>make run</kbd>

      ```swift
      let greeting = "hello"
      ```

      | Name  | Value |
      |:------|------:|
      | alpha | 1     |
      | beta  | 2     |

      <details><summary>More</summary>

      Hidden until opened.

      </details>

      \(padding)
      """

    let file = folder.appendingPathComponent("README.md")
    try Data(text.utf8).write(to: file)

    return file
  }

  /// Attaches a screenshot of the uniterm window element only, never the screen. A window
  /// screenshot shows whatever is on screen over the window's rectangle, so the app must be in front
  /// first. When it cannot be brought forward, the test fails and attaches nothing, rather than
  /// attach pixels that belong to other applications.
  private func attachScreenshot(_ name: String, of window: XCUIElement, in app: XCUIApplication) {
    guard waitForForeground(app, activating: true) else {
      XCTFail("uniterm was not frontmost, so no screenshot was taken: \(name)")
      return
    }

    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func plantViewer(path: String, anchor: String = "", sidebar: Bool = false) throws {
    let start = URL(fileURLWithPath: path).deletingLastPathComponent().path

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"text-viewer","version":1,
      "payload":{"startDirectory":"\(start)","path":"\(path)","sidebarShown":\(sidebar)\(anchor)}}}}]}
      """)
  }

  private func viewer(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["text-viewer"]
  }

  private func segment(_ index: Int, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: "status-applet-\(index)").firstMatch
  }

  /// Catches a launcher without the text viewer, a pane that does not offer to open a document,
  /// and an open panel that does not end in a PDF. Cmd-D shows the launcher, Cmd-7 picks the text
  /// viewer, and the pane's Open button opens a panel that loads the chosen PDF and reports its
  /// page count in the status bar.
  func testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAPDF() throws {
    let file = try writePDF("paper.pdf", pages: ["one", "two"], in: try makeFolder())
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("7", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 10), "no text viewer pane")

    let open = window.buttons["text-viewer-open"]
    XCTAssertTrue(open.waitForExistence(timeout: 5), "an empty viewer has no Open button")
    attachScreenshot("text viewer, empty state", of: window, in: app)
    open.click()
    choose(file, in: app, window: window)

    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 1 of 2" },
      "the PDF never showed")
    XCTAssertFalse(open.exists, "the Open button stays over the document")
    attachScreenshot("text viewer, PDF", of: window, in: app)
  }

  /// Catches an RTF that does not reach the text view in the real app, which reads it only in the
  /// sandboxed helper. A planted pane restores the RTF and shows its character count.
  func testARestoredRTFOpensThroughTheSandboxedHelper() throws {
    let file = try writeRTF("note.rtf", in: try makeFolder())

    try plantViewer(path: file.path)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 20) { $0.hasSuffix(" characters") },
      "the RTF never showed. The sandboxed helper may not have started.")
    attachScreenshot("text viewer, RTF with a heading, bold text, and a table", of: window, in: app)
  }

  /// Catches a layout that loses the file or its view state over a relaunch. A planted PDF pane
  /// restores on its second page, and a quit saves a layout that holds the path and the page.
  func testARestoredPDFComesBackAtItsPageAndTheLayoutHoldsNoContents() throws {
    let file = try writePDF(
      "paper.pdf", pages: ["one", "two", "three"], in: try makeFolder())

    try plantViewer(path: file.path, anchor: #","anchor":{"page":1,"x":72,"y":700}"#)

    let app = launchApp(
      environment: ["UNITERM_LAYOUT_DEBOUNCE": "3600"], arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 2 of 3" })

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8
    ).replacingOccurrences(of: "\\/", with: "/")

    XCTAssertTrue(written.contains(file.path), "the path was not saved: \(written)")
    XCTAssertTrue(written.contains(#""page":1"#), "the page was not saved: \(written)")
    XCTAssertLessThan(written.utf8.count, 4096, "the document was saved in the layout")
  }

  /// Catches Markdown that does not render in the real app, in either theme. A planted pane restores
  /// a README with a raw-HTML header, a list, a code block, a table, `<details>`, `<kbd>`, and a
  /// relative image, and the status bar reports its line count once the page has rendered. The
  /// screenshots show the page in the light and the dark theme.
  func testAREADMERendersInTheLightAndDarkThemes() throws {
    let file = try writeREADME(in: try makeFolder())

    try plantViewer(path: file.path)

    for appearance in ["light", "dark"] {
      let app = launchApp(settings: ["appearance": appearance])
      let window = mainWindow(in: app)

      XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
      XCTAssertTrue(
        waitFor(segment(0, in: window), timeout: 30) { $0.hasSuffix(" lines") },
        "the README never rendered in the \(appearance) theme")

      Thread.sleep(forTimeInterval: 1)
      attachScreenshot("text viewer, Markdown README, \(appearance) theme", of: window, in: app)
      app.terminate()
    }
  }

  /// Catches a Markdown pane that loses its place over a relaunch. A planted pane restores a long
  /// README at a source line, and the layout a quit saves holds the line and no document text.
  func testARestoredREADMEKeepsItsSourceLineAcrossAQuit() throws {
    let file = try writeREADME(in: try makeFolder(), filler: 300)

    try plantViewer(
      path: file.path, anchor: #","anchor":{"sourceLine":400,"fraction":0}"#)

    let app = launchApp(
      environment: ["UNITERM_LAYOUT_DEBOUNCE": "3600"], arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 30) { $0.hasSuffix(" lines") })

    Thread.sleep(forTimeInterval: 1)
    attachScreenshot("text viewer, Markdown README restored at line 400", of: window, in: app)

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8
    ).replacingOccurrences(of: "\\/", with: "/")

    XCTAssertTrue(written.contains(file.path), "the path was not saved: \(written)")
    XCTAssertTrue(written.contains(#""sourceLine":"#), "the source line was not saved: \(written)")
    XCTAssertFalse(written.contains("Paragraph 100"), "the document was saved in the layout")
    XCTAssertLessThan(written.utf8.count, 4096)
  }

  /// Catches a pane that goes stale while its file is edited. The test opens a PDF through the open
  /// panel, rewrites it in place, then replaces it by renaming a new file over it, as an editor's
  /// save does. The page count in the status bar follows each change.
  ///
  /// The package tests drive the same reload against a pane in a test process. This one owns what
  /// only the real app shows: the status bar's segment text over the real watch, with the file
  /// opened through the real open panel.
  func testAnEditedFileReloadsInPlaceAndByRename() throws {
    let folder = try makeFolder()
    let file = try writePDF("paper.pdf", pages: ["one"], in: folder)
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))
    app.typeKey("7", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(launcher(in: window)))

    let open = window.buttons["text-viewer-open"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.click()
    choose(file, in: app, window: window)
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 1 of 1" })

    try writePDF("paper.pdf", pages: ["one", "two", "three"], in: folder)
    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 1 of 3" },
      "a write in place did not reload the pane")

    let replacement = try writePDF(".paper.pdf.tmp", pages: ["a", "b", "c", "d", "e"], in: folder)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 1 of 5" },
      "a write-new-then-rename save did not reload the pane")
  }

  /// Catches a deleted file that blanks the pane or leaves no sign. The render stays, a warning
  /// segment says the file was moved or deleted, and it clears when the file returns and reloads.
  ///
  /// The package tests prove the gone state, the single warning, and the reload on a pane object.
  /// This one owns the real status bar segment and its warning style, and the real watch in the
  /// launched app deleting and recreating the file under a restored pane.
  func testADeletedFileShowsTheMovedOrDeletedSegmentUntilItReturns() throws {
    let folder = try makeFolder()
    let file = try writePDF("paper.pdf", pages: ["one", "two"], in: folder)

    try plantViewer(path: file.path)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 1 of 2" })

    try FileManager.default.removeItem(at: file)

    XCTAssertTrue(
      waitFor(segment(1, in: window), timeout: 20) { $0 == "Moved or deleted" },
      "the Moved or deleted segment never showed")
    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 5) { $0 == "Page 1 of 2" },
      "the render did not stay")
    attachScreenshot("text viewer, file deleted, Moved or deleted segment", of: window, in: app)

    try writePDF("paper.pdf", pages: ["one", "two", "three", "four"], in: folder)

    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 1 of 4" },
      "the file did not reload when it came back")
    XCTAssertFalse(
      segment(1, in: window).exists
        && (segment(1, in: window).value as? String) == "Moved or deleted",
      "the segment stayed after the file returned")
  }

  /// Catches a closed viewer pane that asks, since a read-only viewer never counts as running
  /// something.
  func testClosingAViewerNeverAsks() throws {
    let file = try writePDF("paper.pdf", pages: ["one"], in: try makeFolder())

    try plantViewer(path: file.path)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitForNoSheet(in: window, timeout: 3), "closing a viewer asked first")
  }

  // MARK: Find

  private func findField(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["text-viewer-find"]
  }

  private func findCount(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["text-viewer-find-count"]
  }

  /// Opens the pane's find bar with Cmd-F and types `query` into it.
  private func find(_ query: String, in app: XCUIApplication, window: XCUIElement) {
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(findField(in: window).waitForExistence(timeout: 5), "Cmd-F opened no find bar")
    app.typeText(query)
  }

  /// Catches a find bar that differs between formats, or one that does not step. Each format opens
  /// the bar with Cmd-F, shows a count after typing, steps with Return and Shift-Return, and wraps.
  /// The screenshots show the bar with matches in a PDF, an RTF, and a README.
  func testFindShowsMatchesAndCountsAndStepsInEveryFormat() throws {
    let folder = try makeFolder()
    let pdf = try writePDF("paper.pdf", pages: ["alpha beta", "Alpha gamma"], in: folder)
    let rtf = try writeRTF("note.rtf", in: folder)
    let readme = try writeREADME(in: folder, filler: 2)

    let cases: [(String, URL, String, String)] = [
      ("PDF", pdf, "alpha", "1 of 2"), ("RTF", rtf, "paragraph", "1 of 2"),
      ("Markdown", readme, "paragraph", "1 of 2"),
    ]

    for (format, file, query, first) in cases {
      try plantViewer(path: file.path)

      let app = launchApp()
      let window = mainWindow(in: app)

      XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no pane for \(format)")
      XCTAssertTrue(
        waitFor(segment(0, in: window), timeout: 30) { !$0.isEmpty }, "\(format) never loaded")

      find(query, in: app, window: window)
      XCTAssertTrue(
        waitFor(findCount(in: window), timeout: 20) { $0 == first },
        "\(format) count: \(String(describing: findCount(in: window).value))")

      app.typeKey(.return, modifierFlags: [])
      XCTAssertTrue(waitFor(findCount(in: window), timeout: 5) { $0 == "2 of 2" }, format)
      attachScreenshot("text viewer, find in \(format), second match", of: window, in: app)

      app.typeKey(.return, modifierFlags: .shift)
      XCTAssertTrue(waitFor(findCount(in: window), timeout: 5) { $0 == "1 of 2" }, format)

      app.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(waitUntilGone(findField(in: window), timeout: 5), "Escape left the bar")
      app.terminate()
    }
  }

  /// Catches Use Selection for Find writing the system find pasteboard, or leaving the pane's query
  /// alone. A sentinel sits on the find pasteboard first. Cmd-A selects the document and Cmd-E sets
  /// the pane's query from it, and the sentinel must still be there afterward.
  func testUseSelectionForFindSetsTheQueryAndLeavesTheSystemFindPasteboard() throws {
    let rtf = try writeRTF("note.rtf", in: try makeFolder())
    let findBoard = NSPasteboard(name: .find)
    let saved = findBoard.string(forType: .string)
    let sentinel = "sentinel-\(UUID().uuidString)"

    findBoard.clearContents()
    findBoard.setString(sentinel, forType: .string)
    addTeardownBlock {
      findBoard.clearContents()
      if let saved { findBoard.setString(saved, forType: .string) }
    }

    try plantViewer(path: rtf.path)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0.hasSuffix(" characters") })

    window.descendants(matching: .any)["text-viewer-text"].click()
    app.typeKey("a", modifierFlags: .command)
    app.typeKey("e", modifierFlags: .command)

    XCTAssertTrue(
      waitFor(findField(in: window), timeout: 10) { $0.hasPrefix("A sample document") },
      "Use Selection for Find left the query: \(String(describing: findField(in: window).value))")
    attachScreenshot("text viewer, Use Selection for Find", of: window, in: app)

    XCTAssertEqual(findBoard.string(forType: .string), sentinel)

    window.buttons["text-viewer-find-close"].click()
    XCTAssertTrue(waitUntilGone(findField(in: window), timeout: 5), "Done left the bar")

    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(findField(in: window).waitForExistence(timeout: 5))
    XCTAssertEqual(
      findField(in: window).value as? String, "", "a closed bar keeps no query for the next open")
  }

  // MARK: Contents

  /// A PDF with `titles.count` chapters, each on its own page, and an outline that lists them.
  @discardableResult
  private func writeOutlinedPDF(_ name: String, titles: [String], in folder: URL) throws -> URL {
    let plain = try writePDF("plain-\(name)", pages: titles, in: folder)
    let document = try XCTUnwrap(PDFDocument(url: plain))
    let root = PDFOutline()

    for (index, title) in titles.enumerated() {
      let chapter = PDFOutline()
      chapter.label = title
      chapter.destination = PDFDestination(
        page: try XCTUnwrap(document.page(at: index)), at: CGPoint(x: 72, y: 700))
      root.insertChild(chapter, at: index)
    }

    document.outlineRoot = root

    let file = folder.appendingPathComponent(name)
    XCTAssertTrue(document.write(to: file))

    return file
  }

  private func menuItem(_ title: String, under menu: String, in app: XCUIApplication)
    -> XCUIElement
  {
    app.menuBars.menuBarItems[menu].click()

    return app.menuBars.menuItems[title]
  }

  /// Catches a contents sidebar that is missing in a PDF or a README, one whose entries do not
  /// scroll, and one that loses its visibility over a quit. Show Contents in the View menu opens the
  /// sidebar, an entry moves the PDF to its page, and a relaunch keeps the sidebar shown.
  func testTheContentsSidebarListsAPDFOutlineScrollsAndSurvivesARelaunch() throws {
    let folder = try makeFolder()
    let file = try writeOutlinedPDF(
      "book.pdf", titles: ["Intro", "Middle", "End"], in: folder)

    try plantViewer(path: file.path)

    let app = launchApp(
      environment: ["UNITERM_LAYOUT_DEBOUNCE": "3600"], arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)
    let entry = window.tables["text-viewer-contents"].staticTexts["End"]

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 1 of 3" })

    let toggle = menuItem("Show Contents", under: "View", in: app)
    XCTAssertTrue(toggle.isEnabled, "a PDF with an outline has Show Contents off")
    toggle.click()

    XCTAssertTrue(entry.waitForExistence(timeout: 10), "the sidebar listed no entries")
    entry.click()
    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 10) { $0 == "Page 3 of 3" },
      "selecting an entry did not move the PDF")
    attachScreenshot("text viewer, PDF with the contents sidebar", of: window, in: app)

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let relaunched = launchApp(arguments: closeWindowsOnQuit)
    let restored = mainWindow(in: relaunched)

    XCTAssertTrue(viewer(in: restored).waitForExistence(timeout: 20))
    XCTAssertTrue(
      restored.tables["text-viewer-contents"].staticTexts["Intro"].waitForExistence(timeout: 20),
      "the sidebar did not come back over a relaunch")
  }

  /// Catches a README whose headings are missing from the sidebar, and an entry that does not scroll
  /// the page. The screenshot shows the sidebar beside the rendered page.
  func testTheContentsSidebarListsMarkdownHeadings() throws {
    let file = try writeREADME(in: try makeFolder(), filler: 40)

    try plantViewer(path: file.path, sidebar: true)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 30) { $0.hasSuffix(" lines") })

    let last = window.tables["text-viewer-contents"].staticTexts["Section 28"]
    XCTAssertTrue(last.waitForExistence(timeout: 20), "the sidebar listed no headings")
    attachScreenshot("text viewer, Markdown with the contents sidebar", of: window, in: app)

    last.click()
    attachScreenshot("text viewer, Markdown after choosing a heading", of: window, in: app)
  }

  /// Catches an RTF that invents a list, and a sidebar with nothing to say. The system RTF reader
  /// sets no heading level on this macOS, so Show Contents is off for it, and a sidebar that was
  /// left shown says there are no contents.
  func testAnRTFWithNoHeadingLevelsHasNoContents() throws {
    let rtf = try writeRTF("note.rtf", in: try makeFolder())

    try plantViewer(path: rtf.path, sidebar: true)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no text viewer pane")
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0.hasSuffix(" characters") })
    XCTAssertTrue(
      window.descendants(matching: .any)["text-viewer-contents-empty"].waitForExistence(
        timeout: 10),
      "the sidebar did not say there are no contents")
    attachScreenshot("text viewer, RTF with no contents", of: window, in: app)

    let toggle = menuItem("Show Contents", under: "View", in: app)
    XCTAssertTrue(toggle.exists)
    XCTAssertTrue(toggle.isEnabled, "the command stays on so the sidebar can be hidden")
    toggle.click()

    XCTAssertTrue(waitUntilGone(window.descendants(matching: .any)["text-viewer-contents-empty"]))

    let off = menuItem("Show Contents", under: "View", in: app)
    XCTAssertFalse(off.isEnabled, "no outline and no sidebar, so Show Contents is off")
    app.typeKey(.escape, modifierFlags: [])
  }
}
