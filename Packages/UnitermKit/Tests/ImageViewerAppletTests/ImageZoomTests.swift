import AppKit
import AppletKit
import AppletTestSupport
import HelperHost
import ImageIO
import ImageTestSupport
import ImageViewerModel
import ImageWire
import SourceAccess
import XCTest

@testable import ImageViewerApplet

/// Drives free zoom against a real helper process: the commands, the tiles, the budgets, and the
/// limits. The images are generated in code. The large one is 6000 by 4000, so a 1:1 decode of it
/// is 96 MiB and a pane of 300 points can hold only a few tiles of it.
@MainActor
final class ImageZoomTests: XCTestCase {
  private var folder: URL!
  private var panes: PaneFactory!

  private static let large = (width: 6000, height: 4000)

  override func setUp() async throws {
    folder = try ImageFixtures.makeFolder()
    panes = PaneFactory(folder: folder)
  }

  override func tearDown() async throws {
    panes.closeAll()

    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  @discardableResult
  private func writeLarge(
    _ name: String = "big.png", properties: [CFString: Any] = [:]
  ) throws -> URL {
    let picture = ImageFixtures.solidQuadrants(
      width: Self.large.width, height: Self.large.height)

    return try ImageFixtures.write(
      ImageFixtures.encode(picture, as: .png, properties: properties), named: name, in: folder)
  }

  /// A pane at a backing scale of 2 that shows `file` at fit.
  private func open(
    _ file: URL, settings: HelperSettings? = nil,
    helperBudget: ImageHelperBudget = ImageHelperBudget(limit: 8 << 30, floor: 1 << 30),
    bitmapBudget: ImageBitmapBudget = ImageBitmapBudget(limit: 1 << 30, floor: 256 << 20)
  ) async throws -> (ImageViewerApplet, RecordingHost) {
    let (applet, host) = panes.make(
      settings: settings, helperBudget: helperBudget, bitmapBudget: bitmapBudget)

    applet.content.backingScaleSource = { 2 }
    try applet.replaceSource(with: file, startDirectory: folder.path)

    let shown = await Harness.eventually { applet.phase == .showing && applet.client.source != nil }
    XCTAssertTrue(shown, "\(applet.phase)")

    return (applet, host)
  }

  private func warnings(_ host: RecordingHost) -> [String] {
    host.sent.filter { $0.level == .warning }.map(\.text)
  }

  /// True when every tile the viewport wants is held.
  private func tilesSettled(_ applet: ImageViewerApplet) -> Bool {
    guard let viewport = applet.content.viewport, let level = applet.tileLevel else { return false }

    let wanted = TileMath.wanted(visible: viewport.visibleRect, in: level)

    return !wanted.isEmpty && wanted.allSatisfy { applet.tiles.contains($0) }
  }

  private func zoomSegment(_ applet: ImageViewerApplet) -> String? {
    applet.segments.first { $0.symbolName == "magnifyingglass" }?.text
  }

  /// A pane at a backing scale of 2 that plays an animated GIF of `size` pixels, one frame per
  /// color, with delays short enough to watch it advance.
  private func openAnimation(
    size: Int, settings: HelperSettings? = nil,
    helperBudget: ImageHelperBudget = ImageHelperBudget(limit: 8 << 30, floor: 1 << 30),
    bitmapBudget: ImageBitmapBudget = ImageBitmapBudget(limit: 1 << 30, floor: 256 << 20)
  ) async throws -> (ImageViewerApplet, RecordingHost) {
    let gif = try ImageFixtures.write(
      ImageFixtures.animatedGIF(
        colors: [ImageFixtures.red, ImageFixtures.green, ImageFixtures.blue, ImageFixtures.white],
        delays: [0.06, 0.06, 0.06, 0.06], size: size),
      named: "loop.gif", in: folder)

    let (applet, host) = try await open(
      gif, settings: settings, helperBudget: helperBudget, bitmapBudget: bitmapBudget)

    let playing = await Harness.eventually { applet.isAnimating && applet.frames.count >= 2 }
    XCTAssertTrue(playing)

    return (applet, host)
  }

  /// True when the window of frames is held at the zoom's level and the animation plays.
  private func framesAreSharp(_ applet: ImageViewerApplet) -> Bool {
    guard let level = applet.zoomLevel, applet.isAnimating else { return false }

    let sharp = applet.frames.values.filter { $0.zoomLevel == level && $0.image.width == level }

    return sharp.count >= ImageViewerApplet.framesAhead + 1
  }

  private func frameSummary(_ applet: ImageViewerApplet) -> [String] {
    applet.frames.sorted { $0.key < $1.key }.map {
      "\($0.key):\($0.value.bytes):\($0.value.zoomLevel ?? 0)"
    }
  }

  private func request(_ applet: ImageViewerApplet, id: UInt32, frame: Int, side: Int)
    -> DecodeRequest
  {
    DecodeRequest(
      id: id, source: applet.info?.source ?? 0, maxPixel: side, frame: frame, kind: .frame)
  }

  /// Hands the applet an event as its client would.
  private func deliver(_ event: HelperEvent, to applet: ImageViewerApplet) {
    applet.client.onEvent?(event)
  }

  private func tinyImage(
    _ applet: ImageViewerApplet, frame: Int, space: OutputSpace, format: PixelFormat
  ) -> (ImageHeader, Data) {
    let header = ImageHeader(
      request: 1, source: applet.info?.source ?? 0, frame: UInt32(frame), width: 4, height: 4,
      space: space, format: format)

    return (header, Data(count: 16 * format.bytesPerPixel))
  }

  /// True once the animation has moved off its first frame, which only a tick does.
  private func framesAdvance(_ applet: ImageViewerApplet) -> Bool {
    applet.isAnimating && applet.currentFrame != 0
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)

    bytes.withUnsafeMutableBytes { raw in
      let context = CGContext(
        data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

      context.draw(
        image,
        in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    }

    return bytes
  }

  // MARK: Commands

  /// Catches a zoom that waits on the helper. The command changes the view and the status segment
  /// in the same turn, with the backdrop scaled to the new size and no tile yet. Tiles follow.
  func testZoomInChangesTheViewAtOnceAndTilesFollow() async throws {
    let (applet, _) = try await open(try writeLarge())

    XCTAssertTrue(applet.content.viewport?.isFit == true)
    XCTAssertNil(zoomSegment(applet))

    applet.zoomIn()

    XCTAssertFalse(applet.content.viewport?.isFit ?? true)
    XCTAssertEqual(zoomSegment(applet), "10%")
    XCTAssertEqual(applet.content.tileCount, 0, "no tile has arrived, and the view did not wait")
    XCTAssertEqual(
      applet.content.imageFrame?.size, CGSize(width: 600, height: 400), "the backdrop scaled")
    XCTAssertTrue(applet.isZoomedPastFit)

    let settled = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(settled)
    XCTAssertEqual(applet.tileLevel?.longerSide, 1500, "a quarter of native covers the screen")
    XCTAssertEqual(applet.content.tileCount, applet.tiles.count)
  }

  /// Catches actual size, zoom out, and zoom to fit disagreeing with the viewport. Actual Size
  /// shows 100 percent and decodes at native, Zoom Out halves, and Zoom to Fit drops the segment,
  /// the tiles, and the prefetch gate.
  func testActualSizeZoomOutAndZoomToFitMoveBetweenStates() async throws {
    let (applet, _) = try await open(try writeLarge())

    applet.zoomToActualSize()
    XCTAssertEqual(zoomSegment(applet), "100%")

    let native = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(native)
    XCTAssertEqual(applet.tileLevel?.longerSide, 6000)

    applet.zoomOut()
    XCTAssertEqual(zoomSegment(applet), "50%")

    applet.zoomToFit()

    XCTAssertTrue(applet.content.viewport?.isFit == true)
    XCTAssertNil(zoomSegment(applet))
    XCTAssertEqual(applet.tiles.count, 0)
    XCTAssertEqual(applet.content.tileCount, 0)
    XCTAssertFalse(applet.isZoomedPastFit)

    applet.zoomOut()
    XCTAssertTrue(applet.content.viewport?.isFit == true, "zoom out stops at fit")
  }

  /// Catches the zoom commands staying on while they cannot act. An empty pane has nothing to
  /// zoom, and an animation does zoom, so the registry turns the commands on for it.
  func testZoomCommandsAreOffWithoutAnImageAndOnForAnAnimation() async throws {
    let (empty, _) = panes.make()
    XCTAssertFalse(empty.canZoom)

    let (animated, _) = try await openAnimation(size: 1200)

    XCTAssertTrue(animated.plan.isAnimated)
    XCTAssertTrue(animated.canZoom)

    animated.zoomIn()

    XCTAssertFalse(animated.content.viewport?.isFit ?? true)
    XCTAssertEqual(zoomSegment(animated), "50%")
  }

  /// Catches a gesture that the menu commands do not share. A pinch zooms an animation as it does a
  /// still. The pinch scales what the view holds and asks for the new size only when the fingers
  /// lift, and zoom to fit brings the fit-size frames back.
  func testAPinchZoomsAnAnimationAndZoomToFitBringsTheFitFramesBack() async throws {
    let (animated, _) = try await openAnimation(size: 1200)
    let center = CGPoint(x: 150, y: 150)

    animated.content.pinch(.began, magnification: 0, at: center)
    animated.content.pinch(.changed, magnification: 1.5, at: center)

    XCTAssertTrue(animated.content.isPinching)
    XCTAssertFalse(animated.content.viewport?.isFit ?? true, "the view scaled what it holds")
    XCTAssertNil(animated.zoomLevel, "no new size is asked for while the fingers are down")

    animated.content.pinch(.ended, magnification: 0, at: center)

    XCTAssertNotNil(animated.zoomLevel)
    XCTAssertTrue(animated.isZoomedPastFit)

    let sharp = await Harness.eventually { self.framesAreSharp(animated) }
    XCTAssertTrue(sharp)

    XCTAssertTrue(animated.content.zoom(.fit), "zoom to fit toggles back")
    XCTAssertNil(animated.zoomLevel)
    XCTAssertFalse(animated.isZoomedPastFit)

    let fit = await Harness.eventually {
      animated.frames.values.allSatisfy { $0.zoomLevel == nil && $0.image.width <= 600 }
        && animated.frames.count >= 2
    }
    XCTAssertTrue(fit, "fit-size frames return")
    XCTAssertNil(zoomSegment(animated))
  }

  /// Catches a zoomed animation that freezes or plays blurry. At actual size a 1200 pixel GIF
  /// keeps advancing, and every frame it shows has the 1200 pixel size the zoom needs, where a fit
  /// frame is 600. The animation never goes through tiles.
  func testAZoomedAnimationKeepsAdvancingWithFramesAtTheZoomedSize() async throws {
    let (animated, _) = try await openAnimation(size: 1200)
    let fitWidth = try XCTUnwrap(animated.frames[animated.currentFrame]).image.width

    XCTAssertEqual(fitWidth, 600)

    animated.zoomToActualSize()

    XCTAssertEqual(animated.content.tileCount, 0)

    var shown: [Int] = []
    let advanced = await Harness.eventually {
      guard let frame = animated.frames[animated.currentFrame], frame.zoomLevel == 1200 else {
        return false
      }

      XCTAssertEqual(frame.image.width, 1200)
      XCTAssertEqual(frame.image.height, 1200)
      XCTAssertEqual(frame.bytes, 1200 * 1200 * 4, "eight-bit pixels, charged to the budget")

      if shown.last != animated.currentFrame { shown.append(animated.currentFrame) }

      return shown.count >= 4
    }
    XCTAssertTrue(advanced, "frames shown at the zoomed size: \(shown)")
    XCTAssertNotEqual(Set(shown).count, 1)
    XCTAssertEqual(animated.zoomLevel, 1200)
    XCTAssertEqual(animated.content.tileCount, 0)
    XCTAssertTrue(animated.tiles.entries.isEmpty)

    let held = animated.frames.values.reduce(0) { $0 + $1.bytes }
    let backdrop = try XCTUnwrap(animated.shot).bytes

    XCTAssertEqual(animated.bitmapBudget.held(by: animated.lease), backdrop + held)
    XCTAssertLessThanOrEqual(
      animated.frames.count, ImageViewerApplet.framesAhead + 1,
      "only the window of frames is kept")
  }

  /// Catches a zoom that a cap cannot hold being applied anyway. A zoomed frame larger than the
  /// helper's per-image cap is refused with the zoom warning, the pane goes back to fit and keeps
  /// playing there, and the neighbor's helper keeps its process.
  func testZoomingAnAnimationPastTheHelperCapIsRefusedAndKillsNoOtherHelper() async throws {
    let shared = ImageHelperBudget(limit: 8 << 30, floor: 1 << 30)
    let neighbor = try ImageFixtures.write(ImageFixtures.png(), named: "n.png", in: folder)
    let (calm, calmHost) = try await open(neighbor, helperBudget: shared)
    let process = calm.client.processID

    let (animated, host) = try await openAnimation(
      size: 1200, settings: Harness.settings(maxImageBytes: 8 << 20), helperBudget: shared)

    animated.zoomToActualSize()

    let warned = await Harness.eventually {
      self.warnings(host).contains { $0.contains("zoom limit was reached") }
    }
    XCTAssertTrue(warned, "\(warnings(host))")
    XCTAssertTrue(animated.content.viewport?.isFit == true, "back to fit, as a still goes")
    XCTAssertNil(animated.zoomLevel)
    XCTAssertEqual(animated.phase, .showing)

    let playing = await Harness.eventually { self.framesAdvance(animated) }
    XCTAssertTrue(playing, "the animation goes on at fit")

    XCTAssertTrue(calm.client.isRunning)
    XCTAssertEqual(calm.client.processID, process)
    XCTAssertTrue(warnings(calmHost).isEmpty)
  }

  /// Catches a zoom that the bitmap budget cannot hold. Fit frames fit in the budget and a window
  /// of 1200 pixel frames does not, so the zoom is refused with the warning and the pane goes back
  /// to fit with the budget back at the fit frames.
  func testZoomingAnAnimationPastTheBitmapBudgetIsRefusedAndRevertsToFit() async throws {
    let shared = ImageHelperBudget(limit: 8 << 30, floor: 1 << 30)
    let neighbor = try ImageFixtures.write(ImageFixtures.png(), named: "n.png", in: folder)
    let (calm, calmHost) = try await open(neighbor, helperBudget: shared)
    let process = calm.client.processID

    let (animated, host) = try await openAnimation(
      size: 1200, helperBudget: shared,
      bitmapBudget: ImageBitmapBudget(limit: 8 << 20, floor: 8 << 20))

    animated.zoomToActualSize()

    let warned = await Harness.eventually {
      self.warnings(host).contains { $0.contains("zoom limit was reached") }
    }
    XCTAssertTrue(warned, "\(warnings(host))")
    XCTAssertTrue(animated.content.viewport?.isFit == true)
    XCTAssertNil(animated.zoomLevel)
    XCTAssertFalse(animated.isZoomedPastFit)

    let back = await Harness.eventually {
      self.framesAdvance(animated) && animated.frames.values.allSatisfy { $0.zoomLevel == nil }
    }
    XCTAssertTrue(
      back,
      "the animation plays at fit again: \(animated.isAnimating) \(animated.currentFrame) \(frameSummary(animated)) \(animated.client.outstandingFrames) \(animated.phase)"
    )

    let backdrop = try XCTUnwrap(animated.shot).bytes
    let fitFrames = animated.frames.values.reduce(0) { $0 + $1.bytes }

    XCTAssertEqual(
      animated.bitmapBudget.held(by: animated.lease), backdrop + fitFrames,
      "the zoomed frames' bytes went back to the budget")

    XCTAssertTrue(calm.client.isRunning)
    XCTAssertEqual(calm.client.processID, process)
    XCTAssertTrue(warnings(calmHost).isEmpty)
  }

  /// Catches a detached animation that keeps its zoomed frames. Detach pauses and gives back every
  /// frame made for the zoom, leaving the backdrop, and reattach asks for the zoomed frames again.
  func testDetachReleasesTheZoomedFramesAndReattachRestoresThem() async throws {
    let (animated, _) = try await openAnimation(size: 1200)
    let backdrop = try XCTUnwrap(animated.shot).bytes

    animated.zoomToActualSize()

    let sharp = await Harness.eventually { self.framesAreSharp(animated) }
    XCTAssertTrue(sharp)
    XCTAssertGreaterThan(animated.bitmapBudget.held(by: animated.lease), backdrop)

    animated.detach()

    XCTAssertFalse(animated.isAnimating)
    XCTAssertNil(animated.zoomLevel)
    XCTAssertTrue(animated.frames.values.allSatisfy { $0.zoomLevel == nil && $0.bytes == 0 })
    XCTAssertEqual(animated.bitmapBudget.held(by: animated.lease), backdrop)
    XCTAssertTrue(animated.content.viewport?.isFit == false, "the zoom itself stays")

    let drained = await Harness.eventually { animated.client.outstandingFrames.isEmpty }
    XCTAssertTrue(drained)

    let held = frameSummary(animated)

    for _ in 0..<5 { await Task.yield() }

    XCTAssertEqual(frameSummary(animated), held, "a detached pane asks for no frames")
    XCTAssertEqual(animated.bitmapBudget.held(by: animated.lease), backdrop, "nothing refills")

    animated.reattach()

    let back = await Harness.eventually {
      self.framesAreSharp(animated) && self.framesAdvance(animated)
    }
    XCTAssertTrue(back)
  }

  // MARK: Late results and leaving a zoom

  /// Catches a late failure of a zoomed frame stopping the animation. The zoom has not yet shown a
  /// whole window of frames, so a failure sends the pane back to fit. The second and third results
  /// then belong to a level it has left. They are dropped, the warning is posted once, and the
  /// animation goes on at fit.
  func testLateResultsForZoomedFramesAfterTheRevertLeaveTheAnimationPlayingAtFit() async throws {
    let (animated, host) = try await openAnimation(size: 1200)

    animated.zoomToActualSize()

    let level = try XCTUnwrap(animated.zoomLevel)

    deliver(
      .failed(request(animated, id: 9001, frame: 1, side: level), .limit, "too big"), to: animated)
    XCTAssertNil(animated.zoomLevel)
    XCTAssertTrue(animated.content.viewport?.isFit == true)

    deliver(.refused(request(animated, id: 9002, frame: 2, side: level), "too big"), to: animated)
    deliver(
      .failed(request(animated, id: 9003, frame: 3, side: level), .unreadable, "bad"), to: animated)

    let playing = await Harness.eventually {
      self.framesAdvance(animated) && animated.frames.values.allSatisfy { $0.zoomLevel == nil }
    }
    XCTAssertTrue(playing, "the animation goes on at fit")
    XCTAssertEqual(warnings(host).filter { $0.contains("zoom limit was reached") }.count, 1)
    XCTAssertEqual(animated.phase, .showing)
  }

  /// Catches a helper lost on a zoomed frame showing an error pane once the zoom has changed. The
  /// pane recovers by the zoom path, as it does for a tile: it warns, stays on fit, and opens the
  /// image again.
  func testAHelperLostOnAZoomedFrameRecoversByTheZoomPathAfterTheLevelMoved() async throws {
    for reason in [HelperEnd.crashed("stopped"), .overranTimeBound] {
      let (animated, host) = try await openAnimation(size: 1200)

      animated.zoomToActualSize()

      let level = try XCTUnwrap(animated.zoomLevel)

      deliver(
        .failed(request(animated, id: 9001, frame: 1, side: level), .limit, "too big"), to: animated
      )
      XCTAssertNil(animated.zoomLevel)

      deliver(
        .ended(reason, lost: request(animated, id: 9002, frame: 2, side: level)), to: animated)

      XCTAssertEqual(animated.phase, .showing, "\(reason): no error pane")
      XCTAssertTrue(
        warnings(host).contains { $0.contains("while zooming") || $0.contains("zoom limit") })

      let again = await Harness.eventually {
        animated.phase == .showing && animated.loadingName == nil && self.framesAdvance(animated)
      }
      XCTAssertTrue(again, "\(reason): the image opens again and plays")

      animated.close()
    }
  }

  /// Catches the old animation going on asking for frames while a step loads the next image. The
  /// step stops it at once and holds the frames until the next image is chosen, and the load runs
  /// once.
  func testSteppingAwayFromAZoomedAnimationStopsItAndLoadsOnce() async throws {
    try ImageFixtures.write(ImageFixtures.png(), named: "z.png", in: folder)

    let (animated, host) = try await openAnimation(size: 1200)

    let listed = await Harness.eventually {
      animated.listing.isComplete && animated.listing.count == 2
    }
    XCTAssertTrue(listed)

    animated.zoomToActualSize()

    let sharp = await Harness.eventually { self.framesAreSharp(animated) }
    XCTAssertTrue(sharp)

    let loads = animated.navGeneration

    animated.step(.next)

    XCTAssertFalse(animated.isAnimating, "the old animation asks for nothing during the step")
    XCTAssertTrue(animated.framesFrozen)

    let stepped = await Harness.eventually {
      animated.phase == .showing && animated.committedName == "z.png"
    }
    XCTAssertTrue(stepped)
    XCTAssertEqual(animated.navGeneration, loads + 1, "one load and no reload")
    XCTAssertFalse(animated.framesFrozen)
    XCTAssertTrue(animated.content.viewport?.isFit == true)
    XCTAssertTrue(warnings(host).isEmpty, "\(warnings(host))")
  }

  /// Catches a sharper backdrop replacing the zoomed frame on screen. A larger pane asks for a
  /// sharper fit still of the animation. The zoomed frames stay valid when it arrives, so the
  /// display does not flip to the scaled fit image.
  func testASharperBackdropDoesNotReplaceTheZoomedFrames() async throws {
    let (animated, _) = try await openAnimation(size: 1200)

    animated.zoomToActualSize()

    let sharp = await Harness.eventually { self.framesAreSharp(animated) }
    XCTAssertTrue(sharp)

    final class Tally { var stills = 0, flips = 0 }
    let tally = Tally()
    let original = animated.client.onEvent

    animated.client.onEvent = { [weak animated] event in
      original?(event)

      guard let animated, case .image(let request, _, _) = event, request.kind == .still else {
        return
      }

      tally.stills += 1

      if animated.frames[animated.currentFrame]?.zoomLevel != animated.zoomLevel {
        tally.flips += 1
      }
    }

    let level = animated.zoomLevel

    animated.content.frame = NSRect(x: 0, y: 0, width: 450, height: 450)
    animated.content.layoutSubtreeIfNeeded()

    let arrived = await Harness.eventually { tally.stills >= 1 }
    XCTAssertTrue(arrived, "the larger pane asks for a sharper still")
    XCTAssertEqual(tally.flips, 0, "the zoomed frame stayed the frame on screen")
    XCTAssertEqual(animated.zoomLevel, level)
    XCTAssertEqual(animated.shownPixels?.longer, 900)
  }

  /// Catches stale frames holding the request slots. Two requests for a size the pane left are out.
  /// The next window request goes out anyway, in place of the waiting one.
  func testRequestsForAnOldSizeDoNotBlockTheNextWindow() async throws {
    let (animated, _) = try await openAnimation(size: 1200)

    animated.stopAnimating()

    let drained = await Harness.eventually { animated.client.outstandingFrames.isEmpty }
    XCTAssertTrue(drained)

    animated.client.decode(maxPixel: 1200, frame: 1, kind: .frame)
    animated.client.decode(maxPixel: 1200, frame: 2, kind: .frame)
    XCTAssertEqual(animated.client.outstandingFrames.count, 2)

    animated.dropFrames()
    animated.fillWindow()

    let side = animated.fitLongerSide(of: try XCTUnwrap(animated.info))

    XCTAssertTrue(animated.client.outstandingFrames.contains { $0.maxPixel == side })
  }

  /// Catches a frame for a level the pane left being shown or kept. A frame made for half the
  /// current level arrives after a retarget. It is not stored and the budget does not change.
  func testAFrameForAnOldLevelArrivingLateIsNeitherShownNorKept() async throws {
    let (animated, _) = try await openAnimation(size: 1200)

    animated.zoomToActualSize()

    let sharp = await Harness.eventually { self.framesAreSharp(animated) }
    XCTAssertTrue(sharp)

    let level = try XCTUnwrap(animated.zoomLevel)
    let index = animated.plan.next(after: animated.currentFrame)
    let held = animated.bitmapBudget.held(by: animated.lease)
    let before = frameSummary(animated)

    let (header, pixels) = tinyImage(animated, frame: index, space: .sRGB, format: .rgba8)

    deliver(
      .image(request(animated, id: 9001, frame: index, side: level / 2), header, pixels),
      to: animated)

    XCTAssertEqual(animated.bitmapBudget.held(by: animated.lease), held)
    XCTAssertNotEqual(animated.frames[index]?.image.width, 4)
    XCTAssertEqual(frameSummary(animated).count, before.count)
  }

  /// Catches a half-float frame charged as eight-bit. A zoomed frame in an extended-linear space
  /// arrives as sixteen-bit floats, and the budget is charged for the bytes it holds. The size the
  /// app predicts for the level uses the same pixel width.
  func testAZoomedFrameInAnHDRSpaceIsChargedAtHalfFloatSize() async throws {
    let (animated, _) = try await openAnimation(size: 1200)

    animated.zoomToActualSize()

    let sharp = await Harness.eventually { self.framesAreSharp(animated) }
    XCTAssertTrue(sharp)

    let level = try XCTUnwrap(animated.zoomLevel)
    let index = animated.plan.next(after: animated.currentFrame)
    let old = animated.frames[index]?.bytes ?? 0
    let held = animated.bitmapBudget.held(by: animated.lease)

    let (header, pixels) = tinyImage(
      animated, frame: index, space: .extendedLinearDisplayP3, format: .rgbaF16)

    deliver(
      .image(request(animated, id: 9001, frame: index, side: level), header, pixels), to: animated)

    XCTAssertEqual(animated.frames[index]?.bytes, 4 * 4 * 8)
    XCTAssertEqual(animated.bitmapBudget.held(by: animated.lease), held - old + 4 * 4 * 8)

    let native = PixelSize(width: 1200, height: 1200)

    XCTAssertEqual(
      ImageHelperClient.levelBytes(
        longerSide: level, native: native, space: .extendedLinearDisplayP3),
      level * level * 8)
    XCTAssertEqual(
      ImageHelperClient.levelBytes(longerSide: level, native: native, space: .sRGB),
      level * level * 4)
  }

  /// Catches Actual Size ignoring the declared resolution. A 3000 by 2000 PNG at 144 dots per
  /// inch is 1500 by 1000 points, so it fits a 2000 point pane at its own size, and zooming to
  /// actual size in a smaller pane shows 100 percent of that size.
  func testAFileAt144DotsPerInchShowsAtHalfItsPixelSize() async throws {
    let picture = ImageFixtures.solidQuadrants(width: 3000, height: 2000)
    let data = ImageFixtures.encode(
      picture, as: .png,
      properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
    let file = try ImageFixtures.write(data, named: "retina.png", in: folder)

    let (applet, _) = try await open(file)

    XCTAssertEqual(applet.info?.dpiX, 144)
    XCTAssertEqual(applet.content.viewport?.actualScale, 0.5)

    applet.content.frame = NSRect(x: 0, y: 0, width: 2000, height: 1200)
    applet.content.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      applet.content.imageFrame?.size, CGSize(width: 1500, height: 1000),
      "fit is actual size here, and actual size is half the pixels")
    XCTAssertTrue(applet.content.viewport?.isFit == true)
  }

  // MARK: Pan and keys

  /// Catches arrows that step a zoomed image away. Zoomed past fit, an arrow pans and the
  /// selection stays, while Space still steps. At fit an arrow steps again.
  func testArrowsPanAZoomedImageAndSpaceStillSteps() async throws {
    try ImageFixtures.write(
      ImageFixtures.encode(
        ImageFixtures.solidQuadrants(width: 3000, height: 2000), as: .png), named: "a.png",
      in: folder)
    try ImageFixtures.write(ImageFixtures.png(), named: "b.png", in: folder)

    let (applet, _) = panes.make()
    applet.content.backingScaleSource = { 2 }
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let first = await Harness.eventually {
      applet.phase == .showing && applet.committedName == "a.png" && applet.listing.isComplete
    }
    XCTAssertTrue(first)

    applet.zoomToActualSize()

    let before = try XCTUnwrap(applet.content.viewport)

    XCTAssertTrue(applet.handle(key: .right))
    XCTAssertEqual(applet.listing.index, 0, "the arrow panned and did not step")

    let after = try XCTUnwrap(applet.content.viewport)
    XCTAssertGreaterThan(after.centerX, before.centerX)

    XCTAssertTrue(applet.handle(key: .down))
    XCTAssertGreaterThan(try XCTUnwrap(applet.content.viewport).centerY, before.centerY)

    XCTAssertTrue(applet.handle(key: .space))

    let stepped = await Harness.eventually {
      applet.phase == .showing && applet.committedName == "b.png"
    }
    XCTAssertTrue(stepped, "Space still steps")
    XCTAssertTrue(applet.content.viewport?.isFit == true, "a step returns to fit")
    XCTAssertEqual(applet.tiles.count, 0)
    XCTAssertFalse(applet.isZoomedPastFit)

    XCTAssertTrue(applet.handle(key: .left))
    let back = await Harness.eventually { applet.committedName == "a.png" }
    XCTAssertTrue(back, "at fit an arrow steps")
  }

  /// Catches blank edges and unbounded memory while panning. Panning across a 6000 by 4000 image
  /// at actual size keeps the backdrop over the whole pane, never holds more tiles than the pane
  /// needs, and never charges the budget more than the backdrop and those tiles. The whole image
  /// at 1:1 is 96 MiB, and the pane holds a fraction of it.
  func testPanningAtActualSizeKeepsTheBackdropAndBoundsTheTilesAndTheBudget() async throws {
    let (applet, _) = try await open(try writeLarge())
    let backdrop = try XCTUnwrap(applet.shot).bytes

    applet.zoomToActualSize()

    let first = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(first)

    let pane = try XCTUnwrap(applet.content.viewport).pane
    let capacity = TileMath.capacity(pane: pane, backing: 2)
    let tileBytes = TileMath.tileSize * TileMath.tileSize * 4
    let bound = backdrop + capacity * tileBytes

    var peak = 0
    var peakTiles = 0

    for step in 0..<130 {
      XCTAssertTrue(applet.panImage(by: step < 70 ? .right : .down))

      let frame = try XCTUnwrap(applet.content.imageFrame)
      XCTAssertLessThanOrEqual(frame.minX, 0.001)
      XCTAssertLessThanOrEqual(frame.minY, 0.001)
      XCTAssertGreaterThanOrEqual(frame.maxX, 300 - 0.001, "blank edge on the right")
      XCTAssertGreaterThanOrEqual(frame.maxY, 300 - 0.001, "blank edge at the bottom")

      peak = max(peak, applet.bitmapBudget.held(by: applet.lease))
      peakTiles = max(peakTiles, applet.tiles.count)
      XCTAssertLessThanOrEqual(applet.tiles.count, capacity)

      if step % 10 == 0 { await Task.yield() }
    }

    let settled = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(settled)

    peak = max(peak, applet.bitmapBudget.held(by: applet.lease))

    XCTAssertLessThanOrEqual(peak, bound, "the budget holds the backdrop and a pane of tiles")
    XCTAssertLessThan(peak, 40 << 20, "far below the 96 MiB of the image at 1:1")
    XCTAssertGreaterThan(peakTiles, 1)
    XCTAssertEqual(applet.content.tileCount, applet.tiles.count)
  }

  /// Catches a tile drawn from the wrong part of the image. At the far top left of the image, the
  /// first tile starts with the red quadrant. At the far bottom right it ends in white.
  func testTilesCarryTheRegionOfTheImageTheyWereAskedFor() async throws {
    let (applet, _) = try await open(try writeLarge())

    applet.zoomToActualSize()
    applet.content.pan(byPoints: CGSize(width: 1e7, height: 1e7))

    let topLeft = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(topLeft)

    let origin = TileKey(level: 6000, column: 0, row: 0)
    let first = try XCTUnwrap(applet.tiles.entries[origin]).value.image
    XCTAssertEqual(pixel(first, x: 5, y: 5), [255, 0, 0, 255])

    applet.content.pan(byPoints: CGSize(width: -1e7, height: -1e7))

    let bottomRight = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(bottomRight)

    let last = TileKey(level: 6000, column: 11, row: 7)
    let tile = try XCTUnwrap(applet.tiles.entries[last]).value.image
    XCTAssertEqual(pixel(tile, x: tile.width - 1, y: tile.height - 1), [255, 255, 255, 255])
  }

  // MARK: Limits

  /// Catches a zoom past the app-wide helper budget that kills a neighbor or says nothing. The
  /// first pane's helper keeps running and decoding, and the second pane warns that the limit was
  /// reached and goes back to fit.
  func testZoomPastTheHelperBudgetIsRefusedWithAWarningAndNoOtherHelperIsKilled() async throws {
    let shared = ImageHelperBudget(limit: 200 << 20, floor: 80 << 20)
    let neighbor = try ImageFixtures.write(ImageFixtures.png(), named: "n.png", in: folder)
    let (calm, calmHost) = try await open(neighbor, helperBudget: shared)
    let calmProcess = calm.client.processID

    let (applet, host) = try await open(try writeLarge(), helperBudget: shared)

    applet.zoomToActualSize()

    let warned = await Harness.eventually {
      self.warnings(host).contains { $0.contains("zoom limit was reached") }
    }
    XCTAssertTrue(warned, "\(warnings(host))")
    XCTAssertTrue(applet.content.viewport?.isFit == true)
    XCTAssertEqual(applet.tiles.count, 0)
    XCTAssertEqual(applet.phase, .showing, "the pane keeps its image")

    XCTAssertTrue(calm.client.isRunning)
    XCTAssertEqual(calm.client.processID, calmProcess)
    XCTAssertTrue(warnings(calmHost).isEmpty)
  }

  /// Catches a refused zoom that drops the user to fit. With a step that works and then a step the
  /// helper cannot hold, the pane warns and returns to the zoom that showed tiles.
  func testARefusedZoomGoesBackToTheLastZoomThatWorked() async throws {
    let settings = Harness.settings(maxImageBytes: 50 << 20)
    let (applet, host) = try await open(try writeLarge(), settings: settings)

    applet.zoomIn()

    let worked = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(worked)

    let good = try XCTUnwrap(applet.content.viewport?.scale)

    applet.zoomToActualSize()

    let warned = await Harness.eventually {
      self.warnings(host).contains { $0.contains("zoom limit was reached") }
    }
    XCTAssertTrue(warned)
    XCTAssertEqual(applet.content.viewport?.scale, good)

    let again = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(again, "the tiles of the zoom that worked come back")
  }

  #if DEBUG
    /// Catches a slow but legitimate decode crashing the pane or leaving it blank. The helper takes
    /// longer than the time bound to cut the 1:1 decode, which the app ends. The status bar says the
    /// zoom limit was reached, the image stays at fit, and the pane opens it again.
    func testASlowZoomDecodeReportsTheLimitAndTheImageStays() async throws {
      let file = try writeLarge(
        properties: [
          kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGDescription: "UNITERM-REGION-FAULT slow:5000"
          ]
        ])

      let settings = Harness.settings(timeBound: .milliseconds(1500))
      let (applet, host) = try await open(file, settings: settings)
      let pid = applet.client.processID

      applet.zoomToActualSize()

      let warned = await Harness.eventually {
        self.warnings(host).contains { $0.contains("zoom limit was reached") }
      }
      XCTAssertTrue(warned, "\(warnings(host))")
      XCTAssertTrue(applet.content.viewport?.isFit == true)
      XCTAssertEqual(applet.phase, .showing, "never an error pane, never a crash")

      let again = await Harness.eventually {
        applet.phase == .showing && applet.client.source != nil && applet.loadingName == nil
          && applet.client.processID != pid
      }
      XCTAssertTrue(again, "a fresh helper holds the image again")
      XCTAssertEqual(applet.tiles.count, 0)
    }
  #endif

  // MARK: Memory

  /// Catches a zoom refused for memory that other decodes hold. The budget has room for the
  /// backdrop and two more fit decodes, the previous image and the prefetched one, and not for a
  /// second tile beside them. Zoom lets the prefetch go and the tiles take the previous image's
  /// place, so the zoom shows detail and warns of nothing.
  func testZoomIsNeverRefusedForMemoryAPrefetchHolds() async throws {
    for name in ["a.png", "b.png", "c.png"] {
      try ImageFixtures.write(
        ImageFixtures.encode(
          ImageFixtures.solidQuadrants(width: 6000, height: 4000), as: .png), named: name,
        in: folder)
    }

    let (applet, host) = panes.make(
      bitmapBudget: ImageBitmapBudget(limit: 3_500_000, floor: 3_500_000))
    applet.content.backingScaleSource = { 2 }
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let opened = await Harness.eventually {
      applet.committedName == "a.png" && applet.listing.isComplete
    }
    XCTAssertTrue(opened)

    applet.step(.next)

    let held = await Harness.eventually {
      applet.committedName == "b.png" && applet.cache.previous?.name == "a.png"
        && applet.cache.prefetched?.name == "c.png"
    }
    XCTAssertTrue(held, "the previous and the prefetched image take their share of the budget")

    applet.zoomIn()

    let tiled = await Harness.eventually { applet.tiles.count >= 2 }
    XCTAssertTrue(tiled, "the tiles took the place of the images beside the one on screen")
    XCTAssertNil(applet.cache.prefetched)
    XCTAssertNil(applet.cache.previous)
    XCTAssertTrue(warnings(host).isEmpty, "\(warnings(host))")
  }

  /// Catches a helper that keeps an image it already sent. A prefetch of a 4000 by 4000 image is a
  /// 64 MiB decode, and once the reply is out the helper's footprint falls back toward its
  /// resting size.
  func testTheHelperReleasesAPrefetchedBitmapOnceItIsSent() async throws {
    let picture = ImageFixtures.solidQuadrants(width: 4000, height: 4000)
    let file = try ImageFixtures.write(
      ImageFixtures.encode(picture, as: .png), named: "square.png", in: folder)
    let spare = try ImageFixtures.write(ImageFixtures.png(), named: "spare.png", in: folder)

    let client = ImageHelperClient(
      settings: Harness.settings(), budget: ImageHelperBudget(limit: 8 << 30, floor: 1 << 30))
    defer { client.shutdown() }

    let log = EventLog(client)

    guard case .success(.file(let shown)) = SourceOpener.open(path: spare.path),
      case .success(.file(let next)) = SourceOpener.open(path: file.path)
    else { return XCTFail("the fixtures did not open") }

    client.open(shown)
    await expectEventually { log.opened != nil }

    let id = try XCTUnwrap(client.open(next, role: .prefetch))
    await expectEventually {
      log.events.contains { if case .prefetchOpened = $0 { return true } else { return false } }
    }

    let info = try XCTUnwrap(
      log.events.compactMap { event -> SourceInfo? in
        if case .prefetchOpened(let info) = event { return info } else { return nil }
      }.first)
    XCTAssertEqual(info.source, id)

    let resting = try XCTUnwrap(client.currentFootprint)

    XCTAssertNotNil(client.prefetch(info, maxPixel: 4000))
    await expectEventually { !log.images.isEmpty }

    let image = try XCTUnwrap(log.images.last)
    XCTAssertEqual([image.width, image.height], [4000, 4000])

    let released = await Harness.eventually {
      (client.currentFootprint ?? .max) < resting + (24 << 20)
    }
    XCTAssertTrue(
      released, "footprint \(client.currentFootprint ?? 0) against resting \(resting)")
  }

  // MARK: Detach and display scale

  /// Catches a detached pane that keeps its detail. Detach lets go of the tiles in the app and the
  /// decode in the helper, and keeps only the backdrop. Reattach asks for the tiles again.
  func testDetachReleasesTheTilesAndTheHelpersDecodeAndReattachRestoresThem() async throws {
    let (applet, _) = try await open(try writeLarge())
    let backdrop = try XCTUnwrap(applet.shot).bytes

    applet.zoomToActualSize()

    let tiled = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(tiled)

    let withLevel = try XCTUnwrap(applet.client.currentFootprint)
    XCTAssertGreaterThan(withLevel, 80 << 20, "the helper holds the 1:1 decode")

    applet.detach()

    XCTAssertEqual(applet.tiles.count, 0)
    XCTAssertEqual(applet.content.tileCount, 0)
    XCTAssertEqual(applet.bitmapBudget.held(by: applet.lease), backdrop)
    XCTAssertNotNil(applet.shot, "the backdrop stays")

    let released = await Harness.eventually {
      (applet.client.currentFootprint ?? .max) < withLevel / 2
    }
    XCTAssertTrue(released, "the helper let go of the decode")

    applet.reattach()

    let back = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(back)
  }

  /// Catches a display change that leaves the old pixel density. Moving the pane to a display with
  /// a different scale asks for a sharper backdrop at fit, and new tiles at a new level when
  /// zoomed.
  func testAChangeOfDisplayScaleRequestsNewPixels() async throws {
    let file = try writeLarge()
    let (applet, _) = panes.make()
    var scale: CGFloat = 1

    applet.content.backingScaleSource = { scale }
    try applet.replaceSource(with: file, startDirectory: folder.path)

    let shown = await Harness.eventually { applet.phase == .showing && applet.shot != nil }
    XCTAssertTrue(shown)
    XCTAssertEqual(applet.shownPixels?.longer, 300)

    scale = 2
    applet.content.viewDidChangeBackingProperties()

    let sharper = await Harness.eventually { applet.shownPixels?.longer == 600 }
    XCTAssertTrue(sharper, "\(String(describing: applet.shownPixels))")

    applet.zoomIn()
    let tiled = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(tiled)
    XCTAssertEqual(applet.tileLevel?.longerSide, 1500)

    scale = 1
    applet.content.viewDidChangeBackingProperties()

    let finer = await Harness.eventually {
      applet.tileLevel?.longerSide == 750 && self.tilesSettled(applet)
    }
    XCTAssertTrue(finer, "\(String(describing: applet.tileLevel))")
    XCTAssertTrue(applet.tiles.entries.keys.allSatisfy { $0.level == 750 })
  }
}
