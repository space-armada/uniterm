import AppKit
import XCTest

/// Drives the data viewer in the launched app. Each test proves a contract that needs the real
/// window server: the launcher entry, the open panel, the router's choice of applet for a CSV
/// file, and a layout that comes back over a relaunch.
///
/// A drop of several files is refused with a message, but XCUITest cannot start a drag from
/// Finder. The package tests prove that rule on the applet's drop entry point.
@MainActor
final class DataViewerUITests: UnitermUITestCase {
  private let closeWindowsOnQuit = ["-NSQuitAlwaysKeepsWindows", "NO"]
  private let quitSavesOnly = ["UNITERM_LAYOUT_DEBOUNCE": "3600"]

  private func makeCSV(_ text: String, name: String = "sales.csv") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-data-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let file = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    return file
  }

  private func plantViewer(path: String, extra: String = "") throws {
    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"data-viewer","version":1,
      "payload":{"startDirectory":"\(URL(fileURLWithPath: path).deletingLastPathComponent().path)",
      "path":"\(path)"\(extra)}}}}]}
      """)
  }

  private func viewer(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["data-viewer"]
  }

  private func countText(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: "status-applet-0").firstMatch
  }

  /// Catches a launcher without the data viewer, a pane that does not offer to open a file, and an
  /// open panel that does not end in a table. Cmd-D shows the launcher, Cmd-3 picks the data
  /// viewer, and the pane's Open button opens a panel that loads the chosen file.
  func testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile() throws {
    let file = try makeCSV("region,amount\neast,3\nwest,5\nnorth,2\n")
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("3", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 10), "no data viewer pane")

    let open = window.buttons["data-viewer-open"]
    XCTAssertTrue(open.waitForExistence(timeout: 5), "an empty viewer has no Open button")
    open.click()

    choose(file, in: app, window: window)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 10), "no table")
    XCTAssertTrue(waitFor(countText(in: window), timeout: 10) { $0 == "3 rows" })
  }

  /// Catches Cmd-O routing a CSV file anywhere but the data viewer. The file opens in a new pane
  /// beside the terminal.
  func testCommandORoutesACSVFileToTheDataViewer() throws {
    let file = try makeCSV("region,amount\neast,3\n")
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("o", modifierFlags: .command)
    choose(file, in: app, window: window)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 15), "no table")
    XCTAssertTrue(window.textViews["terminal"].exists, "the terminal went away")
  }

  /// Catches a restore that loses the file, its sort, or its filter, and one that stores rows. The
  /// saved pane loads again at launch with the filter and the descending sort applied. After a quit
  /// the layout holds the path and the filter and none of the file's cells.
  func testARestoredViewerShowsTheFileWithItsSortAndFilterAndStoresNoRows() throws {
    let file = try makeCSV("name,amount\nax,3\nbx,1\ncy,2\ndx,5\n")

    try plantViewer(
      path: file.path,
      extra:
        #","filter":"x","sort":{"column":{"segments":["amount"],"occurrence":0},"ascending":false}"#
    )

    let app = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 20), "no table")
    XCTAssertTrue(waitFor(countText(in: window), timeout: 10) { $0 == "3 of 4 rows" })

    let first = window.tables["data-viewer-table"].cells.element(boundBy: 0)
    XCTAssertTrue(first.staticTexts["dx"].waitForExistence(timeout: 5), "the sort did not apply")

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    // The layout encoder writes "/" as "\/", which is valid JSON for the same string.
    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8
    ).replacingOccurrences(of: "\\/", with: "/")

    XCTAssertTrue(written.contains(file.path), "the path was not saved: \(written)")
    XCTAssertTrue(written.contains(#""filter":"x""#))

    // A bookmark is base64 that carries the file's inode, so it can spell a short value by chance.
    let saved = written.replacingOccurrences(
      of: #""bookmark":"[^"]*""#, with: "", options: .regularExpression)

    XCTAssertFalse(saved.contains("dx"), "rows were saved in the layout: \(saved)")
  }

  /// Catches a nested JSON cell that does not open. A double click on an array cell opens its
  /// values as a table in a popover over the pane, and the table shows the array's own rows.
  func testADoubleClickOnANestedCellOpensItAsATable() throws {
    let file = try makeCSV(
      #"[{"name":"first","tags":[{"t":"alpha"},{"t":"beta"}]}]"#, name: "items.json")

    try plantViewer(path: file.path)

    let app = launchApp()
    let window = mainWindow(in: app)
    let table = window.tables["data-viewer-table"]

    XCTAssertTrue(table.waitForExistence(timeout: 20), "no table")

    let nestedCell = table.staticTexts.matching(
      NSPredicate(format: "value BEGINSWITH %@", "\u{25B8} ")
    ).firstMatch

    XCTAssertTrue(nestedCell.waitForExistence(timeout: 10), "no nested cell")
    nestedCell.doubleClick()

    let nested = app.descendants(matching: .any)["data-viewer-table-nested"]

    XCTAssertTrue(nested.waitForExistence(timeout: 10), "the nested table never opened")
    XCTAssertTrue(nested.staticTexts["alpha"].waitForExistence(timeout: 5), "no nested row")
    XCTAssertTrue(nested.staticTexts["beta"].exists, "no second nested row")
  }

  /// Catches a missing file that shows an empty table or crashes the restore. The pane says the
  /// file is missing.
  func testARestoredViewerWhoseFileIsGoneSaysSo() throws {
    try plantViewer(path: "/private/tmp/uniterm-no-such-file-\(UUID().uuidString).csv")

    let app = launchApp()
    let window = mainWindow(in: app)
    let message = window.descendants(matching: .any).matching(identifier: "data-viewer-message")
      .firstMatch

    XCTAssertTrue(message.waitForExistence(timeout: 20), "no message")
    XCTAssertTrue(
      waitFor(message, timeout: 5) { $0.contains("missing") }, "the message does not say missing")
  }

  // MARK: Workbooks

  /// A workbook with two sheets of text cells, written as a ZIP archive of stored entries. Sales
  /// has two data rows and Costs has one.
  ///
  /// The ZIP writer here is a copy. This target cannot import the package, so it cannot use the
  /// shared writer, `ZipFixture` in the package's `TableTestSupport` test-support target. Keep the
  /// two in step.
  private func makeWorkbook(name: String = "book.xlsx") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-data-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    func sheet(_ rows: [[String]]) -> String {
      let body = rows.map { cells in
        "<row>" + cells.map { "<c t=\"inlineStr\"><is><t>\($0)</t></is></c>" }.joined() + "</row>"
      }.joined()

      return "<worksheet><sheetData>\(body)</sheetData></worksheet>"
    }

    let parts: [(String, String)] = [
      (
        "_rels/.rels",
        "<Relationships><Relationship Id=\"r\" Type=\"x/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
      ),
      (
        "xl/workbook.xml",
        "<workbook xmlns:r=\"x\"><sheets><sheet name=\"Sales\" r:id=\"r1\"/><sheet name=\"Costs\" r:id=\"r2\"/></sheets></workbook>"
      ),
      (
        "xl/_rels/workbook.xml.rels",
        "<Relationships><Relationship Id=\"r1\" Type=\"x/worksheet\" Target=\"s1.xml\"/><Relationship Id=\"r2\" Type=\"x/worksheet\" Target=\"s2.xml\"/></Relationships>"
      ),
      ("xl/s1.xml", sheet([["region", "amount"], ["east", "3"], ["west", "5"]])),
      ("xl/s2.xml", sheet([["item", "cost"], ["rent", "9"]])),
    ]

    func le(_ value: Int, _ width: Int) -> [UInt8] {
      (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    func crc(_ bytes: [UInt8]) -> Int {
      var value: UInt32 = 0xFFFF_FFFF

      for byte in bytes {
        value ^= UInt32(byte)

        for _ in 0..<8 {
          value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
      }

      return Int(value ^ 0xFFFF_FFFF)
    }

    var archive: [UInt8] = []
    var directory: [UInt8] = []

    for (path, text) in parts {
      let body = Array(text.utf8)
      let name = Array(path.utf8)
      let offset = archive.count

      archive += le(0x0403_4B50, 4) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(crc(body), 4)
      archive += le(body.count, 4) + le(body.count, 4) + le(name.count, 2) + le(0, 2) + name + body

      directory += le(0x0201_4B50, 4) + le(20, 2) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 4)
      directory += le(crc(body), 4) + le(body.count, 4) + le(body.count, 4) + le(name.count, 2)
      directory += le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(offset, 4) + name
    }

    let directoryStart = archive.count

    archive += directory
    archive += le(0x0605_4B50, 4) + le(0, 2) + le(0, 2) + le(parts.count, 2) + le(parts.count, 2)
    archive += le(directory.count, 4) + le(directoryStart, 4) + le(0, 2)

    let file = folder.appendingPathComponent(name)
    try Data(archive).write(to: file)
    return file
  }

  /// Catches Cmd-O routing an `.xlsx` file anywhere but the data viewer, a workbook that shows no
  /// sheet picker, and a picker that does not switch the table. The first sheet has two rows, and
  /// choosing Costs shows its one row.
  func testCommandOOpensAWorkbookAndTheSheetPickerSwitchesSheets() throws {
    let file = try makeWorkbook()
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("o", modifierFlags: .command)
    choose(file, in: app, window: window)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 15), "no table")
    XCTAssertTrue(waitFor(countText(in: window), timeout: 10) { $0 == "2 rows" })

    let picker = window.popUpButtons["data-viewer-sheets"]
    XCTAssertTrue(picker.waitForExistence(timeout: 5), "no sheet picker")

    picker.click()
    window.menuItems["Costs"].click()

    XCTAssertTrue(waitFor(countText(in: window), timeout: 10) { $0 == "1 rows" })
    XCTAssertTrue(
      window.tables["data-viewer-table"].staticTexts["rent"].waitForExistence(timeout: 5),
      "the second sheet's row is not shown")
  }

  /// Catches a relaunch that shows the first sheet again. The saved pane stores the sheet name and
  /// loads that sheet.
  func testTheSelectedSheetComesBackAfterARelaunch() throws {
    let file = try makeWorkbook()

    try plantViewer(path: file.path, extra: #","sheet":"Costs""#)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 20), "no table")
    XCTAssertTrue(waitFor(countText(in: window), timeout: 10) { $0 == "1 rows" })
    XCTAssertTrue(
      window.tables["data-viewer-table"].staticTexts["rent"].waitForExistence(timeout: 5),
      "the stored sheet did not load")
    XCTAssertTrue(
      waitFor(window.popUpButtons["data-viewer-sheets"], timeout: 5) { $0 == "Costs" },
      "the picker does not show the stored sheet")
  }

  // MARK: Find

  private func findCount(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["data-viewer-find-count"]
  }

  private func openFindFile() throws -> (XCUIApplication, XCUIElement) {
    let file = try makeCSV("name,city\nann,rome\nbob,romeo\ncy,oslo\n")

    try plantViewer(path: file.path)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 20), "no table")
    return (app, window)
  }

  /// Catches a Find submenu that is missing from Edit, or whose items are live with no file to
  /// search. An empty data viewer has Edit > Find, and its items are disabled.
  func testEditFindExistsAndIsDisabledWithNoFile() throws {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("3", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(window.buttons["data-viewer-open"].waitForExistence(timeout: 10))

    let bar = app.menuBars
    bar.menuBarItems["Edit"].click()

    let find = bar.menuItems["Find"]
    XCTAssertTrue(find.waitForExistence(timeout: 5), "no Edit > Find")
    find.click()

    for title in ["Find\u{2026}", "Find Next", "Find Previous", "Focus Filter"] {
      let item = bar.menuItems[title]
      XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(title) item")
      XCTAssertFalse(item.isEnabled, "\(title) is on with no file")
    }

    app.typeKey(.escape, modifierFlags: [])
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Catches a Cmd-F that does not open the find bar, a query that matches nothing, and Cmd-G and
  /// Cmd-Shift-G that do not step. The count line is the match the highlight stands on. It reads
  /// "1 of 2" for the first match, "2 of 2" after Cmd-G, and "1 of 2" again after Cmd-Shift-G. The
  /// cell colors need a screenshot, which this suite does not take.
  func testCommandFHighlightsMatchesAndCommandGStepsBetweenThem() throws {
    let (app, window) = try openFindFile()

    app.typeKey("f", modifierFlags: .command)

    let field = window.searchFields["data-viewer-find"]
    XCTAssertTrue(field.waitForExistence(timeout: 5), "Cmd-F did not open the find bar")

    app.typeText("rom")

    let count = findCount(in: window)
    XCTAssertTrue(waitFor(count, timeout: 10) { $0 == "1 of 2 matches" })

    app.typeKey("g", modifierFlags: .command)
    XCTAssertTrue(waitFor(count, timeout: 5) { $0 == "2 of 2 matches" })

    app.typeKey("g", modifierFlags: [.command, .shift])
    XCTAssertTrue(waitFor(count, timeout: 5) { $0 == "1 of 2 matches" })
  }

  /// Catches Find keys that a focused filter field swallows. With the keyboard in the filter field,
  /// Cmd-G still steps, and Cmd-F still moves the keyboard to the find bar, so the next typing
  /// lands there and the filter keeps its text.
  func testFindWorksWhileTheFilterFieldHasFocus() throws {
    let (app, window) = try openFindFile()

    app.typeKey("f", modifierFlags: .command)
    app.typeText("rom")

    let count = findCount(in: window)
    XCTAssertTrue(waitFor(count, timeout: 10) { $0 == "1 of 2 matches" })

    let filter = window.searchFields["data-viewer-filter"]
    filter.click()
    app.typeText("o")

    app.typeKey("g", modifierFlags: .command)
    XCTAssertTrue(waitFor(count, timeout: 5) { $0.hasPrefix("2 of 2 matches") })
    XCTAssertEqual(filter.value as? String, "o", "Cmd-G changed the filter text")

    app.typeKey("f", modifierFlags: .command)
    app.typeText("oslo")

    XCTAssertTrue(waitFor(count, timeout: 5) { $0.hasPrefix("1 of 1 matches") })
    XCTAssertEqual(filter.value as? String, "o", "typing after Cmd-F went to the filter")
  }
}
