import AppKit
import XCTest

/// Sends the running app an open-documents event the way another program does, then answers the
/// question in the Pending Requests panel as a user does.
///
/// The runner is an ad hoc signed app with no team and no Apple anchor, so it is not an Apple
/// opener and the app must ask. Whether the event names the runner or another process as its sender
/// depends on how Launch Services relays an event from a sandboxed app, which no package test can
/// show. These tests therefore never depend on which answers the question offers. An accepted open
/// from Finder needs Finder as the sender, which no test can be, so unit tests cover it with a
/// sender fixture and a hand check covers the real Finder.
@MainActor
final class LaunchServicesOpenUITests: UnitermUITestCase {
  /// A folder the runner opens, with a name the test finds in the question.
  private func makeFolder() throws -> (url: URL, name: String) {
    let name = "uniterm-open-\(UUID().uuidString.prefix(8))"
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(name, isDirectory: true)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    return (folder, name)
  }

  /// Hands the folder to the app under test. The app is found by its bundle identifier among the
  /// running applications, so Launch Services sends the event to this instance.
  private func sendOpen(of folder: URL) throws {
    let running = try XCTUnwrap(
      NSRunningApplication.runningApplications(withBundleIdentifier: "dev.uniterm.app").first)
    let appURL = try XCTUnwrap(running.bundleURL)

    let handed = expectation(description: "the open was handed to Launch Services")

    NSWorkspace.shared.open(
      [folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      XCTAssertNil(error)
      handed.fulfill()
    }

    wait(for: [handed], timeout: 20)
  }

  /// Opens the panel from the Window menu and selects the first question.
  private func openQuestion(in app: XCUIApplication) -> XCUIElement {
    app.menuBars.menuBarItems["Window"].click()
    app.menuBars.menuItems["Pending Requests\u{2026}"].click()

    let panel = app.windows["pending-requests-window"]

    XCTAssertTrue(panel.waitForExistence(timeout: 5), "the Pending Requests panel never opened")

    let row = panel.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(row.waitForExistence(timeout: 30), "the question never reached the panel")
    row.click()

    return panel
  }

  private func closePanel(_ panel: XCUIElement) {
    let close = panel.buttons[XCUIIdentifierCloseWindow]

    if close.isHittable { close.click() }
  }

  private func isFocused(_ pane: XCUIElement) -> Bool {
    (pane.value as? String) == "focused"
  }

  /// Catches an open from a program that is not Finder or the Dock that opens a pane before the
  /// user answers, a question that does not name the folder, and an allowed open that leaves the
  /// keyboard behind or lands in another window. The question lists the folder in full. Once the
  /// user allows it, a new terminal opens beside the first and takes the focus, as the user's own
  /// open does.
  func testAnOpenFromAnotherProgramWaitsForTheUserThenOpensBesideTheFocusedPane() throws {
    let target = try makeFolder()

    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)
    XCTAssertTrue(isFocused(window.groups["pane-1"]), "the first pane does not start focused")

    try sendOpen(of: target.url)

    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the window never showed the question")

    let panel = openQuestion(in: app)

    XCTAssertFalse(window.groups["pane-2"].exists, "a pane opened before the user answered")

    let detail = panel.staticTexts["pending-requests-detail"]

    XCTAssertTrue(
      waitFor(detail, timeout: 10) { $0.contains(target.name) },
      "the question does not name the folder")

    XCTAssertTrue(panel.buttons["pending-requests-allow-once"].exists)
    XCTAssertTrue(panel.buttons["Deny"].exists)

    let shot = XCTAttachment(screenshot: panel.screenshot())

    shot.name = "launch-services-question"
    shot.lifetime = .keepAlways
    add(shot)

    panel.buttons["pending-requests-allow-once"].click()
    closePanel(panel)

    XCTAssertTrue(
      window.groups["pane-2"].textViews["terminal"].waitForExistence(timeout: 20),
      "no pane opened beside the first")
    XCTAssertFalse(app.windows["main-window-2"].exists, "the folder opened in a new window")
    XCTAssertTrue(
      waitFor(window.groups["pane-2"], timeout: 10) { $0 == "focused" },
      "the new pane did not take the focus")
    XCTAssertFalse(isFocused(window.groups["pane-1"]), "the first pane kept the focus")
  }

  /// Catches a Deny that still opens a pane, or says nothing. The user denies the question, no
  /// pane opens, and the status bar says the files were not opened and why.
  func testADeniedOpenFromAnotherProgramOpensNothingAndSaysSo() throws {
    let target = try makeFolder()

    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)

    try sendOpen(of: target.url)

    let panel = openQuestion(in: app)

    panel.buttons["Deny"].click()
    closePanel(panel)

    let message = window.staticTexts["status-message"]

    XCTAssertTrue(
      waitFor(message, timeout: 15) {
        $0.contains("did not open the files sent by") && $0.contains("you denied it")
      }, "the refusal never reached the status bar")

    XCTAssertEqual(window.textViews.matching(identifier: "terminal").count, 1)
    XCTAssertFalse(app.windows["main-window-2"].exists)
  }
}
