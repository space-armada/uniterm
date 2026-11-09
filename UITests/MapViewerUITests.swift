import AppKit
import XCTest

/// Drives the map viewer in the launched app. Each test proves a contract that needs the real window
/// server: the launcher entry, the View menu's style commands, and a layout that keeps the style and
/// the region over a relaunch.
///
/// The map itself is MapKit's, and XCUITest sees little of it. The pane's status segment names the
/// style, and the map's accessibility value holds the style and the saved center.
@MainActor
final class MapViewerUITests: UnitermUITestCase {
  private let closeWindowsOnQuit = ["-NSQuitAlwaysKeepsWindows", "NO"]
  private let quitSavesOnly = ["UNITERM_LAYOUT_DEBOUNCE": "3600"]

  private func plantMap(payload: String) throws {
    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"map-viewer","version":1,
      "payload":\(payload)}}}]}
      """)
  }

  private func map(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["map-viewer"]
  }

  private func styleText(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: "status-applet-0").firstMatch
  }

  private func chooseStyle(_ title: String, in app: XCUIApplication) {
    let view = app.menuBars.menuBarItems["View"]
    view.click()

    let item = view.menus.menuItems[title]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "the View menu has no \(title)")
    item.click()
  }

  /// Catches a launcher without the map viewer, a pane that shows no map, and a style command that
  /// does not reach the pane. Cmd-D shows the launcher, Cmd-4 picks the map viewer, and each style
  /// in the View menu shows in the status bar and in the map's accessibility value. Cmd-2 and Cmd-3
  /// then reach the style commands, not the terminal's tab keys.
  func testLauncherOpensAMapAndTheViewMenuSwitchesItsStyle() throws {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("4", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(map(in: window).waitForExistence(timeout: 10), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Standard" })

    chooseStyle("Satellite Map", in: app)
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Satellite" })
    XCTAssertTrue(waitFor(map(in: window), timeout: 5) { $0.hasPrefix("satellite") })

    chooseStyle("Hybrid Map", in: app)
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Hybrid" })

    chooseStyle("Standard Map", in: app)
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Standard" })

    app.typeKey("2", modifierFlags: .command)
    XCTAssertTrue(
      waitFor(styleText(in: window), timeout: 10) { $0 == "Satellite" },
      "Cmd-2 did not reach the map's style command")

    app.typeKey("3", modifierFlags: .command)
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Hybrid" })
  }

  /// Catches a click on the map that leaves the focus mark on another pane. A map opens beside a
  /// terminal, a click moves focus to the terminal, and a click on the map brings it back.
  func testClickingTheMapFocusesItsPane() throws {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))
    app.typeKey("4", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(map(in: window).waitForExistence(timeout: 10), "no map pane")

    let terminalPane = window.groups["pane-1"]
    let mapPane = window.groups["pane-2"]

    terminalPane.textViews["terminal"].click()
    XCTAssertTrue(waitFor(terminalPane, timeout: 10) { $0 == "focused" })
    XCTAssertTrue(waitFor(mapPane, timeout: 10) { $0 == "unfocused" })

    window.descendants(matching: .any)["map-viewer-map"].click()
    XCTAssertTrue(
      waitFor(mapPane, timeout: 10) { $0 == "focused" }, "a click on the map left it unfocused")
  }

  /// Catches a place field the launcher never shows, a Cmd-L that does not reach the map, and a
  /// search that Escape cannot close. Nothing is typed, so the search sends nothing, and the UI
  /// tests turn off place names.
  func testThePlaceFieldShowsInTheLauncherAndCmdLOpensItOverTheMap() throws {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))
    app.typeKey("4", modifierFlags: .command)

    let launcherField = launcher(in: window).textFields["place-search-field"]
    XCTAssertTrue(launcherField.waitForExistence(timeout: 5), "no place field in the launcher")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(map(in: window).waitForExistence(timeout: 10), "no map pane")

    app.typeKey("l", modifierFlags: .command)
    let search = map(in: window).descendants(matching: .any)["place-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5), "Cmd-L showed no place search")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(search), "Escape left the place search over the map")
  }

  /// Catches a restore that drops the stored style or region. A planted layout names the hybrid
  /// style and a region over San Francisco, and the pane shows both.
  func testAPlantedStyleAndRegionComeBack() throws {
    try plantMap(
      payload:
        #"{"style":"hybrid","region":{"center":{"latitude":37.5,"longitude":-122.25},"span":{"latitudeDelta":0.5,"longitudeDelta":0.75}}}"#
    )

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(map(in: window).waitForExistence(timeout: 20), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Hybrid" })
    XCTAssertTrue(
      waitFor(map(in: window), timeout: 5) { $0 == "hybrid 37.50,-122.25" },
      "the map does not hold the stored region")
  }

  /// Catches a style that is chosen but not saved, and a stored style that this build does not
  /// know showing anything but the standard map. A satellite choice survives a quit and a relaunch,
  /// and a planted unknown style shows the standard map.
  func testTheStyleSurvivesARelaunchAndAnUnknownStyleShowsStandard() throws {
    try plantMap(payload: #"{"style":"standard"}"#)

    let first = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let firstWindow = mainWindow(in: first)

    XCTAssertTrue(map(in: firstWindow).waitForExistence(timeout: 20), "no map pane")

    chooseStyle("Satellite Map", in: first)
    XCTAssertTrue(waitFor(styleText(in: firstWindow), timeout: 10) { $0 == "Satellite" })

    first.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(first.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8)

    XCTAssertTrue(written.contains(#""style":"satellite""#), "the style was not saved: \(written)")

    let second = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let secondWindow = mainWindow(in: second)

    XCTAssertTrue(map(in: secondWindow).waitForExistence(timeout: 20), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: secondWindow), timeout: 10) { $0 == "Satellite" })

    second.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(second.wait(for: .notRunning, timeout: 15))

    try plantMap(payload: #"{"style":"terrain"}"#)

    let third = launchApp()
    let thirdWindow = mainWindow(in: third)

    XCTAssertTrue(map(in: thirdWindow).waitForExistence(timeout: 20), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: thirdWindow), timeout: 10) { $0 == "Standard" })
  }

  // MARK: Pins from a file

  private func makeGeoJSON(name: String = "places.geojson") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-map-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let file = folder.appendingPathComponent(name)
    let text = """
      {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"name":"Ferry Building"},
       "geometry":{"type":"Point","coordinates":[-122.3935,37.7955]}},
      {"type":"Feature","properties":{"name":"Pair","marker-color":"#d20f39"},
       "geometry":{"type":"MultiPoint","coordinates":[[-122.41,37.77],[-122.42,37.78]]}},
      {"type":"Feature","properties":{},
       "geometry":{"type":"LineString","coordinates":[[-122.4,37.7],[-122.5,37.8]]}}]}
      """
    try Data(text.utf8).write(to: file)
    return file
  }

  /// Catches Cmd-O routing a GeoJSON file anywhere but the map, and a map that shows no pins for
  /// it. The file opens in a new pane beside the terminal, with three pins and a segment that says
  /// so. The line in the file is skipped.
  func testCommandORoutesAGeoJSONFileToTheMapAndShowsItsPins() throws {
    let file = try makeGeoJSON()
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("o", modifierFlags: .command)
    choose(file, in: app, window: window)

    XCTAssertTrue(map(in: window).waitForExistence(timeout: 15), "no map pane")
    XCTAssertTrue(
      waitFor(map(in: window), timeout: 15) { $0.hasSuffix("pins=3") }, "the pins did not load")
    XCTAssertTrue(window.textViews["terminal"].exists, "the terminal went away")
  }

  /// Catches a restore that loses the file's pins, and a clear that does not stick. A planted
  /// layout names the file, and its pins load at launch. File > Clear File Pins removes them and
  /// drops the path, so the next launch shows an empty map and the layout holds no path.
  func testARestoredFileLoadsAndClearingItSticksOverARelaunch() throws {
    let file = try makeGeoJSON()

    try plantMap(
      payload:
        #"{"startDirectory":"\#(file.deletingLastPathComponent().path)","path":"\#(file.path)"}"#)

    let first = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let firstWindow = mainWindow(in: first)

    XCTAssertTrue(map(in: firstWindow).waitForExistence(timeout: 20), "no map pane")
    XCTAssertTrue(
      waitFor(map(in: firstWindow), timeout: 15) { $0.hasSuffix("pins=3") },
      "the restored pins did not load")

    let fileMenu = first.menuBars.menuBarItems["File"]
    fileMenu.click()

    let clear = fileMenu.menus.menuItems["Clear File Pins"]
    XCTAssertTrue(clear.waitForExistence(timeout: 5), "the File menu has no Clear File Pins")
    clear.click()

    XCTAssertTrue(waitFor(map(in: firstWindow), timeout: 10) { !$0.contains("pins=") })

    first.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(first.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8)

    XCTAssertFalse(written.contains("places.geojson"), "the path stayed in the layout: \(written)")

    let second = launchApp()
    let secondWindow = mainWindow(in: second)

    XCTAssertTrue(map(in: secondWindow).waitForExistence(timeout: 20), "no map pane")
    XCTAssertTrue(waitFor(map(in: secondWindow), timeout: 5) { !$0.contains("pins=") })
  }

  /// Catches pin editing that never reaches the file, an undo that does not reach the map, and a
  /// close that drops unsaved pins without asking. A right-click adds a pin, Cmd-Z takes it back,
  /// a second add and Cmd-S write it beside the file's line, and Cmd-W on an edited map asks.
  func testRightClickAddsAPinThatUndoesAndSaves() throws {
    let file = try makeGeoJSON()
    try plantMap(
      payload:
        #"{"startDirectory":"\#(file.deletingLastPathComponent().path)","path":"\#(file.path)"}"#)

    let app = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)
    let mapView = window.descendants(matching: .any)["map-viewer-map"]

    XCTAssertTrue(
      waitFor(map(in: window), timeout: 20) { $0.hasSuffix("pins=3") }, "the pins did not load")

    func addPin() {
      mapView.rightClick()
      let add = app.menuItems["Add Pin Here"]
      XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add Pin Here in the context menu")
      add.click()
    }

    addPin()
    XCTAssertTrue(waitFor(map(in: window), timeout: 10) { $0.hasSuffix("pins=4 edited") })

    app.typeKey("z", modifierFlags: .command)
    XCTAssertTrue(
      waitFor(map(in: window), timeout: 10) { $0.hasSuffix("pins=3") }, "Cmd-Z did not undo")

    addPin()
    XCTAssertTrue(waitFor(map(in: window), timeout: 10) { $0.hasSuffix("pins=4 edited") })

    app.typeKey("w", modifierFlags: .command)
    let question =
      app.dialogs["unsaved-confirmation"].exists
      ? app.dialogs["unsaved-confirmation"] : window.sheets.firstMatch
    XCTAssertTrue(question.waitForExistence(timeout: 5), "closing an edited map asked nothing")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitForNoSheet(in: window, timeout: 5))

    app.typeKey("s", modifierFlags: .command)
    XCTAssertTrue(
      waitFor(map(in: window), timeout: 10) { $0.hasSuffix("pins=4") }, "Cmd-S left it edited")

    let written = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(written.contains("LineString"), written)
    XCTAssertTrue(written.contains("Ferry Building"), written)
  }
}
