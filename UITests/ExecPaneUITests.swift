import XCTest

/// Drives an exec pane in the real app, with the hosted fixtures a debug build registers behind
/// `UNITERM_TEST_APPLETS`. The layout plants a slides pane that declares a driver, so every run
/// starts from a restore, the way an exec pane comes back after a relaunch.
///
/// The driver is the package tests' perl fixture, read from the source tree. What only the real
/// app shows is the Run strip, the values sheet, the Pending Requests panel's launch row and its
/// buttons, the applet changing under the driver's commands, the user's event reaching the driver,
/// the driver's stderr in the history, and a window shortcut while the driver stalls. The package
/// tests prove the wire, the bounds, and the authority rules.
@MainActor
final class ExecPaneUITests: UnitermUITestCase {
  private static var driverScript: String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Packages/UnitermKit/Tests/ExecTestSupport/Fixtures/driver.pl").path
  }

  private static let command =
    #"{"name":"set-deck","arguments":{"titles":["Intro","Results","Close"]}}"#

  /// Plants one window whose only pane is a slides fixture with a driver declared in `mode`.
  private func plantExecPane(mode: String, keys: [String]) throws {
    let control: [String: Any] = [
      "access": "disconnected", "driver": "exec",
      "exec": [
        "argv": ["/usr/bin/perl", Self.driverScript, mode, "fixture-slides", "0", Self.command],
        "environmentKeys": keys,
      ],
    ]
    let layout: [String: Any] = [
      "version": 3,
      "windows": [
        [
          "frame": ["x": 120, "y": 120, "width": 1000, "height": 640], "highWaterMark": 1,
          "tree": [
            "kind": "pane", "id": 1, "control": control,
            "applet": [
              "type": "fixture-slides", "version": 1,
              "payload": ["titles": [String](), "index": -1],
            ],
          ],
        ]
      ],
    ]

    let data = try JSONSerialization.data(withJSONObject: layout)
    try plantLayout(String(decoding: data, as: UTF8.self))
  }

  private func launchWithFixtures() -> XCUIApplication {
    let app = launchApp(environment: ["UNITERM_TEST_APPLETS": "1"])
    XCTAssertTrue(waitForForeground(app, activating: true))
    return app
  }

  /// Answers the values sheet, then approves the launch once from the panel. The panel's detail
  /// must show the exact inputs before the user allows them.
  private func approveOnce(in app: XCUIApplication, value: String?) {
    let window = mainWindow(in: app)

    if let value {
      let field = window.secureTextFields["exec-value-SYNTHETIC_TOKEN"]
      XCTAssertTrue(field.appears(timeout: 10), "the values sheet never showed")
      act("click the value field", app) { field.click() }
      act("type the value", app) { field.typeText(value) }
      act("click Continue", app) { window.sheets.buttons["Continue"].click() }
    }

    let status = window.staticTexts["pane-exec-status-1"]
    XCTAssertTrue(
      waitFor(status, timeout: 10) { $0.contains("waits for approval") },
      "the run did not wait for approval")

    let stateBeforeMenu = app.state

    act("open the Window menu", app) { app.menuBars.menuBarItems["Window"].click() }

    let item = app.menuBars.menuItems["Pending Requests\u{2026}"]
    XCTAssertTrue(item.appears(timeout: 5), "the Window menu has no Pending Requests item")
    XCTAssertTrue(item.isEnabled, "the Pending Requests item is disabled")
    act("click Pending Requests", app) { item.click() }

    let panel = app.windows["pending-requests-window"]
    XCTAssertTrue(
      panel.appears(timeout: 5),
      "the Pending Requests panel never opened. The windows were: "
        + app.windows.allElementsBoundByIndex.map(\.identifier).joined(separator: ", ")
        + ". The app's state was \(stateBeforeMenu.rawValue) before the menu and "
        + "\(app.state.rawValue) after. The main window can be hit: \(window.isHittable)")

    let row = panel.tables["pending-requests-table"].tableRows.firstMatch
    XCTAssertTrue(row.appears(timeout: 10), "the launch never reached the panel")
    act("select the launch", app) { row.click() }

    let detail = panel.staticTexts["pending-requests-detail"]
    XCTAssertTrue(
      waitFor(detail, timeout: 5) { $0.contains("argv[0] /usr/bin/perl") },
      "the panel did not show the launch's argv")

    if let value {
      XCTAssertTrue((detail.value as? String)?.contains("SYNTHETIC_TOKEN=\(value)") == true)
    }

    keepScreenshot(of: panel, named: "pending-launch")

    act("click Allow Once", app) { panel.buttons["pending-requests-allow-once"].click() }
    act("close the panel", app) { panel.buttons[XCUIIdentifierCloseWindow].click() }
  }

  /// Catches a restored exec pane that runs by itself, a Run that skips the values or the
  /// approval, a driver whose commands never reach the applet, a user event that never reaches
  /// the driver, and driver stderr that never reaches the history.
  func testARestoredExecPaneRunsOnlyAfterValuesAndApprovalThenDrivesTheApplet() throws {
    try plantExecPane(mode: "script", keys: ["SYNTHETIC_TOKEN"])

    let app = launchWithFixtures()
    let window = mainWindow(in: app)
    let run = window.buttons["pane-exec-run-1"]
    let title = window.staticTexts["fixture-slides-title"]

    XCTAssertTrue(run.appears(timeout: 20), "the restored pane shows no Run")
    XCTAssertEqual(title.value as? String, "No slide", "the restored pane ran its driver")

    keepScreenshot(of: window, named: "restored-exec-pane")

    act("click Run", app) { run.click() }
    approveOnce(in: app, value: "synthetic-value")

    XCTAssertTrue(waitFor(title, timeout: 20) { $0 == "Intro" }, "the driver never set the deck")

    act("click Next", app) { window.buttons["fixture-slides-button"].click() }

    XCTAssertTrue(
      waitFor(title, timeout: 10) { $0 == "Results" }, "the driver never answered the event")

    act("open the history", app) { window.groups["status-bar"].click() }

    let rows = window.staticTexts.matching(identifier: "history-row")
    XCTAssertTrue(rows.firstMatch.appears(timeout: 5), "the history never opened")

    let deadline = Date().addingTimeInterval(10)
    var values: [String] = []
    var found = false

    while Date() < deadline, !found {
      values = rows.allElementsBoundByIndex.map { ($0.value as? String) ?? "(no value)" }
      found = values.contains {
        $0.contains("got event advance-requested") && $0.hasPrefix("info")
      }

      if !found { Thread.sleep(forTimeInterval: 0.25) }
    }

    keepScreenshot(of: window, named: "exec-pane-running")
    XCTAssertTrue(
      found,
      "the driver's stderr never reached the history as info. The rows were: "
        + values.joined(separator: " | "))
  }

  /// Catches a stalled driver that takes the window's shortcuts: while the driver neither reads
  /// nor writes, and the applet floods it with events, Cmd-D still splits the pane.
  func testWindowShortcutsWorkWhileTheDriverStalls() throws {
    try plantExecPane(mode: "stall", keys: [])

    let app = launchWithFixtures()
    let window = mainWindow(in: app)
    let run = window.buttons["pane-exec-run-1"]

    XCTAssertTrue(run.appears(timeout: 20), "the restored pane shows no Run")

    act("click Run", app) { run.click() }
    approveOnce(in: app, value: nil)

    let status = window.staticTexts["pane-exec-status-1"]
    XCTAssertTrue(waitFor(status, timeout: 10) { $0.contains("is running") })

    let next = window.buttons["fixture-slides-button"]

    act("click Next 30 times", app) { for _ in 0..<30 { next.click() } }

    act("press Cmd-D", app) { app.typeKey("d", modifierFlags: .command) }

    XCTAssertTrue(
      launcher(in: window).appears(timeout: 5),
      "Cmd-D did nothing while the driver stalled. \(focusReport(app))")
  }

  /// What each interaction found: the app's state before and after it, and how long it took. A
  /// failure carries the trail, so a click that did not land says whether uniterm was frontmost
  /// and whether the app stayed busy after it.
  private var trail: [String] = []

  private func act(_ name: String, _ app: XCUIApplication, _ body: () -> Void) {
    let before = app.state
    let started = Date()

    body()

    let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
    trail.append("\(name): state \(before.rawValue) then \(app.state.rawValue), \(seconds) s")
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    trail = []
  }

  override func record(_ issue: XCTIssue) {
    var described = issue
    described.compactDescription += ". Trail: " + trail.joined(separator: "; ")
    super.record(described)
  }

  /// Keeps a screenshot of uniterm's own element, never of the screen.
  private func keepScreenshot(of element: XCUIElement, named name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
