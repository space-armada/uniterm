import AppKit
import AppletKit
import HelperHost
import ImageViewerModel
import ImageWire
import SourceAccess
import StatusKit
import Theme
import UniformTypeIdentifiers

/// Shows one image, or steps through the images of a folder.
///
/// Every load goes through `replaceSource`. The open panel, a drop, the router, and a restore all
/// reach the same path. It finds and opens the source off the main thread, then hands the image's
/// descriptor to the pane's helper. The app never reads image bytes: the helper decodes in its own
/// sandbox and sends pixels the app has checked.
///
/// The description holds the source's path and bookmark and the current image's name, never
/// pixels. `describe()` reads memory only.
///
/// Stepping, the slideshow, and the prefetch live in extensions beside this file. They share the
/// state below, which is why it is not private.
@MainActor
public final class ImageViewerApplet: Applet, SourceReplacing {
  public let typeID = ImageViewerDescription.typeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public internal(set) var title = ImageViewerApplet.untitled
  public internal(set) var segments: [AppletSegment] = []
  public internal(set) var publishedTabs: AppletTabList

  static let untitled = "Image viewer"

  let content: ImageViewerView
  let client: ImageHelperClient

  let bitmapBudget: ImageBitmapBudget
  let lease: ImageBitmapBudget.Lease
  let scanPace: ScanPace
  let slideshowSleep: SlideshowSleep

  var record: ImageViewerDescription
  var describesFromRecord: Bool
  var restoreWaitsForStart: Bool
  var closed = false
  var alerts = AppletAlerts()
  var palette = ThemePalette.latte
  var loadOrigin = LoadOrigin.user
  var loading: Task<Void, Never>?
  var loadGeneration = 0
  var resizeCheck: Task<Void, Never>?

  private(set) var types = SupportedImageTypes()
  var phase = Phase.empty

  var folder: OpenedFolder?
  var openFile: OpenedImageFile?
  var listing = ImageListing(sort: .name)
  var folderNotListed = false
  var notListedNoticePosted = false
  var scanTask: Task<Void, Never>?
  var scanGeneration = 0
  var reloadBuffer: [ListedImage]?
  var scannedOrder: (sort: ImageSort, images: [ListedImage])?
  var sortGeneration = 0

  /// The image a restore or a reload wants back when only the scan can find it.
  var landing: WantedImage?

  /// What is on screen, and the bytes the bitmap budget holds for it.
  struct Shot {
    var name: String
    var modified: Double?
    var info: SourceInfo
    var image: CGImage
    var pixels: PixelSize
    var space: OutputSpace
    var bytes: Int
  }

  var shot: Shot?

  /// The source the helper last opened for the pane to show.
  var info: SourceInfo?

  /// The name and modification time of the image the display source was opened for.
  var sourceName: String?
  var sourceModified: Double?

  /// The image whose load last finished, shown or failed. `loadingName` is the one in progress.
  /// The selection may be ahead of both while the user holds a key.
  var committedName: String?
  var loadingName: String?
  var navTask: Task<Void, Never>?
  var navGeneration = 0
  var travelsForward = true

  var cache = FitCache<Shot>()

  /// The tiles of a zoomed image, the level they are cut from, and the last viewport that showed
  /// some. A refused zoom goes back to that viewport.
  var tiles = TileCache<TileImage>(capacity: 1)
  var tileLevel: TileLevel?
  var lastGood: ZoomViewport?
  var tileDenied: Set<TileKey> = []

  /// True while a load takes the pane back to fit. The prefetch waits until the load has chosen
  /// its image.
  var leavingZoom = false
  var prefetch: PrefetchJob?
  var prefetchTask: Task<Void, Never>?
  var prefetchFailed: Set<String> = []

  /// Opens the file a prefetch asks for. Tests replace it to hold the open.
  var prefetchOpener:
    @Sendable (OpenedFolder, String) async -> Result<OpenedImageFile, SourceAccessError> =
      { folder, name in await SourceLoader.openImage(in: folder, named: name) }

  var isPlaying = false
  var slideshowTask: Task<Void, Never>?

  var plan = AnimationPlan(delays: [0])
  var frames: [Int: Frame] = [:]
  var currentFrame = 0
  var waitingFor: Int?
  var playing: Task<Void, Never>?
  var isDetached = false

  /// The longer side the animation's frames are decoded at while the pane is zoomed past what a fit
  /// frame shows, or nil while frames are fit size. Frames made for another level are stale.
  var zoomLevel: Int?

  /// True from the moment a zoomed animation is left for another image until the next image is
  /// chosen. The old animation stays on screen and asks for nothing.
  var framesFrozen = false

  /// Frames kept ahead of the one showing. The bitmap budget can cut it to none.
  static let framesAhead = 2

  /// Whether the pane shows more than a fit. A pane that does never prefetches.
  var isZoomedPastFit = false {
    didSet { client.isZoomedPastFit = isZoomedPastFit }
  }

  enum Phase: Equatable {
    case empty
    case opening
    case showing
    case problem(PaneMessage)
  }

  struct Frame {
    var image: CGImage
    var bytes: Int

    /// The decode level of the zoom the frame was made for, or nil for a frame at fit size.
    var zoomLevel: Int?
  }

  /// An empty pane that starts in `startDirectory`. The directory is explicit, and the applet never
  /// reads it from another pane.
  public convenience init(startDirectory: String?) {
    self.init(
      startDirectory: startDirectory, settings: HelperSettings(location: .bundledImageDecoder),
      helperBudget: .shared, bitmapBudget: .shared)
  }

  init(
    startDirectory: String?, settings: HelperSettings, helperBudget: ImageHelperBudget,
    bitmapBudget: ImageBitmapBudget, scanPace: ScanPace = ScanPace(),
    slideshowSleep: @escaping SlideshowSleep = ImageViewerApplet.realSleep
  ) {
    record = ImageViewerDescription(startDirectory: startDirectory)
    restoreWaitsForStart = false
    describesFromRecord = false

    content = ImageViewerView(frame: .zero)
    client = ImageHelperClient(settings: settings, budget: helperBudget)
    self.bitmapBudget = bitmapBudget
    self.scanPace = scanPace
    self.slideshowSleep = slideshowSleep
    lease = bitmapBudget.makeLease()
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    refresh()
  }

  /// Restores a pane from its description. The source is found and opened when the pane starts, so
  /// restoring touches nothing on disk. A description this build cannot read is refused.
  public convenience init(restoring description: AppletDescription) throws {
    try self.init(
      restoring: description, settings: HelperSettings(location: .bundledImageDecoder),
      helperBudget: .shared, bitmapBudget: .shared)
  }

  init(
    restoring description: AppletDescription, settings: HelperSettings,
    helperBudget: ImageHelperBudget, bitmapBudget: ImageBitmapBudget,
    scanPace: ScanPace = ScanPace(),
    slideshowSleep: @escaping SlideshowSleep = ImageViewerApplet.realSleep
  ) throws {
    record = try ImageViewerDescription.decode(description)
    restoreWaitsForStart = record.path != nil
    describesFromRecord = true

    content = ImageViewerView(frame: .zero)
    client = ImageHelperClient(settings: settings, budget: helperBudget)
    self.bitmapBudget = bitmapBudget
    self.scanPace = scanPace
    self.slideshowSleep = slideshowSleep
    lease = bitmapBudget.makeLease()
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))
    listing = ImageListing(sort: record.sort)

    wire()
    refresh()
  }

  /// The factory behind the router and the launcher: a pane that starts in `startDirectory` and
  /// opens `file`.
  public static func opening(_ file: URL, startDirectory: String) throws -> ImageViewerApplet {
    let applet = ImageViewerApplet(startDirectory: startDirectory)
    try applet.replaceSource(with: file, startDirectory: startDirectory)

    return applet
  }

  public var view: NSView { content }

  public var openPanelContentTypes: [UTType]? { types.openPanelTypes }

  public var currentDirectory: String? {
    if let path = record.path {
      let folder = record.kind == .folder ? path : (path as NSString).deletingLastPathComponent

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
    content.onOpen = { [weak self] in self?.showOpenPanel() }
    content.onRetry = { [weak self] in self?.retry() }
    content.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
    content.onGeometryChange = { [weak self] in self?.geometryChanged() }
    content.onKey = { [weak self] key in self?.handle(key: key) ?? false }
    content.onViewportChange = { [weak self] _ in self?.viewportChanged() }
    content.onPinchBegin = { [weak self] in self?.stopSlideshow() }
    client.onEvent = { [weak self] event in self?.handle(event) }
  }

  var shownPixels: PixelSize? { shot?.pixels }
  var shownSpace: OutputSpace? { shot?.space }

  // MARK: Source

  /// Shows `file`, or the first image of it when it is a folder, in place of what the pane shows.
  /// A playing slideshow or animation stops. Nothing here touches the disk, so a missing or
  /// unreadable source shows its message in the pane.
  public func replaceSource(with file: URL, startDirectory: String) throws {
    record = ImageViewerDescription(
      startDirectory: startDirectory, path: file.path, sort: record.sort)
    describesFromRecord = false
    restoreWaitsForStart = false

    begin(path: file.path, bookmark: nil, wanted: nil, origin: .user)
  }

  func begin(path: String, bookmark: Data?, wanted: WantedImage?, origin: LoadOrigin) {
    exitZoom()
    loading?.cancel()
    loadGeneration += 1
    loadOrigin = origin
    alerts.replaceLoad()
    stopSlideshow()
    clearImage()
    cancelNavigation()

    folder = nil
    openFile = nil
    listing = ImageListing(sort: record.sort)
    folderNotListed = false
    notListedNoticePosted = false
    committedName = nil
    prefetchFailed = []
    landing = wanted
    phase = .opening
    refresh()

    let generation = loadGeneration
    let storedKind = record.kind
    let sort = record.sort
    let supported = types

    loading = Task { [weak self] in
      let result = await SourceLoader.load(
        path: path, bookmark: bookmark, storedKind: storedKind, wanted: wanted, sort: sort,
        types: supported)

      guard let self, generation == self.loadGeneration, !self.closed else { return }

      self.loading = nil
      self.finishLoading(result, wanted: wanted)
    }
  }

  private func finishLoading(
    _ result: Result<LoadedSource, SourceLoadFailure>, wanted: WantedImage?
  ) {
    describesFromRecord = false

    switch result {
    case .failure(let failure):
      landing = nil
      phase = .problem(
        PaneMessage(text: failure.localizedDescription, offersOpen: true, offersRetry: false))
      notify(.warning, failure.localizedDescription, delivery: .historyOnly)
      refresh()

    case .success(let loaded):
      record.bookmark = loaded.resolved.bookmark
      record.kind = loaded.kind

      if let movedFrom = loaded.resolved.movedFrom {
        record.path = movedFrom
        notify(.info, "Moved. Found at \(movedFrom).", delivery: .message)
      }

      folder = loaded.folder
      folderNotListed = loaded.folderNotListed
      listing = ImageListing(sort: record.sort)

      if let file = loaded.image {
        landing = nil
        listing.seed(ListedImage(name: file.name, modified: file.modified))
        show(file: file)
      }

      if loaded.folderNotListed {
        listing.finish()
        postNotListedNotice()
      } else {
        startScan()
      }

      refresh()
    }
  }

  func postNotListedNotice() {
    guard !notListedNoticePosted else { return }

    notListedNoticePosted = true

    let name = record.current.map { "\u{201C}\($0)\u{201D}" } ?? "this image"

    notify(
      .warning,
      "The folder of \(name) could not be listed, so only this image is shown. macOS may be protecting the folder.",
      delivery: .message)
  }

  /// Starts showing `file` as the image the helper decodes. What the pane showed stays on screen
  /// until the new image arrives.
  func show(file: OpenedImageFile) {
    openFile = file
    sourceName = file.name
    sourceModified = file.modified
    record.current = file.name
    record.currentModified = file.modified
    loadingName = file.name
    info = nil

    stopAnimating()
    dropFrames()
    framesFrozen = false

    if phase != .showing { phase = .opening }

    refresh()
    client.open(file, role: .display)
  }

  /// Opens the shown image again, as after a helper crash.
  func retry() {
    if let current = listing.current, folder != nil || openFile != nil {
      beginLoad(of: current, bypassCache: true)
      return
    }

    if let path = record.path {
      begin(
        path: path, bookmark: record.bookmark,
        wanted: record.current.map { WantedImage(name: $0, modified: record.currentModified) },
        origin: .user)
    }
  }

  /// A drop of one file or folder replaces the pane's source. Several items are refused with a
  /// warning, and so is a drop that carries no file URL. The pane keeps what it showed.
  func handleDrop(_ urls: [URL]) -> Bool {
    guard let item = urls.first else {
      notify(
        .warning,
        "Drop a file or a folder from Finder. Images dragged from other apps are not supported.",
        delivery: .message)
      return false
    }

    guard urls.count == 1 else {
      notify(
        .warning, "Drop one file or folder at a time. The image viewer shows one source in a pane.",
        delivery: .message)
      return false
    }

    do {
      try replaceSource(with: item, startDirectory: SourceStartDirectory.of(item))
      return true
    } catch {
      notify(
        .warning,
        "\u{201C}\(item.lastPathComponent)\u{201D} could not be opened: \(error.localizedDescription)",
        delivery: .message)
      return false
    }
  }

  private func showOpenPanel() {
    Task { @MainActor [weak self] in
      guard let self else { return }

      await SourceOpening.open(self, picker: SystemOpenPanel.pick)
    }
  }

  // MARK: Helper events

  private func handle(_ event: HelperEvent) {
    guard !closed else { return }

    switch event {
    case .types(let identifiers):
      types.update(helperTypes: identifiers)

    case .opened(let opened):
      info = opened
      plan = AnimationPlan(delays: opened.frameDelays)
      currentFrame = 0
      reapPrefetch()
      requestStill()
      refresh()

    case .prefetchOpened(let opened):
      prefetchOpened(opened)

    case .prefetchDropped(let request):
      prefetchDropped(request)

    case .prefetchOpenFailed(let source, let text):
      prefetchOpenFailed(source, text)

    case .image(let request, let header, let pixels):
      received(request, header, pixels)

    case .failed(let request, let kind, let text):
      failed(request, kind, text)

    case .refused(let request, let text):
      if request.kind == .prefetch {
        prefetchLost(text)
      } else if request.kind == .tile {
        zoomRefused(text)
      } else if isZoomedFrame(request) {
        zoomedFrameLost(request, text)
      } else if request.kind == .still {
        problem(text, offersRetry: true)
      } else {
        stopAnimating()
      }

    case .ended(let reason, let lost):
      if lost?.kind == .prefetch, !(prefetch?.promoted ?? false) {
        helperLostDuringPrefetch()
      } else if let lost, lost.kind == .tile || isZoomedFrame(lost), phase == .showing, shot != nil
      {
        zoomEnded(reason)
      } else {
        ended(reason)
      }
    }
  }

  private var imageName: String { record.current ?? title }

  private func ended(_ reason: HelperEnd) {
    if let failing = loadingName ?? sourceName { committedName = failing }

    clearImage()
    stopAnimating()

    let name = "\u{201C}\(imageName)\u{201D}"
    let text: String

    switch reason {
    case .crashed:
      text = "The image decoder stopped while showing \(name). A damaged file can cause this."

    case .unresponsive:
      text = "The image decoder stopped responding while showing \(name)."

    case .overranTimeBound:
      text = "\(name) took longer to decode than uniterm allows, so it is past the limit."

    case .overFootprint:
      text =
        "\(name) needs more memory than uniterm lets an image decoder use, so it is past the limit."

    case .misbehaved:
      text = "The image decoder sent something uniterm refused while showing \(name)."

    case .versionMismatch:
      text = ImageProtocol.mismatchText

    case .unavailable(let reason):
      text = reason
    }

    problem(text, offersRetry: reason.offersRetry)
  }

  private func failed(_ request: DecodeRequest?, _ kind: FailureKind, _ text: String) {
    if let request, request.kind == .prefetch {
      prefetchLost(text)
      return
    }

    if let request, request.kind == .tile, kind != .staleSource {
      zoomRefused(text)
      return
    }

    if let request, isZoomedFrame(request), kind != .staleSource {
      zoomedFrameLost(request, text)
      return
    }

    switch kind {
    case .staleSource:
      guard let request, request.source == info?.source,
        let current = listing.current
      else { return }

      beginLoad(of: current, bypassCache: true)

    case .noSource:
      problem(text, offersRetry: true)

    case .unsupportedFormat, .unreadable, .limit:
      if let request, request.kind == .frame {
        stopAnimating()
        return
      }

      problem(text, offersRetry: false)
    }
  }

  /// Shows `text` in place of the image. The load in progress, if any, is finished.
  func problem(_ text: String, offersRetry: Bool) {
    if let loadingName { committedName = loadingName }

    loadingName = nil
    phase = .problem(PaneMessage(text: text, offersOpen: true, offersRetry: offersRetry))
    notify(.warning, text, delivery: .historyOnly)
    refresh()
    pump()
  }

  // MARK: Decoding

  private func requestedLongerSide(for info: SourceInfo) -> Int {
    let native = PixelSize(width: Int(info.width), height: Int(info.height))
    let displayed = content.displayedPixels(for: native, actualScale: info.actualScale)

    guard displayed.longer > 0 else { return min(native.longer, 2048) }

    return FitMath.requestedLongerSide(displayed: displayed, native: native)
  }

  func fitLongerSide(of info: SourceInfo) -> Int {
    requestedLongerSide(for: info)
  }

  private func requestStill() {
    guard let info else { return }

    client.decode(maxPixel: requestedLongerSide(for: info), frame: currentFrame, kind: .still)
  }

  private func received(_ request: DecodeRequest, _ header: ImageHeader, _ pixels: Data) {
    if request.kind == .prefetch {
      prefetchArrived(request, header, pixels)
      return
    }

    if request.kind == .tile {
      tileArrived(request, header, pixels)
      return
    }

    guard let info, request.source == info.source else { return }

    let native = PixelSize(width: Int(info.width), height: Int(info.height))

    guard let image = BitmapFactory.makeImage(header, pixels: pixels) else {
      problem("The image could not be shown.", offersRetry: false)
      return
    }

    let size = PixelSize(width: Int(header.width), height: Int(header.height))

    if request.kind == .frame {
      store(frame: Int(header.frame), request: request, image: image, bytes: pixels.count)
      return
    }

    let sameImage = shot?.name == sourceName

    // A sharper backdrop for a zoomed animation must not replace the zoomed frame on screen.
    let keepsZoomedFrames = sameImage && plan.isAnimated && zoomLevel != nil

    if !keepsZoomedFrames { dropFrames() }

    retireShown(keeping: sourceName)

    guard reserve(pixels.count) else {
      problem(
        "There is not enough memory to show \u{201C}\(imageName)\u{201D} right now. Close an image pane and retry.",
        offersRetry: true)
      return
    }

    if !keepsZoomedFrames { currentFrame = Int(header.frame) }

    shot = Shot(
      name: sourceName ?? imageName, modified: sourceModified, info: info, image: image,
      pixels: size, space: header.space, bytes: pixels.count)
    committedName = sourceName
    loadingName = nil
    phase = .showing

    if !keepsZoomedFrames {
      content.show(
        image: image, native: native, actualScale: info.actualScale, hdr: header.space.isHDR,
        keepingZoom: sameImage)
      frames[currentFrame] = Frame(image: image, bytes: 0)
    }

    refresh()

    if plan.isAnimated {
      startAnimating()
      fillWindow()
    }

    shownSettled()
    viewportChanged()
  }

  /// Reserves `bytes` in the bitmap budget. The images a pane keeps beside the one on screen give
  /// way first, so a pane can always show the image the user asked for.
  func reserve(_ bytes: Int) -> Bool {
    if bitmapBudget.reserve(bytes, lease: lease) { return true }

    releaseCache()

    return bitmapBudget.reserve(bytes, lease: lease)
  }

  /// Puts what the pane shows aside. A different image becomes the previous one, which the cache
  /// keeps. The same image, decoded again at another size, gives its bytes back.
  func retireShown(keeping next: String?) {
    guard let old = shot else { return }

    shot = nil

    if old.name == next {
      bitmapBudget.giveBack(old.bytes, lease: lease)
      return
    }

    let entry = FitCache<Shot>.Entry(name: old.name, modified: old.modified, value: old)

    if let evicted = cache.keepPrevious(entry) {
      bitmapBudget.giveBack(evicted.value.bytes, lease: lease)
    }
  }

  func releaseCache() {
    for entry in cache.removeAll() {
      bitmapBudget.giveBack(entry.value.bytes, lease: lease)
    }
  }

  /// Releases the bitmap the budget holds for the image on screen, and the frames behind it.
  func clearImage() {
    framesFrozen = false
    resizeCheck?.cancel()
    stopAnimating()
    dropFrames()
    releaseCache()
    prefetchTask?.cancel()
    prefetchTask = nil
    prefetch = nil

    if let old = shot { bitmapBudget.giveBack(old.bytes, lease: lease) }

    resetZoomState()
    shot = nil
    info = nil
    sourceName = nil
    sourceModified = nil
    loadingName = nil
    plan = AnimationPlan(delays: [0])
    content.show(message: PaneMessage(text: "", offersOpen: false, offersRetry: false))
  }

  func dropFrames() {
    for frame in frames.values {
      bitmapBudget.giveBack(frame.bytes, lease: lease)
    }

    frames = [:]
    waitingFor = nil
  }

  // MARK: Resize

  func geometryChanged() {
    if shot != nil { viewportChanged() }

    guard phase == .showing, shot != nil, loadingName == nil else { return }

    resizeCheck?.cancel()
    resizeCheck = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(120))

      guard !Task.isCancelled, let self else { return }

      self.sharpenIfNeeded()
    }
  }

  private func sharpenIfNeeded() {
    guard let held = shot, phase == .showing, loadingName == nil else { return }

    let native = PixelSize(width: Int(held.info.width), height: Int(held.info.height))
    let displayed = content.displayedPixels(for: native, actualScale: held.info.actualScale)

    guard FitMath.needsSharperDecode(held: held.pixels, displayed: displayed, native: native) else {
      return
    }

    guard client.source?.source == held.info.source, info?.source == held.info.source else {
      if let current = listing.current { beginLoad(of: current, bypassCache: true) }
      return
    }

    requestStill()
  }

  // MARK: Animation

  var isAnimating: Bool { playing != nil }

  /// The animation frame on screen.
  var frameIndex: Int { currentFrame }

  func startAnimating() {
    guard plan.isAnimated, !isDetached, !closed, playing == nil else { return }

    fillWindow()
    scheduleNextFrame()
  }

  func stopAnimating() {
    playing?.cancel()
    playing = nil
  }

  private func scheduleNextFrame() {
    playing?.cancel()

    let delay = plan.delay(of: currentFrame)

    playing = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(delay)))

      guard !Task.isCancelled, let self else { return }

      self.advance()
    }
  }

  private func advance() {
    let next = plan.next(after: currentFrame)

    guard let frame = frames[next], frame.zoomLevel == zoomLevel else {
      waitingFor = next
      fillWindow()
      return
    }

    showFrame(next, frame)
  }

  private func showFrame(_ index: Int, _ frame: Frame) {
    currentFrame = index
    waitingFor = nil
    content.swap(image: frame.image, zoomed: frame.zoomLevel != nil)

    let keep = Set(plan.window(from: index, ahead: Self.framesAhead))

    for held in frames.keys where !keep.contains(held) {
      if let dropped = frames.removeValue(forKey: held) {
        bitmapBudget.giveBack(dropped.bytes, lease: lease)
      }
    }

    fillWindow()
    scheduleNextFrame()
  }

  /// The longer side a frame is decoded at now: the zoom's level, or the fit size.
  func frameSide(for info: SourceInfo) -> Int {
    zoomLevel ?? fitLongerSide(of: info)
  }

  /// True for a frame request made for a zoom. Only a zoom asks for frames larger than the fit
  /// size, so the size tells it from a fit request, whatever the zoom has become since.
  func isZoomedFrame(_ request: DecodeRequest) -> Bool {
    guard request.kind == .frame, let info, request.source == info.source else { return false }

    return request.maxPixel > fitLongerSide(of: info)
  }

  /// A limit or a failure hit a zoomed frame. The zoom it was made for is refused like a tile. A
  /// request for a level the pane has already left says nothing about the current one, so it is
  /// dropped and the window is asked for again.
  func zoomedFrameLost(_ request: DecodeRequest, _ text: String) {
    if request.maxPixel == zoomLevel {
      zoomRefused(text)
    } else {
      fillWindow()
    }
  }

  private func holdsCurrentFrame(_ index: Int) -> Bool {
    frames[index].map { $0.zoomLevel == zoomLevel } ?? false
  }

  /// Asks for the first frame of the window that is not held at the current size. Frame requests
  /// yield to a still. A frame already in flight or waiting is not asked for twice.
  func fillWindow() {
    guard let info, !isDetached, !framesFrozen else { return }

    let side = frameSide(for: info)

    // A request waiting for the current size keeps its place, since a newer one would replace it.
    // Requests for a size the pane has left still run to the end and are replaced when they wait.
    guard client.pendingFrame?.maxPixel != side else { return }

    let outstanding = client.outstandingFrames

    for wanted in plan.window(from: currentFrame, ahead: Self.framesAhead)
    where !holdsCurrentFrame(wanted) {
      if outstanding.contains(where: { $0.frame == wanted && $0.maxPixel == side }) { continue }

      client.decode(maxPixel: side, frame: wanted, kind: .frame)
      return
    }
  }

  private func store(frame index: Int, request: DecodeRequest, image: CGImage, bytes: Int) {
    guard plan.isAnimated, plan.window(from: currentFrame, ahead: Self.framesAhead).contains(index),
      let info
    else { return }

    guard request.maxPixel == frameSide(for: info) else {
      fillWindow()
      return
    }

    if let old = frames.removeValue(forKey: index) {
      bitmapBudget.giveBack(old.bytes, lease: lease)
    }

    guard bitmapBudget.reserve(bytes, lease: lease) else {
      if zoomLevel != nil {
        zoomRefused("There is not enough memory to keep the animation's frames at this zoom.")
        return
      }

      stopAnimating()
      notify(
        .warning, "The animation paused because there is not enough memory to keep its frames.",
        delivery: .message)
      return
    }

    let frame = Frame(image: image, bytes: bytes, zoomLevel: zoomLevel)
    frames[index] = frame

    if zoomLevel != nil,
      plan.window(from: currentFrame, ahead: Self.framesAhead).allSatisfy(holdsCurrentFrame)
    {
      lastGood = content.viewport
    }

    if waitingFor == index, playing != nil {
      showFrame(index, frame)
      return
    }

    if index == currentFrame { content.swap(image: image, zoomed: frame.zoomLevel != nil) }

    fillWindow()
  }

  // MARK: Applet

  public func start(origin: StartOrigin) {
    guard restoreWaitsForStart, let path = record.path else { return }

    restoreWaitsForStart = false
    begin(
      path: path, bookmark: record.bookmark,
      wanted: record.current.map { WantedImage(name: $0, modified: record.currentModified) },
      origin: origin.loadOrigin)
  }

  public func close() {
    closed = true
    loading?.cancel()
    resizeCheck?.cancel()
    scanTask?.cancel()
    cancelNavigation()
    stopSlideshow()
    stopAnimating()
    alerts.discard()
    clearImage()
    client.shutdown()
    bitmapBudget.release(lease)
    folder = nil
    openFile = nil
  }

  /// Pauses an animation and the slideshow, and holds back alerts while the pane is off screen. The
  /// slideshow remembers that it was playing.
  public func detach() {
    isDetached = true
    alerts.detach()
    stopAnimating()
    pauseSlideshowTimer()
    abandonPrefetchOpening()
    content.cancelPinch()
    releaseZoomForDetach()
  }

  public func reattach() {
    isDetached = false
    alerts.reattach(from: self, to: host)
    restoreZoomAfterReattach()

    if phase == .showing, plan.isAnimated { startAnimating() }

    resumeSlideshowTimer()
    maybePrefetch()
  }

  public func focus() {
    content.window?.makeFirstResponder(content)
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette
    content.apply(palette)
  }

  public func describe() -> AppletDescription {
    (try? record.appletDescription())
      ?? AppletDescription(
        type: ImageViewerDescription.typeID, version: ImageViewerDescription.currentVersion,
        payload: .object([:]))
  }

  // MARK: Display

  func notify(_ level: StatusLevel, _ text: String, delivery: AppletNotice.Delivery) {
    alerts.deliver(
      AppletNotice(level, text, delivery: delivery), origin: loadOrigin, from: self, to: host)
  }

  func refresh() {
    guard !closed else { return }

    switch phase {
    case .empty:
      content.show(
        message: PaneMessage(
          text: "Open an image or a folder, or drop one here.", offersOpen: true, offersRetry: false
        ))

    case .opening:
      content.show(
        message: PaneMessage(text: "Opening\u{2026}", offersOpen: false, offersRetry: false))

    case .problem(let message):
      content.show(message: message)

    case .showing:
      break
    }

    let newTitle = record.current ?? Self.untitled
    let newSegments = segmentsForState()
    let titleChanged = newTitle != title

    guard titleChanged || newSegments != segments else { return }

    title = newTitle
    segments = newSegments

    if titleChanged {
      publishedTabs = AppletTabList(first: AppletTab(id: publishedTabs.first.id, title: newTitle))
      host?.appletTabsDidChange(self)
    }

    host?.appletDidChange(self)
  }

  private func segmentsForState() -> [AppletSegment] {
    var segments: [AppletSegment] = []

    if phase == .showing, let held = shot {
      segments.append(
        AppletSegment(
          symbolName: "photo",
          text: "\(held.info.width.formatted()) \u{00D7} \(held.info.height.formatted())"))

      if plan.isAnimated {
        segments.append(
          AppletSegment(symbolName: "play.rectangle", text: "\(plan.frameCount) frames"))
      }

      if let viewport = content.viewport, !viewport.isFit {
        let percent = Int((viewport.scale / viewport.actualScale * 100).rounded())

        segments.append(
          AppletSegment(symbolName: "magnifyingglass", text: "\(percent.formatted())%"))
      }

      if listing.count > 1, let index = listing.index {
        let more = listing.isComplete ? "" : "+"

        segments.append(
          AppletSegment(
            symbolName: "folder",
            text: "\((index + 1).formatted()) of \(listing.count.formatted())\(more)"))
      }
    }

    if isPlaying {
      segments.append(AppletSegment(symbolName: "play.fill", text: "Slideshow"))
    }

    if folderNotListed {
      segments.append(
        AppletSegment(
          symbolName: "folder.badge.questionmark", text: "Folder not listed", style: .warning))
    }

    return segments
  }
}
