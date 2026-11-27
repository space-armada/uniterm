import AppKit
import AppletKit
import AppletTestSupport
import ImageTestSupport
import ImageViewerModel
import ImageWire
import SourceAccess
import XCTest
import os

@testable import ImageViewerApplet

/// Drives stepping, the slideshow, sort, reload, restore, and the prefetch against a real helper
/// process. Each test names a contract of the folder slideshow.
@MainActor
final class ImageViewerNavigationTests: XCTestCase {
  private var folder: URL!
  private var panes: PaneFactory!

  override func setUp() async throws {
    folder = try ImageFixtures.makeFolder()
    panes = PaneFactory(folder: folder)
  }

  override func tearDown() async throws {
    panes.closeAll()

    chmod(folder.path, 0o755)
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private func write(_ names: String..., width: Int = 64, height: Int = 32) throws {
    for name in names {
      try ImageFixtures.write(
        ImageFixtures.png(width: width, height: height), named: name, in: folder)
    }
  }

  private func shows(_ applet: ImageViewerApplet, _ name: String) async -> Bool {
    await Harness.eventually { applet.phase == .showing && applet.committedName == name }
  }

  private func listed(_ applet: ImageViewerApplet) async -> Bool {
    await Harness.eventually { applet.listing.isComplete }
  }

  private func openFolder(
    _ applet: ImageViewerApplet, showing name: String
  ) async throws {
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let first = await shows(applet, name)
    XCTAssertTrue(first, "\(applet.phase)")

    let complete = await listed(applet)
    XCTAssertTrue(complete)
  }

  private func key(_ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: 0)!
  }

  private func functionKey(_ code: Int, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    key(String(Character(UnicodeScalar(UInt32(code))!)), flags)
  }

  private func warnings(_ host: RecordingHost) -> [String] {
    host.sent.filter { $0.level == .warning }.map(\.text)
  }

  // MARK: Stepping

  /// Catches stepping that cannot reach every image, or that runs off an end. Next, previous, first,
  /// and last move through the folder in Finder order and stop at the first and the last image.
  func testSteppingMovesThroughAFolderAndStopsAtTheEnds() async throws {
    try write("a.png", "b.png", "c.png")

    let (applet, _) = panes.make()
    try await openFolder(applet, showing: "a.png")

    applet.step(.next)
    let second = await shows(applet, "b.png")
    XCTAssertTrue(second)
    XCTAssertEqual(applet.segments.last?.text, "2 of 3")

    applet.step(.last)
    let last = await shows(applet, "c.png")
    XCTAssertTrue(last)

    applet.step(.next)
    XCTAssertEqual(applet.committedName, "c.png", "no step past the last image")
    XCTAssertFalse(applet.canStep(.next))

    applet.step(.first)
    let first = await shows(applet, "a.png")
    XCTAssertTrue(first)

    applet.step(.previous)
    XCTAssertEqual(applet.committedName, "a.png", "no step before the first image")
    XCTAssertFalse(applet.canStep(.previous))
  }

  /// Catches a folder that lists what is not an image. Non-image files are skipped by extension and
  /// type, so the listing and the position segment count only the images.
  func testNonImageFilesAreSkippedWhileStepping() async throws {
    try write("a.png", "b.png")
    try ImageFixtures.write(Data("text".utf8), named: "notes.txt", in: folder)
    try ImageFixtures.write(Data("%PDF-1.4".utf8), named: "paper.pdf", in: folder)

    let (applet, _) = panes.make()
    try await openFolder(applet, showing: "a.png")

    XCTAssertEqual(applet.listing.images.map(\.name), ["a.png", "b.png"])
    XCTAssertEqual(applet.segments.last?.text, "1 of 2")
  }

  /// Catches a folder with nothing to show leaving a blank pane. Once the scan ends with no image,
  /// the pane says the folder has none and offers to open another.
  func testAFolderWithNoImagesSaysSo() async throws {
    try ImageFixtures.write(Data("x".utf8), named: "a.txt", in: folder)

    let (applet, _) = panes.make()
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let said = await Harness.eventually {
      if case .problem(let message) = applet.phase { return message.text.contains("no images") }

      return false
    }

    XCTAssertTrue(said)
  }

  /// Catches view keys that do not step, and chords that the view takes from the menu and the
  /// palette. The arrows, Space, Shift-Space, Home, and End step. Command, option, and control
  /// chords are left alone.
  func testViewKeysStepAndChordsAreLeftAlone() async throws {
    try write("a.png", "b.png", "c.png")

    let (applet, _) = panes.make()
    try await openFolder(applet, showing: "a.png")

    applet.content.keyDown(with: functionKey(NSRightArrowFunctionKey))
    let right = await shows(applet, "b.png")
    XCTAssertTrue(right)

    applet.content.keyDown(with: functionKey(NSLeftArrowFunctionKey))
    let left = await shows(applet, "a.png")
    XCTAssertTrue(left)

    applet.content.keyDown(with: functionKey(NSEndFunctionKey))
    let end = await shows(applet, "c.png")
    XCTAssertTrue(end)

    applet.content.keyDown(with: functionKey(NSHomeFunctionKey))
    let home = await shows(applet, "a.png")
    XCTAssertTrue(home)

    applet.content.keyDown(with: key(" "))
    let space = await shows(applet, "b.png")
    XCTAssertTrue(space)

    applet.content.keyDown(with: key(" ", .shift))
    let shiftSpace = await shows(applet, "a.png")
    XCTAssertTrue(shiftSpace)

    XCTAssertNil(ImageKey.key(for: functionKey(NSLeftArrowFunctionKey, .command)))
    XCTAssertNil(ImageKey.key(for: functionKey(NSRightArrowFunctionKey, .option)))
    XCTAssertNil(ImageKey.key(for: key(" ", .control)))
    XCTAssertNil(ImageKey.key(for: key("x")))
  }

  /// Catches a held next key that stops showing images or respawns the helper. Five steps at once
  /// finish on the last image, every image the pane loaded finished before the next began, and the
  /// same helper process decoded them all.
  func testHoldingTheNextKeyKeepsShowingImagesWithoutRespawningTheHelper() async throws {
    try write("a.png", "b.png", "c.png", "d.png", "e.png", "f.png", width: 1600, height: 1000)

    let (applet, _) = panes.make()
    try await openFolder(applet, showing: "a.png")

    let process = applet.client.processID
    XCTAssertNotNil(process)

    for _ in 0..<5 { applet.step(.next) }

    let last = await shows(applet, "f.png")
    XCTAssertTrue(last)
    XCTAssertEqual(applet.client.processID, process)
    XCTAssertEqual(applet.segments.last?.text, "6 of 6")
  }

  // MARK: Partial listing

  /// Catches stepping that waits for a large folder, an order that shifts under the user, and a
  /// slideshow that wraps before the listing ends. The scan is held after its first batch, then
  /// after its second. The prefix never moves, the position stays provisional, and only a complete
  /// listing wraps.
  func testSteppingWorksWhileTheListingIsPartialAndTheShowWaitsToWrap() async throws {
    try write("img1.png", "img2.png", "img3.png", "img4.png", "img5.png", "img6.png")

    let first = DispatchSemaphore(value: 0)
    let second = DispatchSemaphore(value: 0)
    let pace = ScanPace(batchSize: 2) { index in
      if index == 1 { first.wait() }
      if index == 2 { second.wait() }
    }
    let sleeper = ManualSleeper()

    let (applet, _) = panes.make(scanPace: pace, sleeper: sleeper)
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let opening = await Harness.eventually { applet.phase == .showing }
    XCTAssertTrue(opening)
    XCTAssertFalse(applet.listing.isComplete)

    let prefix = applet.listing.images.map(\.name)
    XCTAssertEqual(prefix.count, 2)
    XCTAssertEqual(applet.committedName, prefix[0], "the first image of the first batch shows")
    XCTAssertEqual(applet.segments.last?.text, "1 of 2+")

    applet.step(.next)
    let stepped = await shows(applet, prefix[1])
    XCTAssertTrue(stepped, "stepping works before the listing ends")

    applet.startSlideshow()
    let armed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(armed)

    sleeper.tick()
    let rearmed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(rearmed)
    XCTAssertEqual(applet.committedName, prefix[1], "a partial listing does not wrap")

    first.signal()

    let grown = await Harness.eventually { applet.listing.count == 4 }
    XCTAssertTrue(grown)
    XCTAssertFalse(applet.listing.isComplete)
    XCTAssertEqual(
      Array(applet.listing.images.prefix(2).map(\.name)), prefix, "the prefix is stable")

    second.signal()

    let complete = await listed(applet)
    XCTAssertTrue(complete)
    XCTAssertEqual(applet.listing.images.map(\.name).count, 6)
    XCTAssertEqual(applet.listing.images.map(\.name), applet.listing.images.map(\.name).sorted())
    XCTAssertEqual(applet.listing.current?.name, prefix[1], "the selection follows its image")
  }

  /// Catches a restore that shows the first image of a large folder before the stored one. The scan
  /// is held after its first batch. The pane opens the stored image at once, and no other image
  /// shows while the listing runs.
  func testRestoringIntoAFolderOpensTheStoredImageWhileTheListingRuns() async throws {
    try write("img1.png", "img2.png", "img3.png", "img4.png", "img5.png", "img6.png")

    let gate = DispatchSemaphore(value: 0)
    let pace = ScanPace(batchSize: 2) { index in
      if index == 1 { gate.wait() }
    }

    let record = ImageViewerDescription(
      startDirectory: folder.path, path: folder.path, kind: .folder, current: "img5.png",
      currentModified: 0, sort: .name)
    let (applet, _) = try panes.restored(record, scanPace: pace)

    applet.start(origin: .restore)

    var seen: Set<String> = []
    let shown = await Harness.eventually {
      if let name = applet.committedName { seen.insert(name) }

      return applet.phase == .showing
    }

    XCTAssertTrue(shown)
    XCTAssertEqual(applet.title, "img5.png")
    XCTAssertFalse(applet.listing.isComplete, "the stored image shows before the listing ends")

    gate.signal()

    let complete = await listed(applet)
    XCTAssertTrue(complete)
    XCTAssertEqual(applet.committedName, "img5.png")
    XCTAssertEqual(seen, ["img5.png"])
    XCTAssertEqual(applet.segments.last?.text, "5 of 6")
  }

  /// Catches a restore whose stored image is gone landing on the first image. The pane waits for the
  /// listing, then lands on the nearest image in the stored name order.
  func testRestoreLandsOnTheNearestImageByNameWhenTheStoredOneIsGone() async throws {
    try write("a.png", "b.png", "e.png")

    let record = ImageViewerDescription(
      startDirectory: folder.path, path: folder.path, kind: .folder, current: "c.png",
      currentModified: 0, sort: .name)
    let (applet, _) = try panes.restored(record)

    applet.start(origin: .restore)

    var seen: Set<String> = []
    let shown = await Harness.eventually {
      if let name = applet.committedName { seen.insert(name) }

      return applet.phase == .showing
    }

    XCTAssertTrue(shown)
    XCTAssertEqual(applet.committedName, "e.png")
    XCTAssertEqual(seen, ["e.png"], "the first image never showed")
  }

  /// Catches a restore in date order that lands by name. The stored modification time places the
  /// missing image between its neighbors in newest-first order.
  func testRestoreLandsByModificationTimeInDateOrder() async throws {
    for (name, time) in [("old.png", 100.0), ("mid.png", 200.0), ("new.png", 300.0)] {
      let file = try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)

      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: file.path)
    }

    let record = ImageViewerDescription(
      startDirectory: folder.path, path: folder.path, kind: .folder, current: "gone.png",
      currentModified: 250, sort: .dateModified)
    let (applet, _) = try panes.restored(record)

    applet.start(origin: .restore)

    let landed = await shows(applet, "mid.png")
    XCTAssertTrue(landed, "\(String(describing: applet.committedName))")
  }

  // MARK: Slideshow

  /// Catches a slideshow that does not advance on its interval, wraps early or not at all, or keeps
  /// playing after a manual step. The clock is injected, so no test sleeps.
  func testTheSlideshowAdvancesWrapsAndStopsOnAManualStep() async throws {
    try write("a.png", "b.png", "c.png")

    let sleeper = ManualSleeper()
    let (applet, _) = panes.make(sleeper: sleeper)
    try await openFolder(applet, showing: "a.png")

    applet.togglePlayback()

    let armed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(armed)
    XCTAssertEqual(sleeper.requested, [.seconds(5)])
    XCTAssertTrue(applet.segments.contains { $0.text == "Slideshow" })

    sleeper.tick()
    let second = await shows(applet, "b.png")
    XCTAssertTrue(second)

    let again = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(again)
    sleeper.tick()
    let third = await shows(applet, "c.png")
    XCTAssertTrue(third)

    let wrapArmed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(wrapArmed)
    sleeper.tick()
    let wrapped = await shows(applet, "a.png")
    XCTAssertTrue(wrapped, "the show wraps at the end of a complete listing")

    applet.step(.next)
    XCTAssertFalse(applet.isPlaying)
    XCTAssertFalse(applet.segments.contains { $0.text == "Slideshow" })

    let stopped = await Harness.eventually { sleeper.waitingCount == 0 }
    XCTAssertTrue(stopped)
  }

  /// Catches a slideshow that steps away from an image the user zoomed into. Zooming past fit is a
  /// manual action, so it stops the show, and a tick that was already due leaves the image alone.
  func testZoomingStopsASlideshowLikeAManualStep() async throws {
    try write("a.png", "b.png")

    let sleeper = ManualSleeper()
    let (applet, _) = panes.make(sleeper: sleeper)
    try await openFolder(applet, showing: "a.png")

    applet.togglePlayback()

    let armed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(armed)

    applet.zoomIn()

    XCTAssertTrue(applet.isZoomedPastFit)
    XCTAssertFalse(applet.isPlaying)
    XCTAssertFalse(applet.isSlideshowTimerRunning)
    XCTAssertFalse(applet.segments.contains { $0.text == "Slideshow" })

    sleeper.tick()
    applet.slideshowTick()

    XCTAssertEqual(applet.committedName, "a.png")
    XCTAssertTrue(applet.isZoomedPastFit)
  }

  /// Catches a slideshow that steps away in the middle of a pinch. A pinch reports its viewport only
  /// when the fingers lift, so the start of the pinch has to stop the show, as a zoom does.
  func testAPinchStopsASlideshowBeforeItsTickCanStepAway() async throws {
    try write("a.png", "b.png", width: 600, height: 600)

    let sleeper = ManualSleeper()
    let (applet, _) = panes.make(sleeper: sleeper)
    try await openFolder(applet, showing: "a.png")

    applet.togglePlayback()

    let armed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(armed)

    applet.content.pinch(.began, magnification: 0, at: CGPoint(x: 150, y: 150))
    XCTAssertTrue(applet.content.isPinching)

    sleeper.tick()
    applet.slideshowTick()

    XCTAssertFalse(applet.isPlaying)
    XCTAssertEqual(applet.committedName, "a.png")
    XCTAssertEqual(applet.listing.current?.name, "a.png")
  }

  /// Catches a slideshow that keeps running off screen, or that restarts when it was not playing.
  /// Leaving the screen stops the timer and keeps the intent. Coming back resumes a show that was playing and
  /// starts none that was not.
  func testTheSlideshowPausesOffScreenAndResumesOnlyIfItWasPlaying() async throws {
    try write("a.png", "b.png")

    let sleeper = ManualSleeper()
    let (applet, _) = panes.make(sleeper: sleeper)
    try await openFolder(applet, showing: "a.png")

    applet.togglePlayback()
    let armed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(armed)

    applet.leaveScreen()
    let paused = await Harness.eventually { sleeper.waitingCount == 0 }
    XCTAssertTrue(paused)
    XCTAssertFalse(applet.isSlideshowTimerRunning)
    XCTAssertTrue(applet.isPlaying, "the intent to play is kept")

    applet.returnToScreen()
    let resumed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(resumed)

    applet.togglePlayback()
    XCTAssertFalse(applet.isPlaying)

    applet.leaveScreen()
    applet.returnToScreen()

    XCTAssertFalse(applet.isSlideshowTimerRunning, "a show that was not playing stays stopped")

    let idle = await Harness.eventually { sleeper.waitingCount == 0 }
    XCTAssertTrue(idle)
  }

  /// Catches a slideshow that survives opening another source. A pane shows one source, and
  /// replacing it stops the show.
  func testOpeningAnotherSourceStopsTheSlideshow() async throws {
    try write("a.png", "b.png")

    let sleeper = ManualSleeper()
    let (applet, _) = panes.make(sleeper: sleeper)
    try await openFolder(applet, showing: "a.png")

    applet.togglePlayback()
    XCTAssertTrue(applet.isPlaying)

    try applet.replaceSource(
      with: folder.appendingPathComponent("b.png"), startDirectory: folder.path)

    XCTAssertFalse(applet.isPlaying)
  }

  /// Catches a slideshow that spins on a folder with nothing left to show. When every other image
  /// has been deleted, the show stops and the status bar says why.
  func testTheSlideshowStopsWithAWarningWhenTheRestWasDeleted() async throws {
    try write("a.png", "b.png", "c.png")

    let sleeper = ManualSleeper()
    let (applet, host) = panes.make(sleeper: sleeper)
    applet.prefetchOpener = Self.failingOpener
    try await openFolder(applet, showing: "a.png")

    applet.togglePlayback()
    let armed = await Harness.eventually { sleeper.waitingCount == 1 }
    XCTAssertTrue(armed)

    try FileManager.default.removeItem(at: folder.appendingPathComponent("b.png"))
    try FileManager.default.removeItem(at: folder.appendingPathComponent("c.png"))

    sleeper.tick()

    let stopped = await Harness.eventually { !applet.isPlaying }
    XCTAssertTrue(stopped)
    XCTAssertEqual(applet.committedName, "a.png")
    XCTAssertTrue(warnings(host).contains { $0.contains("slideshow stopped") })
    XCTAssertEqual(warnings(host).filter { $0.contains("no longer in the folder") }.count, 2)
  }

  /// A prefetch opener that always fails, so a step has no held decode to show and meets the file
  /// itself.
  static let failingOpener:
    @Sendable (OpenedFolder, String) async -> Result<OpenedImageFile, SourceAccessError> = {
      _, name in .failure(.missing(path: name))
    }

  // MARK: Deleted files

  /// Catches a deleted file that blocks stepping or goes unmentioned. Reaching it posts a warning
  /// and the pane goes on to the next image.
  func testADeletedImageIsSkippedWithAWarning() async throws {
    try write("a.png", "b.png", "c.png")

    let (applet, host) = panes.make()
    applet.prefetchOpener = Self.failingOpener
    try await openFolder(applet, showing: "a.png")

    try FileManager.default.removeItem(at: folder.appendingPathComponent("b.png"))

    applet.step(.next)

    let skipped = await shows(applet, "c.png")
    XCTAssertTrue(skipped)
    XCTAssertTrue(warnings(host).contains { $0.contains("b.png") })
    XCTAssertEqual(applet.listing.count, 2)
    XCTAssertEqual(applet.segments.last?.text, "2 of 2")
  }

  // MARK: Sort and reload

  /// Catches a sort that moves the user or does not stick. Sorting by date puts the newest first and
  /// keeps the image on screen, and the description records the order.
  func testSortingByDateKeepsTheImageAndIsSaved() async throws {
    for (name, time) in [("a.png", 100.0), ("b.png", 300.0), ("c.png", 200.0)] {
      let file = try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)

      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: file.path)
    }

    let (applet, _) = panes.make()
    try await openFolder(applet, showing: "a.png")

    applet.setSort(.dateModified)

    let sorted = await Harness.eventually {
      applet.listing.images.map(\.name) == ["b.png", "c.png", "a.png"]
    }
    XCTAssertTrue(sorted)
    XCTAssertEqual(applet.listing.current?.name, "a.png")
    XCTAssertEqual(applet.segments.last?.text, "3 of 3")

    guard case .object(let payload) = applet.describe().payload,
      case .string(let sort) = payload["sort"]
    else { return XCTFail("no sort in the description") }

    XCTAssertEqual(sort, "dateModified")

    applet.step(.first)
    let newest = await shows(applet, "b.png")
    XCTAssertTrue(newest)

    applet.setSort(.name)

    let byName = await Harness.eventually {
      applet.listing.images.map(\.name) == ["a.png", "b.png", "c.png"]
    }
    XCTAssertTrue(byName)
  }

  /// Catches a reload that moves the user off their image, or that misses new files. Reload lists
  /// again, keeps the image on screen, and lands on the nearest image when it is gone.
  func testReloadKeepsTheCurrentImageOrLandsNearestIt() async throws {
    try write("a.png", "c.png", "e.png")

    let (applet, host) = panes.make()
    try await openFolder(applet, showing: "a.png")

    applet.step(.next)
    let onC = await shows(applet, "c.png")
    XCTAssertTrue(onC)

    try write("d.png")
    applet.reloadFolder()

    let grown = await Harness.eventually { applet.listing.count == 4 }
    XCTAssertTrue(grown)
    XCTAssertEqual(applet.committedName, "c.png")
    XCTAssertEqual(applet.listing.current?.name, "c.png")
    XCTAssertTrue(host.posts.contains { $0.text.hasPrefix("Reloaded") })

    try FileManager.default.removeItem(at: folder.appendingPathComponent("c.png"))
    applet.reloadFolder()

    let landed = await shows(applet, "d.png")
    XCTAssertTrue(landed, "the image after the deleted one")
    XCTAssertEqual(applet.listing.count, 3)
  }

  // MARK: Single files

  /// Catches a single file that cannot step. Given one file, the pane lists its siblings and starts
  /// at that file.
  func testASingleFileStepsThroughItsSiblingsStartingAtItself() async throws {
    try write("a.png", "b.png", "c.png")

    let (applet, _) = panes.make()
    try applet.replaceSource(
      with: folder.appendingPathComponent("b.png"), startDirectory: folder.path)

    let first = await shows(applet, "b.png")
    XCTAssertTrue(first)

    let complete = await listed(applet)
    XCTAssertTrue(complete)
    XCTAssertEqual(applet.segments.last?.text, "2 of 3")

    applet.step(.previous)
    let before = await shows(applet, "a.png")
    XCTAssertTrue(before)
  }

  /// Catches a folder that cannot be listed leaving an empty pane, a repeated notice, or no sign of
  /// the cause. The pane shows the file, the status bar says so once, and a warning segment shows
  /// while it holds. Stepping has nowhere to go.
  func testAFolderThatCannotBeListedShowsTheFileAndSaysSoOnce() async throws {
    try write("a.png", "b.png")

    XCTAssertEqual(chmod(folder.path, 0o311), 0)

    let (applet, host) = panes.make()
    try applet.replaceSource(
      with: folder.appendingPathComponent("a.png"), startDirectory: folder.path)

    let shown = await shows(applet, "a.png")
    XCTAssertTrue(shown, "\(applet.phase)")

    XCTAssertEqual(warnings(host).filter { $0.contains("could not be listed") }.count, 1)

    let segment = applet.segments.first { $0.text == "Folder not listed" }
    XCTAssertEqual(segment?.style, .warning)

    XCTAssertFalse(applet.canStep(.next))
    XCTAssertFalse(applet.segments.contains { $0.symbolName == "folder" })

    applet.step(.next)
    XCTAssertEqual(applet.committedName, "a.png")
    XCTAssertEqual(warnings(host).filter { $0.contains("could not be listed") }.count, 1)
  }

  /// Catches a single-file restore that shows the stored file instead of the image the user had
  /// stepped to. The stored path is found, and the current image of its folder shows.
  func testARestoredFileShowsTheCurrentImageOfItsFolder() async throws {
    try write("a.png", "b.png", "c.png")

    let record = ImageViewerDescription(
      startDirectory: folder.path, path: folder.appendingPathComponent("a.png").path, kind: .file,
      current: "c.png", currentModified: 0, sort: .name)
    let (applet, _) = try panes.restored(record)

    applet.start(origin: .restore)

    let shown = await shows(applet, "c.png")
    XCTAssertTrue(shown)
  }

  /// Catches a single-file restore that fails when the stored file is gone but its folder and the
  /// current image remain. The pane opens the current image in the old folder and says where.
  func testARestoredFileWhoseSourceIsGoneOpensTheCurrentImageInTheOldFolder() async throws {
    try write("b.png", "c.png")

    let record = ImageViewerDescription(
      startDirectory: folder.path, path: folder.appendingPathComponent("a.png").path, kind: .file,
      current: "c.png", currentModified: 0, sort: .name)
    let (applet, host) = try panes.restored(record)

    applet.start(origin: .user)

    let shown = await shows(applet, "c.png")
    XCTAssertTrue(shown)
    XCTAssertTrue(host.posts.contains { $0.text.hasPrefix("Moved. Found at") })

    guard case .object(let payload) = applet.describe().payload,
      case .string(let path) = payload["path"]
    else { return XCTFail("no path") }

    XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "c.png")
  }

  // MARK: Prefetch

  /// Catches a step that decodes an image twice. The next image is decoded at fit size while the
  /// pane is idle. Stepping to it shows that decode with no new request to the helper, the image
  /// left is kept, and stepping back uses it the same way.
  func testStepsToThePrefetchedAndThePreviousImageNeedNoDecode() async throws {
    try write("a.png", "b.png", "c.png")

    let (applet, _) = panes.make()
    try await openFolder(applet, showing: "a.png")

    let ready = await Harness.eventually { applet.cache.prefetched?.name == "b.png" }
    XCTAssertTrue(ready)

    let process = applet.client.processID
    let decodes = applet.client.decodesSent

    applet.step(.next)

    XCTAssertEqual(applet.committedName, "b.png", "the cached decode shows at once")
    XCTAssertEqual(applet.client.decodesSent, decodes)
    XCTAssertEqual(applet.cache.previous?.name, "a.png")

    applet.step(.previous)

    XCTAssertEqual(applet.committedName, "a.png", "the kept decode shows at once")
    XCTAssertEqual(applet.client.decodesSent, decodes)
    XCTAssertEqual(applet.client.processID, process)
  }

  /// Catches a step taken while the prefetch is still preparing the next image decoding it twice.
  /// Whichever way the timing falls, three images take three decodes: the first, the second, and the
  /// prefetch of the third.
  func testSteppingRightAfterTheFirstImageNeverDecodesAnImageTwice() async throws {
    try write("a.png", "b.png", "c.png")

    let (applet, _) = panes.make()
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let first = await shows(applet, "a.png")
    XCTAssertTrue(first)

    applet.step(.next)

    let second = await shows(applet, "b.png")
    XCTAssertTrue(second)

    let third = await Harness.eventually { applet.cache.prefetched?.name == "c.png" }
    XCTAssertTrue(third)
    XCTAssertEqual(applet.client.decodesSent, 3)
  }

  /// Catches a failing prefetch spoiling the image on screen. The next file crashes the decoder
  /// when it decodes. The pane keeps showing the current image with no message, and the failure
  /// appears only when the user steps to the file.
  func testAPrefetchFailureIsSilentUntilTheUserStepsThere() async throws {
    try write("a.png")
    try ImageFixtures.write(ImageFixtures.fault("crash"), named: "b.png", in: folder)
    try write("c.png")

    let (applet, host) = panes.make()
    try await openFolder(applet, showing: "a.png")

    let failed = await Harness.eventually { applet.prefetchFailed.contains("b.png") }
    XCTAssertTrue(failed)
    XCTAssertEqual(applet.phase, .showing)
    XCTAssertEqual(applet.committedName, "a.png")
    XCTAssertTrue(warnings(host).isEmpty, "\(warnings(host))")

    applet.step(.next)

    let shown = await Harness.eventually {
      if case .problem(let message) = applet.phase {
        return message.text.contains("decoder stopped")
      }

      return false
    }

    XCTAssertTrue(shown)
    XCTAssertTrue(warnings(host).contains { $0.contains("decoder stopped") })

    applet.step(.next)
    let recovered = await shows(applet, "c.png")
    XCTAssertTrue(recovered, "a fresh helper decodes the next image")
  }

  /// Catches a zoomed pane prefetching. The prefetch's open is held while the user zooms in, and
  /// the pane drops it, so the helper keeps the one fit decode and its tiles and decodes nothing
  /// of the next image.
  func testAPaneZoomedPastFitNeverPrefetches() async throws {
    try write("a.png", "b.png")

    let gate = OpenGate()
    let (applet, _) = panes.make()

    applet.prefetchOpener = { folder, name in
      await gate.wait()

      return await SourceLoader.openImage(in: folder, named: name)
    }

    try await openFolder(applet, showing: "a.png")

    let waiting = await Harness.eventually { applet.prefetch != nil }
    XCTAssertTrue(waiting)

    applet.zoomIn()
    XCTAssertTrue(applet.isZoomedPastFit)
    XCTAssertNil(applet.prefetch)

    await gate.release()

    let settled = await Harness.eventually { applet.prefetchTask == nil }
    XCTAssertTrue(settled)
    XCTAssertNil(applet.prefetch)
    XCTAssertNil(applet.cache.prefetched)
    XCTAssertFalse(applet.client.prefetchInFlight)
  }

  /// Catches a sort or a reload leaving a prefetch of the old neighbor behind. Sorting drops the
  /// prefetched image, and the pane prefetches the new neighbor.
  func testSortingReplacesThePrefetchedImage() async throws {
    for (name, time) in [("a.png", 100.0), ("b.png", 200.0), ("c.png", 300.0)] {
      let file = try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)

      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: file.path)
    }

    let (applet, _) = panes.make()
    try await openFolder(applet, showing: "a.png")

    let byName = await Harness.eventually { applet.cache.prefetched?.name == "b.png" }
    XCTAssertTrue(byName)

    applet.setSort(.dateModified)

    let byDate = await Harness.eventually {
      applet.listing.position(ofName: "a.png") == 2 && applet.cache.prefetched == nil
        && applet.prefetch == nil
    }
    XCTAssertTrue(byDate, "the neighbor in date order is the end of the list, so nothing follows")
  }

  /// Catches a prefetch that a newer request replaced in the scheduler stranding the pane. An
  /// animation keeps frame requests flowing, which replace a waiting prefetch. Stepping to the
  /// image that was being prefetched must still show it.
  func testAStepToAnImageWhosePrefetchWasReplacedStillShowsIt() async throws {
    let gif = ImageFixtures.animatedGIF(
      colors: [ImageFixtures.red, ImageFixtures.green, ImageFixtures.blue],
      delays: [0.02, 0.02, 0.02], size: 1200)

    try ImageFixtures.write(gif, named: "a.gif", in: folder)
    try write("b.png")

    let (applet, _) = panes.make()
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let first = await shows(applet, "a.gif")
    XCTAssertTrue(first)

    let preparing = await Harness.eventually {
      applet.prefetch != nil || applet.cache.prefetched != nil
    }
    XCTAssertTrue(preparing)

    applet.step(.next)

    let stepped = await Harness.eventually(seconds: 5) { applet.committedName == "b.png" }
    XCTAssertTrue(stepped, "the step hung on a prefetch the scheduler dropped")
  }

  /// Catches a prefetch's file open stranded when the pane leaves the screen. The open is held, the pane
  /// leaves the screen and returns, and a step to that image still shows it.
  func testLeavingTheScreenDuringAPrefetchOpenDoesNotStrandTheNextStep() async throws {
    try write("a.png", "b.png")

    let gate = OpenGate()
    let (applet, _) = panes.make()
    let calls = OSAllocatedUnfairLock(initialState: 0)
    applet.prefetchOpener = { folder, name in
      let call = calls.withLock {
        $0 += 1
        return $0
      }

      if call == 1 { await gate.wait() }

      return await SourceLoader.openImage(in: folder, named: name)
    }

    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let first = await shows(applet, "a.png")
    XCTAssertTrue(first)

    let held = await Harness.eventually { applet.prefetchTask != nil }
    XCTAssertTrue(held)

    applet.leaveScreen()
    applet.returnToScreen()
    applet.step(.next)

    let stepped = await Harness.eventually(seconds: 5) { applet.committedName == "b.png" }
    XCTAssertTrue(stepped, "the step hung on a job that leaving the screen abandoned")

    await gate.release()
  }

  /// Catches a step that the window never saves. The window saves the layout when a pane reports a
  /// change and its description differs. A step changes the title and the description's current
  /// image, so the pane reports it, and a relaunch restores the stepped-to image.
  func testAStepReportsAChangeAndTheDescriptionNamesTheNewImage() async throws {
    try write("a.png", "b.png")

    let (applet, host) = panes.make()
    try await openFolder(applet, showing: "a.png")

    let before = host.changes

    applet.step(.next)

    XCTAssertGreaterThan(host.changes, before)

    guard case .object(let payload) = applet.describe().payload,
      case .string(let current) = payload["current"]
    else { return XCTFail("no current image") }

    XCTAssertEqual(current, "b.png")
  }
}
