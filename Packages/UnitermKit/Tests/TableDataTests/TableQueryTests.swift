import XCTest

@testable import TableData

/// Sorting and filtering over a loaded table. Expected row orders are written by hand from the
/// documented order.
final class TableQueryTests: XCTestCase {
  private func table(_ test: XCTestCase, _ csv: String) throws -> TableSnapshot {
    let scratch = try Scratch(test)
    return loadFile(try scratch.write("t.csv", csv)).snapshot
  }

  private func rows(_ selection: RowSelection?) -> [Int] {
    guard let selection else { return [] }

    return (0..<selection.count).map { selection.row(at: $0) }
  }

  private let qty = ColumnIdentity.named("qty")

  /// Catches a query that is not the identity when empty: every row in file order.
  func testAnEmptyQueryShowsEveryRowInFileOrder() throws {
    let snapshot = try table(self, "name,qty\na,1\nb,2\n")

    XCTAssertEqual(
      TableQueryEngine.evaluate(snapshot, query: TableQuery()), .all(count: 2))
  }

  /// Catches numbers that sort as text (10 before 2), text that sorts before numbers, and empty
  /// cells that do not come last in both directions. Ties keep file order.
  func testSortOrdersNumbersThenTextAndEmptyLast() throws {
    let snapshot = try table(self, "name,qty\na,10\nb,2\nc,\nd,Zed\ne,apple\nf,2\ng,-1.5\n")

    let ascending = TableQueryEngine.evaluate(
      snapshot, query: TableQuery(sort: SortSpec(column: qty, ascending: true)))
    XCTAssertEqual(rows(ascending), [6, 1, 5, 0, 4, 3, 2])

    let descending = TableQueryEngine.evaluate(
      snapshot, query: TableQuery(sort: SortSpec(column: qty, ascending: false)))
    XCTAssertEqual(rows(descending), [3, 4, 0, 1, 5, 6, 2])
  }

  /// Catches a filter that is case sensitive, one that looks at one column only, and one that
  /// misses text that is not ASCII.
  func testFilterMatchesAnyCellIgnoringCase() throws {
    let snapshot = try table(self, "name,qty\nWidget,1\ngadget,WIDE\nCaf\u{E9},3\nother,4\n")

    func matches(_ filter: String) -> [Int] {
      rows(TableQueryEngine.evaluate(snapshot, query: TableQuery(filter: filter)))
    }

    XCTAssertEqual(matches("wid"), [0, 1])
    XCTAssertEqual(matches("WIDGET"), [0])
    XCTAssertEqual(matches("caf\u{C9}"), [2])
    XCTAssertEqual(matches("zzz"), [])
  }

  /// Catches a sort that runs before the filter, so filtered rows come back, and a filter that
  /// loses the sorted order.
  func testFilterAndSortCompose() throws {
    let snapshot = try table(self, "name,qty\nax,3\nbx,1\ncy,2\ndx,2\n")

    let result = TableQueryEngine.evaluate(
      snapshot, query: TableQuery(sort: SortSpec(column: qty, ascending: true), filter: "x"))

    XCTAssertEqual(rows(result), [1, 3, 0])
  }

  /// Catches a stored sort on a column the file lacks that breaks the query. The sort is ignored.
  func testASortOnAnAbsentColumnIsIgnored() throws {
    let snapshot = try table(self, "name,qty\na,2\nb,1\n")

    let result = TableQueryEngine.evaluate(
      snapshot, query: TableQuery(sort: SortSpec(column: .named("nope"), ascending: true)))

    XCTAssertEqual(result, .all(count: 2))
  }

  /// Catches two same-named columns that sort as one: the occurrence picks the column.
  func testTheOccurrencePicksTheDuplicateColumn() throws {
    let snapshot = try table(self, "v,v\n1,9\n2,8\n3,7\n")

    let second = TableQueryEngine.evaluate(
      snapshot,
      query: TableQuery(sort: SortSpec(column: .named("v", occurrence: 1), ascending: true)))

    XCTAssertEqual(rows(second), [2, 1, 0])
  }

  /// Catches a run that ignores cancellation and returns a result nobody wants.
  func testACancelledRunReturnsNothing() throws {
    let snapshot = try table(self, "name,qty\na,2\nb,1\n")

    XCTAssertNil(
      TableQueryEngine.evaluate(
        snapshot, query: TableQuery(sort: SortSpec(column: qty, ascending: true)),
        isCancelled: { true }))
  }

  /// Catches a sort that takes memory from nowhere. The keys are reserved from the budget and
  /// given back, and a sort the budget refuses leaves the filtered rows in file order and says so.
  func testASortReservesItsKeysAndGivesThemBack() throws {
    let snapshot = try table(self, "name,qty\nb,2\na,1\nc,3\n")
    let query = TableQuery(sort: SortSpec(column: qty, ascending: true))
    let budget = TableBudget(limit: 1 << 20, floor: 0)
    let lease = budget.makeLease()

    let sorted = TableQueryEngine.run(snapshot, query: query, memory: SortMemory(lease: lease))

    XCTAssertEqual(sorted, .done(.rows([1, 0, 2]), sortSkipped: false))
    XCTAssertEqual(budget.used, 0)

    let tight = TableBudget(limit: 8, floor: 0)
    let refused = TableQueryEngine.run(
      snapshot, query: query, memory: SortMemory(lease: tight.makeLease()))

    XCTAssertEqual(refused, .done(.rows([0, 1, 2]), sortSkipped: true))
    XCTAssertEqual(tight.used, 0)
  }

  /// Catches a memory warning that stops sorting in a pane that is already open. A warning ends the
  /// loads running at that moment. A later sort on the same lease still gets its key memory.
  func testASortStillRunsAfterAMemoryWarning() throws {
    let snapshot = try table(self, "name,qty\nb,2\na,1\nc,3\n")
    let query = TableQuery(sort: SortSpec(column: qty, ascending: true))
    let budget = TableBudget(limit: 1 << 20, floor: 0)
    let lease = budget.makeLease()

    budget.memoryPressureWarning()

    let sorted = TableQueryEngine.run(snapshot, query: query, memory: SortMemory(lease: lease))

    XCTAssertEqual(sorted, .done(.rows([1, 0, 2]), sortSkipped: false))
    XCTAssertEqual(budget.used, 0)
  }
}
