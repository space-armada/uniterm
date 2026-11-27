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
    XCTAssertTrue(item.appears(timeout: 5), "the View menu has no \(title)")
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
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))

    app.typeKey("4", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(map(in: window).appears(timeout: 10), "no map pane")
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
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))
    app.typeKey("4", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(map(in: window).appears(timeout: 10), "no map pane")

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
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))
    app.typeKey("4", modifierFlags: .command)

    let launcherField = launcher(in: window).textFields["place-search-field"]
    XCTAssertTrue(launcherField.appears(timeout: 5), "no place field in the launcher")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(map(in: window).appears(timeout: 10), "no map pane")

    app.typeKey("l", modifierFlags: .command)
    let search = map(in: window).descendants(matching: .any)["place-search"]
    XCTAssertTrue(search.appears(timeout: 5), "Cmd-L showed no place search")

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

    XCTAssertTrue(map(in: window).appears(timeout: 20), "no map pane")
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

    XCTAssertTrue(map(in: firstWindow).appears(timeout: 20), "no map pane")

    chooseStyle("Satellite Map", in: first)
    XCTAssertTrue(waitFor(styleText(in: firstWindow), timeout: 10) { $0 == "Satellite" })

    first.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(first.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8)

    XCTAssertTrue(written.contains(#""style":"satellite""#), "the style was not saved: \(written)")

    let second = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let secondWindow = mainWindow(in: second)

    XCTAssertTrue(map(in: secondWindow).appears(timeout: 20), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: secondWindow), timeout: 10) { $0 == "Satellite" })

    second.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(second.wait(for: .notRunning, timeout: 15))

    try plantMap(payload: #"{"style":"terrain"}"#)

    let third = launchApp()
    let thirdWindow = mainWindow(in: third)

    XCTAssertTrue(map(in: thirdWindow).appears(timeout: 20), "no map pane")
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

    XCTAssertTrue(map(in: window).appears(timeout: 15), "no map pane")
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

    XCTAssertTrue(map(in: firstWindow).appears(timeout: 20), "no map pane")
    XCTAssertTrue(
      waitFor(map(in: firstWindow), timeout: 15) { $0.hasSuffix("pins=3") },
      "the restored pins did not load")

    let fileMenu = first.menuBars.menuBarItems["File"]
    fileMenu.click()

    let clear = fileMenu.menus.menuItems["Clear File Pins"]
    XCTAssertTrue(clear.appears(timeout: 5), "the File menu has no Clear File Pins")
    clear.click()

    XCTAssertTrue(waitFor(map(in: firstWindow), timeout: 10) { !$0.contains("pins=") })

    first.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(first.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8)

    XCTAssertFalse(written.contains("places.geojson"), "the path stayed in the layout: \(written)")

    let second = launchApp()
    let secondWindow = mainWindow(in: second)

    XCTAssertTrue(map(in: secondWindow).appears(timeout: 20), "no map pane")
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
      XCTAssertTrue(add.appears(timeout: 5), "no Add Pin Here in the context menu")
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
    XCTAssertTrue(question.appears(timeout: 5), "closing an edited map asked nothing")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitForNoSheet(in: window, timeout: 5))

    app.typeKey("s", modifierFlags: .command)
    XCTAssertTrue(
      waitFor(map(in: window), timeout: 10) { $0.hasSuffix("pins=4") }, "Cmd-S left it edited")

    let written = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(written.contains("LineString"), written)
    XCTAssertTrue(written.contains("Ferry Building"), written)
  }

  /// Catches a quit that drops unsaved pins when nothing is running. A map with a pin added by
  /// right-click sits beside no terminal activity, and Cmd-Q must ask whether to save. Cancel
  /// leaves the app running with the edit intact.
  func testQuittingAnEditedMapAsksEvenWhenNothingRuns() throws {
    let file = try makeGeoJSON()
    try plantMap(
      payload:
        #"{"startDirectory":"\#(file.deletingLastPathComponent().path)","path":"\#(file.path)"}"#)

    let app = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)
    let mapView = window.descendants(matching: .any)["map-viewer-map"]

    XCTAssertTrue(
      waitFor(map(in: window), timeout: 20) { $0.hasSuffix("pins=3") }, "the pins did not load")

    mapView.rightClick()
    let add = app.menuItems["Add Pin Here"]
    XCTAssertTrue(add.appears(timeout: 5), "no Add Pin Here in the context menu")
    add.click()
    XCTAssertTrue(waitFor(map(in: window), timeout: 10) { $0.hasSuffix("pins=4 edited") })

    app.typeKey("q", modifierFlags: .command)

    let question =
      app.dialogs["unsaved-confirmation"].exists
      ? app.dialogs["unsaved-confirmation"] : window.sheets.firstMatch
    XCTAssertTrue(question.appears(timeout: 5), "quitting an edited map asked nothing")
    XCTAssertTrue(app.staticTexts["Save changes before quitting?"].exists)
    XCTAssertEqual(app.state, .runningForeground, "the app quit past the question")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitForNoSheet(in: window, timeout: 5))
    XCTAssertEqual(app.state, .runningForeground, "Cancel did not keep the app running")
    XCTAssertTrue(waitFor(map(in: window), timeout: 10) { $0.hasSuffix("pins=4 edited") })
  }

  // MARK: Pins from a program

  private static var driverScript: String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Packages/UnitermKit/Tests/ExecTestSupport/Fixtures/driver.pl").path
  }

  /// Plants an exec map as pane 1. With `beside`, a terminal pane 2 sits next to it, so closing the map
  /// leaves a pane to reopen it beside.
  private func plantExecMap(commands: [String], beside terminal: Bool = false) throws {
    let control: [String: Any] = [
      "access": "disconnected", "driver": "exec",
      "exec": [
        "argv": ["/usr/bin/perl", Self.driverScript, "script", "map-viewer", "0.0"] + commands,
        "environmentKeys": [String](),
      ],
    ]
    let mapPane: [String: Any] = [
      "kind": "pane", "id": 1, "control": control,
      "applet": ["type": "map-viewer", "version": 1, "payload": [String: Any]()],
    ]
    let tree: [String: Any] =
      terminal
      ? [
        "kind": "split", "id": 3, "axis": "row",
        "children": [
          ["weight": 0.5, "node": mapPane],
          [
            "weight": 0.5,
            "node": [
              "kind": "pane", "id": 2,
              "applet": [
                "type": "terminal", "version": 1,
                "payload": [
                  "mode": "shell", "tabs": [["workingDirectory": NSNull()]], "selectedTab": 0,
                ] as [String: Any],
              ] as [String: Any],
            ] as [String: Any],
          ],
        ],
      ]
      : mapPane
    let layout: [String: Any] = [
      "version": 3,
      "windows": [
        [
          "frame": ["x": 120, "y": 120, "width": 1000, "height": 640],
          "highWaterMark": terminal ? 3 : 1, "focusedPane": 1, "tree": tree,
        ]
      ],
    ]

    let data = try JSONSerialization.data(withJSONObject: layout)
    try plantLayout(String(decoding: data, as: UTF8.self))
  }

  /// Clicks Run on a restored exec map and allows the launch once from the Pending Requests panel.
  private func approveRun(of run: XCUIElement, in app: XCUIApplication, window: XCUIElement) {
    run.click()

    let status = window.staticTexts["pane-exec-status-1"]
    XCTAssertTrue(
      waitFor(status, timeout: 10) { $0.contains("waits for approval") },
      "the run did not wait for approval")

    app.menuBars.menuBarItems["Window"].click()

    let item = app.menuBars.menuItems["Pending Requests\u{2026}"]
    XCTAssertTrue(item.appears(timeout: 5), "the Window menu has no Pending Requests item")
    item.click()

    let panel = app.windows["pending-requests-window"]
    XCTAssertTrue(panel.appears(timeout: 5), "the Pending Requests panel never opened")

    let row = panel.tables["pending-requests-table"].tableRows.firstMatch
    XCTAssertTrue(row.appears(timeout: 10), "the launch never reached the panel")
    row.click()
    panel.buttons["pending-requests-allow-once"].click()
    panel.buttons[XCUIIdentifierCloseWindow].click()
  }

  /// Opens the history from the status bar and waits until a row's value satisfies `condition`.
  /// Returns every row's value at the end, so a failure message can show them.
  private func historyRows(
    in window: XCUIElement, timeout: TimeInterval = 10,
    until condition: @escaping ([String]) -> Bool
  ) -> (matched: Bool, values: [String]) {
    let rows = window.staticTexts.matching(identifier: "history-row")
    var values: [String] = []

    let held = pollUntil(timeout: timeout) {
      values = rows.allElementsBoundByIndex.map { ($0.value as? String) ?? "(no value)" }
      return condition(values)
    }

    return (held, values)
  }

  private func statusSegment(_ index: Int, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: "status-applet-\(index)").firstMatch
  }

  /// Catches a driver whose set-layer never reaches a real map pane, and a restored exec map that
  /// runs by itself. The layout plants a map that declares the fixture driver. Run asks for approval
  /// in the Pending Requests panel, and the map's accessibility value then counts the program's
  /// pins. The pins draw as MapKit draws them, which this test cannot judge.
  func testADriverRunFromAnExecMapPlacesPins() throws {
    let pins =
      #"[{"id":"a","coordinate":{"latitude":37.77,"longitude":-122.42},"label":"A"},"#
      + #"{"id":"b","coordinate":{"latitude":37.80,"longitude":-122.27},"label":"B"}]"#

    try plantExecMap(commands: [
      #"{"name":"set-layer","arguments":{"layer":"trucks","pins":\#(pins)}}"#,
      #"{"name":"set-region","arguments":{"center":{"latitude":37.78,"longitude":-122.35},"span":{"latitude-delta":0.4,"longitude-delta":0.4}}}"#,
    ])

    let app = launchApp()
    XCTAssertTrue(waitForForeground(app, activating: true))

    let window = mainWindow(in: app)
    let run = window.buttons["pane-exec-run-1"]

    XCTAssertTrue(run.appears(timeout: 20), "the restored pane shows no Run")
    XCTAssertFalse(
      (map(in: window).value as? String)?.contains("program-pins") == true,
      "the restored map ran its driver")

    approveRun(of: run, in: app, window: window)

    XCTAssertTrue(
      waitFor(map(in: window), timeout: 20) { $0.contains("program-pins=2") },
      "the driver's pins never reached the map")

    let capture = XCTAttachment(screenshot: window.screenshot())
    capture.name = "driver-pins"
    capture.lifetime = .keepAlways
    add(capture)
  }

  /// Catches program pins that a reopen loses, a reopen that shows them as live, and a relaunch that
  /// either shows them or drops the news. A driver places two pins. Closing the map and pressing
  /// Cmd-Shift-T brings them back with the earlier-run segment. A quit and relaunch then shows no
  /// pins, and the history holds the one notice that program layers held pins last session. The
  /// pins draw as MapKit draws them, which this test cannot judge.
  func testProgramPinsReturnOnReopenAndAreAnnouncedAfterARelaunch() throws {
    let pins =
      #"[{"id":"a","coordinate":{"latitude":37.77,"longitude":-122.42},"label":"A"},"#
      + #"{"id":"b","coordinate":{"latitude":37.80,"longitude":-122.27},"label":"B"}]"#

    try plantExecMap(
      commands: [
        #"{"name":"set-layer","arguments":{"layer":"trucks","pins":\#(pins)}}"#,
        #"{"name":"set-region","arguments":{"center":{"latitude":37.78,"longitude":-122.35},"span":{"latitude-delta":0.4,"longitude-delta":0.4}}}"#,
      ], beside: true)

    let first = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    XCTAssertTrue(waitForForeground(first, activating: true))

    let firstWindow = mainWindow(in: first)
    let run = firstWindow.buttons["pane-exec-run-1"]

    XCTAssertTrue(run.appears(timeout: 20), "the restored pane shows no Run")

    approveRun(of: run, in: first, window: firstWindow)

    XCTAssertTrue(
      waitFor(map(in: firstWindow), timeout: 20) { $0.contains("program-pins=2") },
      "the driver's pins never reached the map")
    XCTAssertFalse(
      statusSegment(1, in: firstWindow).exists, "a live run shows the earlier-run segment")

    firstWindow.groups["pane-1"].click()
    first.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      waitUntilGone(map(in: firstWindow), timeout: 15), "Cmd-W did not close the map pane")

    first.typeKey("t", modifierFlags: [.command, .shift])
    XCTAssertTrue(map(in: firstWindow).appears(timeout: 15), "Cmd-Shift-T brought no map")
    XCTAssertTrue(
      waitFor(map(in: firstWindow), timeout: 20) { $0.contains("program-pins=2") },
      "the reopened map lost the program pins")
    XCTAssertTrue(
      waitFor(statusSegment(1, in: firstWindow), timeout: 10) { $0 == "From an earlier run" },
      "the reopened map does not say its pins are from an earlier run")

    let reopened = XCTAttachment(screenshot: firstWindow.screenshot())
    reopened.name = "reopened-earlier-run"
    reopened.lifetime = .keepAlways
    add(reopened)

    first.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(first.wait(for: .notRunning, timeout: 15))

    let second = launchApp()
    let secondWindow = mainWindow(in: second)

    XCTAssertTrue(map(in: secondWindow).appears(timeout: 20), "no map pane after relaunch")
    XCTAssertTrue(
      secondWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-exec-run-'"))
        .firstMatch.appears(timeout: 20),
      "the relaunched map shows no Run")
    XCTAssertFalse(
      (map(in: secondWindow).value as? String)?.contains("program-pins") == true,
      "the relaunched map shows program pins")

    secondWindow.groups["status-bar"].click()

    let rows = secondWindow.staticTexts.matching(identifier: "history-row")
    XCTAssertTrue(rows.firstMatch.appears(timeout: 5), "the history never opened")

    let notice = "held pins last session"
    let history = historyRows(in: secondWindow) { $0.filter { $0.contains(notice) }.count >= 1 }

    XCTAssertEqual(
      history.values.filter { $0.contains(notice) }.count, 1,
      "the history should hold one restore notice. The rows were: "
        + history.values.joined(separator: " | "))

    XCTAssertFalse(
      history.values.contains { $0.contains("could not be restored") },
      "a saved pane failed to restore. The rows were: " + history.values.joined(separator: " | "))

    let relaunched = XCTAttachment(screenshot: secondWindow.screenshot())
    relaunched.name = "relaunched-notice"
    relaunched.lifetime = .keepAlways
    add(relaunched)
  }

  /// Catches a click on the empty map that never reaches the driver as a map-clicked event, such
  /// as a chrome match that rejects the map's own surface. The driver logs each event it gets to
  /// stderr, and the history shows it. The click lands where no pin, control, or label is.
  func testAClickOnTheEmptyMapReachesTheDriver() throws {
    let pin =
      #"[{"id":"a","coordinate":{"latitude":37.77,"longitude":-122.42},"label":"A"}]"#

    try plantExecMap(commands: [
      #"{"name":"set-layer","arguments":{"layer":"trucks","pins":\#(pin)}}"#,
      #"{"name":"set-region","arguments":{"center":{"latitude":37.78,"longitude":-122.35},"span":{"latitude-delta":0.4,"longitude-delta":0.4}}}"#,
    ])

    let app = launchApp()
    XCTAssertTrue(waitForForeground(app, activating: true))

    let window = mainWindow(in: app)
    let run = window.buttons["pane-exec-run-1"]

    XCTAssertTrue(run.appears(timeout: 20), "the restored pane shows no Run")

    approveRun(of: run, in: app, window: window)

    // The map drops events until the driver's hello is accepted. A pin from its set-layer proves
    // the driver is connected, so the click cannot land before it.
    XCTAssertTrue(
      waitFor(map(in: window), timeout: 20) { $0.contains("program-pins=1") },
      "the driver never connected")

    map(in: window).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).click()

    window.groups["status-bar"].click()

    let rows = window.staticTexts.matching(identifier: "history-row")
    XCTAssertTrue(rows.firstMatch.appears(timeout: 5), "the history never opened")

    let history = historyRows(in: window) { $0.contains { $0.contains("got event map-clicked") } }
    let found = history.matched
    let values = history.values

    XCTAssertTrue(
      found,
      "the driver never got map-clicked. The rows were: " + values.joined(separator: " | "))
  }
}
