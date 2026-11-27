import AppKit
import AppletKit
import AppletTestSupport
import StatusKit
import TableData
import XCTest

@testable import DataViewerApplet

/// The applet through its public contract: open, replace, drop, restore, and describe. The files
/// are real, and the waits poll the applet's own state.
@MainActor
final class DataViewerAppletTests: XCTestCase {
  private let amount = ColumnIdentity.named("amount")

  private func loaded(_ applet: DataViewerApplet) async -> Bool {
    await eventually { applet.session.phase == .loaded }
  }

  private func column(_ applet: DataViewerApplet, _ index: Int) -> [String] {
    (0..<applet.session.visibleCount).map {
      applet.session.snapshot.text(row: applet.session.selection.row(at: $0), column: index)
    }
  }

  private func restore(_ description: DataViewerDescription) throws -> DataViewerApplet {
    try DataViewerApplet(restoring: description.appletDescription(), budget: makeBudget())
  }

  // MARK: Opening

  /// Catches a pane that cannot open a CSV file, or that never reports the file's name and row
  /// count to its pane.
  func testOpeningAFileShowsItsTableTitleAndCount() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("sales.csv", "region,amount\neast,3\nwest,5\n")
    let applet = DataViewerApplet(startDirectory: scratch.url.path, budget: makeBudget())
    let host = RecordingHost()
    applet.host = host

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let done = await loaded(applet)
    XCTAssertTrue(done)
    XCTAssertEqual(applet.content.body, .table)
    XCTAssertEqual(applet.title, "sales.csv")
    XCTAssertEqual(applet.segments.map(\.text), ["2 rows"])
    XCTAssertEqual(applet.publishedTabs.first.title, "sales.csv")
    XCTAssertGreaterThan(host.changes, 0)
  }

  /// Catches a replace that keeps the old sort and filter, or the old file's path in the saved
  /// state. The new file starts clean.
  func testReplacingTheFileClearsTheQueryAndDescribesTheNewFile() async throws {
    let scratch = try Scratch(self)
    let first = try scratch.write("a.csv", "amount\n3\n1\n2\n")
    let second = try scratch.write("b.csv", "amount\n9\n8\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    try applet.replaceSource(with: first, startDirectory: scratch.url.path)
    _ = await loaded(applet)
    applet.session.setSort(SortSpec(column: amount, ascending: true))
    applet.session.setFilter("1")

    try applet.replaceSource(with: second, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded && applet.title == "b.csv" }

    XCTAssertEqual(applet.session.query, TableQuery())
    XCTAssertEqual(column(applet, 0), ["9", "8"])

    let saved = try DataViewerDescription.decode(applet.describe())
    XCTAssertEqual(saved.path, second.path)
    XCTAssertNil(saved.sort)
    XCTAssertNil(saved.filter)
    XCTAssertEqual(saved.startDirectory, scratch.url.path)
  }

  /// Catches an Open in This Pane that drops the pane's file when the chosen one cannot be read.
  /// The pane keeps its table and its saved path, and the status bar names the file that failed.
  func testAFailedOpenInThisPaneKeepsTheOldFileAndWarns() async throws {
    let scratch = try Scratch(self)
    let good = try scratch.write("a.csv", "amount\n3\n1\n2\n")
    let bad = try scratch.write("broken.json", #"{"rows": [{"amount": 1}, "#)
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    let host = RecordingHost()
    applet.host = host

    try applet.replaceSource(with: good, startDirectory: scratch.url.path)
    let first = await loaded(applet)
    XCTAssertTrue(first)

    await applet.replaceSource(withChosen: bad).value
    _ = await eventually { applet.session.phase != .loading }

    XCTAssertEqual(applet.session.phase, .loaded)
    XCTAssertEqual(applet.title, "a.csv")
    XCTAssertEqual(column(applet, 0), ["3", "1", "2"])
    XCTAssertEqual(try DataViewerDescription.decode(applet.describe()).path, good.path)

    let warned = host.sent.contains { $0.level == .warning && $0.text.contains("broken.json") }
    XCTAssertTrue(warned, "\(host.sent)")
  }

  /// Catches a missing file that crashes or shows an empty table, and a message that says
  /// "corrupt". The pane says the file is missing and keeps the path.
  func testAMissingFileShowsAMessageInThePane() async throws {
    let scratch = try Scratch(self)
    let missing = scratch.url.appendingPathComponent("gone.csv")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    try applet.replaceSource(with: missing, startDirectory: scratch.url.path)

    _ = await eventually { applet.session.phase != .idle && applet.session.phase != .loading }

    guard case .message(let text) = applet.content.body else { return XCTFail("no message") }

    XCTAssertTrue(text.contains("gone.csv"))
    XCTAssertTrue(text.contains("missing"))
    XCTAssertFalse(text.contains("corrupt"))
  }

  /// Catches a JSON file that the pane cannot open, or that opens without its row count and
  /// columns. The pane shows the table and reports the rows.
  func testAJSONFileOpensAsATable() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.json", #"[{"a":1,"b":{"c":"x"}},{"a":2}]"#)
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let done = await loaded(applet)
    XCTAssertTrue(done)
    XCTAssertEqual(applet.content.body, .table)
    XCTAssertEqual(applet.segments.map(\.text), ["2 rows"])
    XCTAssertEqual(applet.session.snapshot.columns.map(\.title), ["a", "b.c"])
  }

  /// Catches a JSON scalar or a syntax error that crashes the pane or leaves it blank. The pane
  /// says what is wrong and names the line.
  func testAJSONFileThatIsNotATableShowsAMessage() async throws {
    let scratch = try Scratch(self)
    let scalar = try scratch.write("one.json", "42")
    let broken = try scratch.write("broken.json", "[1,\n2,,]")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    for (file, expected) in [(scalar, "holds only a number"), (broken, "line 2")] {
      try applet.replaceSource(with: file, startDirectory: scratch.url.path)
      _ = await eventually {
        applet.title == file.lastPathComponent && applet.session.phase != .loading
          && applet.session.phase != .idle
      }

      guard case .message(let text) = applet.content.body else { return XCTFail("no message") }

      XCTAssertTrue(text.contains(expected), text)
      XCTAssertFalse(text.contains("corrupt"))
      XCTAssertEqual(applet.session.visibleCount, 0)
    }
  }

  /// Catches a nested cell that opens to a blank popover, or that keeps its rows after it closes.
  /// The value loads into a session of its own under the shared budget, shows its table, and gives
  /// the budget back on close. A cell inside it opens one more.
  func testANestedValueShowsATableAndFreesItsRowsOnClose() async throws {
    let budget = makeBudget()
    let table = NestedTable(
      bytes: Array(#"[{"x":1,"y":[{"z":2}]},{"x":3}]"#.utf8), title: "items", budget: budget,
      palette: .latte)

    let done = await eventually { table.session.phase == .loaded }
    XCTAssertTrue(done)
    XCTAssertEqual(table.view.body, .table)
    XCTAssertEqual(table.session.snapshot.columns.map(\.title), ["x", "y"])
    XCTAssertGreaterThan(budget.used, 0)

    table.close()

    XCTAssertEqual(budget.used, 0)
  }

  /// Catches a nested table whose load stopped with columns and no rows. It would show an empty
  /// table and no notice. It says memory is short instead, as the main pane does. It cannot prove
  /// the wording of a stop that keeps some rows.
  func testANestedValueStoppedBeforeAnyRowShowsTheMemoryMessage() async throws {
    let budget = TableBudget(limit: 1, floor: 0)
    let table = NestedTable(
      bytes: Array(#"[{"x":1,"y":2}]"#.utf8), title: "items", budget: budget, palette: .latte)

    let done = await eventually { table.session.phase != .loading && table.session.phase != .idle }
    XCTAssertTrue(done)
    XCTAssertEqual(table.session.snapshot.rowCount, 0)
    XCTAssertFalse(table.session.snapshot.columns.isEmpty)

    guard case .message(let text) = table.view.body else { return XCTFail("no message") }

    XCTAssertTrue(text.contains("not enough memory"), text)
  }

  /// Catches a folder, which the loader must refuse without reading it.
  func testAFolderShowsAMessage() async throws {
    let scratch = try Scratch(self)
    let folder = scratch.url.appendingPathComponent("dir.csv")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    try applet.replaceSource(with: folder, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase != .loading && applet.session.phase != .idle }

    guard case .message(let text) = applet.content.body else { return XCTFail("no message") }

    XCTAssertTrue(text.contains("a folder"))
  }

  // MARK: Notices

  /// Catches a load notice shown over the table instead of the status bar, or one posted again on
  /// every refresh. A cut cell posts its notice once, and a segment says rows were cut while the
  /// table shows them.
  func testLoadNoticesGoToTheStatusBarOnce() async throws {
    let scratch = try Scratch(self)
    let big = String(repeating: "x", count: (1 << 20) + 10)
    let file = try scratch.write("big.csv", "note\n\(big)\nsmall\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    let host = RecordingHost()
    applet.host = host

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(applet)

    let cut = "1 row had an oversized cell cut."
    XCTAssertEqual(host.posts.filter { $0.text == cut }.count, 1, "\(host.posts)")
    XCTAssertTrue(applet.segments.contains { $0.text == "1 row cut" }, "\(applet.segments)")

    applet.session.setFilter("small")
    _ = await eventually { applet.session.visibleCount == 1 }

    XCTAssertEqual(host.posts.filter { $0.text == cut }.count, 1, "the notice posted again")
  }

  /// Catches a count that posts again each time it grows. Three rows are cut over several pages.
  /// The status bar gets the notice once, after the load settles, with the whole count.
  func testACutRowCountThatGrowsDuringALoadPostsOnceWithTheFinalCount() async throws {
    let scratch = try Scratch(self)
    let big = String(repeating: "x", count: (1 << 20) + 10)
    let file = try scratch.write("big.csv", "note\n\(big)\n\(big)\n\(big)\nsmall\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget(), pageTarget: 1)
    let host = RecordingHost()
    applet.host = host

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    let done = await loaded(applet)

    let cuts = host.posts.filter { $0.text.contains("oversized") }
    XCTAssertTrue(done)
    XCTAssertEqual(cuts.map(\.text), ["3 rows had oversized cells cut."], "\(host.posts)")
    XCTAssertEqual(cuts.map(\.level), [.warning])
  }

  /// Catches a sheet switch that stays quiet because the old sheet's notice looked the same. Each
  /// sheet is a load of its own, so the notice posts again for the second one.
  func testSwitchingSheetsPostsTheNewSheetsNoticesAgain() async throws {
    let scratch = try Scratch(self)
    let big = String(repeating: "x", count: (1 << 20) + 10)
    let file = scratch.url.appendingPathComponent("book.xlsx")

    try makeWorkbook([
      (name: "Sales", rows: [["note"], [big], ["a"]]),
      (name: "Costs", rows: [["note"], [big], ["b"]]),
    ]).write(to: file)

    let applet = DataViewerApplet(startDirectory: scratch.url.path, budget: makeBudget())
    let host = RecordingHost()
    applet.host = host

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    let first = await loaded(applet)
    XCTAssertTrue(first)

    let cut = "1 row had an oversized cell cut."
    XCTAssertEqual(host.posts.filter { $0.text == cut }.count, 1, "\(host.posts)")

    applet.content.sheetPicker.selectItem(at: 1)
    _ = applet.content.sheetPicker.sendAction(
      applet.content.sheetPicker.action, to: applet.content.sheetPicker.target)

    let switched = await eventually {
      applet.session.phase == .loaded && applet.session.selectedSheet == "Costs"
    }

    XCTAssertTrue(switched)
    XCTAssertEqual(host.posts.filter { $0.text == cut }.count, 2, "\(host.posts)")
  }

  // MARK: Empty panes and levels

  /// Catches a failed load that leaves the pane explaining itself and the history empty, or one
  /// that also takes a turn on the bar. The pane keeps its explanation. The history gets one
  /// warning, once, and the bar gets nothing, because the pane already says it.
  func testAFailureThatEmptiesThePaneIsRecordedOnceInTheHistoryOnly() async throws {
    let scratch = try Scratch(self)
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    let host = RecordingHost()
    applet.host = host

    try applet.replaceSource(
      with: scratch.url.appendingPathComponent("gone.csv"), startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase != .idle && applet.session.phase != .loading }

    applet.session.setFilter("x")

    guard case .message(let text) = applet.content.body else { return XCTFail("no message") }

    XCTAssertTrue(text.contains("is missing"), text)
    XCTAssertTrue(host.posts.isEmpty, "\(host.posts)")
    XCTAssertEqual(host.records.map(\.level), [.warning])
    XCTAssertEqual(host.records.map(\.text), [text])
  }

  /// Catches a memory stop with no rows that is explained only in the pane. It counts as an empty
  /// pane, so it gets the same one history entry and no turn on the bar.
  func testAStopBeforeAnyRowIsRecordedOnceInTheHistoryOnly() async throws {
    let scratch = try Scratch(self)
    let file = scratch.url.appendingPathComponent("wide.xlsx")
    try makeWorkbook([("S", [["a", "b"], ["1", "2"]])]).write(to: file)

    let applet = DataViewerApplet(
      startDirectory: nil, budget: TableBudget(limit: 1, floor: 0), pageTarget: 2_000)
    let host = RecordingHost()
    applet.host = host

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase != .loading && applet.session.phase != .idle }

    XCTAssertTrue(applet.session.stoppedBeforeAnyRow)
    XCTAssertTrue(host.posts.isEmpty, "\(host.posts)")
    XCTAssertEqual(host.records.map(\.level), [.warning])
    XCTAssertTrue(host.records.first?.text.contains("memory is in short supply") == true)
  }

  /// Catches a level that drifts from the rule. A file found at a new path changes nothing on
  /// screen, so it is info. A failed load shows no content, so it is a warning and never an error,
  /// because a viewer holds no edits to lose.
  func testNoticeLevelsFollowTheRule() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "x\n1\n")

    let original = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    try original.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(original)

    let description = original.describe()
    let moved = scratch.url.appendingPathComponent("moved.csv")
    try FileManager.default.moveItem(at: file, to: moved)

    let found = try DataViewerApplet(restoring: description, budget: makeBudget())
    let host = RecordingHost()
    found.host = host
    found.start(origin: .user)
    _ = await loaded(found)

    XCTAssertEqual(host.posts.map(\.level), [.info], "\(host.posts)")
    XCTAssertTrue(host.posts.first?.text.hasPrefix("Moved. Found at") == true)
    XCTAssertEqual(DataViewerApplet.failureLevel, .warning)
  }

  // MARK: Drop

  /// Catches a drop of several files that replaces the file, or that is silent. The pane keeps what
  /// it showed and says to drop one file. A drop of one file replaces it.
  func testADropOfSeveralFilesIsRefusedAndOneFileReplaces() async throws {
    let scratch = try Scratch(self)
    let first = try scratch.write("a.csv", "amount\n1\n")
    let second = try scratch.write("b.csv", "amount\n2\n")
    let third = try scratch.write("c.csv", "amount\n3\n4\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    let host = RecordingHost()
    applet.host = host

    try applet.replaceSource(with: first, startDirectory: scratch.url.path)
    _ = await loaded(applet)

    XCTAssertFalse(applet.handleDrop([second, third]))
    XCTAssertEqual(host.posts.count, 1)
    XCTAssertEqual(host.posts.first?.level, .warning)
    XCTAssertTrue(host.posts.first?.text.contains("one file") ?? false)
    XCTAssertEqual(applet.title, "a.csv")
    XCTAssertEqual(column(applet, 0), ["1"])

    XCTAssertFalse(applet.handleDrop([]))

    XCTAssertTrue(applet.handleDrop([third]))
    _ = await eventually { applet.session.phase == .loaded && applet.title == "c.csv" }
    XCTAssertEqual(column(applet, 0), ["3", "4"])
  }

  /// Catches a filter field that keeps old text after a new file clears the filter. The user typed
  /// in the field and left focus there. Opening another file must empty the field, since the
  /// session's filter is empty.
  func testOpeningAnotherFileEmptiesAFilterFieldThatStillHasFocus() async throws {
    let scratch = try Scratch(self)
    let first = try scratch.write("a.csv", "amount\n1\n2\n")
    let second = try scratch.write("b.csv", "amount\n9\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = applet.view
    addTeardownBlock { window.close() }

    try applet.replaceSource(with: first, startDirectory: scratch.url.path)
    _ = await loaded(applet)

    let field = applet.content.filterField
    XCTAssertTrue(window.makeFirstResponder(field))
    XCTAssertNotNil(field.currentEditor())

    field.stringValue = "1"
    _ = field.sendAction(field.action, to: field.target)
    XCTAssertEqual(applet.session.query.filter, "1")

    try applet.replaceSource(with: second, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded && applet.title == "b.csv" }

    XCTAssertEqual(applet.session.query.filter, "")
    XCTAssertEqual(field.stringValue, "")
  }

  // MARK: Describe and restore

  /// Catches a layout save that depends on the disk or changes between calls. An unchanged pane
  /// describes itself the same way twice, even for a path that does not exist.
  func testDescribeReadsOnlyMemoryAndIsStable() throws {
    let description = DataViewerDescription(
      startDirectory: "/no/such/dir", path: "/no/such/dir/x.csv", bookmark: Data([9]),
      sort: SortSpec(column: amount, ascending: true), filter: "q")
    let applet = try restore(description)

    XCTAssertEqual(applet.describe(), applet.describe())
    XCTAssertEqual(try DataViewerDescription.decode(applet.describe()), description)
  }

  /// Catches a restore that loses the sort and filter, or applies them to rows that are still
  /// arriving. After the file loads, the rows are filtered and sorted. While the bookmark and file
  /// are still being found, `describe()` returns the restored payload unchanged.
  func testRestoreBringsBackTheFileWithItsSortAndFilter() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "name,amount\nax,3\nbx,1\ncy,2\ndx,5\n")
    let description = DataViewerDescription(
      startDirectory: scratch.url.path, path: file.path,
      sort: SortSpec(column: amount, ascending: false), filter: "x")
    let applet = try restore(description)

    applet.start(origin: .user)

    XCTAssertEqual(try DataViewerDescription.decode(applet.describe()), description)

    let done = await eventually {
      applet.session.phase == .loaded && self.column(applet, 1) == ["5", "3", "1"]
    }

    XCTAssertTrue(done)

    let saved = try DataViewerDescription.decode(applet.describe())
    XCTAssertEqual(saved.sort, description.sort)
    XCTAssertEqual(saved.filter, "x")
    XCTAssertNotNil(saved.bookmark)
  }

  /// Catches a restored sort on a column the file no longer has that shows an error, and one that
  /// stays in the saved state forever. It is dropped once the load ends.
  func testAStoredSortOnAnAbsentColumnIsDropped() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "name,amount\nax,3\n")
    let applet = try restore(
      DataViewerDescription(
        startDirectory: scratch.url.path, path: file.path,
        sort: SortSpec(column: .named("gone"), ascending: true)))

    applet.start(origin: .user)
    let done = await loaded(applet)

    XCTAssertTrue(done)
    XCTAssertEqual(applet.content.body, .table)
    XCTAssertNil(try DataViewerDescription.decode(applet.describe()).sort)
  }

  /// Catches a moved file that is reported missing, and a stored path that stays stale. The path is
  /// gone, the bookmark finds the file, the pane says where, and the stored path becomes the new
  /// one.
  func testAMovedFileIsFoundThroughItsBookmarkAndThePathFollows() async throws {
    let scratch = try Scratch(self)
    let old = try scratch.write("old.csv", "amount\n7\n")
    let bookmark = try old.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let new = scratch.url.appendingPathComponent("new.csv")
    try FileManager.default.moveItem(at: old, to: new)

    let applet = try restore(
      DataViewerDescription(startDirectory: scratch.url.path, path: old.path, bookmark: bookmark))
    applet.start(origin: .user)

    let done = await loaded(applet)
    XCTAssertTrue(done)
    XCTAssertEqual(column(applet, 0), ["7"])
    XCTAssertEqual(applet.title, "new.csv")

    let saved = try DataViewerDescription.decode(applet.describe())
    XCTAssertEqual(URL(fileURLWithPath: saved.path ?? "").resolvingSymlinksInPath().path, new.path)
  }

  /// Catches a file in a protected folder that reads as missing. A file that cannot be opened for
  /// permission says so, and the sort and filter are still saved.
  func testAFileThatCannotBeReadSaysPermissionAndKeepsItsState() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("locked.csv", "amount\n1\n")
    XCTAssertEqual(chmod(file.path, 0), 0)
    let sort = SortSpec(column: amount, ascending: true)
    let applet = try restore(
      DataViewerDescription(startDirectory: scratch.url.path, path: file.path, sort: sort))

    applet.start(origin: .user)
    _ = await eventually {
      if case .failed = applet.session.phase { return true }
      return false
    }

    guard case .message(let text) = applet.content.body else { return XCTFail("no message") }

    XCTAssertTrue(text.contains("permission"))
    XCTAssertEqual(try DataViewerDescription.decode(applet.describe()).sort, sort)
  }

  // MARK: Directories and lifecycle

  /// Catches a split that starts nowhere useful. An empty pane reports the start directory, a pane
  /// with a file reports the file's folder, and a folder that is gone falls back to the start
  /// directory, then to nil.
  func testCurrentDirectoryFollowsTheFileThenTheStartDirectory() throws {
    let scratch = try Scratch(self)
    let start = scratch.url.appendingPathComponent("start", isDirectory: true)
    let other = scratch.url.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

    let empty = DataViewerApplet(startDirectory: start.path, budget: makeBudget())
    XCTAssertEqual(empty.currentDirectory, start.path)

    let withFile = try restore(
      DataViewerDescription(startDirectory: start.path, path: other.path + "/x.csv"))
    XCTAssertEqual(withFile.currentDirectory, other.path)

    try FileManager.default.removeItem(at: other)
    XCTAssertEqual(withFile.currentDirectory, start.path)

    try FileManager.default.removeItem(at: start)
    XCTAssertNil(withFile.currentDirectory)
    XCTAssertNil(DataViewerApplet(startDirectory: nil, budget: makeBudget()).currentDirectory)
  }

  /// Catches a close that asks, or that keeps memory. A pane never counts as running something,
  /// and closing it mid-load frees its share of the budget at once.
  func testClosingMidLoadNeverAsksAndFreesTheBudget() async throws {
    let scratch = try Scratch(self)
    var text = "id,v\n"
    for index in 0..<200_000 { text += "\(index),some text \(index)\n" }

    let file = try scratch.write("big.csv", text)
    let budget = makeBudget()
    let applet = DataViewerApplet(startDirectory: nil, budget: budget)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    let reserved = await eventually { budget.used > 0 }
    XCTAssertTrue(reserved)
    XCTAssertFalse(applet.isRunningSomething)
    XCTAssertEqual(applet.runningLabels, [])

    applet.close()

    XCTAssertEqual(budget.used, 0)
  }

  /// Catches a budget kept per pane. Two panes on one tiny budget together hold no more than the
  /// limit plus their floors, and each still shows rows.
  func testPanesShareOneBudgetAndEachKeepsItsFloor() async throws {
    let scratch = try Scratch(self)
    var text = "id,v\n"
    for index in 0..<5_000 { text += "\(index),row number \(index)\n" }

    let file = try scratch.write("big.csv", text)
    let budget = TableBudget(limit: 40_000, floor: 8_000)
    let one = DataViewerApplet(startDirectory: nil, budget: budget, pageTarget: 2_000)
    let two = DataViewerApplet(startDirectory: nil, budget: budget, pageTarget: 2_000)

    try one.replaceSource(with: file, startDirectory: scratch.url.path)
    try two.replaceSource(with: file, startDirectory: scratch.url.path)

    let done = await eventually {
      one.session.phase == .stoppedAtBudget && two.session.phase == .stoppedAtBudget
    }

    XCTAssertTrue(done)
    XCTAssertGreaterThan(one.session.snapshot.rowCount, 0)
    XCTAssertGreaterThan(two.session.snapshot.rowCount, 0)
    XCTAssertLessThanOrEqual(budget.used, 40_000 + 2 * 8_000)
    XCTAssertTrue(one.segments.first?.text?.contains("first") ?? false)
  }

  /// Catches a header click that does not cycle. First click ascending, second descending, third
  /// clears, and a click on another column starts it ascending.
  func testClickingAHeaderCyclesTheSort() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "amount,other\n2,x\n1,y\n3,z\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(applet)

    applet.content.onSort?(amount)
    XCTAssertEqual(applet.session.query.sort, SortSpec(column: amount, ascending: true))

    applet.content.onSort?(amount)
    XCTAssertEqual(applet.session.query.sort, SortSpec(column: amount, ascending: false))

    applet.content.onSort?(amount)
    XCTAssertNil(applet.session.query.sort)

    applet.content.onSort?(.named("other"))
    XCTAssertEqual(
      applet.session.query.sort, SortSpec(column: .named("other"), ascending: true))
  }

  // MARK: Workbooks

  private func workbook(_ scratch: Scratch, _ name: String = "book.xlsx") throws -> URL {
    let file = scratch.url.appendingPathComponent(name)

    try makeWorkbook([
      (name: "Sales", rows: [["region", "amount"], ["east", "3"], ["west", "5"]]),
      (name: "Costs", rows: [["item", "cost"], ["rent", "9"]]),
    ]).write(to: file)

    return file
  }

  /// Catches a workbook that opens with no way to reach its other sheets, and a picker that does
  /// not change the table. The picker lists every sheet, and choosing one shows its rows.
  func testAWorkbookOffersASheetPickerThatSwitchesTheTable() async throws {
    let scratch = try Scratch(self)
    let applet = DataViewerApplet(startDirectory: scratch.url.path, budget: makeBudget())

    try applet.replaceSource(
      with: try workbook(scratch), startDirectory: scratch.url.path)

    let done = await loaded(applet)
    XCTAssertTrue(done)
    XCTAssertFalse(applet.content.sheetPicker.isHidden)
    XCTAssertEqual(applet.content.sheetPicker.itemTitles, ["Sales", "Costs"])
    XCTAssertEqual(applet.session.snapshot.columns.map(\.title), ["region", "amount"])
    XCTAssertEqual(try DataViewerDescription.decode(applet.describe()).sheet, "Sales")

    applet.content.sheetPicker.selectItem(at: 1)
    _ = applet.content.sheetPicker.sendAction(
      applet.content.sheetPicker.action, to: applet.content.sheetPicker.target)

    let switched = await eventually {
      applet.session.phase == .loaded
        && applet.session.snapshot.columns.map(\.title) == ["item", "cost"]
    }

    XCTAssertTrue(switched)
    XCTAssertEqual(column(applet, 0), ["rent"])
    XCTAssertEqual(applet.content.sheetPicker.titleOfSelectedItem, "Costs")
    XCTAssertEqual(try DataViewerDescription.decode(applet.describe()).sheet, "Costs")
  }

  /// Catches a relaunch that shows the first sheet again. The stored sheet reloads, and a sheet
  /// the workbook no longer has falls back to the first.
  func testTheSelectedSheetSurvivesARestore() async throws {
    let scratch = try Scratch(self)
    let file = try workbook(scratch)

    let applet = try restore(
      DataViewerDescription(startDirectory: scratch.url.path, path: file.path, sheet: "Costs"))

    XCTAssertEqual(try DataViewerDescription.decode(applet.describe()).sheet, "Costs")

    applet.start(origin: .user)
    let done = await loaded(applet)

    XCTAssertTrue(done)
    XCTAssertEqual(column(applet, 0), ["rent"])
    XCTAssertEqual(try DataViewerDescription.decode(applet.describe()).sheet, "Costs")

    let gone = try restore(
      DataViewerDescription(startDirectory: scratch.url.path, path: file.path, sheet: "Deleted"))

    gone.start(origin: .user)
    let fallback = await loaded(gone)

    XCTAssertTrue(fallback)
    XCTAssertEqual(column(gone, 0), ["east", "west"])
    XCTAssertEqual(try DataViewerDescription.decode(gone.describe()).sheet, "Sales")
  }

  /// Catches a spreadsheet format that shows a message saying "corrupt", or no message at all.
  func testAnOldWorkbookShowsAMessageNamingItsFormat() async throws {
    let scratch = try Scratch(self)
    let file = scratch.url.appendingPathComponent("old.xls")
    try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 600))
      .write(to: file)

    let applet = DataViewerApplet(startDirectory: scratch.url.path, budget: makeBudget())
    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let failed = await eventually {
      if case .failed = applet.session.phase { return true }

      return false
    }

    XCTAssertTrue(failed)

    guard case .message(let text) = applet.content.body else {
      return XCTFail("expected a message")
    }

    XCTAssertTrue(text.contains(".xls"), text)
    XCTAssertFalse(text.lowercased().contains("corrupt"), text)
  }

  // MARK: Commands

  /// Catches an Open that asks for a key, which would shadow the window's Cmd-O, and a
  /// declaration that drifts from the owner rank for CSV, JSON, and `.xlsx`.
  func testTheCommandSetAndDeclaration() {
    let commands = DataViewerApplet.commandSet.commands

    XCTAssertEqual(
      commands.map(\.name), ["open", "find", "find-next", "find-previous", "focus-filter"])
    XCTAssertNil(commands.first?.key)
    XCTAssertEqual(commands.first?.home, .file)

    XCTAssertEqual(
      DataViewerApplet.typeDeclaration.opens,
      [
        OpenedType("public.comma-separated-values-text", rank: .owner),
        OpenedType("public.json", rank: .owner),
        OpenedType("org.openxmlformats.spreadsheetml.sheet", rank: .owner),
      ])
  }

  // MARK: Find

  private func command(_ name: String) -> AppletCommand {
    DataViewerApplet.commandSet.commands.first { $0.name == name }!
  }

  private let findNames = ["find", "find-next", "find-previous", "focus-filter"]

  /// Catches a find command that is on with no file to search, or one that stays off once a table
  /// shows. All four are off for an empty pane and on for a loaded one.
  func testFindCommandsAreOffWithNoFileAndOnWithATable() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "name\nann\nbob\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    for name in findNames {
      XCTAssertFalse(command(name).isAvailable(applet), name)
    }

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(applet)

    for name in findNames {
      XCTAssertTrue(command(name).isAvailable(applet), name)
    }
  }

  /// Catches a find that touches the filter or the file, and a step that does not follow the
  /// matches. The query marks cells among the rows shown, and Find Next and Find Previous move the
  /// current match and wrap. The filter and the saved description stay as they were.
  func testFindMarksCellsAndStepsWithoutTouchingTheFilter() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "name,city\nann,rome\nbob,romeo\ncy,oslo\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await loaded(applet)

    let before = applet.describe()
    applet.content.onFind?("rom")

    let found = await eventually { applet.session.matches.count == 2 }
    XCTAssertTrue(found)
    XCTAssertEqual(applet.session.currentMatch, 0)
    XCTAssertEqual(applet.session.query.filter, "")
    XCTAssertEqual(applet.content.findCountLabel.stringValue, "1 of 2 matches")

    command("find-next").run(applet)
    XCTAssertEqual(applet.session.currentMatch, 1)

    command("find-next").run(applet)
    XCTAssertEqual(applet.session.currentMatch, 0)

    command("find-previous").run(applet)
    XCTAssertEqual(applet.session.currentMatch, 1)
    XCTAssertEqual(applet.describe(), before, "the find query reached the description")
  }

  /// Catches a find that counts rows the filter hides, and one that forgets the load stopped early.
  /// With the budget cut, the count says it covers the first rows only.
  func testFindCountsNameTheRowsTheSearchCovered() async throws {
    let scratch = try Scratch(self)
    var text = "id,v\n"
    for index in 0..<5_000 { text += "\(index),row number \(index)\n" }

    let file = try scratch.write("big.csv", text)
    let applet = DataViewerApplet(
      startDirectory: nil, budget: TableBudget(limit: 40_000, floor: 8_000), pageTarget: 2_000)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .stoppedAtBudget }

    applet.content.onFind?("number 1")
    _ = await eventually { !applet.session.isSearching && !applet.session.matches.isEmpty }

    let loaded = applet.session.snapshot.rowCount.formatted()
    XCTAssertTrue(
      applet.content.findCountLabel.stringValue.hasSuffix("matches in the first \(loaded) rows"),
      applet.content.findCountLabel.stringValue)
  }

  /// Catches a status segment that reads "The first 0 rows" while the body says memory is short.
  /// A stop before any row says so in the segment too, in the warning style.
  func testAStopBeforeAnyRowSaysSoInTheStatusSegment() async throws {
    let scratch = try Scratch(self)
    let file = scratch.url.appendingPathComponent("wide.xlsx")
    try makeWorkbook([("S", [["a", "b"], ["1", "2"]])]).write(to: file)

    let applet = DataViewerApplet(
      startDirectory: nil, budget: TableBudget(limit: 1, floor: 0), pageTarget: 2_000)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase != .loading && applet.session.phase != .idle }

    XCTAssertTrue(applet.session.stoppedBeforeAnyRow)
    XCTAssertFalse(applet.segments.isEmpty)
    XCTAssertEqual(applet.segments.compactMap(\.text), ["Stopped for memory, no rows loaded"])
    XCTAssertEqual(applet.segments.first?.style, .warning)
  }
}
