import Darwin
import Foundation
import HelperHost
import ImageViewerModel
import ImageWire
import os

/// Why the pane opens a file: to show it, or to have it ready for the next step.
enum OpenRole: Equatable, Sendable {
  case display
  case prefetch
}

/// What the client tells the pane.
enum HelperEvent: Equatable, Sendable {
  case types([String])
  case opened(SourceInfo)

  /// The helper opened a file the pane asked for ahead of time. The pane decides what to decode.
  case prefetchOpened(SourceInfo)

  /// A prefetch decode that was waiting for the helper was replaced or dropped before it was sent.
  /// The ID is the request's.
  case prefetchDropped(UInt32)

  /// The helper could not open a file the pane asked for ahead of time.
  case prefetchOpenFailed(UInt32, String)

  /// A decoded image that matched its request. The pane builds the bitmap from the bytes.
  case image(DecodeRequest, ImageHeader, Data)

  /// The helper declined a request or an open and kept running.
  case failed(DecodeRequest?, FailureKind, String)

  /// The decode was not started because a memory limit would be passed.
  case refused(DecodeRequest, String)

  /// The helper is gone. The request in flight, if any, was lost with it.
  case ended(HelperEnd, lost: DecodeRequest?)
}

extension HelperLocation {
  /// The image decoder in the app bundle. A debug build honors `UNITERM_IMAGE_HELPER`.
  static var bundledImageDecoder: HelperLocation {
    bundled(named: "ImageDecoder", debugOverride: "UNITERM_IMAGE_HELPER")
  }
}

/// Tuning for one client. Tests shorten the times and the cap to reach each limit.
struct HelperSettings: Sendable {
  var location: HelperLocation
  var timeBound: Duration = ImageHelperPolicy.decodeTimeBound

  /// How often a request in flight is probed and its footprint read.
  var probeInterval: Duration = .milliseconds(250)

  /// How long a ping may go unanswered before the helper counts as stopped.
  var pongGrace: Duration = .seconds(3)

  var footprintCap = ImageHelperPolicy.perHelperCap
  var maxImageBytes = 512 << 20
}

/// One pane's connection to its image helper.
///
/// The helper starts when the pane first needs it. The client sends one open and one decode at a
/// time through `RequestScheduler`, validates every reply against the request, and watches the
/// request in flight. A crash, a stopped process, a decode past the time bound, and a footprint
/// past the cap each end only this pane's helper. The next request starts a fresh one.
@MainActor
final class ImageHelperClient {
  var onEvent: ((HelperEvent) -> Void)?

  private let settings: HelperSettings
  private let budget: ImageHelperBudget
  private let owner: Int

  private var process: HelperProcess?
  private var generation = 0
  private var scheduler = RequestScheduler()
  private var sourceID: UInt32 = 0

  /// The source the pane shows. Its info is in `infos` once the helper has opened it.
  private var displaySource: UInt32 = 0

  /// The sources the helper has opened and still keeps, with what it said about each. It mirrors
  /// the helper's own limit, so a source the helper dropped is gone here too. The mirror follows
  /// the helper's order of use: an open and a decode touch a source, and selecting one does not,
  /// since the helper never hears of a selection. An open that the helper has not answered yet
  /// already counts, because the helper orders requests as they arrive.
  private var infos: [UInt32: SourceInfo] = [:]
  private var recentSources: [UInt32] = []

  /// The output space each source last decoded in, which sizes the level a zoom would hold.
  var outputSpaces: [UInt32: OutputSpace] = [:]

  private var openingSources: [(id: UInt32, role: OpenRole)] = []
  private var liveness: HelperLiveness
  private var watchdog: Task<Void, Never>?
  private var requestCounter: UInt32 = 0
  private var expectation: ImageExpectation?

  private let readLimit: OSAllocatedUnfairLock<Int>

  private static let owners = OSAllocatedUnfairLock(initialState: 0)

  /// How many tasks still read a helper's events. Each helper has one, and it ends when the helper
  /// is gone.
  private(set) var activePumps = 0

  /// How many decode requests reached the helper. A step to an image the pane already holds adds
  /// none.
  private(set) var decodesSent = 0

  /// The footprint last read, which tests report as the helper's resting size.
  private(set) var lastFootprint: Int?

  /// Types the helper listed at hello, once it has.
  private(set) var types: [String]?

  init(settings: HelperSettings, budget: ImageHelperBudget) {
    self.settings = settings
    self.budget = budget
    self.liveness = HelperLiveness(
      timeBound: settings.timeBound, pongGrace: settings.pongGrace,
      footprintCap: settings.footprintCap)
    self.readLimit = OSAllocatedUnfairLock(initialState: 0)
    self.owner = Self.owners.withLock {
      $0 += 1
      return $0
    }
  }

  /// The helper's footprint now, for tests that check it lets go of what it sent.
  var currentFootprint: Int? { process?.footprint() }

  /// The most the helper's footprint has been, for tests that measure a decode.
  var peakFootprint: Int? { process?.peakFootprint() }

  /// The most bytes the reader accepts for an image body now.
  var imageReadLimit: Int { readLimit.withLock { $0 } }

  var isRunning: Bool { process != nil }
  var processID: pid_t? { process?.pid }
  var source: SourceInfo? { infos[displaySource] }

  /// True while a prefetch decode is the one in flight.
  var prefetchInFlight: Bool { scheduler.inFlight?.kind == .prefetch }

  /// Whether the pane shows more than a fit. A pane that does is never prefetched for.
  var isZoomedPastFit: Bool {
    get { scheduler.isZoomedPastFit }
    set {
      let waiting = scheduler.pending

      scheduler.isZoomedPastFit = newValue
      reportDropped(waiting)
    }
  }

  /// Offers `request` to the scheduler. A prefetch it was holding that the request replaced is
  /// reported, since nothing else would tell the pane it will never be decoded.
  private func submit(_ request: DecodeRequest) -> DecodeRequest? {
    let waiting = scheduler.pending
    let toSend = scheduler.submit(request)

    reportDropped(waiting)

    return toSend
  }

  private func reportDropped(_ waiting: DecodeRequest?) {
    guard let waiting, waiting.kind == .prefetch, scheduler.pending?.id != waiting.id,
      scheduler.inFlight?.id != waiting.id
    else { return }

    onEvent?(.prefetchDropped(waiting.id))
  }

  private var info: SourceInfo? { infos[displaySource] }

  /// Starts the helper if it is not running, and returns whether it is.
  @discardableResult
  func ensureRunning() -> Bool {
    if process != nil { return true }

    guard let url = settings.location.url else {
      end(.unavailable("The image decoder is missing from this copy of uniterm."), lost: nil)
      return false
    }

    do {
      let spawned = try HelperProcess.spawn(executable: url)
      generation += 1

      let current = generation
      let stream = AsyncStream<HelperRead<HelperMessage>>.makeStream()
      let limit = readLimit

      spawned.startReading(
        threadName: "uniterm.image-helper.reader",
        bodyLimit: { HelperMessage.bodyLimit(type: $0, maxImageBytes: limit.withLock { $0 }) },
        decode: HelperMessage.decode(type:body:),
        deliver: { event in
          stream.continuation.yield(event)

          if case .exited = event { stream.continuation.finish() }
        })

      process = spawned
      types = nil

      try spawned.socket.send(AppMessage.hello(version: ImageProtocol.version).frame())

      activePumps += 1

      Task { @MainActor [weak self] in
        for await event in stream.stream {
          self?.handle(event, generation: current)
        }

        self?.activePumps -= 1
      }

      return true
    } catch {
      end(.unavailable("The image decoder could not start (\(error))."), lost: nil)
      return false
    }
  }

  /// Opens `file` in the helper. A display open makes it the source the pane shows, and anything
  /// the pane shows from an earlier source is stale. A prefetch open leaves the shown source alone.
  /// Returns the source ID, or nil when the helper could not start or the descriptor could not go.
  @discardableResult
  func open(_ file: OpenedImageFile, role: OpenRole = .display) -> UInt32? {
    guard ensureRunning(), let process else { return nil }

    sourceID &+= 1

    let id = sourceID

    if role == .display { displaySource = id }

    openingSources.append((id, role))
    touch(id)

    if !liveness.isBusy { markBusy() }

    do {
      try withExtendedLifetime(file) {
        try process.socket.send(AppMessage.open(source: id).frame(), descriptor: file.descriptor)
      }
    } catch {
      end(.crashed("The image decoder stopped answering."), lost: nil)
      return nil
    }

    return id
  }

  /// Shows a source the helper opened earlier, as when the pane steps to an image it already holds.
  /// Returns false when the helper no longer keeps it.
  func select(source: UInt32) -> Bool {
    guard infos[source] != nil else { return false }

    displaySource = source

    return true
  }

  /// Asks for the fit decode of a source that is not the one on screen. Returns false when the
  /// scheduler drops the request, as it does for a pane zoomed past fit or one with a request
  /// already waiting.
  @discardableResult
  func prefetch(_ opened: SourceInfo, maxPixel: Int) -> UInt32? {
    guard infos[opened.source] != nil, process != nil else { return nil }

    requestCounter &+= 1

    let request = DecodeRequest(
      id: requestCounter, source: opened.source, maxPixel: maxPixel, frame: 0, kind: .prefetch)

    if let toSend = submit(request) {
      send(toSend)
    }

    let accepted = scheduler.inFlight?.id == request.id || scheduler.pending?.id == request.id

    return accepted ? request.id : nil
  }

  private func touch(_ source: UInt32) {
    recentSources.removeAll { $0 == source }
    recentSources.append(source)

    while recentSources.count > ImageProtocol.retainedSources, let oldest = recentSources.first {
      recentSources.removeFirst()
      infos[oldest] = nil
      outputSpaces[oldest] = nil
    }
  }

  /// Asks for `frame` of the current source with the longer side at most `maxPixel`. Returns the
  /// request, or nil when the source is not open.
  @discardableResult
  func decode(maxPixel: Int, frame: Int, kind: DecodeRequest.Kind) -> DecodeRequest? {
    guard let info, process != nil else { return nil }

    requestCounter &+= 1

    let request = DecodeRequest(
      id: requestCounter, source: info.source, maxPixel: maxPixel, frame: frame, kind: kind)

    if let toSend = submit(request) {
      send(toSend)
    }

    return request
  }

  /// Asks for a rectangle of the zoomed image. A tile already waiting is replaced, so only the newest
  /// viewport's request is ever sent after the one in flight. Returns nil when the source is not
  /// open.
  @discardableResult
  func decodeRegion(_ region: TileRegion) -> DecodeRequest? {
    guard let info, process != nil else { return nil }

    requestCounter &+= 1

    let request = DecodeRequest(
      id: requestCounter, source: info.source, maxPixel: region.level, frame: 0, kind: .tile,
      region: region)

    if let toSend = submit(request) {
      send(toSend)
    }

    return request
  }

  /// The tile in flight or waiting, if there is one. The pane does not ask twice for it.
  var tileRegionsOutstanding: [TileRegion] {
    [scheduler.inFlight, scheduler.pending].compactMap { $0?.kind == .tile ? $0?.region : nil }
  }

  /// The frame requests in flight or waiting, so the pane does not ask for one twice.
  var outstandingFrames: [DecodeRequest] {
    [scheduler.inFlight, scheduler.pending].compactMap { $0?.kind == .frame ? $0 : nil }
  }

  /// The frame request waiting for the helper, if one is.
  var pendingFrame: DecodeRequest? {
    scheduler.pending?.kind == .frame ? scheduler.pending : nil
  }

  var tileInFlightRegion: TileRegion? {
    scheduler.inFlight?.kind == .tile ? scheduler.inFlight?.region : nil
  }

  /// Tells the helper to drop the decode it keeps for tiles of the shown source. A tile waiting to
  /// be sent is dropped too.
  func releaseLevel() {
    if scheduler.pending?.kind == .tile { cancelPending() }

    guard let process, infos[displaySource] != nil else { return }

    try? process.socket.send(AppMessage.release(source: displaySource).frame())
  }

  /// Drops the waiting request without touching the one in flight.
  func cancelPending() {
    guard let inFlight = scheduler.inFlight else {
      scheduler.reset()
      return
    }

    scheduler.reset()
    _ = scheduler.submit(inFlight)
  }

  /// Ends the helper at once, as when the pane closes.
  func shutdown() {
    watchdog?.cancel()
    watchdog = nil
    liveness.markIdle()

    if let process {
      process.kill()
      self.process = nil
    }

    generation += 1
    scheduler.reset()
    infos = [:]
    outputSpaces = [:]
    recentSources = []
    readLimit.withLock { $0 = 0 }
    budget.release(owner: owner)
    onEvent = nil
  }

  // MARK: Sending

  private func predictedBytes(for request: DecodeRequest) -> Int {
    guard let info = infos[request.source] else { return 0 }

    let native = PixelSize(width: Int(info.width), height: Int(info.height))
    let longer = request.maxPixel > 0 ? min(request.maxPixel, native.longer) : native.longer
    let scale = Double(longer) / Double(max(native.longer, 1))
    let width = max(1, Int((Double(native.width) * scale).rounded(.up)))
    let height = max(1, Int((Double(native.height) * scale).rounded(.up)))

    return ImageLimits.byteCount(width: width, height: height, format: .rgbaF16) ?? Int.max
  }

  /// The bytes of the whole decode a tile is cut from. The helper holds it while it cuts, so it
  /// sets what the request may cost.
  ///
  /// The level is in the output space the source decoded in, which the pane learned from the fit
  /// decode. A space that is not known yet counts as sixteen-bit floats, the larger of the two.
  static func levelBytes(longerSide: Int, native: PixelSize, space: OutputSpace?) -> Int {
    let ratio = Double(longerSide) / Double(max(native.longer, 1))
    let width = max(1, Int((Double(native.width) * ratio).rounded(.up)))
    let height = max(1, Int((Double(native.height) * ratio).rounded(.up)))

    return ImageLimits.byteCount(width: width, height: height, format: space?.format ?? .rgbaF16)
      ?? Int.max
  }

  private func levelBytes(for region: TileRegion, of info: SourceInfo) -> Int {
    let native = PixelSize(width: Int(info.width), height: Int(info.height))

    return Self.levelBytes(
      longerSide: region.level, native: native, space: outputSpaces[info.source])
  }

  private func send(_ request: DecodeRequest) {
    guard let process, let info = infos[request.source] else {
      refuse(request, "The image is no longer open in the decoder.")
      return
    }

    let region = request.region
    let held = region.map { levelBytes(for: $0, of: info) } ?? predictedBytes(for: request)
    let predicted = region.map { $0.width * $0.height * PixelFormat.rgbaF16.bytesPerPixel } ?? held
    let estimate = held.multipliedReportingOverflow(by: 2).partialValue + (64 << 20)

    guard held <= settings.maxImageBytes else {
      refuse(request, "This image is past the size uniterm will decode for it.")
      return
    }

    guard budget.admits(owner: owner, estimate: estimate) else {
      refuse(request, "Image decoding is using all the memory it may. Close an image pane.")
      return
    }

    touch(request.source)

    expectation = ImageExpectation(
      request: request.id, source: request.source, frame: UInt32(request.frame),
      maxPixel: request.maxPixel, sourceWidth: Int(info.width), sourceHeight: Int(info.height),
      byteCap: region == nil ? settings.maxImageBytes : predicted,
      region: region.map { ($0.width, $0.height) })

    readLimit.withLock { $0 = predicted }
    decodesSent += 1
    markBusy()

    let message: AppMessage

    if let region {
      message = .region(
        request: request.id, source: request.source, level: UInt32(region.level),
        x: UInt32(region.x), y: UInt32(region.y), width: UInt32(region.width),
        height: UInt32(region.height))
    } else {
      message = .decode(
        request: request.id, source: request.source, maxPixel: UInt32(request.maxPixel),
        frame: UInt32(request.frame))
    }

    do {
      try process.socket.send(message.frame())
    } catch {
      end(.crashed("The image decoder stopped answering."), lost: request)
    }
  }

  private func refuse(_ request: DecodeRequest, _ text: String) {
    expectation = nil
    readLimit.withLock { $0 = 0 }

    let next = scheduler.finish()

    onEvent?(.refused(request, text))

    if let next {
      send(next)
    } else if openingSources.isEmpty, scheduler.inFlight == nil {
      markIdle()
    }
  }

  // MARK: Receiving

  private func handle(_ event: HelperRead<HelperMessage>, generation current: Int) {
    guard current == generation else { return }

    switch event {
    case .message(let message):
      handle(message)

    case .violation(let text):
      end(.misbehaved(text), lost: scheduler.inFlight)

    case .exited(let status):
      end(
        .crashed("The image decoder \(HelperProcess.describe(status: status))."),
        lost: scheduler.inFlight)
    }
  }

  private func handle(_ message: HelperMessage) {
    switch message {
    case .hello:
      do {
        types = try HelperHandshake.validate(message)
      } catch {
        end(.versionMismatch, lost: nil)
        return
      }

      if let types { onEvent?(.types(types)) }

    case .opened(let opened):
      guard !openingSources.isEmpty else {
        end(.misbehaved("an unrequested open reply"), lost: scheduler.inFlight)
        return
      }

      let expected = openingSources.removeFirst()

      if openingSources.isEmpty && scheduler.inFlight == nil { markIdle() }

      guard opened.source == expected.id else {
        end(.misbehaved("an open reply for the wrong source"), lost: scheduler.inFlight)
        return
      }

      guard validate(opened) else {
        end(.misbehaved("a source with impossible dimensions"), lost: scheduler.inFlight)
        return
      }

      infos[opened.source] = opened

      switch expected.role {
      case .display:
        if opened.source == displaySource { onEvent?(.opened(opened)) }

      case .prefetch:
        onEvent?(.prefetchOpened(opened))
      }

    case .image(let header, let pixels):
      guard let request = scheduler.inFlight, let expectation, expectation.request == header.request
      else {
        end(.misbehaved("an image nobody asked for"), lost: scheduler.inFlight)
        return
      }

      do {
        try expectation.validate(header, pixels: pixels)
      } catch {
        end(.misbehaved("\(error)"), lost: request)
        return
      }

      self.expectation = nil

      if infos[header.source] != nil { outputSpaces[header.source] = header.space }

      completeDecode()
      onEvent?(.image(request, header, pixels))

    case .failure(let id, let kind, let text):
      if id == 0 {
        guard !openingSources.isEmpty else {
          end(.misbehaved("an unrequested failure"), lost: scheduler.inFlight)
          return
        }

        let failed = openingSources.removeFirst()

        if openingSources.isEmpty && scheduler.inFlight == nil { markIdle() }

        if failed.role == .display, failed.id == displaySource {
          onEvent?(.failed(nil, kind, text))
        } else if failed.role == .prefetch {
          onEvent?(.prefetchOpenFailed(failed.id, text))
        }

        return
      }

      guard let request = scheduler.inFlight, request.id == id else {
        end(.misbehaved("a failure nobody asked for"), lost: scheduler.inFlight)
        return
      }

      expectation = nil
      completeDecode()
      onEvent?(.failed(request, kind, text))

    case .pong(let value):
      liveness.pong(value)
    }
  }

  private func validate(_ opened: SourceInfo) -> Bool {
    let limit = 1 << 20

    return opened.width > 0 && opened.height > 0 && Int(opened.width) <= limit
      && Int(opened.height) <= limit && opened.frameCount >= 1
  }

  private func completeDecode() {
    readLimit.withLock { $0 = 0 }

    let next = scheduler.finish()

    if let next {
      send(next)
    } else if openingSources.isEmpty {
      markIdle()
    }
  }

  // MARK: Watching

  private func markBusy() {
    liveness.markBusy()

    guard watchdog == nil else { return }

    let interval = settings.probeInterval
    let current = generation

    watchdog = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)

        guard let self, !Task.isCancelled, current == self.generation else { return }

        self.probe()
      }
    }
  }

  private func markIdle() {
    liveness.markIdle()
    watchdog?.cancel()
    watchdog = nil

    if let footprint = process?.footprint() {
      lastFootprint = footprint
      budget.record(owner: owner, footprint: footprint)
    }
  }

  private func probe() {
    guard let process, liveness.isBusy else { return }

    let footprint = process.footprint()

    if let footprint {
      lastFootprint = footprint
      budget.record(owner: owner, footprint: footprint)
    }

    switch liveness.probe(footprint: footprint) {
    case .healthy:
      break

    case .end(let reason):
      end(reason, lost: scheduler.inFlight)

    case .sendPing(let value):
      try? process.socket.send(AppMessage.ping(nonce: value).frame())
    }
  }

  /// Ends the helper and tells the pane why.
  private func end(_ reason: HelperEnd, lost: DecodeRequest?) {
    let had = process

    readLimit.withLock { $0 = 0 }

    watchdog?.cancel()
    watchdog = nil
    liveness.markIdle()
    expectation = nil
    scheduler.reset()
    openingSources = []
    infos = [:]
    outputSpaces = [:]
    recentSources = []
    process = nil
    generation += 1

    had?.kill()
    budget.release(owner: owner)

    onEvent?(.ended(reason, lost: lost))
  }
}
