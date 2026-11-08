import Darwin
import Foundation
import SourceAccess

/// Where a table's rows come from. A file is the usual source. A nested value that a cell holds
/// loads from memory through the same entry point, with no file behind it. A byte stream joins when
/// its first caller lands, and spools to a file for the formats that need random access.
public enum TableSource: Sendable, Equatable {
  /// A file. `sheet` names the sheet of a workbook to read, and the first visible sheet shows when
  /// it is nil or the workbook has no sheet of that name. Other formats ignore it.
  case file(URL, sheet: String? = nil)

  /// A JSON value that a nested cell holds, shown as a table of its own. `name` stands in for a
  /// path in messages.
  case embeddedJSON(name: String, bytes: [UInt8])
}

/// How far a load has come.
public struct LoadProgress: Sendable, Equatable {
  public var bytesRead = 0
  public var totalBytes = 0

  /// Rows that a size cap cut short. See `CSVParser`.
  public var truncatedRows = 0

  /// The sheets a workbook offers, in order. Empty for a file that is not a workbook.
  public var sheets: [String] = []

  /// The sheet the rows come from.
  public var selectedSheet: String?

  public var fraction: Double? {
    totalBytes > 0 ? min(1, Double(bytesRead) / Double(totalBytes)) : nil
  }
}

/// Why a load ended.
public enum LoadEnd: Sendable, Equatable {
  case completed

  /// The memory budget ran out. The snapshot holds the first rows of the file.
  case stoppedAtBudget

  /// The system warned about memory. The snapshot holds the first rows of the file.
  case stoppedLowMemory

  case failed(TableLoadError)
  case cancelled

  /// True when the load ended early with the first rows of the file.
  var isStoppedEarly: Bool {
    self == .stoppedAtBudget || self == .stoppedLowMemory
  }
}

public enum LoadEvent: Sendable {
  case snapshot(TableSnapshot, LoadProgress)
  case finished(TableSnapshot, LoadEnd, LoadProgress)
}

/// Reads a source into a snapshot of rows, off the main thread, under a memory budget.
///
/// The loader opens regular files only. A FIFO, a device, or a socket is refused after the open and
/// before any read, and the open itself never blocks, so a stalled path cannot hold a pane. The
/// rows go into pages of about `pageTarget` bytes. Each page reserves its cost from the lease when
/// it seals. A page the budget refuses is dropped, and the load ends with the pages before it.
public enum TableLoader {
  /// The size at which the row page being filled seals.
  public static let defaultPageTarget = 1 << 20

  /// The least time between two snapshots of a running load.
  static let snapshotInterval = Duration.milliseconds(100)

  @concurrent
  public static func load(
    _ source: TableSource, lease: TableBudget.Lease, pageTarget: Int = defaultPageTarget,
    emit: @escaping @Sendable (LoadEvent) -> Void
  ) async {
    loadBlocking(
      source, lease: lease, pageTarget: pageTarget, isCancelled: { Task.isCancelled }, emit: emit)
  }

  /// The same load with the spreadsheet caps spelled out. Tests and the fuzzer shrink them to
  /// reach a cap with a small file.
  static func loadBlocking(
    _ source: TableSource, lease: TableBudget.Lease, pageTarget: Int = defaultPageTarget,
    limits: SpreadsheetLimits, isCancelled: @escaping () -> Bool = { false },
    emit: @escaping (LoadEvent) -> Void
  ) {
    var run = LoadRun(
      lease: lease, pageTarget: pageTarget, limits: limits, isCancelled: isCancelled, emit: emit)

    switch source {
    case .file(let url, let sheet):
      run.load(file: url, sheet: sheet)

    case .embeddedJSON(let name, let bytes):
      run.load(embedded: bytes, name: name)
    }
  }

  /// The same load on the calling thread. Tests and the fuzzer call it directly.
  public static func loadBlocking(
    _ source: TableSource, lease: TableBudget.Lease, pageTarget: Int = defaultPageTarget,
    isCancelled: @escaping () -> Bool = { false }, emit: @escaping (LoadEvent) -> Void
  ) {
    loadBlocking(
      source, lease: lease, pageTarget: pageTarget, limits: .standard, isCancelled: isCancelled,
      emit: emit)
  }
}

struct LoadRun {
  let lease: TableBudget.Lease
  let pageTarget: Int
  let limits: SpreadsheetLimits
  let isCancelled: () -> Bool
  let emit: (LoadEvent) -> Void

  var pages: [RowPage] = []
  var builder = RowPageBuilder()
  var progress = LoadProgress()
  var end: LoadEnd?

  private var header: [String]?
  private var maxCells = 0
  private var firstRow = true
  private var lastSnapshot = ContinuousClock.now

  var json = JSONReadState()
  var sheet = SheetReadState()

  init(
    lease: TableBudget.Lease, pageTarget: Int, limits: SpreadsheetLimits,
    isCancelled: @escaping () -> Bool, emit: @escaping (LoadEvent) -> Void
  ) {
    self.lease = lease
    self.pageTarget = pageTarget
    self.limits = limits
    self.isCancelled = isCancelled
    self.emit = emit
  }

  mutating func load(file url: URL, sheet: String?) {
    let path = url.path
    let ext = url.pathExtension.lowercased()

    let descriptor: Int32
    let info: RegularFile.Info

    switch RegularFile.open(path: path) {
    case .failure(let error):
      finish(.failed(TableLoadError(error)))
      return

    case .success(let opened):
      descriptor = opened.descriptor
      info = opened.info
    }

    defer { close(descriptor) }

    switch Format.of(extension: ext) {
    case .unsupported(let description):
      finish(.failed(.unsupportedFormat(path: path, description: description)))
      return

    case .csv:
      progress.totalBytes = info.size
      readCSV(from: descriptor, fileExtension: ext, path: path)

    case .json:
      progress.totalBytes = info.size
      readJSON(from: descriptor, fileExtension: ext, path: path)

    case .spreadsheet:
      progress.totalBytes = info.size
      readSpreadsheet(
        from: descriptor, fileSize: info.size, path: path, sheet: sheet)
    }
  }

  private mutating func readCSV(from descriptor: Int32, fileExtension: String, path: String) {
    var chunk = [UInt8](repeating: 0, count: 256 << 10)
    var sample: [UInt8] = []
    var atEnd = false

    while sample.count < CSVRule.sampleSize, !atEnd {
      guard let count = fill(descriptor, &chunk, into: &sample, path: path) else { return }

      atEnd = count == 0
    }

    let head = Array(sample.prefix(CSVRule.sampleSize))
    let (encoding, bom) = CSVRule.encoding(
      of: head, isWholeFile: atEnd && head.count == sample.count)

    var sniffed: [UInt8] = []
    var sniffer = TextTranscoder(encoding)
    sniffer.convert(head[bom...], final: false, into: &sniffed)

    var transcoder = TextTranscoder(encoding)
    var text: [UInt8] = []
    transcoder.convert(sample[bom...], final: atEnd, into: &text)

    var parser = CSVParser(
      delimiter: CSVRule.delimiter(in: sniffed, fileExtension: fileExtension))

    feed(&parser, text[...], final: atEnd)

    var raw: [UInt8] = []

    while !atEnd, end == nil {
      if isCancelled() {
        finish(.cancelled)
        return
      }

      raw.removeAll(keepingCapacity: true)

      guard let count = fill(descriptor, &chunk, into: &raw, path: path) else { return }

      atEnd = count == 0
      text.removeAll(keepingCapacity: true)
      transcoder.convert(raw[...], final: atEnd, into: &text)
      feed(&parser, text[...], final: atEnd)
    }

    guard end == nil else { return }

    progress.truncatedRows = parser.truncatedRows

    if !sealPage() { return }

    finish(.completed)
  }

  /// Reads one chunk and appends it to `bytes`. Returns the count, or nil after the load has ended
  /// with the read's error.
  mutating func fill(
    _ descriptor: Int32, _ chunk: inout [UInt8], into bytes: inout [UInt8], path: String
  ) -> Int? {
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }

      if count < 0 {
        if errno == EINTR { continue }

        finish(.failed(.posix(errno, path: path)))
        return nil
      }

      bytes.append(contentsOf: chunk[0..<count])
      progress.bytesRead += count
      return count
    }
  }

  private mutating func feed(_ parser: inout CSVParser, _ text: ArraySlice<UInt8>, final: Bool) {
    guard end == nil else { return }

    parser.feed(text) { row, ends in
      accept(row: row, ends: ends)
      return end == nil
    }

    if final, end == nil {
      parser.finish { row, ends in
        accept(row: row, ends: ends)
        return end == nil
      }
    }

    progress.truncatedRows = parser.truncatedRows
    publishIfDue()
  }

  private mutating func accept(row: [UInt8], ends: [UInt32]) {
    if firstRow {
      firstRow = false
      var start = 0
      var cells: [String] = []

      for cellEnd in ends {
        cells.append(String(decoding: row[start..<Int(cellEnd)], as: UTF8.self))
        start = Int(cellEnd)
      }

      maxCells = max(maxCells, cells.count)

      if CSVRule.isHeader(cells) {
        header = cells
        return
      }
    }

    maxCells = max(maxCells, ends.count)
    builder.append(row: row, ends: ends)

    if builder.cost >= pageTarget {
      _ = sealPage()
    }
  }

  /// Checks for cancellation once in 256 rows, so a read of small rows stays cheap.
  ///
  /// Ends the load and returns true when it was cancelled.
  mutating func cancelled(atRow count: Int) -> Bool {
    guard count & 0xFF == 0, isCancelled() else { return false }

    finish(.cancelled)
    return true
  }

  /// Moves the page being filled into the sealed pages, if the budget lets it. Returns false after
  /// the load ended because it did not.
  mutating func sealPage() -> Bool {
    guard builder.rowCount > 0 else { return true }

    let page = builder.sealed()

    switch lease.reserve(page.cost) {
    case .granted:
      pages.append(page)
      builder.reset()
      return true

    case .overBudget:
      finish(.stoppedAtBudget)
      return false

    case .memoryPressure:
      finish(.stoppedLowMemory)
      return false

    case .released:
      finish(.cancelled)
      return false
    }
  }

  func snapshot(includingPartialPage: Bool) -> TableSnapshot {
    var all = pages

    if includingPartialPage, builder.rowCount > 0 {
      all.append(builder.sealed())
    }

    if json.isActive {
      return TableSnapshot(columns: json.columns.columns, pages: all)
    }

    if sheet.isActive {
      return TableSnapshot(
        columns: TableColumn.columns(
          header: sheet.header, count: max(sheet.columns, sheet.header?.count ?? 0)),
        pages: all)
    }

    let count = max(maxCells, header?.count ?? 0)
    return TableSnapshot(columns: TableColumn.columns(header: header, count: count), pages: all)
  }

  mutating func publishIfDue() {
    guard end == nil else { return }

    let now = ContinuousClock.now

    guard now - lastSnapshot >= TableLoader.snapshotInterval else { return }

    lastSnapshot = now
    emit(.snapshot(snapshot(includingPartialPage: true), progress))
  }

  /// Ends the load. A load that stopped early still reports the rows it holds.
  mutating func finish(_ reason: LoadEnd) {
    guard end == nil else { return }

    end = reason

    switch reason {
    case .failed, .cancelled:
      emit(.finished(.empty, reason, progress))

    case .completed, .stoppedAtBudget, .stoppedLowMemory:
      emit(.finished(snapshot(includingPartialPage: false), reason, progress))
    }
  }
}

private enum Format {
  case csv
  case json
  case spreadsheet
  case unsupported(description: String)

  /// The format a file name's extension names. CSV, TSV, and JSON load. A GeoJSON file is JSON, so it
  /// loads too. The spreadsheet extensions go to the workbook reader, which decides by content
  /// whether it is a workbook it can read or a format it names and refuses. The rest say that the
  /// viewer does not read them.
  static func of(extension ext: String) -> Format {
    switch ext {
    case "csv", "tsv", "tab":
      return .csv

    case "json", "jsonl", "ndjson", "geojson":
      return .json

    case "xlsx", "xlsm", "xls", "xlsb":
      return .spreadsheet

    case "":
      return .unsupported(description: "a file with no extension")

    default:
      return .unsupported(description: "a .\(ext) file")
    }
  }
}
