import AppKit
import AppletKit
import FileWatching
import GeoData
import PlaceSearch
import SourceAccess
import StatusKit
import Theme
import UniformTypeIdentifiers

/// Shows a map that the user can pan and zoom, in one of three styles, with the pins of a GeoJSON
/// file on it.
///
/// MapKit owns the map and its gestures. The applet keeps the visible region and the style in its
/// description, and `describe()` reads memory only. The region is saved when the map settles, not
/// at every frame.
///
/// Every file load goes through `replaceSource`. The open panel, a drop, the router, and a restore
/// reach the same path, which finds the file and parses it off the main thread. The file's pins are
/// their own layer, so loading another file replaces them and nothing else. The description holds
/// the file's path and bookmark, never its pins.
@MainActor
public final class MapViewerApplet: Applet, SourceReplacing {
  public let typeID = MapViewerDescription.typeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public private(set) var title = MapViewerApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  private static let untitled = "Map"
  private static let limits = GeoJSONLimits()

  let content = MapViewerView()
  let places: PlaceNamer
  private let services: PlaceServices
  private var record: MapViewerDescription
  private var closed = false
  private(set) var opening: Task<Void, Never>?
  private var openGeneration = 0
  private var restoreWaitsForStart = false
  private var filePins: [GeoPin] = []
  private var fileNotices: [String] = []

  /// Points and shapes the file holds that the map does not show, and whether the file passed
  /// the point bound. The status bar's segment counts them.
  private var hiddenFromFile = 0
  private var fileTruncated = false

  /// The notices already posted to the status bar for the file shown now.
  private var posted = AppletNotices()

  /// Reaches the status bar for every alert, and holds them back while the pane is detached.
  private var alerts = AppletAlerts()

  /// The origin of the load that produced the file notices shown now. Each load, and each edit
  /// that reads pins back, sets its own when it settles. A later user edit never inherits a
  /// restore.
  private var fileNoticeOrigin = LoadOrigin.user

  /// What set the changed-on-disk flag. A restore sets it when the unsaved pins were made over
  /// bytes that differ from the file now. The file watcher sets it when the file changes under
  /// edits.
  private var changedOnDiskOrigin = LoadOrigin.reload

  /// Why the file did not open, while that holds. The failure follows the current load. A new
  /// load or a clear ends it.
  private var fileFailure: String?
  private var resolvedNotice: String?
  private var tileFailure: String?

  /// The file's bytes as the user has edited them. Nil before any file or pin.
  private(set) var document: Data?

  /// The file's bytes as they are on disk, as of the last load or save.
  private(set) var savedDocument: Data?

  /// The pane's own undo stack, for pin edits. Cmd-Z reaches it while the map has focus. Each step
  /// keeps a whole document, so the stack is bounded.
  let undoManager: UndoManager = {
    let manager = UndoManager()
    manager.levelsOfUndo = 50
    return manager
  }()

  /// The read of an edited document's pins, while it runs.
  private(set) var editing: Task<Void, Never>?
  private var editGeneration = 0
  private var watcher: FileWatcher?
  private var changedOnDisk = false
  /// Unsaved pins a closed pane carried, waiting for its file to load: the edited bytes, the
  /// file's bytes the edits were made over, and the file's path. They apply only to that file.
  private var unsavedFromUndo: UnsavedPins?

  /// The features whose pins the patcher can change, by ordinal.
  private var editableOrdinals: Set<Int> = []

  /// The save in flight. A second Save waits for it, so it cannot read the file between the
  /// first one's write and its record of what it wrote, and see its own write as a conflict.
  private var saving: Task<Bool, Never>?

  /// A question about unsaved edits, while it is open.
  private(set) var asking: Task<Void, Never>?

  /// Asks where Save As writes, given a suggested name and a start folder. Tests replace it.
  var chooseSaveLocation: @MainActor (String, String?, NSWindow?) async -> URL? =
    MapViewerApplet.runSavePanel

  /// Asks what Save does when the file changed on disk since it was read. Tests replace it.
  var resolveConflict: @MainActor (String, NSWindow?) async -> SaveConflictChoice =
    MapViewerApplet.runConflictAlert

  /// An empty pane that starts in `startDirectory`. The directory is explicit, and the applet never
  /// reads it from another pane.
  ///
  /// `region` is where the map starts, such as a place the user picked in the launcher. It is the
  /// user's choice, so it is saved with the pane.
  ///
  /// `places` names the map's center for the palette and backs Go to Place. A pane given none asks
  /// no one, shows no name, and offers no search.
  public init(startDirectory: String?, region: GeoRegion? = nil, places: PlaceServices = .none) {
    self.places = PlaceNamer(lookup: places.names)
    services = places
    record = MapViewerDescription(startDirectory: startDirectory)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()

    if let region {
      record.region = region
      content.show(region: region)
    }

    refresh()
  }

  /// Restores a pane from its description. The region and style come back with no work on the
  /// disk or the network. A description this build cannot read is refused.
  public init(restoring description: AppletDescription, places: PlaceServices = .none) throws {
    self.places = PlaceNamer(lookup: places.names)
    services = places
    record = try MapViewerDescription.decode(description)
    restoreWaitsForStart = record.path != nil
    unsavedFromUndo = Self.unsavedPins(in: description)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    content.show(style: record.style)

    if let region = record.region {
      content.show(region: region)
    }

    refresh()

    if record.path == nil, let unsaved = unsavedFromUndo, unsaved.path == nil {
      unsavedFromUndo = nil
      replaceDocument(with: unsaved.document, registeringUndo: false)
    }
  }

  /// The factory behind the router and the launcher: a pane that starts in `startDirectory` and
  /// opens `file`.
  public static func opening(
    _ file: URL, startDirectory: String, places: PlaceServices = .none
  ) -> MapViewerApplet {
    let applet = MapViewerApplet(startDirectory: startDirectory, places: places)
    applet.replaceSource(with: file, startDirectory: startDirectory)

    return applet
  }

  public var view: NSView { content }

  /// The open file's folder, or else the directory the pane started in.
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
    content.onRegionSettled = { [weak self] region in self?.regionSettled(region) }
    content.onTilesChanged = { [weak self] failure in self?.tilesChanged(failure) }
    content.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
    content.onRegionShown = { [weak self] region in self?.places.regionShown(region) }
    places.onName = { [weak self] _ in self?.refresh() }
    content.onPlacePicked = { [weak self] region in self?.goTo(region) }
    content.onAddPin = { [weak self] coordinate in self?.addPin(at: coordinate) }
    content.onAddPinAtCenter = { [weak self] in self?.addPinAtCenter() }
    content.onUpdatePin = { [weak self] old, new in self?.update(old, to: new) }
    content.onRemovePin = { [weak self] pin in self?.remove(pin) }
    content.ownUndoManager = undoManager
  }

  // MARK: Style

  /// The style the pane shows.
  public var style: MapStyle { record.style }

  /// Shows the map in `style`. The choice is in the description at once, so a reopen or a
  /// relaunch brings it back.
  func choose(style: MapStyle) {
    guard style != record.style else { return }

    record.style = style
    content.show(style: style)
    refresh()
    host?.appletDidChange(self)
  }

  // MARK: Region

  private func regionSettled(_ region: GeoRegion) {
    if let stored = record.region, stored.isIndistinguishable(from: region) { return }

    record.region = region
    refresh()
    host?.appletDidChange(self)
  }

  /// True when the file layer has pins for Zoom to Fit Pins to show.
  var canFitPins: Bool { !filePins.isEmpty }

  /// Shows every pin of the file layer, as a load does, and saves that region with the pane.
  func fitPins() {
    guard let region = GeoRegion.fitting(filePins.map(\.coordinate)) else { return }

    content.show(region: region)
    regionSettled(region)
  }

  // MARK: Go to place

  /// True when the pane has a place search to offer.
  var canGoToPlace: Bool { services.search != nil }

  /// Shows the place search over the map and puts the keyboard in it.
  func showPlaceSearch() {
    guard let makeSearcher = services.search else { return }

    content.showPlaceSearch(makeSearcher: makeSearcher)
  }

  /// Moves the map to a place the user picked. The move is the user's, so it is saved.
  private func goTo(_ region: GeoRegion) {
    content.show(region: region)
    regionSettled(region)
    content.hidePlaceSearch()
  }

  // MARK: Source

  /// Shows the pins of `file` in place of the file layer's. The pins on the map go at once. The new
  /// file is found and parsed off the main thread. A failure is a warning on the status bar and a
  /// segment while it holds. When the map has no tiles and no command pins to show, the pane says
  /// it instead, and the history keeps one entry. The map then fits the new pins, and that region
  /// is saved with the pane.
  ///
  /// `SourceReplacing` lets a viewer throw. This one never does, since every failure shows once
  /// the load runs.
  public func replaceSource(with file: URL, startDirectory: String) {
    guard isDirty else {
      load(file, startDirectory: startDirectory)
      return
    }

    let name = displayName

    asking = Task { [weak self] in
      guard let self else { return }

      defer { asking = nil }

      let request = AppletConfirmation(
        title: "Discard your changes to \u{201C}\(name)\u{201D}?",
        detail:
          "Opening \u{201C}\(file.lastPathComponent)\u{201D} replaces the pins you have not saved.",
        confirmTitle: "Discard and Open", cancelTitle: "Cancel")

      guard await host?.applet(self, confirm: request) == true, !closed else { return }

      load(file, startDirectory: startDirectory)
    }
  }

  private func load(_ file: URL, startDirectory: String) {
    dropUnsavedFromUndo()
    record.startDirectory = startDirectory
    record.path = file.path
    record.bookmark = nil
    restoreWaitsForStart = false

    open(path: file.path, bookmark: nil, fitsPins: true, origin: .user)
  }

  private func open(path: String, bookmark: Data?, fitsPins: Bool, origin: LoadOrigin) {
    opening?.cancel()
    openGeneration += 1
    resolvedNotice = nil
    fileFailure = nil
    fileNotices = []
    hiddenFromFile = 0
    fileTruncated = false
    posted.reset()
    alerts.replaceLoad()
    filePins = []
    content.removePins(layer: .file)
    forgetDocument()

    let generation = openGeneration
    let limits = Self.limits

    opening = Task { [weak self] in
      let resolved = await SourceResolver.resolve(path: path, bookmark: bookmark)

      guard let self, generation == self.openGeneration, !self.closed else { return }

      switch resolved {
      case .failure(let error):
        self.dropUnsavedFromUndo()
        self.finishOpen(failure: error.errorDescription, origin: origin)

      case .success(let source):
        self.record.bookmark = source.bookmark

        if source.movedFrom != nil {
          self.record.path = source.file.path
          self.resolvedNotice = "Moved. Found at \(source.file.path)."
        }

        let result = await GeoJSONFileReader.readDocument(source.file, limits: limits)

        guard generation == self.openGeneration, !self.closed else { return }

        switch result {
        case .failure(let error):
          self.dropUnsavedFromUndo()
          self.finishOpen(failure: error.errorDescription, origin: origin)

        case .success(let read):
          self.document = read.bytes
          self.savedDocument = read.bytes
          self.editableOrdinals = GeoJSONPatcher.editableOrdinals(in: read.bytes)
          self.watch(source.file)
          self.finishOpen(layer: read.layer, fitsPins: fitsPins, origin: origin)

          // The edits were made over the file as it was at close. Save compares with those
          // bytes, so a file changed since then asks before it is overwritten.
          if let unsaved = self.unsavedFromUndo, unsaved.path == path {
            self.unsavedFromUndo = nil
            self.savedDocument = unsaved.base ?? read.bytes
            self.changedOnDisk = self.savedDocument != read.bytes
            self.changedOnDiskOrigin = origin
            self.replaceDocument(with: unsaved.document, registeringUndo: false, origin: origin)
          } else {
            self.dropUnsavedFromUndo()
          }
        }
      }
    }

    refresh()
    host?.appletDidChange(self)
  }

  private func finishOpen(failure: String?, origin: LoadOrigin) {
    opening = nil
    fileNoticeOrigin = origin
    fileFailure = failure ?? "The file could not be opened."
    refresh()
    host?.appletDidChange(self)
  }

  private func finishOpen(layer: GeoFileLayer, fitsPins: Bool, origin: LoadOrigin) {
    opening = nil
    fileNoticeOrigin = origin
    filePins = layer.pins
    fileNotices = layer.notices(limit: Self.limits.maxPoints)
    count(layer)

    if layer.pins.isEmpty && layer.skippedShapes == 0 && layer.invalidCoordinates == 0 {
      fileNotices.append("The file has no points to show.")
    }

    let accent = fileAccent

    record.fileAccent = accent.rawValue
    showFilePins()

    if fitsPins, let region = GeoRegion.fitting(layer.pins.map(\.coordinate)) {
      record.region = region
      content.show(region: region)
    }

    refresh()
    host?.appletDidChange(self)
  }

  static let changedOnDiskNotice =
    "The file changed on disk. Saving asks before it overwrites the change."

  /// The origin of a notice. The changed-on-disk notice follows what set the flag. Every other
  /// notice comes from the load or edit that produced the file notices.
  private func origin(of notice: AppletNotice) -> LoadOrigin {
    notice.key == Self.changedOnDiskNotice ? changedOnDiskOrigin : fileNoticeOrigin
  }

  /// The notices about the file shown now. What a read left out is a warning. A file that did not
  /// open is a warning too. A file found at a new path is info. They go to the status bar, except
  /// a failure that leaves the pane empty. The pane says that one, so it goes to the history only.
  var statusNotices: [AppletNotice] {
    var notices = fileNotices.map { AppletNotice(.warning, $0) }

    if let fileFailure {
      notices.insert(
        AppletNotice(.warning, fileFailure, delivery: paneIsEmpty ? .historyOnly : .message),
        at: 0)
    }

    if let resolvedNotice { notices.append(AppletNotice(.info, resolvedNotice)) }

    if changedOnDisk { notices.append(AppletNotice(.warning, Self.changedOnDiskNotice)) }

    return notices
  }

  /// Keeps why the map's tiles fail to load, for a segment while they do. MapKit can report one
  /// outage many times, so only the first report of an outage goes to the status bar. The next
  /// successful load ends the outage.
  private func tilesChanged(_ failure: String?) {
    guard failure != tileFailure else { return }

    if let failure, tileFailure == nil {
      alerts.deliver(.warning, failure, from: self, to: host)
    }

    tileFailure = failure
    refresh()
    host?.appletDidChange(self)
  }

  /// True when the file failed and nothing else is on the map: its tiles do not load and no
  /// command layer has a pin. The pane has room to explain itself then.
  private var paneIsEmpty: Bool {
    fileFailure != nil && tileFailure != nil && !content.hasPins(otherThan: .file)
  }

  /// Keeps what a read of the file left out, for the status bar's segment.
  private func count(_ layer: GeoFileLayer) {
    hiddenFromFile = layer.skippedShapes + layer.invalidCoordinates
    fileTruncated = layer.truncated
  }

  /// The file layer's default accent: the stored one while it names an accent, else the first of
  /// the fixed order. The layer keeps it for the pane's life, even after a clear.
  var fileAccent: ThemeToken {
    PinAccents.validated(record.fileAccent) ?? PinAccents.layerDefault(at: 0)
  }

  /// The pins the file layer shows now.
  var filePinsShown: [GeoPin] { filePins }

  /// True when the file layer holds pins or names a file, which is when Clear File Pins has work.
  var canClearFile: Bool { record.path != nil || !filePins.isEmpty || fileFailure != nil }

  /// Removes the file layer's pins and forgets the file, so a relaunch does not bring them back.
  /// The layer keeps its default accent. Unsaved edits are asked about first, since the clear
  /// cannot be undone.
  func clearFile() {
    guard isDirty else {
      clearFileNow()
      return
    }

    let name = displayName

    asking = Task { [weak self] in
      guard let self else { return }

      defer { asking = nil }

      let request = AppletConfirmation(
        title: "Discard your changes to \u{201C}\(name)\u{201D}?",
        detail: "Clearing the file's pins also drops the pins you have not saved.",
        confirmTitle: "Discard and Clear", cancelTitle: "Cancel")

      guard await host?.applet(self, confirm: request) == true, !closed else { return }

      clearFileNow()
    }
  }

  private func clearFileNow() {
    dropUnsavedFromUndo()
    opening?.cancel()
    opening = nil
    openGeneration += 1
    restoreWaitsForStart = false
    resolvedNotice = nil
    fileFailure = nil
    fileNotices = []
    hiddenFromFile = 0
    fileTruncated = false
    filePins = []
    record.path = nil
    record.bookmark = nil
    content.removePins(layer: .file)
    forgetDocument()

    refresh()
    host?.appletDidChange(self)
  }

  /// A drop of one file replaces the file layer. Several files are refused with a message, and the
  /// pane keeps what it showed.
  func handleDrop(_ urls: [URL]) -> Bool {
    guard let file = urls.first else { return false }

    guard urls.count == 1 else {
      alerts.deliver(
        .warning, "Drop one file at a time. The map shows one file in a pane.", from: self,
        to: host)
      return false
    }

    replaceSource(with: file, startDirectory: SourceStartDirectory.of(file))

    return true
  }

  // MARK: Applet

  public func start(origin: StartOrigin) {
    guard restoreWaitsForStart, let path = record.path else { return }

    restoreWaitsForStart = false
    open(path: path, bookmark: record.bookmark, fitsPins: false, origin: origin.loadOrigin)
  }

  public func close() {
    closed = true
    alerts.discard()
    opening?.cancel()
    opening = nil
    editing?.cancel()
    editing = nil
    watcher?.stop()
    watcher = nil
    content.closeEditor()
    undoManager.removeAllActions()
    content.onRegionSettled = nil
    content.onTilesChanged = nil
    content.onDrop = nil
    content.onRegionShown = nil
    content.onPlacePicked = nil
    content.hidePlaceSearch()
    places.cancel()
    content.stopObserving()
    content.mapView.delegate = nil
  }

  /// The map holds back its alerts while detached. See `AppletAlerts`.
  public func detach() {
    alerts.detach()
  }

  public func reattach() {
    alerts.reattach(from: self, to: host)
  }

  public func focus() {
    content.window?.makeFirstResponder(content.mapView)
  }

  public func apply(_ palette: ThemePalette) {
    content.apply(palette)
  }

  public func describe() -> AppletDescription {
    // The payload always encodes. The fields are plain values, so a failure is a programming error.
    // A release build falls back to an empty payload, which restores as a default map.
    if let description = try? record.appletDescription() {
      guard isDirty, let document else { return description }

      return AppletDescription(
        type: description.type, version: description.version, payload: description.payload,
        undoState: Self.undoState(document: document, base: savedDocument, path: record.path))
    }

    assertionFailure("the map viewer description failed to encode")

    return AppletDescription(
      type: MapViewerDescription.typeID, version: MapViewerDescription.currentVersion,
      payload: .object([:]))
  }

  // MARK: Display

  private func refresh() {
    guard !closed else { return }

    var newSegments = [AppletSegment(symbolName: "map", text: Self.name(of: record.style))]

    if isDirty {
      newSegments.append(AppletSegment(symbolName: "pencil", text: "Edited"))
    }

    if !filePins.isEmpty {
      newSegments.append(
        AppletSegment(
          symbolName: "mappin",
          text: filePins.count == 1 ? "1 pin" : "\(filePins.count.formatted()) pins"))
    }

    if fileTruncated {
      newSegments.append(
        AppletSegment(symbolName: "eye.slash", text: "Some points hidden", style: .warning))
    } else if hiddenFromFile > 0 {
      newSegments.append(
        AppletSegment(symbolName: "eye.slash", text: "\(hiddenFromFile.formatted()) hidden"))
    }

    if changedOnDisk {
      newSegments.append(
        AppletSegment(
          symbolName: "exclamationmark.triangle", text: "Changed on disk", style: .warning))
    }

    if fileFailure != nil {
      newSegments.append(
        AppletSegment(
          symbolName: "exclamationmark.triangle", text: "File not opened", style: .warning))
    }

    if tileFailure != nil {
      newSegments.append(
        AppletSegment(symbolName: "wifi.exclamationmark", text: "Map not loading", style: .warning))
    }

    segments = newSegments

    // The pane says only what stands in for the map's content: a failure when nothing else is
    // on the map, or the wait while a file opens. Every other notice goes to the status bar once,
    // and stays in its history.
    var lines: [String] = []

    if paneIsEmpty, let fileFailure { lines.append(fileFailure) }

    if opening != nil { lines.append("Opening\u{2026}") }

    content.show(explanation: lines)

    for notice in posted.unposted(statusNotices) {
      alerts.deliver(notice, origin: origin(of: notice), from: self, to: host)
    }
    content.setAccessibilityValue(accessibilitySummary())

    let newTitle = displayName + (isDirty ? " \u{2014} Edited" : "")
    let tab = AppletTab(
      id: publishedTabs.first.id, title: newTitle, details: places.name.map { [$0] } ?? [])

    title = newTitle

    if tab != publishedTabs.first {
      publishedTabs = AppletTabList(first: tab)
      host?.appletTabsDidChange(self)
    }
  }

  private static func name(of style: MapStyle) -> String {
    switch style {
    case .standard: return "Standard"
    case .satellite: return "Satellite"
    case .hybrid: return "Hybrid"
    }
  }

  /// The style and the center of the saved region, to two places. A UI test and an assistive tool
  /// read it, since the map view itself says little.
  private func accessibilitySummary() -> String {
    var text = record.style.rawValue

    if let center = record.region?.center {
      text += String(format: " %.2f,%.2f", center.latitude, center.longitude)
    }

    if !filePins.isEmpty { text += " pins=\(filePins.count)" }

    if isDirty { text += " edited" }

    return text
  }
}

// MARK: - Editing

/// Unsaved pins a closed pane carried in its description's undo-only part.
struct UnsavedPins: Equatable {
  let document: Data
  let base: Data?
  let path: String?
}

/// What Save does when the file changed on disk after the map read it.
enum SaveConflictChoice: Equatable {
  /// Write the edits over the change on disk.
  case overwrite

  /// Write the edits to a new file instead.
  case saveAs

  /// Drop the edits and show the file as it is on disk.
  case revert

  case cancel
}

extension MapViewerApplet {
  static let unsavedKey = "unsavedDocument"

  /// True when the pins differ from the file on disk, or a pane with no file holds pins.
  var isDirty: Bool { document != nil && document != savedDocument }

  /// The file's name, or what an unsaved map is called.
  var displayName: String {
    if let path = record.path { return (path as NSString).lastPathComponent }

    return document == nil ? "Map" : "Untitled"
  }

  public var unsavedWork: AppletUnsavedWork? {
    isDirty ? AppletUnsavedWork(label: displayName) : nil
  }

  public func saveUnsavedWork() async -> Bool {
    await save()
  }

  /// True when no read of an edit is still running. An edit names pins by the IDs the last read
  /// gave them, and a removal or a split renumbers them, so a second edit waits for the first.
  var canEdit: Bool { editing == nil && opening == nil }

  // MARK: Edits

  func addPin(at coordinate: GeoCoordinate) {
    let pin = GeoPin(
      id: "", coordinate: coordinate, label: GeoFileLayerBuilder.coordinateText(coordinate))

    apply(.add(pin), named: "Add Pin")
  }

  /// Adds a pin at the center of the map, for the pin list's Add Pin.
  func addPinAtCenter() {
    let center = content.mapView.centerCoordinate

    addPin(at: GeoCoordinate(latitude: center.latitude, longitude: center.longitude))
  }

  func update(_ old: GeoPin, to new: GeoPin) {
    guard old != new else { return }

    apply(
      .update(old: old, new: new), named: old.coordinate != new.coordinate ? "Move Pin" : "Edit Pin"
    )
  }

  func remove(_ pin: GeoPin) {
    apply(.remove(pin), named: "Remove Pin")
  }

  /// Removes the pin selected on the map.
  func removeSelectedPin() {
    guard let pin = content.selectedFilePin?.pin else { return }

    remove(pin)
  }

  /// Opens the editor for the pin selected on the map.
  func editSelectedPin() {
    guard let pin = content.selectedFilePin else { return }

    content.showEditor(for: pin)
  }

  var hasSelectedPin: Bool { content.selectedFilePin != nil }

  private func apply(_ edit: PinEdit, named action: String) {
    guard canEdit else {
      NSSound.beep()
      showFilePins()
      return
    }

    do {
      let next = try GeoJSONPatcher.apply(edit, to: document ?? GeoJSONPatcher.emptyDocument)

      undoManager.setActionName(action)
      replaceDocument(with: next, registeringUndo: true, actionName: action)
    } catch {
      showFilePins()
      alerts.deliver(
        .warning, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        from: self, to: host)
    }
  }

  /// Makes `next` the document and reads its pins off the main thread. Undo puts back the document
  /// as it was, and redo puts back `next`, through this same path.
  func replaceDocument(
    with next: Data?, registeringUndo: Bool, actionName: String = "", origin: LoadOrigin = .user
  ) {
    let previous = document

    if registeringUndo {
      undoManager.registerUndo(withTarget: self) { applet in
        applet.replaceDocument(with: previous, registeringUndo: true, actionName: actionName)
      }
      undoManager.setActionName(actionName)
    }

    document = next
    editGeneration += 1

    let generation = editGeneration
    let path = record.path ?? "Untitled"
    let bytes = next ?? GeoJSONPatcher.emptyDocument

    editing = Task { [weak self] in
      let result = await GeoJSONFileReader.layer(of: bytes, path: path)

      guard let self, generation == self.editGeneration, !self.closed else { return }

      self.editing = nil

      switch result {
      case .failure(let error):
        // The edit made bytes the reader refuses. Keeping them would let Save write a broken
        // file, so the document goes back and the undo stack, which now points at them, goes.
        self.document = previous
        self.undoManager.removeAllActions()

        let reason = error.errorDescription ?? "the file could not be read back"

        self.alerts.deliver(
          .warning, "The edit was not applied, since it made the file unreadable: \(reason)",
          from: self, to: self.host)

      case .success(let layer):
        self.fileNoticeOrigin = origin
        self.filePins = layer.pins
        self.fileNotices = layer.notices(limit: Self.limits.maxPoints)
        self.count(layer)
        self.editableOrdinals = GeoJSONPatcher.editableOrdinals(in: bytes)
        self.showFilePins()

        if actionName == "Add Pin", layer.truncated {
          self.alerts.deliver(
            .warning,
            "The pin is in the file, past the map's \(Self.limits.maxPoints.formatted())-point limit, "
              + "so it does not show.",
            from: self, to: self.host)
        }
      }

      self.refresh()
      self.host?.appletDidChange(self)
    }

    refresh()
  }

  /// Drops the document and its undo stack, as when another file loads.
  private func forgetDocument() {
    editing?.cancel()
    editing = nil
    editGeneration += 1
    document = nil
    savedDocument = nil
    changedOnDisk = false
    watcher?.stop()
    watcher = nil
    undoManager.removeAllActions()
  }

  // MARK: Saving

  var canSave: Bool { isDirty || (document != nil && record.path == nil) }

  /// Writes the edits to the file. A pane with no file asks where. A file changed on disk since
  /// the map read it asks before it is overwritten. Returns true when the edits are on disk.
  @discardableResult
  func save() async -> Bool {
    if let saving { return await saving.value }

    let task = Task { await performSave() }
    saving = task
    defer { saving = nil }

    return await task.value
  }

  private func performSave() async -> Bool {
    guard let path = record.path else { return await saveAs() }

    guard let document else { return true }

    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let onDisk = try? Data(contentsOf: url)

    if onDisk != savedDocument {
      switch await resolveConflict(displayName, content.window) {
      case .overwrite: break
      case .saveAs: return await saveAs()
      case .revert:
        revert()
        return false
      case .cancel: return false
      }
    }

    return await write(document, to: url)
  }

  /// Writes the pins to a new file the user names, and makes it the pane's file.
  @discardableResult
  func saveAs() async -> Bool {
    let suggested = record.path == nil ? "Pins.geojson" : displayName

    guard let url = await chooseSaveLocation(suggested, currentDirectory, content.window) else {
      return false
    }

    let bytes = document ?? GeoJSONPatcher.emptyDocument

    guard await write(bytes, to: url) else { return false }

    record.path = url.path
    record.bookmark = nil
    record.startDirectory = url.deletingLastPathComponent().path
    document = bytes
    savedDocument = bytes
    watch(url)
    refresh()
    host?.appletDidChange(self)

    return true
  }

  private func write(_ bytes: Data, to url: URL) async -> Bool {
    switch await Self.atomicWrite(bytes, to: url) {
    case .success:
      if url.path == record.path { savedDocument = bytes }

      changedOnDisk = false
      refresh()
      host?.appletTabsDidChange(self)

      return true

    case .failure(let error):
      alerts.deliver(
        .error,
        "\u{201C}\(url.lastPathComponent)\u{201D} could not be saved: \(error.localizedDescription)",
        from: self, to: host)

      return false
    }
  }

  /// Writes beside the file, then swaps the new file in. A failure leaves the old file whole. The
  /// swap keeps the old file's permissions and other metadata.
  @concurrent
  static func atomicWrite(_ bytes: Data, to url: URL) async -> Result<Void, any Error> {
    let manager = FileManager.default
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).uniterm-\(UUID().uuidString)")

    do {
      try bytes.write(to: temporary, options: .withoutOverwriting)

      if manager.fileExists(atPath: url.path) {
        _ = try manager.replaceItemAt(url, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: url)
      }

      return .success(())
    } catch {
      try? manager.removeItem(at: temporary)
      return .failure(error)
    }
  }

  /// Drops the edits and reads the file as it is on disk.
  func revert() {
    guard let path = record.path else { return }

    open(path: path, bookmark: record.bookmark, fitsPins: false, origin: .reload)
  }

  // MARK: The file on disk

  private func watch(_ url: URL) {
    watcher?.stop()
    watcher = FileWatcher(url: url, policy: .fileOnly) { [weak self] _ in
      self?.fileChangedOnDisk()
    }
  }

  /// The file on disk changed. A pane with no edits reads it again. A pane with edits keeps them
  /// and says so, and Save asks before it overwrites the change. A change that only repeats what
  /// the map last saved or read, as its own save does, is not a change.
  func fileChangedOnDisk() {
    guard !closed, let path = record.path else { return }

    let onDisk = try? Data(contentsOf: URL(fileURLWithPath: path))

    guard onDisk != savedDocument else { return }

    if isDirty {
      changedOnDisk = true
      changedOnDiskOrigin = .reload
      refresh()
    } else {
      open(path: path, bookmark: record.bookmark, fitsPins: false, origin: .reload)
    }
  }

  // MARK: Restore

  /// The undo-only part of a dirty pane's description: the edited bytes, and for a pane with a
  /// file, the bytes the edits were made over and the file's path.
  static func undoState(document: Data, base: Data?, path: String?) -> JSONValue {
    var fields: [String: JSONValue] = [unsavedKey: .string(document.base64EncodedString())]

    if let base { fields[unsavedBaseKey] = .string(base.base64EncodedString()) }

    if let path { fields[unsavedPathKey] = .string(path) }

    return .object(fields)
  }

  static let unsavedBaseKey = "unsavedBase"
  static let unsavedPathKey = "unsavedPath"

  static func unsavedPins(in description: AppletDescription) -> UnsavedPins? {
    guard case .object(let fields)? = description.undoState,
      case .string(let encoded)? = fields[unsavedKey],
      let document = Data(base64Encoded: encoded)
    else { return nil }

    var base: Data?
    var path: String?

    if case .string(let text)? = fields[unsavedBaseKey] { base = Data(base64Encoded: text) }

    if case .string(let text)? = fields[unsavedPathKey] { path = text }

    return UnsavedPins(document: document, base: base, path: path)
  }

  /// Lets go of a closed pane's unsaved pins that can no longer apply, and says so.
  func dropUnsavedFromUndo() {
    guard unsavedFromUndo != nil else { return }

    unsavedFromUndo = nil
    alerts.deliver(
      .error,
      "The pins left unsaved when this pane closed could not be restored, since their file did not open.",
      from: self, to: host)
  }

  /// Shows the file layer's pins as the last read gave them. A pin dragged off its place, or one
  /// a refused edit moved, goes back to where the file holds it.
  func showFilePins() {
    let editable = editableOrdinals

    content.replacePins(layer: .file, pins: filePins, defaultAccent: fileAccent) { pin in
      pin.id.split(separator: ":").first.flatMap { Int($0) }.map(editable.contains) ?? false
    }
  }

  // MARK: Panels

  static let runSavePanel: @MainActor (String, String?, NSWindow?) async -> URL? = {
    name, directory, window in
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [UTType("public.geojson") ?? .json]
    panel.canCreateDirectories = true

    if let directory { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }

    let response: NSApplication.ModalResponse

    if let window, window.isVisible {
      response = await panel.beginSheetModal(for: window)
    } else {
      response = panel.runModal()
    }

    return response == .OK ? panel.url : nil
  }

  static let runConflictAlert: @MainActor (String, NSWindow?) async -> SaveConflictChoice = {
    name, window in
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "\u{201C}\(name)\u{201D} changed on disk."
    alert.informativeText =
      "Another program changed the file after the map read it. Saving now replaces that change."
    alert.addButton(withTitle: "Save As\u{2026}")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Overwrite")
    alert.addButton(withTitle: "Revert")
    alert.window.setAccessibilityIdentifier("map-save-conflict")

    let response: NSApplication.ModalResponse

    if let window, window.isVisible {
      response = await alert.beginSheetModal(for: window)
    } else {
      response = alert.runModal()
    }

    switch response {
    case .alertFirstButtonReturn: return .saveAs
    case .alertThirdButtonReturn: return .overwrite
    case NSApplication.ModalResponse(
      rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
      return .revert
    default: return .cancel
    }
  }
}
