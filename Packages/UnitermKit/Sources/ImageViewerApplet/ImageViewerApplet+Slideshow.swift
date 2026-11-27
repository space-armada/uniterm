import AppKit
import ImageViewerModel

/// How the slideshow waits between images. Tests pass a sleeper they release by hand.
typealias SlideshowSleep = @MainActor @Sendable (Duration) async throws -> Void

/// The slideshow: a fixed timer that selects the next image and lets the usual load follow.
///
/// Playing is the pane's intent, not saved state. Going off screen stops the timer and keeps the
/// intent, so coming back resumes a slideshow that was playing and starts none that was not.
extension ImageViewerApplet {
  static let realSleep: SlideshowSleep = { duration in
    try await Task.sleep(for: duration)
  }

  var canPlay: Bool {
    listing.count > 1 || (!listing.isComplete && listing.count > 0)
  }

  func togglePlayback() {
    if isPlaying {
      stopSlideshow()
    } else {
      startSlideshow()
    }
  }

  func startSlideshow() {
    guard canPlay, !isPlaying else { return }

    isPlaying = true
    refresh()

    if !isOffScreen { runSlideshowTimer() }
  }

  func stopSlideshow() {
    slideshowTask?.cancel()
    slideshowTask = nil

    guard isPlaying else { return }

    isPlaying = false
    refresh()
  }

  /// Stops the timer and keeps the intent to play.
  func pauseSlideshowTimer() {
    slideshowTask?.cancel()
    slideshowTask = nil
  }

  func resumeSlideshowTimer() {
    if isPlaying && !closed { runSlideshowTimer() }
  }

  var isSlideshowTimerRunning: Bool { slideshowTask != nil }

  private func runSlideshowTimer() {
    slideshowTask?.cancel()

    let sleep = slideshowSleep

    slideshowTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await sleep(SlideshowPolicy.interval)
        } catch {
          return
        }

        guard let self, !Task.isCancelled else { return }

        self.slideshowTick()
      }
    }
  }

  /// Selects the next image. It wraps only once the folder has been listed to its end.
  func slideshowTick() {
    guard isPlaying, !closed, !isOffScreen, let target = listing.slideshowTarget else { return }

    travelsForward = true
    listing.select(target)
    refresh()
    pump()
  }
}
