import AppKit
import HelperHost
import ImageViewerModel
import ImageWire

/// A decoded tile the pane holds, drawn over the backdrop.
struct TileImage {
  var image: CGImage
  var hdr: Bool
}

/// Free zoom: the zoom commands, the tiles that give a zoomed image its detail, and the limits.
///
/// The backdrop is the fit-size decode the pane already holds. A zoom scales it at once, so the
/// main thread never waits on a tile. The helper decodes the image once at the scale the zoom
/// needs, never past native, and sends tiles around the viewport. The pane keeps a bounded set of
/// them in the bitmap budget, so its memory follows the size of the pane and not the image. Tile
/// requests go through the same latest-wins scheduler as every other request, and a step or a
/// resize goes ahead of them.
///
/// A zoomed animation has no tiles. Its frames decode at the same level instead, through the frame
/// path, so it keeps playing with sharp detail. See `retargetFrames`.
///
/// A pane zoomed past fit never prefetches. A zoom the helper's cap or the app-wide budget cannot
/// hold is refused with a status bar warning, and the pane goes back to the last zoom that worked.
/// No other pane's helper is touched.
extension ImageViewerApplet {
  // MARK: Commands

  var canZoom: Bool {
    phase == .showing && shot != nil && info != nil && !closed
  }

  func zoomIn() {
    zoom(.step(zoomingIn: true))
  }

  func zoomOut() {
    zoom(.step(zoomingIn: false))
  }

  func zoomToActualSize() {
    zoom(.actual)
  }

  func zoomToFit() {
    zoom(.fit)
  }

  private func zoom(_ target: ImageViewerView.ZoomTarget) {
    guard canZoom else { return }

    content.zoom(target)
  }

  /// Moves a zoomed image under the pane, as the arrow keys do. Returns false at fit, where the
  /// arrows step instead.
  func panImage(by key: ImageKey) -> Bool {
    guard let viewport = content.viewport, !viewport.isFit else { return false }

    let horizontal = viewport.pane.width * Self.panFraction
    let vertical = viewport.pane.height * Self.panFraction

    switch key {
    case .left: content.pan(byPoints: CGSize(width: horizontal, height: 0))
    case .right: content.pan(byPoints: CGSize(width: -horizontal, height: 0))
    case .up: content.pan(byPoints: CGSize(width: 0, height: vertical))
    case .down: content.pan(byPoints: CGSize(width: 0, height: -vertical))
    default: return false
    }

    return true
  }

  /// How much of the pane an arrow key moves the image.
  static let panFraction: CGFloat = 0.2

  // MARK: Viewport

  /// The zoom or the pan changed, or the pane did. Keeps the prefetch gate, the tiles, and the
  /// status segment in step with the viewport.
  func viewportChanged() {
    guard let viewport = content.viewport else { return }

    let free = !viewport.isFit

    if free != isZoomedPastFit {
      isZoomedPastFit = free

      if free {
        stopSlideshow()
        dropPrefetched()
      } else {
        releaseTiles()
        client.releaseLevel()

        if !leavingZoom { maybePrefetch() }
      }
    }

    if free, !content.isPinching { refreshTiles() }

    retargetFrames()
    refresh()
  }

  /// Keeps an animation's frames at the size the zoom needs. A frame decodes at the level a still's
  /// tiles are cut from, so a zoom that crosses to another level, or back to fit, asks for the
  /// window again. The frame on screen stays until its replacement arrives, so the animation never
  /// blanks. A pinch changes nothing until the fingers lift.
  func retargetFrames() {
    guard plan.isAnimated, let info, let viewport = content.viewport, !content.isPinching else {
      return
    }

    if leavingZoom {
      zoomLevel = nil
      return
    }

    var wanted: Int?

    if !viewport.isFit {
      let level = TileLevel(
        native: viewport.native, scale: viewport.scale, backing: Double(content.backingScale))

      if level.longerSide > fitLongerSide(of: info) { wanted = level.longerSide }
    }

    guard wanted != zoomLevel else { return }

    zoomLevel = wanted

    for (index, frame) in frames where frame.zoomLevel != wanted && index != currentFrame {
      bitmapBudget.giveBack(frame.bytes, lease: lease)
      frames[index] = nil
    }

    fillWindow()
  }

  /// Returns the pane to fit before another image takes its place. The helper drops the decode it
  /// kept for tiles while the old source is still the shown one.
  func exitZoom() {
    guard content.viewport?.isFit == false else { return }

    leavingZoom = true
    defer { leavingZoom = false }

    if plan.isAnimated {
      stopAnimating()
      framesFrozen = true
    }

    content.zoom(.fit)
  }

  /// Forgets all zoom state, as when the image goes away.
  func resetZoomState() {
    releaseTiles()
    lastGood = nil
    zoomLevel = nil
    isZoomedPastFit = false
  }

  // MARK: Tiles

  func releaseTiles() {
    for entry in tiles.removeAll() {
      bitmapBudget.giveBack(entry.bytes, lease: lease)
    }

    tileLevel = nil
    tileDenied = []
    content.setTiles([])
  }

  /// Keeps the tiles around the viewport and asks for the nearest one that is missing.
  func refreshTiles() {
    guard let viewport = content.viewport, !viewport.isFit, !plan.isAnimated, let held = shot,
      phase == .showing, !isDetached, !closed, !content.isPinching,
      held.info.source == info?.source
    else { return }

    let backing = Double(content.backingScale)
    let level = TileLevel(native: viewport.native, scale: viewport.scale, backing: backing)

    if tileLevel?.longerSide != level.longerSide { tileDenied = [] }

    tileLevel = level
    tiles.capacity = TileMath.capacity(pane: viewport.pane, backing: backing)

    let wanted = TileMath.wanted(visible: viewport.visibleRect, in: level)

    for entry in tiles.retain(Set(wanted)) {
      bitmapBudget.giveBack(entry.bytes, lease: lease)
    }

    showTiles(level)
    requestNextTile(from: wanted, in: level)
  }

  private func showTiles(_ level: TileLevel) {
    let sprites = tiles.entries.map { key, entry in
      let rect = level.rect(of: key)

      return TileSprite(
        key: key, image: entry.value.image, rect: rect, ratio: level.ratio, hdr: entry.value.hdr)
    }

    content.setTiles(sprites)
  }

  private func requestNextTile(from wanted: [TileKey], in level: TileLevel) {
    let queued = client.tileRegionsOutstanding
    let running = client.tileInFlightRegion

    for key in wanted where !tiles.contains(key) && !tileDenied.contains(key) {
      let rect = level.rect(of: key)

      guard rect.width > 0, rect.height > 0 else { continue }

      let region = TileRegion(
        level: level.longerSide, x: rect.x, y: rect.y, width: rect.width, height: rect.height)

      if region == running { continue }

      if queued.contains(region) { return }

      client.decodeRegion(region)

      return
    }
  }

  func tileArrived(_ request: DecodeRequest, _ header: ImageHeader, _ pixels: Data) {
    guard let region = request.region, let viewport = content.viewport, !viewport.isFit,
      let level = tileLevel, region.level == level.longerSide, request.source == info?.source,
      !isDetached
    else {
      refreshTiles()
      return
    }

    let key = TileKey(
      level: region.level, column: region.x / TileMath.tileSize, row: region.y / TileMath.tileSize)

    let wanted = TileMath.wanted(visible: viewport.visibleRect, in: level)

    guard wanted.contains(key), !tiles.contains(key) else {
      refreshTiles()
      return
    }

    guard let image = BitmapFactory.makeImage(header, pixels: pixels) else {
      tileDenied.insert(key)
      refreshTiles()
      return
    }

    guard reserve(pixels.count) else {
      tileDenied.insert(key)
      refreshTiles()
      return
    }

    let dropped = tiles.insert(
      TileImage(image: image, hdr: header.space.isHDR), bytes: pixels.count, for: key)

    for entry in dropped {
      bitmapBudget.giveBack(entry.bytes, lease: lease)
    }

    lastGood = viewport
    refreshTiles()
  }

  // MARK: Limits

  /// The helper declined a zoom, or could not make the tiles for it. The pane goes back to the last
  /// zoom that showed tiles, and falls back to fit when that fails too.
  func zoomRefused(_ detail: String) {
    notify(.warning, "The zoom limit was reached. \(detail)", delivery: .message)

    let good = lastGood

    lastGood = nil
    releaseTiles()

    if let good, !good.isFit, good.native == content.viewport?.native {
      content.restore(good)
    } else {
      content.zoom(.fit)
    }
  }

  /// The helper died while it made tiles. The pane keeps its backdrop at fit and opens the image
  /// again, since the helper's copy of it went with the process.
  func zoomEnded(_ reason: HelperEnd) {
    let name = "\u{201C}\(record.current ?? title)\u{201D}"
    let text: String

    switch reason {
    case .overranTimeBound:
      text = "The zoom limit was reached. \(name) took longer to decode than uniterm allows."

    case .overFootprint:
      text =
        "The zoom limit was reached. \(name) needs more memory than uniterm lets an image decoder use."

    case .unresponsive:
      text = "The image decoder stopped responding while zooming \(name)."

    case .misbehaved:
      text = "The image decoder sent something uniterm refused while zooming \(name)."

    default:
      text = "The image decoder stopped while zooming \(name). A damaged file can cause this."
    }

    notify(.warning, text, delivery: .message)

    lastGood = nil
    releaseTiles()
    content.zoom(.fit)

    if let current = listing.current { beginLoad(of: current, bypassCache: true) }
  }

  // MARK: Detach

  /// A pane off screen keeps only its backdrop. Both the app and the helper let go of the tiles and
  /// the decode behind them.
  func releaseZoomForDetach() {
    guard isZoomedPastFit else { return }

    releaseTiles()
    client.releaseLevel()
    releaseZoomedFrames()
  }

  /// Puts an animation back on its fit-size backdrop and lets go of the frames made for the zoom.
  /// The viewport stays zoomed, so the backdrop shows scaled, as a still does without its tiles.
  private func releaseZoomedFrames() {
    guard plan.isAnimated, zoomLevel != nil, let held = shot else { return }

    dropFrames()
    zoomLevel = nil
    currentFrame = 0
    frames[0] = Frame(image: held.image, bytes: 0)
    content.swap(image: held.image)
  }

  func restoreZoomAfterReattach() {
    guard isZoomedPastFit else { return }

    refreshTiles()
    retargetFrames()
  }
}
