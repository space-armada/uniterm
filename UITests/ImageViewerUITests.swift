import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Drives the image viewer in the launched app, with the real signed and sandboxed helper. Each
/// test proves a contract that needs the real window server: the launcher entry, the open panel,
/// the pane's layout, a layout that comes back over a relaunch, and a close that never asks.
///
/// The color checks cannot be automated. Two tests attach screenshots of a Display P3 image and an
/// animated image, and the person reading the run compares them with Preview.
@MainActor
final class ImageViewerUITests: UnitermUITestCase {
  private let closeWindowsOnQuit = ["-NSQuitAlwaysKeepsWindows", "NO"]

  private func makeFolder() throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-images-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    return folder
  }

  private func bitmap(
    width: Int, height: Int, space: CGColorSpace, fill: (Int, Int) -> (UInt8, UInt8, UInt8)
  ) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)

    for y in 0..<height {
      for x in 0..<width {
        let color = fill(x, y)
        let at = (y * width + x) * 4
        bytes[at] = color.0
        bytes[at + 1] = color.1
        bytes[at + 2] = color.2
      }
    }

    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }

  @discardableResult
  private func writePNG(
    _ name: String, in folder: URL, width: Int = 400, height: Int = 200,
    space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  ) throws -> URL {
    let picture = bitmap(width: width, height: height, space: space) { x, y in
      (UInt8(x * 255 / width), UInt8(y * 255 / height), 128)
    }

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, picture, nil)
    CGImageDestinationFinalize(destination)

    let file = folder.appendingPathComponent(name)
    try (data as Data).write(to: file)

    return file
  }

  /// A large PNG of four solid quadrants. The fills are rectangles, so a big image costs four
  /// calls and not a closure per pixel.
  @discardableResult
  private func writeLargePNG(
    _ name: String, in folder: URL, width: Int = 3000, height: Int = 2000
  ) throws -> URL {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let halfWidth = CGFloat(width / 2)
    let halfHeight = CGFloat(height / 2)
    let quadrants: [(CGRect, [CGFloat])] = [
      (CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), [1, 0, 0]),
      (CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), [0, 1, 0]),
      (CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), [0, 0, 1]),
      (CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), [1, 1, 1]),
    ]

    for (rect, color) in quadrants {
      context.setFillColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
      context.fill(rect)
    }

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)

    let file = folder.appendingPathComponent(name)
    try (data as Data).write(to: file)

    return file
  }

  private func writeGIF(_ name: String, in folder: URL) throws -> URL {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.gif.identifier as CFString, 3, nil)!
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    CGImageDestinationSetProperties(
      destination,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

    for color in [(UInt8(255), UInt8(0), UInt8(0)), (0, 255, 0), (0, 0, 255)] {
      CGImageDestinationAddImage(
        destination, bitmap(width: 64, height: 64, space: space) { _, _ in color },
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]] as CFDictionary)
    }

    CGImageDestinationFinalize(destination)

    let file = folder.appendingPathComponent(name)
    try (data as Data).write(to: file)

    return file
  }

  private func plantViewer(path: String, kind: String, current: String? = nil) throws {
    let start =
      kind == "folder" ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
    let currentField = current.map { #","current":"\#($0)""# } ?? ""

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"image-viewer","version":1,
      "payload":{"startDirectory":"\(start)","path":"\(path)","kind":"\(kind)","sort":"name"\(currentField)}}}}]}
      """)
  }

  private func viewer(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["image-viewer"]
  }

  private func segment(_ index: Int, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: "status-applet-\(index)").firstMatch
  }

  /// Attaches a screenshot of the uniterm window only, so it carries nothing of the user's other
  /// windows.
  private func attachScreenshot(_ name: String, of window: XCUIElement) {
    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Catches a launcher without the image viewer, a pane that does not offer to open an image, and
  /// an open panel that does not end in a picture. Cmd-D shows the launcher, Cmd-6 picks the image
  /// viewer, and the pane's Open button opens a panel that loads the chosen PNG and reports its
  /// size in the status bar.
  func testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAnImage() throws {
    let file = try writePNG("shot.png", in: try makeFolder())
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("6", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 10), "no image viewer pane")

    let open = window.buttons["image-viewer-open"]
    XCTAssertTrue(open.waitForExistence(timeout: 5), "an empty viewer has no Open button")
    open.click()

    choose(file, in: app, window: window)

    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 20) { $0 == "400 \u{00D7} 200" },
      "the image never showed. The sandboxed helper may not have started.")
    XCTAssertFalse(
      window.buttons["image-viewer-open"].exists, "the Open button stays over the image")
    attachScreenshot("image viewer, sRGB PNG", of: window)
  }

  /// Catches a layout that loses the folder or its current image over a relaunch, and a restore that
  /// shows the wrong picture. A planted folder pane restores on its second image at fit, and a
  /// quit saves a layout that holds the path and no pixels.
  func testARestoredFolderPaneShowsItsCurrentImageAndSavesNoPixels() throws {
    let folder = try makeFolder()

    for name in ["a.png", "b.png", "c.png"] { try writePNG(name, in: folder) }

    try plantViewer(path: folder.path, kind: "folder", current: "b.png")

    let app = launchApp(
      environment: ["UNITERM_LAYOUT_DEBOUNCE": "3600"], arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no image viewer pane")
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 20) { $0 == "2 of 3" })

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8
    ).replacingOccurrences(of: "\\/", with: "/")

    XCTAssertTrue(written.contains(folder.path), "the path was not saved: \(written)")
    XCTAssertTrue(written.contains(#""current":"b.png""#))
    XCTAssertLessThan(written.utf8.count, 4096, "pixels were saved in the layout")
  }

  /// Catches a close that asks while an animation plays. Cmd-W on the second pane closes it with no
  /// sheet, and the terminal beside it keeps running.
  func testClosingAnAnimatingViewerNeverAsks() throws {
    let file = try writeGIF("loop.gif", in: try makeFolder())

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":1000,"height":600},"highWaterMark":3,
      "focusedPane":2,"tree":{"kind":"split","id":3,"axis":"row","children":[
      {"weight":0.5,"node":{"kind":"pane","id":1,"applet":{"type":"terminal","version":1,"payload":{}}}},
      {"weight":0.5,"node":{"kind":"pane","id":2,"applet":{"type":"image-viewer","version":1,
      "payload":{"startDirectory":"\(file.deletingLastPathComponent().path)","path":"\(file.path)","kind":"file","sort":"name"}}}}]}}]}
      """)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "64 \u{00D7} 64" })
    attachScreenshot("image viewer, animated GIF", of: window)

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitForNoSheet(in: window, timeout: 3), "closing the viewer asked a question")
    XCTAssertTrue(window.exists)
  }

  private func palette(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["command-palette"]
  }

  /// Catches view keys that do not step the folder in the real window. The arrows, Space,
  /// Shift-Space, Home, and End move through three differently sized images, and the position
  /// segment follows.
  func testViewKeysStepThroughAFolder() throws {
    let folder = try makeFolder()

    try writePNG("a.png", in: folder, width: 100, height: 100)
    try writePNG("b.png", in: folder, width: 200, height: 100)
    try writePNG("c.png", in: folder, width: 300, height: 100)
    try plantViewer(path: folder.path, kind: "folder", current: "a.png")

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 20) { $0 == "1 of 3" })
    viewer(in: window).click()

    app.typeKey(.rightArrow, modifierFlags: [])
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 10) { $0 == "200 \u{00D7} 100" })

    app.typeKey(.end, modifierFlags: [])
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "3 of 3" })

    app.typeKey(.leftArrow, modifierFlags: [])
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "2 of 3" })

    app.typeKey(.home, modifierFlags: [])
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "1 of 3" })

    app.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "2 of 3" })

    app.typeKey(" ", modifierFlags: [.shift])
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "1 of 3" })
  }

  /// Catches registry commands that are missing from the viewer's menu, or that do nothing. Next
  /// Image steps, and Play or Pause Slideshow shows and hides the slideshow segment.
  func testTheImageViewerMenuStepsAndTogglesTheSlideshow() throws {
    let folder = try makeFolder()

    try writePNG("a.png", in: folder, width: 100, height: 100)
    try writePNG("b.png", in: folder, width: 200, height: 100)
    try plantViewer(path: folder.path, kind: "folder", current: "a.png")

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 20) { $0 == "1 of 2" })
    viewer(in: window).click()

    let menu = app.menuBars.menuBarItems["Image Viewer"]
    XCTAssertTrue(menu.waitForExistence(timeout: 5), "no Image Viewer menu")

    menu.click()
    app.menuBars.menuItems["Next Image"].click()
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "2 of 2" })

    menu.click()
    app.menuBars.menuItems["Play or Pause Slideshow"].click()
    XCTAssertTrue(waitFor(segment(2, in: window), timeout: 10) { $0 == "Slideshow" })

    menu.click()
    app.menuBars.menuItems["Play or Pause Slideshow"].click()
    XCTAssertTrue(
      waitUntilGone(segment(2, in: window), timeout: 10), "pausing left the slideshow segment")
  }

  /// Catches an image viewer chord that reaches the menu before the palette's search field. With an
  /// image pane focused, Cmd-Left in the field moves the caret to the start, so the next letter
  /// lands in front of what was typed. The palette stays open.
  func testCommandLeftInThePaletteSearchFieldMovesTheCaretWhileAnImagePaneHasFocus() throws {
    let folder = try makeFolder()
    let file = try writePNG("a.png", in: folder)

    try plantViewer(path: file.path, kind: "file", current: "a.png")

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "400 \u{00D7} 200" })

    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(palette(in: app).waitForExistence(timeout: 5), "the palette never showed")

    let field = app.descendants(matching: .any)["command-palette-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))

    app.typeText("ab")
    app.typeKey(.leftArrow, modifierFlags: [.command])
    app.typeText("c")

    XCTAssertEqual(field.value as? String, "cab")
    XCTAssertTrue(palette(in: app).exists, "Cmd-Left closed the palette")
  }

  /// Catches zoom keys that do nothing in the real window. A 3000 by 2000 image fits the pane with
  /// no zoom segment. Cmd-0 shows it at 100 percent, Cmd-+ doubles that, and Cmd-9 returns to fit
  /// and drops the segment. The screenshots show the sharp detail for the person reading the run.
  func testZoomKeysShowActualSizeZoomInAndFit() throws {
    let file = try writeLargePNG("big.png", in: try makeFolder())

    try plantViewer(path: file.path, kind: "file", current: "big.png")

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0.contains("\u{00D7}") })
    XCTAssertFalse(segment(1, in: window).exists, "a fit image shows no zoom segment")
    viewer(in: window).click()

    app.typeKey("0", modifierFlags: .command)
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "100%" })
    attachScreenshot("image viewer, actual size", of: window)

    app.typeKey("+", modifierFlags: .command)
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "200%" })
    attachScreenshot("image viewer, 200 percent", of: window)

    app.typeKey("9", modifierFlags: .command)
    XCTAssertTrue(
      waitUntilGone(segment(1, in: window), timeout: 10), "Zoom to Fit left the zoom segment")
  }

  /// The color at `point` of the pane in a window-server screenshot, as red and green levels. The
  /// point is a fraction of the pane's width and height from its top left.
  private func color(
    of pane: XCUIElement, at point: CGVector = CGVector(dx: 0.5, dy: 0.5),
    settle: TimeInterval = 0.6
  ) throws -> (red: Int, green: Int) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: settle))

    let screenshot = pane.screenshot()
    let image = try XCTUnwrap(
      screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let x = min(image.width - 1, Int(CGFloat(image.width) * point.dx))
    let y = min(image.height - 1, Int(CGFloat(image.height) * point.dy))
    let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))

    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))

    return (Int(pixel[0]), Int(pixel[1]))
  }

  /// Catches a zoomed image that renders scrambled, and a drag that moves it against the user. The
  /// image is a gradient whose red grows to the right and whose green grows downward, so the
  /// color at a pane point names the image point under it. After Cmd-0, green must be higher
  /// at 75 percent of the pane's height than at 25 percent. A drag down and right must show
  /// content from further up and left, so both levels at the center fall.
  func testDragAndScrollMoveAZoomedImageTheRightWay() throws {
    let file = try writePNG("gradient.png", in: try makeFolder(), width: 2000, height: 2000)

    try plantViewer(path: file.path, kind: "file", current: "gradient.png")

    let app = launchApp()
    let window = mainWindow(in: app)

    // The size segment groups digits by locale, such as "2,000 × 2,000", so match its shape.
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0.contains("\u{00D7}") })

    let pane = viewer(in: window)

    pane.click()
    app.typeKey("0", modifierFlags: .command)
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "100%" })

    let upper = try color(of: pane, at: CGVector(dx: 0.5, dy: 0.25), settle: 2)
    let lower = try color(of: pane, at: CGVector(dx: 0.5, dy: 0.75))
    let tolerance = 3

    XCTAssertGreaterThan(
      lower.green, upper.green + tolerance,
      "green is \(upper.green) at 25 percent and \(lower.green) at 75 percent of the height")

    let start = try color(of: pane)
    let origin = pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

    origin.press(
      forDuration: 0.1,
      thenDragTo: origin.withOffset(CGVector(dx: 150, dy: 150)))

    let dragged = try color(of: pane)
    let dragX = dragged.red - start.red
    let dragY = dragged.green - start.green

    func direction(_ delta: Int) -> String {
      delta > 0 ? "up" : delta < 0 ? "down" : "nowhere"
    }

    XCTAssertLessThan(
      dragX, -tolerance,
      "a drag right moved the center red \(direction(dragX)) by \(dragX)")
    XCTAssertLessThan(
      dragY, -tolerance,
      "a drag down moved the center green \(direction(dragY)) by \(dragY)")
  }

  /// Catches a scroll that moves a zoomed image against the way a table moves. Both panes get
  /// the same `scroll(byDeltaX:deltaY:)`. The data viewer's table is an NSScrollView, so which way
  /// its rows go names the direction on this machine under its scroll setting. The image must
  /// move the same way. If the table's rows move up, the image shows content from further down, so
  /// green rises at a fixed point. If they move down, green falls.
  func testScrollMovesAZoomedImageTheWayATableMoves() throws {
    let csv = try makeFolder().appendingPathComponent("rows.csv")
    let rows = (0..<2000).map { String(format: "r%04d,x", $0) }

    try Data((["id,value"] + rows).joined(separator: "\n").utf8).write(to: csv)

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"data-viewer","version":1,
      "payload":{"startDirectory":"\(csv.deletingLastPathComponent().path)","path":"\(csv.path)"}}}}]}
      """)

    var app = launchApp()
    var window = mainWindow(in: app)
    let table = window.tables["data-viewer-table"]

    XCTAssertTrue(table.waitForExistence(timeout: 20), "no table")
    XCTAssertTrue(
      table.staticTexts["r0000"].waitForExistence(timeout: 10), "the table shows no rows")

    // The first row visible in the table, by the index in its first column. One snapshot reads the
    // whole tree in a single round trip. Querying cells one by one costs about a second each.
    func firstVisibleRow() throws -> Int? {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))

      // The table's own frame spans the whole document, so the visible part is the scroll view's.
      let visible = window.scrollViews.containing(.table, identifier: "data-viewer-table")
        .firstMatch.frame
      let root = try table.snapshot()
      var rows: [Int] = []

      func visit(_ node: any XCUIElementSnapshot) {
        if node.elementType == .staticText, visible.intersects(node.frame),
          let text = node.value as? String, text.hasPrefix("r"), let row = Int(text.dropFirst())
        {
          rows.append(row)
        }

        node.children.forEach(visit)
      }

      visit(root)

      return rows.min()
    }

    // Park in the middle, whichever way the first scroll goes, so the next one cannot hit an end.
    table.scroll(byDeltaX: 0, deltaY: -600)
    table.scroll(byDeltaX: 0, deltaY: 300)

    let before = try XCTUnwrap(try firstVisibleRow(), "no visible row")

    table.scroll(byDeltaX: 0, deltaY: 100)

    let after = try XCTUnwrap(try firstVisibleRow(), "no visible row after the scroll")

    XCTAssertNotEqual(before, after, "the table did not move for a scroll of +100")

    let tableContentMovedUp = after > before

    app.terminate()

    let file = try writePNG("gradient.png", in: try makeFolder(), width: 2000, height: 2000)

    try plantViewer(path: file.path, kind: "file", current: "gradient.png")

    app = launchApp()
    window = mainWindow(in: app)
    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0.contains("\u{00D7}") })

    let pane = viewer(in: window)

    pane.click()
    app.typeKey("0", modifierFlags: .command)
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "100%" })

    let start = try color(of: pane, settle: 2)

    pane.scroll(byDeltaX: 0, deltaY: 100)

    let scrolled = try color(of: pane)
    let change = scrolled.green - start.green
    let tolerance = 3

    XCTAssertGreaterThan(
      abs(change), tolerance, "a scroll of +100 left the center green at \(scrolled.green)")

    let tableWent = tableContentMovedUp ? "up" : "down"

    XCTAssertEqual(
      change > 0, tableContentMovedUp,
      "the table moved \(tableWent) and the center green changed by \(change)")
  }

  /// Catches the shared Actual Size title moving only the terminal's item. With one remap of
  /// "Actual Size" to Cmd-J, Cmd-0 no longer zooms the viewer and Cmd-J does.
  func testARemapOfActualSizeMovesTheViewersItemToo() throws {
    let file = try writeLargePNG("big.png", in: try makeFolder())

    try plantViewer(path: file.path, kind: "file", current: "big.png")

    let app = launchApp(arguments: ["-NSUserKeyEquivalents", #"{"Actual Size"="@j";}"#])
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0.contains("\u{00D7}") })
    viewer(in: window).click()

    app.typeKey("0", modifierFlags: .command)
    XCTAssertFalse(
      segment(1, in: window).waitForExistence(timeout: 2), "Cmd-0 still zooms the viewer")

    app.typeKey("j", modifierFlags: .command)
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0 == "100%" })
  }

  /// Catches a View menu without the viewer's zoom items, or items that do nothing. Zoom In is a
  /// menu item of the focused viewer, and choosing it shows the zoom segment.
  func testTheViewMenuZoomsTheImageViewer() throws {
    let file = try writeLargePNG("big.png", in: try makeFolder())

    try plantViewer(path: file.path, kind: "file", current: "big.png")

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0.contains("\u{00D7}") })
    viewer(in: window).click()

    app.menuBars.menuBarItems["View"].click()
    app.menuBars.menuItems["Zoom In"].click()

    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 10) { $0.hasSuffix("%") })
  }

  /// Attaches a Display P3 image for comparison with Preview. The green here lies outside sRGB, so
  /// a viewer that converts to sRGB shows a duller green than Preview does. The test only proves
  /// that the image shows. The comparison is left to the person reading the attachment.
  func testADisplayP3ImageShowsForComparisonWithPreview() throws {
    let folder = try makeFolder()
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let picture = bitmap(width: 400, height: 200, space: p3) { x, _ in
      x < 200 ? (30, 220, 70) : (220, 40, 40)
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, picture, nil)
    CGImageDestinationFinalize(destination)

    let file = folder.appendingPathComponent("p3.png")
    try (data as Data).write(to: file)
    try plantViewer(path: file.path, kind: "file", current: "p3.png")

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "400 \u{00D7} 200" })
    attachScreenshot("image viewer, Display P3 image (compare with Preview)", of: window)
  }
}
