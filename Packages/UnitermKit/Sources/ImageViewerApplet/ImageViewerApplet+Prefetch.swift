import AppKit
import ImageViewerModel
import ImageWire

/// The next image, decoded at fit size while the pane is idle.
struct PrefetchJob {
  enum Phase {
    case opening
    case decoding
  }

  var name: String
  var modified: Double?
  var source: UInt32?
  var requestID: UInt32?
  var info: SourceInfo?
  var realPath: String?
  var phase = Phase.opening

  /// The user stepped to this image while it was still being prepared, so its result is shown when
  /// it arrives and its failure is the user's to see.
  var promoted = false
}

/// The prefetch and the decodes the pane keeps beside the one on screen.
///
/// The pane prefetches one image, the next in the direction of travel, only when it is showing an
/// image and nothing else is loading. A prefetch failure is silent: the pane records the name and
/// lets the user find out by stepping there. A pane zoomed past fit never prefetches, and the
/// scheduler enforces that, so a prefetch cannot push the helper past its cap while the pane holds
/// a larger decode.
extension ImageViewerApplet {
  func maybePrefetch() {
    guard !closed, !isOffScreen, phase == .showing, loadingName == nil, prefetch == nil,
      prefetchTask == nil, !isZoomedPastFit, client.isRunning, let folder, let held = shot,
      let at = listing.position(ofName: held.name)
    else { return }

    let neighbor = travelsForward ? at + 1 : at - 1

    guard listing.images.indices.contains(neighbor) else { return }

    let target = listing.images[neighbor]

    guard !prefetchFailed.contains(target.name),
      !cache.holds(name: target.name, modified: target.modified)
    else { return }

    prefetch = PrefetchJob(name: target.name, modified: target.modified)

    let name = target.name

    let opener = prefetchOpener

    prefetchTask = Task { [weak self] in
      let result = await opener(folder, name)

      guard let self, !Task.isCancelled, !self.closed else { return }

      self.prefetchTask = nil

      guard let job = self.prefetch, job.name == name, job.source == nil else { return }

      switch result {
      case .success(let file):
        let source = self.client.open(file, role: .prefetch)

        self.prefetch?.realPath = file.realPath

        if source == nil {
          self.prefetch = nil
        } else {
          self.prefetch?.source = source
        }

      case .failure:
        self.prefetchFailed.insert(name)
        self.prefetch = nil

        if job.promoted, let image = self.listing.images.first(where: { $0.name == name }) {
          self.beginLoad(of: image, bypassCache: true)
        }
      }
    }
  }

  /// Stops a prefetch that has not reached the helper yet. One the helper is decoding runs on.
  func cancelPrefetchOpening() {
    guard !(prefetch?.promoted ?? false) else { return }

    prefetchTask?.cancel()
    prefetchTask = nil

    if prefetch?.source == nil { prefetch = nil }
  }

  /// Forgets a prefetch decode that a newer request replaced in the scheduler.
  func reapPrefetch() {
    guard let job = prefetch, job.phase == .decoding, !job.promoted, !client.prefetchInFlight
    else { return }

    prefetch = nil
  }

  func prefetchOpened(_ opened: SourceInfo) {
    guard var job = prefetch, job.source == opened.source else { return }

    if (loadingName != nil || isZoomedPastFit) && !job.promoted {
      prefetch = nil
      return
    }

    job.info = opened
    job.phase = .decoding
    prefetch = job

    if let request = client.prefetch(opened, maxPixel: fitLongerSide(of: opened)) {
      prefetch?.requestID = request
    } else {
      abandon(job)
    }
  }

  /// A prefetch the scheduler replaced before it was sent will never arrive. A step that was
  /// waiting on it loads the image the usual way.
  func prefetchDropped(_ request: UInt32) {
    guard let job = prefetch, job.requestID == request else { return }

    abandon(job)
  }

  /// Forgets `job`. When the user had already stepped to its image, the image loads normally.
  private func abandon(_ job: PrefetchJob) {
    prefetch = nil

    if job.promoted, let image = listing.images.first(where: { $0.name == job.name }) {
      beginLoad(of: image, bypassCache: true)
    }
  }

  /// Stops the open of a prefetch that has not reached the helper, whatever its state. A step that
  /// was waiting on it loads the image the usual way.
  func abandonPrefetchOpening() {
    prefetchTask?.cancel()
    prefetchTask = nil

    if let job = prefetch, job.source == nil { abandon(job) }
  }

  func prefetchOpenFailed(_ source: UInt32, _ text: String) {
    guard let job = prefetch, job.source == source else { return }

    prefetchLost(text)
  }

  /// A prefetch failed or was refused. The pane says nothing unless the user already stepped there.
  func prefetchLost(_ text: String) {
    guard let job = prefetch else { return }

    prefetchFailed.insert(job.name)
    prefetch = nil

    if job.promoted { problem(text, offersRetry: false) }
  }

  /// The helper died while a prefetch ran. The image on screen stays. A step that was waiting on
  /// the helper starts again, and meets the failure itself if the file is the cause.
  func helperLostDuringPrefetch() {
    if let job = prefetch { prefetchFailed.insert(job.name) }

    prefetch = nil
    dropPrefetched()

    if let name = loadingName, let image = listing.images.first(where: { $0.name == name }) {
      beginLoad(of: image, bypassCache: true)
    }
  }

  func dropPrefetched() {
    if let entry = cache.dropPrefetched() {
      bitmapBudget.giveBack(entry.value.bytes, lease: lease)
    }

    if let job = prefetch, !job.promoted { prefetch = nil }
  }

  func prefetchArrived(_ request: DecodeRequest, _ header: ImageHeader, _ pixels: Data) {
    guard let job = prefetch, job.source == request.source, let opened = job.info else { return }

    prefetch = nil

    guard let image = BitmapFactory.makeImage(header, pixels: pixels) else {
      prefetchFailed.insert(job.name)

      if job.promoted { problem("The image could not be shown.", offersRetry: false) }

      return
    }

    let decoded = Shot(
      name: job.name, modified: job.modified, info: opened, image: image,
      pixels: PixelSize(width: Int(header.width), height: Int(header.height)), space: header.space,
      bytes: pixels.count, realPath: job.realPath)
    let entry = FitCache<Shot>.Entry(name: job.name, modified: job.modified, value: decoded)

    if job.promoted {
      guard reserve(pixels.count) else {
        problem(
          "There is not enough memory to show \u{201C}\(job.name)\u{201D} right now. Close an image pane and retry.",
          offersRetry: true, code: .limit)
        return
      }

      guard client.select(source: opened.source) else {
        bitmapBudget.giveBack(pixels.count, lease: lease)

        if let image = listing.images.first(where: { $0.name == job.name }) {
          beginLoad(of: image, bypassCache: true)
        }

        return
      }

      display(entry)
      return
    }

    guard bitmapBudget.reserve(pixels.count, lease: lease) else { return }

    if let replaced = cache.keepPrefetched(entry) {
      bitmapBudget.giveBack(replaced.value.bytes, lease: lease)
    }
  }
}
