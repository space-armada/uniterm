import AppKit
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

  /// Attaches a screenshot of the uniterm window only, so it carries nothing of the user's other
  /// windows.
  private func attachScreenshot(_ name: String, of window: XCUIElement) {
    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func plantViewer(path: String, anchor: String = "") throws {
    let start = URL(fileURLWithPath: path).deletingLastPathComponent().path

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"text-viewer","version":1,
      "payload":{"startDirectory":"\(start)","path":"\(path)","sidebarShown":false\(anchor)}}}}]}
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
    attachScreenshot("text viewer, empty state", of: window)
    open.click()
    choose(file, in: app, window: window)

    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 20) { $0 == "Page 1 of 2" },
      "the PDF never showed")
    XCTAssertFalse(open.exists, "the Open button stays over the document")
    attachScreenshot("text viewer, PDF", of: window)
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
    attachScreenshot("text viewer, RTF with a heading, bold text, and a table", of: window)
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
      attachScreenshot("text viewer, Markdown README, \(appearance) theme", of: window)
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
    attachScreenshot("text viewer, Markdown README restored at line 400", of: window)

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
}
