import Foundation

/// A sort by one column.
public struct SortSpec: Equatable, Codable, Sendable {
  public var column: ColumnIdentity
  public var ascending: Bool

  public init(column: ColumnIdentity, ascending: Bool) {
    self.column = column
    self.ascending = ascending
  }
}

/// What the user asked to see: a sort and a filter.
public struct TableQuery: Equatable, Sendable {
  public var sort: SortSpec?

  /// Text that a row must contain in some cell, ignoring case. Empty shows every row.
  public var filter: String

  public init(sort: SortSpec? = nil, filter: String = "") {
    self.sort = sort
    self.filter = filter
  }

  public var isEmpty: Bool { sort == nil && filter.isEmpty }
}

/// The rows a query shows, as row numbers of the snapshot it ran on. Rows only append, so the
/// numbers stay valid for every later snapshot of the same load.
public enum RowSelection: Sendable, Equatable {
  /// Every row, in file order.
  case all(count: Int)

  case rows([UInt32])

  public var count: Int {
    switch self {
    case .all(let count): return count
    case .rows(let rows): return rows.count
    }
  }

  public func row(at index: Int) -> Int {
    switch self {
    case .all: return index
    case .rows(let rows): return Int(rows[index])
    }
  }
}

/// Where a sort gets the memory for its keys. The keys scale with the rows, and the rows already
/// fill the budget, so the sort asks the same budget and gives the bytes back when it is done.
public struct SortMemory: Sendable {
  let reserve: @Sendable (Int) -> Bool
  let giveBack: @Sendable (Int) -> Void

  public init(lease: TableBudget.Lease) {
    reserve = { lease.reserveForWork($0) == .granted }
    giveBack = { lease.giveBack($0) }
  }
}

/// How a query ended.
public enum QueryOutcome: Sendable, Equatable {
  /// The rows to show. `sortSkipped` is true when the sort did not get the memory it needed, so the
  /// rows are filtered and in file order.
  case done(RowSelection, sortSkipped: Bool)

  case cancelled
}

/// Filters and sorts a snapshot.
///
/// The filter keeps a row when some cell contains the text, ignoring case. A nested cell holds its
/// JSON text, so a filter finds text inside it too.
///
/// The sort reads one column, and orders every cell by one total order. Ascending, the classes are:
/// 1. Numbers, by value. A JSON number compares as a double.
/// 2. Text, by its lowercased form.
/// 3. Booleans, false before true.
/// 4. Nested cells, which compare equal to each other.
/// 5. Null, and a spreadsheet formula with no cached result.
/// 6. Missing, which is a JSON row without the key and a CSV cell with nothing in it.
///
/// Descending reverses classes 1 to 4 and the order inside each. Null and then missing stay last in
/// either direction, so absent values never lead a sorted column. Rows that compare equal keep file
/// order.
///
/// A CSV cell has no kind, so its text decides: a plain number is a number, nothing is missing, and
/// anything else is text. A JSON string is always text, so `"12"` sorts as text and 12 as a number.
public enum TableQueryEngine {
  /// Nil when `isCancelled` turned true before the result was done.
  public static func evaluate(
    _ snapshot: TableSnapshot, query: TableQuery, isCancelled: () -> Bool = { false }
  ) -> RowSelection? {
    guard case .done(let selection, _) = run(snapshot, query: query, isCancelled: isCancelled)
    else { return nil }

    return selection
  }

  public static func run(
    _ snapshot: TableSnapshot, query: TableQuery, isCancelled: () -> Bool = { false },
    memory: SortMemory? = nil
  ) -> QueryOutcome {
    let sortColumn = query.sort.flatMap { spec in
      snapshot.columns.firstIndex { $0.identity == spec.column }
    }

    guard !query.filter.isEmpty || sortColumn != nil else {
      return .done(.all(count: snapshot.rowCount), sortSkipped: false)
    }

    var rows: [UInt32] = []

    if query.filter.isEmpty {
      rows = (0..<UInt32(snapshot.rowCount)).map { $0 }
    } else {
      let matcher = CellMatcher(query.filter)
      var counter = 0

      snapshot.forEachRow { row, page, local in
        counter += 1

        if counter & 0xFFF == 0, isCancelled() { return false }

        let first = Int(page.rowFirstCell[local])

        for cell in 0..<page.cellCount(row: local) {
          let start = first + cell == 0 ? 0 : Int(page.cellEnds[first + cell - 1])

          if matcher.matches(page.bytes[start..<Int(page.cellEnds[first + cell])]) {
            rows.append(UInt32(row))
            break
          }
        }

        return true
      }
    }

    if isCancelled() { return .cancelled }

    var skipped = false

    if let sortColumn, let spec = query.sort {
      switch sort(rows, snapshot: snapshot, column: sortColumn, spec, isCancelled, memory) {
      case .sorted(let sorted):
        rows = sorted

      case .cancelled:
        return .cancelled

      case .noMemory:
        skipped = true
      }
    }

    return isCancelled() ? .cancelled : .done(.rows(rows), sortSkipped: skipped)
  }

  private enum SortResult {
    case sorted([UInt32])
    case cancelled
    case noMemory
  }

  private enum Key {
    case number(Double)
    case text(String)
    case bool(Bool)
    case nested
    case null
    case missing

    var rank: Int {
      switch self {
      case .number: return 0
      case .text: return 1
      case .bool: return 2
      case .nested: return 3
      case .null: return 4
      case .missing: return 5
      }
    }

    /// Absent values, which sort last in either direction.
    var isAbsent: Bool { rank >= 4 }
  }

  private static func key(of snapshot: TableSnapshot, row: Int, column: Int, text: String) -> Key {
    switch snapshot.kind(row: row, column: column) {
    case .missing:
      return .missing

    case .null, .notComputed:
      return .null

    case .bool:
      return .bool(text == "true")

    case .number:
      return .number(Double(text) ?? 0)

    case .string:
      return .text(text.lowercased())

    case .nested:
      return .nested

    case .text:
      if text.isEmpty { return .missing }

      if let number = CSVRule.number(text) { return .number(number) }

      return .text(text.lowercased())
    }
  }

  private static func sort(
    _ rows: [UInt32], snapshot: TableSnapshot, column: Int, _ spec: SortSpec,
    _ isCancelled: () -> Bool, _ memory: SortMemory?
  ) -> SortResult {
    // A key, the order array, its sorted copy, and the result, for each row. Text longer than a
    // small string also holds heap bytes, which are reserved in batches as the keys are built.
    var reserved = 0
    defer { if reserved > 0 { memory?.giveBack(reserved) } }

    let fixed = rows.count * (MemoryLayout<Key>.stride + 2 * MemoryLayout<Int>.stride + 4)

    if let memory {
      guard memory.reserve(fixed) else { return .noMemory }

      reserved += fixed
    }

    var heap = 0
    var keys: [Key] = []
    keys.reserveCapacity(rows.count)

    for (index, row) in rows.enumerated() {
      if index & 0xFFF == 0 {
        if isCancelled() { return .cancelled }

        if let memory, heap > 0 {
          guard memory.reserve(heap) else { return .noMemory }

          reserved += heap
          heap = 0
        }
      }

      let text = snapshot.text(row: Int(row), column: column, limit: 512)
      heap += text.utf8.count > 15 ? text.utf8.count : 0

      keys.append(key(of: snapshot, row: Int(row), column: column, text: text))
    }

    let ascending = spec.ascending
    let order = Array(rows.indices)

    let sorted = order.sorted { left, right in
      let result = compare(keys[left], keys[right])

      if result == .orderedSame { return left < right }

      let leftAbsent = keys[left].isAbsent
      let rightAbsent = keys[right].isAbsent

      if leftAbsent != rightAbsent { return rightAbsent }

      if leftAbsent { return result == .orderedAscending }

      return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    return .sorted(sorted.map { rows[$0] })
  }

  private static func compare(_ left: Key, _ right: Key) -> ComparisonResult {
    if left.rank != right.rank {
      return left.rank < right.rank ? .orderedAscending : .orderedDescending
    }

    switch (left, right) {
    case (.number(let a), .number(let b)):
      return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame

    case (.text(let a), .text(let b)):
      return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame

    case (.bool(let a), .bool(let b)):
      return a == b ? .orderedSame : (!a ? .orderedAscending : .orderedDescending)

    default:
      return .orderedSame
    }
  }
}

/// Finds a needle in a cell, ignoring case. An ASCII needle searches the cell's bytes. Bytes of a
/// multi-byte character never equal an ASCII byte, so the search needs no decoding. Any other needle
/// decodes each cell.
struct CellMatcher {
  private let ascii: [UInt8]?
  private let lowered: String

  init(_ needle: String) {
    lowered = needle.lowercased()

    let bytes = Array(needle.utf8)
    ascii = bytes.allSatisfy { $0 < 0x80 } ? bytes.map(Self.fold) : nil
  }

  func matches(_ cell: ArraySlice<UInt8>) -> Bool {
    guard let needle = ascii else {
      return String(decoding: cell, as: UTF8.self).lowercased().range(of: lowered) != nil
    }

    guard cell.count >= needle.count else { return false }

    let last = cell.endIndex - needle.count

    var start = cell.startIndex
    while start <= last {
      var offset = 0

      while offset < needle.count, Self.fold(cell[start + offset]) == needle[offset] {
        offset += 1
      }

      if offset == needle.count { return true }

      start += 1
    }

    return false
  }

  private static func fold(_ byte: UInt8) -> UInt8 {
    byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
  }
}
