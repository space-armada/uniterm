import XCTest

/// Drives a program outside every uniterm pane through the Pending Requests panel, as a user would.
///
/// A program run from the app's terminal descends from that terminal's session, so it is bound to
/// its pane. The shell script here starts the program in a subshell and exits at once. The subshell
/// is then a child of launchd, outside every pane, so the program's calls are refused and it asks
/// the user. The program keeps its connection and tries again until it is answered or denied.
///
/// What only the real app shows is the panel, the menu and the window's indicator that open it, and
/// a grant reaching the program's next call. The package tests prove each way a grant ends.
@MainActor
final class PendingRequestsUITests: UnitermUITestCase {
  /// Starts the outside program from the terminal. It prints its outcome to `output`, and writes
  /// `status` once it has exited. The files are removed when the test ends.
  private func startOutsideProgram(_ name: String, in app: XCUIApplication) throws -> (
    output: String, status: String
  ) {
    let command = try bundledCommand()
    let fixture = scratch + "-\(name).janet"
    let shell = scratch + "-\(name).sh"
    let output = scratch + "-\(name).out"
    let status = scratch + "-\(name).status"

    try write(
      """
      (declare-permissions {:name "Synthetic Outside Program"}
        {:kind :pane-control})

      (import uniterm)

      (var outcome "gave up")

      (for attempt 0 240
        (def [ok value] (protect (uniterm/list-windows)))

        (cond
          ok (do (set outcome (string "windows " (length value))) (break))
          (string/find "denied" (string value)) (do (set outcome "denied") (break)))

        (os/sleep 0.25))

      (print outcome)
      """, to: fixture)

    try write(
      """
      (
        sleep 1
        "\(command)" run --socket "\(testSocket)" "\(fixture)" > "\(output)" 2> "\(output).err"
        echo "exit=$?" > "\(status)"
      ) < /dev/null > /dev/null 2>&1 &
      """, to: shell)

    addTeardownBlock {
      for path in [fixture, shell, output, output + ".err", status] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    app.typeText("sh \(shell)\n")

    return (output, status)
  }

  /// What the program printed, once it has exited.
  private func outcome(of program: (output: String, status: String)) -> String? {
    guard waitForFile(program.status) != nil else { return nil }

    return try? String(contentsOfFile: program.output, encoding: .utf8)
  }

  private func openPendingRequests(in app: XCUIApplication) -> XCUIElement {
    app.menuBars.menuBarItems["Window"].click()
    app.menuBars.menuItems["Pending Requests\u{2026}"].click()

    let panel = app.windows["pending-requests-window"]

    XCTAssertTrue(panel.appears(timeout: 5), "the Pending Requests panel never opened")

    return panel
  }

  /// Opens the panel by clicking the window's indicator, as a user who notices it would.
  private func openPendingRequests(from indicator: XCUIElement, in app: XCUIApplication)
    -> XCUIElement
  {
    indicator.click()

    let panel = app.windows["pending-requests-window"]

    XCTAssertTrue(panel.appears(timeout: 5), "the indicator did not open the panel")

    return panel
  }

  /// Keeps a screenshot with the test's results, so a reviewer sees the indicator as the user does.
  /// The shot is of the window alone, so it covers nothing but uniterm's own UI.
  private func keepScreenshot(of element: XCUIElement, named name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Selects the panel's first row once the outside program's request reaches it.
  private func selectRequest(in panel: XCUIElement, of app: XCUIApplication) {
    let table = panel.tables["pending-requests-table"]
    let row = table.tableRows.firstMatch

    XCTAssertTrue(row.appears(timeout: 30), "the request never reached the panel")

    // The one failure here was a bare "Unable to find hit point" from the click. Waiting for the
    // row to take a click first turns that into a failure that says who held the screen.
    XCTAssertTrue(
      waitUntilHittable(row), "the request's row cannot take a click. \(focusReport(app))")
    row.click()
  }

  /// Catches an outside program that gets a pane without the user, a request that never reaches
  /// the panel or the window's indicator, an indicator without a count or that does not open the
  /// panel, and a grant that does not let the program's next call through. The program lists the
  /// windows once the grant is made.
  func testAnOutsideProgramAsksAndAGrantLetsItsNextCallThrough() throws {
    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)

    let program = try startOutsideProgram("granted", in: app)

    answerFirstReview(in: app, pressing: "pending-requests-allow-session")

    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.appears(timeout: 30), "the window never showed the request")
    XCTAssertTrue(
      waitFor(indicator, timeout: 30) { $0 == "1 request" },
      "the indicator never counted the one request")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: program.status), "the program ended before a grant")

    keepScreenshot(of: window, named: "pending-indicator")

    let panel = openPendingRequests(from: indicator, in: app)

    selectRequest(in: panel, of: app)
    panel.buttons["Grant Access\u{2026}"].click()

    let sheet = panel.sheets.firstMatch

    XCTAssertTrue(sheet.appears(timeout: 5), "Grant Access asked nothing")
    XCTAssertTrue(sheet.popUpButtons["pending-requests-pane"].exists, "the sheet names no pane")

    sheet.buttons["Grant"].click()

    XCTAssertEqual(outcome(of: program), "windows 1\n")
    XCTAssertTrue(waitUntilGone(indicator, timeout: 10), "the indicator stayed after the grant")
  }

  /// Catches a denial that the program's next call undoes. The program is told it was denied, and
  /// the window's indicator goes.
  func testADenialReachesTheProgramAndClearsTheIndicator() throws {
    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)

    let program = try startOutsideProgram("denied", in: app)

    answerFirstReview(in: app, pressing: "pending-requests-allow-session")

    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.appears(timeout: 30), "the window never showed the request")

    let panel = openPendingRequests(in: app)

    selectRequest(in: panel, of: app)
    panel.buttons["Deny"].click()

    XCTAssertEqual(outcome(of: program), "denied\n")
    XCTAssertTrue(waitUntilGone(indicator, timeout: 10), "the indicator stayed after the denial")
  }
}
