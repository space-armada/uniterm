import AppKit
import AppletKit
import SourceAccess
import StatusKit
import TableData
import Theme

/// Shows one file as a table, with a sort and a filter.
///
/// Every load goes through `replaceSource`. The open panel, a drop, the router, and a restore all
/// reach the same path, which finds the file off the main thread and hands it to the session. The
/// session reads it, also off the main thread, and the applet shows what it holds.
///
/// An open the user chooses, from the panel or a drop, asks `checkSource` first. A file that cannot
/// be opened then leaves the pane's source alone.
///
/// The description holds the file's path and bookmark, never its rows. `describe()` reads memory
/// only.
@MainActor
public final class DataViewerApplet: Applet, SourceReplacing {
  public let typeID = DataViewerDescription.typeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public private(set) var title = DataViewerApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  /// The grants that can act on the pane now. The one tab carries the authority marker while any
  /// can.
  private var authority = PaneAuthority.none
  public let openPicker: OpenPicker
  public let sourceSwap = SourceSwap()

  private static let untitled = "Data viewer"

  let content: DataViewerView
  let session: TableSession
  private var record: DataViewerDescription
  private var opening: Task<Void, Never>?
  private var openGeneration = 0
  private var resolvedNotice: String?

  /// The notices already posted to the status bar for the file shown now.
  private var posted = AppletNotices()

  /// Reaches the status bar for every alert.
  private var alerts = AppletAlerts()

  /// The origin of the load shown now. Each load sets its own, so a replacement never inherits
  /// a restore.
  private var loadOrigin = LoadOrigin.user

  /// The origin of the sort now in effect. A restored sort carries the restore's origin. A sort
  /// the user makes sets `user`, so its notice posts normally on a restored pane. A filter does
  /// not change it, since a filter cannot cause the skip.
  private var sortOrigin = LoadOrigin.user

  private var restoreWaitsForStart: Bool
  private var describesFromRecord: Bool
  private var closed = false
  private let budget: TableBudget
  private let pageTarget: Int
  private var nested: NestedTable?
  private(set) var valuePopover: ValuePopover?

  /// Where a value popover's Copy writes. The system pasteboard in the app, and a private named
  /// one in tests, since the system clipboard may hold the user's secrets.
  private let pasteboard: NSPasteboard
  private var revealedRevision = 0
  private var palette = ThemePalette.latte

  /// An empty pane that starts in `startDirectory`. The directory is explicit, and the applet never
  /// reads it from another pane.
  public init(
    startDirectory: String?, budget: TableBudget = .shared,
    pageTarget: Int = TableLoader.defaultPageTarget,
    picker: @escaping OpenPicker = SystemOpenPanel.pick, pasteboard: NSPasteboard = .general
  ) {
    record = DataViewerDescription(startDirectory: startDirectory)
    openPicker = picker
    self.pasteboard = pasteboard
    restoreWaitsForStart = false
    describesFromRecord = false
    self.budget = budget
    self.pageTarget = pageTarget

    session = TableSession(budget: budget, pageTarget: pageTarget)
    content = DataViewerView(session: session)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
  }

  /// Restores a pane from its description. The file is found and read when the pane starts, so
  /// restoring touches nothing on disk. A description this build cannot read is refused.
  public init(
    restoring description: AppletDescription, budget: TableBudget = .shared,
    pageTarget: Int = TableLoader.defaultPageTarget,
    picker: @escaping OpenPicker = SystemOpenPanel.pick, pasteboard: NSPasteboard = .general
  ) throws {
    record = try DataViewerDescription.decode(description)
    openPicker = picker
    self.pasteboard = pasteboard
    restoreWaitsForStart = record.path != nil
    describesFromRecord = true
    self.budget = budget
    self.pageTarget = pageTarget

    session = TableSession(budget: budget, pageTarget: pageTarget)
    content = DataViewerView(session: session)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    refresh()
  }

  /// The factory behind the router and the launcher: a pane that starts in `startDirectory` and
  /// opens `file`.
  public static func opening(
    _ file: URL, startDirectory: String, budget: TableBudget = .shared,
    picker: @escaping OpenPicker = SystemOpenPanel.pick, pasteboard: NSPasteboard = .general
  ) throws -> DataViewerApplet {
    let applet = DataViewerApplet(
      startDirectory: startDirectory, budget: budget, picker: picker, pasteboard: pasteboard)
    try applet.replaceSource(with: file, startDirectory: startDirectory)

    return applet
  }

  public var view: NSView { content }

  public var currentDirectory: String? {
    if let path = record.path {
      let folder = (path as NSString).deletingLastPathComponent

      if Self.isDirectory(folder) { return folder }
    }

    if let start = record.startDirectory, Self.isDirectory(start) { return start }

    return nil
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false

    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func wire() {
    session.onChange = { [weak self] in self?.refresh() }
    content.onSort = { [weak self] column in
      self?.sortOrigin = .user
      self?.session.cycleSort(column)
    }
    content.onFilter = { [weak self] text in
      self?.session.setFilter(text)
    }
    content.onFind = { [weak self] text in self?.session.setFind(text) }
    content.onStep = { [weak self] forward in self?.session.stepMatch(forward: forward) }
    content.onOpen = { [weak self] in self?.showOpenPanel() }
    content.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
    content.onExpand = { [weak self] request in self?.expand(request) }
    content.onShowValue = { [weak self] request in self?.showValue(request) }
    content.onSheet = { [weak self] name in self?.selectSheet(name) }
  }

  /// Shows another sheet of the open workbook. The choice is in the description at once, so a
  /// reopen or a relaunch brings the same sheet back.
  private func selectSheet(_ name: String) {
    record.sheet = name
    describesFromRecord = false

    // A sheet is a load of its own. The old sheet's notices are spent, and the file was found
    // once already.
    posted.reset()
    resolvedNotice = nil
    loadOrigin = .user
    sortOrigin = .user
    session.selectSheet(name)
  }

  // MARK: Find

  /// True when the pane shows a table, which is what the find commands need.
  var hasTable: Bool { content.body == .table }

  /// Opens the find bar and puts the keyboard in it.
  func showFind() {
    content.showFind()
  }

  /// Steps to the next or the previous match. With no query to step through, it opens the find bar
  /// instead, as Find Next does in other macOS apps.
  func stepFind(forward: Bool) {
    guard !session.findQuery.isEmpty else {
      content.showFind()
      return
    }

    session.stepMatch(forward: forward)
  }

  func focusFilter() {
    content.focusFilter()
  }

  private func findDisplay() -> FindDisplay {
    let query = session.findQuery

    guard !query.isEmpty else { return FindDisplay() }

    let matches = session.matches
    var status: String

    if session.isSearching {
      status = "Searching\u{2026}"
    } else if matches.isEmpty {
      status = "No matches"
    } else {
      let position = (session.currentMatch ?? 0) + 1
      let more = matches.isTruncated ? "+" : ""
      status = "\(position.formatted()) of \(matches.count.formatted())\(more) matches"
    }

    let loaded = session.snapshot.rowCount.formatted()
    let visible = session.visibleCount.formatted()
    let cut = session.phase == .stoppedAtBudget || session.phase == .stoppedLowMemory
    let filtered = session.visibleCount != session.snapshot.rowCount

    switch (cut, filtered) {
    case (true, true): status += " in \(visible) of the first \(loaded) rows"
    case (true, false): status += " in the first \(loaded) rows"
    case (false, true): status += " in \(visible) of \(loaded) rows"
    case (false, false): break
    }

    return FindDisplay(query: query, status: status)
  }

  private func revealCurrentMatch() {
    guard session.matchRevision != revealedRevision else { return }

    revealedRevision = session.matchRevision

    if let current = session.currentMatch {
      let place = session.matches.position(at: current)
      content.reveal(row: place.row, column: place.column)
    }
  }

  // MARK: Nested

  /// Opens a nested cell as a table in a popover over the cell, within this pane.
  private func expand(_ request: NestedRequest) {
    closePopovers()

    let table = NestedTable(
      bytes: request.bytes, title: request.title, budget: budget, palette: palette,
      pageTarget: pageTarget, pasteboard: pasteboard)
    table.onNotice = { [weak self] notice in
      guard let self else { return }

      alerts.deliver(notice, origin: .user, from: self, to: host)
    }

    nested = table
    table.present(relativeTo: request.rect, of: request.anchor)
  }

  /// Shows a cell's whole value in a popover over the cell.
  private func showValue(_ request: ValueRequest) {
    closePopovers()

    let popover = ValuePopover(request, palette: palette, pasteboard: pasteboard)
    valuePopover = popover
    popover.present(relativeTo: request.rect, of: request.anchor)
  }

  /// Closes the nested table and the value popover, whichever is open. The pane shows one at a time.
  private func closePopovers() {
    nested?.close()
    nested = nil
    valuePopover?.close()
    valuePopover = nil
  }

  // MARK: Source

  /// Shows `file` in place of what the pane shows. The load before it stops, and the new file starts
  /// with no sort and no filter. Nothing here touches the disk, so a missing or unreadable file
  /// shows its message in the pane.
  public func replaceSource(with file: URL, startDirectory: String) throws {
    record = DataViewerDescription(startDirectory: startDirectory, path: file.path)
    describesFromRecord = false
    restoreWaitsForStart = false

    open(path: file.path, bookmark: nil, restoring: nil, sheet: nil, origin: .user)
  }

  /// Finds `file` and reads its first rows the way a load does, and drops them. A file that is
  /// missing, unsupported, or does not parse from its start fails here, and the table stays. A
  /// failure that only a later row reaches still shows in the pane after the swap.
  public func checkSource(_ file: URL, startDirectory: String) async throws {
    switch await SourceResolver.resolve(path: file.path, bookmark: nil) {
    case .failure(let error):
      throw TableLoadError(error)

    case .success(let resolved):
      let failure = await TableLoader.probe(
        .file(resolved.file, sheet: nil), budget: budget, pageTarget: pageTarget)

      try Task.checkCancellation()

      if let failure { throw failure }
    }
  }

  private func open(
    path: String, bookmark: Data?, restoring query: TableQuery?, sheet: String?,
    origin: LoadOrigin
  ) {
    opening?.cancel()
    openGeneration += 1
    loadOrigin = origin
    sortOrigin = origin
    resolvedNotice = nil
    posted.reset()
    closePopovers()

    let generation = openGeneration
    session.close()
    refresh()

    opening = Task { [weak self] in
      let result = await SourceResolver.resolve(path: path, bookmark: bookmark)

      guard let self, generation == self.openGeneration, !self.closed else { return }

      self.opening = nil
      self.describesFromRecord = false

      switch result {
      case .success(let resolved):
        self.record.bookmark = resolved.bookmark

        if let movedFrom = resolved.movedFrom {
          self.record.path = movedFrom
          self.resolvedNotice = "Moved. Found at \(movedFrom)."
        }

        self.session.load(.file(resolved.file, sheet: sheet), restoring: query)

      case .failure(let error):
        self.session.fail(TableLoadError(error), restoring: query)
      }
    }
  }

  /// A drop of one file replaces the pane's file. Several files are refused with a message, and the
  /// pane keeps what it showed.
  func handleDrop(_ urls: [URL]) -> Bool {
    guard let file = urls.first else { return false }

    guard urls.count == 1 else {
      alerts.deliver(
        .warning, "Drop one file at a time. The data viewer shows one file in a pane.",
        from: self, to: host)
      return false
    }

    replaceSource(withChosen: file)

    return true
  }

  private func showOpenPanel() {
    Task { @MainActor [weak self] in
      guard let self else { return }

      await SourceOpening.open(self, picker: openPicker)
    }
  }

  // MARK: Applet

  public func start(origin: StartOrigin) {
    guard restoreWaitsForStart, let path = record.path else { return }

    restoreWaitsForStart = false
    open(
      path: path, bookmark: record.bookmark, restoring: record.query, sheet: record.sheet,
      origin: origin.loadOrigin)
  }

  public func close() {
    closed = true
    sourceSwap.cancel()
    closePopovers()
    opening?.cancel()
    opening = nil
    session.onChange = nil
    session.close()
  }

  public func authorityDidChange(_ authority: PaneAuthority) {
    guard authority != self.authority else { return }

    self.authority = authority
    publishedTabs = AppletTabList(
      first: authority.applyingOneTabMarker(to: publishedTabs.first))
    host?.appletTabsDidChange(self)
  }

  public func focus() {
    content.focusBody()
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette
    nested?.apply(palette)
    valuePopover?.apply(palette)
    content.apply(palette)
  }

  public func describe() -> AppletDescription {
    var description = record

    if !describesFromRecord {
      let query = session.query

      description.sort = query.sort
      description.filter = query.filter.isEmpty ? nil : query.filter
      description.sheet = session.selectedSheet ?? record.sheet
    }

    // The payload always encodes. The fields are plain values, so a failure is a programming error.
    return (try? description.appletDescription())
      ?? AppletDescription(
        type: DataViewerDescription.typeID, version: DataViewerDescription.currentVersion,
        payload: .object([:]))
  }

  // MARK: Display

  private func refresh() {
    guard !closed else { return }

    let query = describesFromRecord ? record.query : session.query

    if session.phase == .loaded || session.phase == .stoppedAtBudget
      || session.phase == .stoppedLowMemory
    {
      record.sheet = session.selectedSheet
    }

    content.fileName = fileName
    content.show(
      body(), filter: query.filter, sort: query.sort, find: findDisplay(),
      sheets: SheetDisplay(names: session.sheets, selected: session.selectedSheet))
    revealCurrentMatch()
    postNotices()

    let newTitle = fileName ?? Self.untitled
    let newSegments = segmentsForState()
    let titleChanged = newTitle != title

    guard titleChanged || newSegments != segments else { return }

    title = newTitle
    segments = newSegments

    if titleChanged {
      publishedTabs = AppletTabList(
        first: authority.applyingOneTabMarker(
          to: AppletTab(id: publishedTabs.first.id, title: newTitle)))
      host?.appletTabsDidChange(self)
    }

    host?.appletDidChange(self)
  }

  private var fileName: String? {
    record.path.map { ($0 as NSString).lastPathComponent }
  }

  private func body() -> DataViewerBody {
    if let failure = failure() {
      return .message(failure)
    }

    if !session.snapshot.columns.isEmpty, !session.stoppedBeforeAnyRow {
      return .table
    }

    let opening = "Opening \(fileName ?? "the file")\u{2026}"

    switch session.phase {
    case .idle:
      return record.path == nil
        ? .message("Open a CSV, JSON, or .xlsx file, or drop one here.")
        : .loading(opening, fraction: nil)

    case .loading:
      return .loading(opening, fraction: session.progress.fraction)

    case .loaded:
      if let sheet = session.selectedSheet, session.sheets.count > 1 {
        return .message("The sheet \u{201C}\(sheet)\u{201D} has no rows.")
      }

      return .message("\u{201C}\(title)\u{201D} has no rows.")

    case .stoppedAtBudget, .stoppedLowMemory:
      return .message(Self.stoppedBeforeAnyRowText)

    case .failed:
      return .message("")
    }
  }

  private static let stoppedBeforeAnyRowText =
    "Loading stopped because memory is in short supply, so no rows are shown."

  /// The level of a load that fails. A viewer holds no edits, so a failed load loses no user
  /// work. It leaves the requested content unshown, which is a warning.
  static let failureLevel = StatusLevel.warning

  private func failure() -> String? {
    if case .failed(let error) = session.phase {
      return error.errorDescription ?? "The file could not be opened."
    }

    return nil
  }

  /// Delivers each notice about the load once. While a table fills the pane, the status bar
  /// carries them, and its history keeps them. When the load leaves the pane empty, the pane
  /// explains itself, and the notice goes to the history only.
  private func postNotices() {
    for notice in posted.unposted(notices()) {
      alerts.deliver(notice, origin: origin(of: notice), from: self, to: host)
    }
  }

  /// The origin of a notice. A skipped sort follows the sort now in effect. Every other notice
  /// follows the load.
  private func origin(of notice: AppletNotice) -> LoadOrigin {
    notice.key == DataViewerNotices.sortSkippedKey ? sortOrigin : loadOrigin
  }

  /// The notices about what loaded.
  var loadNotices: [AppletNotice] { notices() }

  /// Rows not loaded or not sorted are warnings. A file found at a new path is info.
  private func notices() -> [AppletNotice] {
    var lines: [String] = []
    let loaded = session.snapshot.rowCount.formatted()
    let whole = session.sheets.isEmpty ? "the file" : "the sheet"

    if session.snapshot.rowCount > 0 {
      switch session.phase {
      case .stoppedAtBudget:
        lines.append(
          "Showing the first \(loaded) rows of \(whole). Sorting, filtering, and search cover only these rows."
        )

      case .stoppedLowMemory:
        lines.append(
          "Loading stopped because memory is low. Showing the first \(loaded) rows of \(whole). Sorting, filtering, and search cover only these rows."
        )

      default:
        break
      }
    }

    var notices = lines.map { AppletNotice(.warning, $0) }

    notices += DataViewerNotices.notices(
      sortSkipped: session.sortSkipped, truncatedRows: session.progress.truncatedRows,
      settled: session.phase != .idle && session.phase != .loading)

    if let failure = failure() {
      notices.append(AppletNotice(Self.failureLevel, failure, delivery: .historyOnly))
    }

    if session.stoppedBeforeAnyRow {
      notices.append(
        AppletNotice(Self.failureLevel, Self.stoppedBeforeAnyRowText, delivery: .historyOnly))
    }

    if let resolvedNotice {
      notices.append(AppletNotice(.info, resolvedNotice))
    }

    return notices
  }

  private func segmentsForState() -> [AppletSegment] {
    let loaded = session.snapshot.rowCount
    let visible = session.visibleCount
    let filtered = !session.query.isEmpty && visible != loaded

    switch session.phase {
    case .idle, .failed:
      return []

    case .loading:
      let percent = session.progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
      return [
        AppletSegment(
          symbolName: "tablecells", text: "Loading\(percent), \(loaded.formatted()) rows")
      ]

    case .loaded:
      return [
        AppletSegment(
          symbolName: "tablecells",
          text: filtered
            ? "\(visible.formatted()) of \(loaded.formatted()) rows"
            : "\(loaded.formatted()) rows")
      ] + cutSegments()

    case .stoppedAtBudget, .stoppedLowMemory:
      if session.stoppedBeforeAnyRow {
        return [
          AppletSegment(
            symbolName: "tablecells", text: "Stopped for memory, no rows loaded", style: .warning)
        ]
      }

      return [
        AppletSegment(
          symbolName: "tablecells",
          text: filtered
            ? "\(visible.formatted()) of the first \(loaded.formatted()) rows"
            : "The first \(loaded.formatted()) rows",
          style: .warning)
      ] + cutSegments()
    }
  }

  /// Segments that stay while the pane shows rows the notices said were changed: cells cut to
  /// size, or rows left in file order because sorting would not fit.
  private func cutSegments() -> [AppletSegment] {
    var segments: [AppletSegment] = []
    let cut = session.progress.truncatedRows

    if cut > 0 {
      segments.append(
        AppletSegment(
          symbolName: "scissors", text: cut == 1 ? "1 row cut" : "\(cut.formatted()) rows cut",
          style: .warning))
    }

    if session.sortSkipped {
      segments.append(
        AppletSegment(symbolName: "arrow.up.arrow.down", text: "Unsorted", style: .warning))
    }

    return segments
  }
}

extension DataViewerApplet: UserFileSourcing {
  public var userFileSource: String? { record.path }
}
