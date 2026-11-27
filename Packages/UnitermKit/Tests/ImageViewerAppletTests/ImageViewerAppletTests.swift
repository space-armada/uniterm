import AppKit
import AppletKit
import AppletTestSupport
import ImageTestSupport
import ImageViewerModel
import ImageWire
import StatusKit
import XCTest

@testable import ImageViewerApplet

/// Drives the applet against a real helper process. Each test names a contract of the pane: what it
/// shows, what it saves, what it refuses, and what it says when something goes wrong.
@MainActor
final class ImageViewerAppletTests: XCTestCase {
  private var folder: URL!
  private var applets: [ImageViewerApplet] = []

  override func setUp() async throws {
    folder = try ImageFixtures.makeFolder()
  }

  override func tearDown() async throws {
    for applet in applets { applet.close() }

    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  @discardableResult
  private func make(
    settings: HelperSettings? = nil, helperBudget: ImageHelperBudget? = nil,
    bitmapBudget: ImageBitmapBudget? = nil, startDirectory: String? = nil
  ) -> (ImageViewerApplet, RecordingHost) {
    let applet = ImageViewerApplet(
      startDirectory: startDirectory ?? folder.path, settings: settings ?? Harness.settings(),
      helperBudget: helperBudget ?? ImageHelperBudget(limit: 8 << 30, floor: 1 << 30),
      bitmapBudget: bitmapBudget ?? ImageBitmapBudget(limit: 1 << 30, floor: 256 << 20))
    let host = RecordingHost()

    applet.host = host
    applet.view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    applet.view.layoutSubtreeIfNeeded()
    applets.append(applet)

    return (applet, host)
  }

  private func restored(
    _ description: AppletDescription, settings: HelperSettings? = nil,
    helperBudget: ImageHelperBudget? = nil, bitmapBudget: ImageBitmapBudget? = nil
  ) throws -> (ImageViewerApplet, RecordingHost) {
    let applet = try ImageViewerApplet(
      restoring: description, settings: settings ?? Harness.settings(),
      helperBudget: helperBudget ?? ImageHelperBudget(limit: 8 << 30, floor: 1 << 30),
      bitmapBudget: bitmapBudget ?? ImageBitmapBudget(limit: 1 << 30, floor: 256 << 20))
    let host = RecordingHost()

    applet.host = host
    applet.view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    applet.view.layoutSubtreeIfNeeded()
    applets.append(applet)

    return (applet, host)
  }

  private func showing(_ applet: ImageViewerApplet) async -> Bool {
    await Harness.eventually { applet.phase == .showing }
  }

  private func problem(_ applet: ImageViewerApplet) -> PaneMessage? {
    if case .problem(let message) = applet.phase { return message }

    return nil
  }

  // MARK: Showing

  /// Catches a pane that cannot show a chosen image. A PNG opens through the one source entry point,
  /// and the pane titles its tab with the file name and reports the size in the status bar.
  func testOpeningAFileShowsItAndNamesTheTab() async throws {
    let file = try ImageFixtures.write(
      ImageFixtures.png(width: 400, height: 200), named: "shot.png", in: folder)
    let (applet, _) = make()

    try applet.replaceSource(with: file, startDirectory: folder.path)

    let opened = await showing(applet)

    XCTAssertTrue(opened)
    XCTAssertEqual(applet.title, "shot.png")
    XCTAssertEqual(applet.publishedTabs.first.title, "shot.png")
    XCTAssertEqual(applet.segments.first?.text, "400 \u{00D7} 200")
    XCTAssertEqual(applet.shownSpace, .sRGB)
    XCTAssertFalse(applet.isRunningSomething)
  }

  /// Catches an Open in This Pane that drops the pane's image when the chosen file is not an
  /// image. The pane keeps showing its image and its saved path, and the status bar names the file.
  func testAFailedOpenInThisPaneKeepsTheOldImageAndWarns() async throws {
    let good = try ImageFixtures.write(
      ImageFixtures.png(width: 400, height: 200), named: "shot.png", in: folder)
    let bad = folder.appendingPathComponent("notes.txt")
    try Data("not an image".utf8).write(to: bad)

    let (applet, host) = make()

    try applet.replaceSource(with: good, startDirectory: folder.path)
    let opened = await showing(applet)
    XCTAssertTrue(opened)

    await applet.replaceSource(withChosen: bad).value

    XCTAssertEqual(applet.phase, .showing)
    XCTAssertEqual(applet.title, "shot.png")
    XCTAssertEqual(applet.segments.first?.text, "400 \u{00D7} 200")
    XCTAssertEqual(try ImageViewerDescription.decode(applet.describe()).path, good.path)

    let warned = host.sent.contains { $0.level == .warning && $0.text.contains("notes.txt") }
    XCTAssertTrue(warned, "\(host.sent)")
  }

  /// Catches an image that does not fit the pane, or that is enlarged past its own size. A large
  /// image shrinks to the pane and keeps its aspect ratio, and a small one stays its own size.
  func testTheImageFitsThePaneAndASmallOneIsNeverEnlarged() async throws {
    let big = try ImageFixtures.write(
      ImageFixtures.png(width: 1000, height: 500), named: "big.png", in: folder)
    let small = try ImageFixtures.write(
      ImageFixtures.png(width: 40, height: 20), named: "small.png", in: folder)
    let (applet, _) = make()

    try applet.replaceSource(with: big, startDirectory: folder.path)
    let bigShown = await showing(applet)
    XCTAssertTrue(bigShown)
    applet.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(applet.content.imageFrame?.size, CGSize(width: 300, height: 150))

    try applet.replaceSource(with: small, startDirectory: folder.path)
    let smallShown = await Harness.eventually {
      applet.phase == .showing && applet.title == "small.png"
    }
    XCTAssertTrue(smallShown)
    applet.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(applet.content.imageFrame?.size, CGSize(width: 40, height: 20))
  }

  /// Catches a resize that leaves the image at the old size or blurry. Growing the pane rescales
  /// the image at once and asks the helper for more pixels, so the bitmap held grows with the pane.
  func testResizingThePaneRescalesTheImageAndSharpensIt() async throws {
    let file = try ImageFixtures.write(
      ImageFixtures.png(width: 2000, height: 1000), named: "wide.png", in: folder)
    let (applet, _) = make()

    applet.view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
    applet.view.layoutSubtreeIfNeeded()

    try applet.replaceSource(with: file, startDirectory: folder.path)
    let first = await showing(applet)
    XCTAssertTrue(first)

    let before = try XCTUnwrap(applet.shownPixels).longer

    applet.view.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
    applet.view.layoutSubtreeIfNeeded()

    XCTAssertEqual(applet.content.imageFrame?.size, CGSize(width: 800, height: 400))

    let sharper = await Harness.eventually { (applet.shownPixels?.longer ?? 0) > before }
    XCTAssertTrue(sharper)
  }

  /// Catches a folder that opens anywhere but its first image, and a position segment that is
  /// missing. The pane lists the folder off the main thread and shows the first image in Finder
  /// order.
  func testAFolderOpensOnItsFirstImage() async throws {
    for name in ["img10.png", "img2.png", "img1.png"] {
      try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)
    }

    let (applet, _) = make()
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let opened = await showing(applet)
    XCTAssertTrue(opened)
    XCTAssertEqual(applet.title, "img1.png")

    let counted = await Harness.eventually { applet.segments.last?.text == "1 of 3" }
    XCTAssertTrue(counted)
    XCTAssertEqual(applet.currentDirectory, folder.path)
  }

  /// Catches a file that is not an image opening anyway, and a failure that leaves the pane blank.
  /// The pane says the file is not an image and offers Open again.
  func testAFileThatIsNotAnImageSaysSo() async throws {
    let text = try ImageFixtures.write(Data("hello".utf8), named: "notes.txt", in: folder)
    let (applet, _) = make()

    try applet.replaceSource(with: text, startDirectory: folder.path)

    let failed = await Harness.eventually { self.problem(applet) != nil }
    XCTAssertTrue(failed)
    XCTAssertTrue(problem(applet)?.text.contains("not an image") ?? false)
    XCTAssertTrue(problem(applet)?.offersOpen ?? false)
  }

  /// Catches an image that crashes the decoder taking the pane's other states with it. The pane says
  /// why, offers a retry, and a retry after the file is replaced by a good image shows it.
  func testACrashingFileShowsAMessageAndRetryRecovers() async throws {
    let file = try ImageFixtures.write(ImageFixtures.fault("crash"), named: "bad.png", in: folder)
    let (applet, _) = make()

    try applet.replaceSource(with: file, startDirectory: folder.path)

    let failed = await Harness.eventually { self.problem(applet) != nil }
    XCTAssertTrue(failed)
    XCTAssertTrue(problem(applet)?.text.contains("decoder stopped") ?? false)
    XCTAssertTrue(problem(applet)?.offersRetry ?? false)

    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: ImageFixtures.png())
    try handle.close()

    applet.retry()

    let shown = await showing(applet)
    XCTAssertTrue(shown)
  }

  /// Catches a decode killed for overrunning its bound being offered as a retry. The pane says the
  /// image is past the limit and offers no retry.
  func testAnOverrunReportsALimitWithNoRetry() async throws {
    let file = try ImageFixtures.write(ImageFixtures.fault("spin"), named: "slow.png", in: folder)
    let (applet, _) = make(settings: Harness.settings(timeBound: .milliseconds(400)))

    try applet.replaceSource(with: file, startDirectory: folder.path)

    let failed = await Harness.eventually { self.problem(applet) != nil }
    XCTAssertTrue(failed)
    XCTAssertTrue(problem(applet)?.text.contains("past the limit") ?? false)
    XCTAssertFalse(problem(applet)?.offersRetry ?? true)
  }

  /// Catches an app and a helper of different versions showing a blank pane. The pane tells the
  /// user to relaunch uniterm.
  func testAVersionMismatchTellsTheUserToRelaunch() async throws {
    let location = try Harness.scriptHelper(
      writing: "\\001\\000\\000\\000\\004\\000\\143\\000\\000")
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    let (applet, _) = make(settings: Harness.settings(location: location))

    try applet.replaceSource(with: file, startDirectory: folder.path)

    let failed = await Harness.eventually { self.problem(applet) != nil }
    XCTAssertTrue(failed)
    XCTAssertTrue(problem(applet)?.text.contains("Relaunch uniterm") ?? false)
  }

  // MARK: Drops

  /// Catches a drop of several items replacing the pane's image. Several items are refused with a
  /// warning, a drop with no file URL warns why, and the pane keeps what it showed. One item
  /// replaces the source.
  func testDropRefusalsWarnAndKeepTheImage() async throws {
    let first = try ImageFixtures.write(ImageFixtures.png(), named: "one.png", in: folder)
    let second = try ImageFixtures.write(ImageFixtures.png(), named: "two.png", in: folder)
    let (applet, host) = make()

    try applet.replaceSource(with: first, startDirectory: folder.path)
    let shown = await showing(applet)
    XCTAssertTrue(shown)

    XCTAssertFalse(applet.handleDrop([first, second]))
    XCTAssertFalse(applet.handleDrop([]))

    XCTAssertEqual(host.posts.map(\.level), [.warning, .warning])
    XCTAssertTrue(host.posts[0].text.contains("one file or folder"))
    XCTAssertTrue(host.posts[1].text.contains("Finder"))
    XCTAssertEqual(applet.phase, .showing)
    XCTAssertEqual(applet.title, "one.png")

    XCTAssertTrue(applet.handleDrop([second]))

    let replaced = await Harness.eventually {
      applet.title == "two.png" && applet.phase == .showing
    }
    XCTAssertTrue(replaced)
  }

  // MARK: Description

  /// Catches a description that stores image data, drifts in its key set, or changes between two
  /// calls. The payload holds the path, kind, bookmark, current image, and sort, and describing
  /// reads memory only: it works after the file is gone.
  func testTheDescriptionHoldsTheSourceAndNoImageDataAndIsStable() async throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    let (applet, _) = make()

    try applet.replaceSource(with: file, startDirectory: folder.path)
    let shown = await showing(applet)
    XCTAssertTrue(shown)

    let description = applet.describe()

    XCTAssertEqual(description.type, "image-viewer")
    XCTAssertEqual(description.version, 1)

    guard case .object(let payload) = description.payload else { return XCTFail("not an object") }

    XCTAssertEqual(
      Set(payload.keys),
      ["startDirectory", "path", "kind", "bookmark", "current", "currentModified", "sort"])

    try FileManager.default.removeItem(at: file)

    XCTAssertEqual(applet.describe(), description)
    XCTAssertEqual(applet.describe(), applet.describe())
    XCTAssertLessThan(
      (try? JSONEncoder().encode(description).count) ?? .max, 4096, "no pixels in the layout file")
  }

  /// Catches a relaunch that loses the source or the current image. A folder pane restores from its
  /// description and shows the same image at fit, paused.
  func testARestoredPaneShowsTheSameImage() async throws {
    for name in ["a.png", "b.png", "c.png"] {
      try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)
    }

    let description = AppletDescription(
      type: "image-viewer", version: 1,
      payload: try JSONValue(
        encoding: ImageViewerDescription(
          startDirectory: folder.path, path: folder.path, kind: .folder, current: "b.png",
          currentModified: 0, sort: .name)))

    let (applet, _) = try restored(description)

    XCTAssertEqual(applet.phase, .empty, "restoring touches nothing")

    applet.start(origin: .restore)

    let shown = await showing(applet)
    XCTAssertTrue(shown)
    XCTAssertEqual(applet.title, "b.png")

    let counted = await Harness.eventually { applet.segments.last?.text == "2 of 3" }
    XCTAssertTrue(counted)
    XCTAssertFalse(applet.isAnimating)
  }

  /// Catches a restore that cannot find a renamed folder, or that stays silent about it. The
  /// bookmark finds the folder, the pane says where, and the stored path becomes the new one.
  func testAMovedSourceIsFoundThroughItsBookmarkAndThePaneSaysWhere() async throws {
    try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)

    let (first, _) = make()
    try first.replaceSource(with: folder, startDirectory: folder.path)
    let shown = await showing(first)
    XCTAssertTrue(shown)

    let saved = first.describe()
    let moved = folder.deletingLastPathComponent().appendingPathComponent("elsewhere")
    try FileManager.default.moveItem(at: folder, to: moved)
    defer { try? FileManager.default.removeItem(at: moved) }

    let (second, host) = try restored(saved)
    second.start(origin: .user)

    let found = await showing(second)
    XCTAssertTrue(found)
    XCTAssertTrue(host.posts.contains { $0.text.hasPrefix("Moved. Found at") })

    guard case .object(let payload) = second.describe().payload,
      case .string(let path) = payload["path"]
    else { return XCTFail("no path") }

    XCTAssertEqual(
      URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
      moved.resolvingSymlinksInPath().path)
  }

  /// Catches an empty pane that forgets where it started, and an open panel that starts somewhere
  /// else. The empty pane reports its start directory, and a gone folder falls back to the start
  /// directory, then to nil.
  func testCurrentDirectoryFallsBackFromTheViewedFolderToTheStartDirectory() async throws {
    let start = try ImageFixtures.makeFolder("start")
    defer { try? FileManager.default.removeItem(at: start.deletingLastPathComponent()) }

    let (applet, _) = make(startDirectory: start.path)
    XCTAssertEqual(applet.currentDirectory, start.path)

    let viewed = try ImageFixtures.makeFolder("viewed")
    defer { try? FileManager.default.removeItem(at: viewed.deletingLastPathComponent()) }
    try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: viewed)

    try applet.replaceSource(with: viewed, startDirectory: start.path)
    let shown = await showing(applet)
    XCTAssertTrue(shown)
    XCTAssertEqual(applet.currentDirectory, viewed.path)

    try FileManager.default.removeItem(at: viewed)
    XCTAssertEqual(applet.currentDirectory, start.path)

    try FileManager.default.removeItem(at: start)
    XCTAssertNil(applet.currentDirectory)
  }

  /// Catches an empty pane that does not reopen empty. Its description holds no source and its
  /// restored twin shows the open prompt.
  func testAnEmptyPaneReopensEmptyInItsStartDirectory() throws {
    let (applet, _) = make()

    let (again, _) = try restored(applet.describe())
    again.start(origin: .restore)

    XCTAssertEqual(again.phase, .empty)
    XCTAssertEqual(again.currentDirectory, folder.path)
    XCTAssertEqual(again.describe(), applet.describe())
  }

  /// Catches a description from a newer build being read as if it were this one's.
  func testADescriptionOfANewerVersionIsRefused() {
    let newer = AppletDescription(type: "image-viewer", version: 2, payload: .object([:]))

    XCTAssertThrowsError(try ImageViewerApplet(restoring: newer))
  }

  /// Catches the open panel offering the wrong types. Before a helper answers, it accepts images
  /// by conformance. Once the helper lists its types, the panel narrows to them, PDF excluded.
  func testTheOpenPanelAcceptsImagesAndNarrowsToTheHelpersTypes() async throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    let (applet, _) = make()

    XCTAssertEqual(applet.openPanelContentTypes?.map(\.identifier), ["public.image"])

    try applet.replaceSource(with: file, startDirectory: folder.path)
    let shown = await showing(applet)
    XCTAssertTrue(shown)

    let identifiers = applet.openPanelContentTypes?.map(\.identifier) ?? []

    XCTAssertTrue(identifiers.contains("public.png"))
    XCTAssertFalse(identifiers.contains("com.adobe.pdf"))
  }

  // MARK: Close

  /// Catches a close that asks. The image viewer is never running something, so closing never asks
  /// and the helper goes with the pane.
  func testClosingNeverAsksAndEndsTheHelper() async throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    let (applet, host) = make()

    try applet.replaceSource(with: file, startDirectory: folder.path)
    let shown = await showing(applet)
    XCTAssertTrue(shown)
    XCTAssertTrue(applet.client.isRunning)

    XCTAssertFalse(applet.isRunningSomething)
    XCTAssertEqual(applet.runningLabels, [])

    applet.close()

    XCTAssertFalse(applet.client.isRunning)
    XCTAssertTrue(host.confirmations.isEmpty)
  }

  // MARK: Animation

  /// Catches an animation that does not play, or that keeps playing off screen. The GIF steps its
  /// frames, stops off screen, and resumes on return only because it was playing.
  func testAnAnimationPlaysAndPausesOffScreen() async throws {
    let gif = ImageFixtures.animatedGIF(
      colors: [ImageFixtures.red, ImageFixtures.green, ImageFixtures.blue],
      delays: [0.05, 0.05, 0.05])
    let file = try ImageFixtures.write(gif, named: "loop.gif", in: folder)
    let (applet, _) = make()

    try applet.replaceSource(with: file, startDirectory: folder.path)
    let shown = await showing(applet)
    XCTAssertTrue(shown)
    XCTAssertTrue(applet.segments.contains { $0.text == "3 frames" })

    let advanced = await Harness.eventually { applet.isAnimating && applet.frameIndex != 0 }
    XCTAssertTrue(advanced)

    applet.leaveScreen()
    XCTAssertFalse(applet.isAnimating)

    applet.returnToScreen()
    XCTAssertTrue(applet.isAnimating)
  }

  /// Catches an animation holding more bitmaps than the budget allows. With room for the first
  /// frame and no more, the pane keeps showing its image, stops the animation, and says why on the
  /// status bar.
  func testAnAnimationThatCannotFitItsFramesPausesWithAWarning() async throws {
    let gif = ImageFixtures.animatedGIF(
      colors: [ImageFixtures.red, ImageFixtures.green, ImageFixtures.blue],
      delays: [0.05, 0.05, 0.05])
    let file = try ImageFixtures.write(gif, named: "loop.gif", in: folder)
    let (applet, host) = make(bitmapBudget: ImageBitmapBudget(limit: 1, floor: 1500))

    try applet.replaceSource(with: file, startDirectory: folder.path)

    let paused = await Harness.eventually {
      host.posts.contains { $0.text.contains("animation paused") }
    }

    XCTAssertTrue(paused)
    XCTAssertEqual(applet.phase, .showing)
    XCTAssertFalse(applet.isAnimating)
  }

  // MARK: Budgets

  /// Catches a pane that is blank when memory is short. With the bitmap budget spent and no floor,
  /// the pane says why and offers a retry.
  func testASpentBitmapBudgetShowsAMessageNotABlankPane() async throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    let (applet, _) = make(bitmapBudget: ImageBitmapBudget(limit: 1, floor: 0))

    try applet.replaceSource(with: file, startDirectory: folder.path)

    let failed = await Harness.eventually { self.problem(applet) != nil }
    XCTAssertTrue(failed)
    XCTAssertTrue(problem(applet)?.text.contains("not enough memory") ?? false)
    XCTAssertTrue(problem(applet)?.offersRetry ?? false)
  }

  /// Catches a helper budget with no room leaving a pane blank. Without a floor the pane says why.
  func testASpentHelperBudgetShowsAMessage() async throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    let (applet, _) = make(helperBudget: ImageHelperBudget(limit: 1, floor: 0))

    try applet.replaceSource(with: file, startDirectory: folder.path)

    let failed = await Harness.eventually { self.problem(applet) != nil }
    XCTAssertTrue(failed)
    XCTAssertTrue(problem(applet)?.text.contains("all the memory") ?? false)
  }

  /// Catches many image panes restored at launch leaving some blank. Every pane keeps a floor in
  /// both budgets, so six panes that share tiny budgets all show their images at fit.
  func testManyRestoredPanesAllShowTheirImageWhenTheBudgetsAreTiny() async throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    let helperBudget = ImageHelperBudget(limit: 1, floor: 512 << 20)
    let bitmapBudget = ImageBitmapBudget(limit: 1, floor: 64 << 20)

    let description = AppletDescription(
      type: "image-viewer", version: 1,
      payload: try JSONValue(
        encoding: ImageViewerDescription(
          startDirectory: folder.path, path: file.path, kind: .file, current: "a.png")))

    var panes: [ImageViewerApplet] = []

    for _ in 0..<6 {
      let (pane, _) = try restored(
        description, helperBudget: helperBudget, bitmapBudget: bitmapBudget)
      pane.start(origin: .restore)
      panes.append(pane)
    }

    for pane in panes {
      let shown = await showing(pane)

      XCTAssertTrue(shown, "\(String(describing: pane.phase))")
    }
  }
}
