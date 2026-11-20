import XCTest

/// Runs `uniterm open` from the app's own terminal, answers the question in the Pending Requests
/// panel as a user does, and checks where the routed pane lands.
///
/// The UI test runner is sandboxed, so as in `ScriptRunUITests` a shell script written into the
/// scratch folder runs the bundled command, and the test reads the file the script writes. A folder
/// is the target, since a folder routed to the terminal opens a new terminal there with no viewer
/// to find. What only the real app shows is the question reaching the panel with its buttons, the
/// command waiting until the answer, and the new pane's place and focus. The package tests prove the
/// rest of the authority, including that no path is looked at before the answer.
@MainActor
final class ScriptOpenUITests: UnitermUITestCase {
  /// A folder the command opens, with a name the test finds in the question and in the new shell.
  private func makeFolder() throws -> (url: URL, name: String) {
    let name = "uniterm-open-\(UUID().uuidString.prefix(8))"
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(name, isDirectory: true)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    return (folder.resolvingSymlinksInPath(), name)
  }

  /// Writes the script that runs the command and records its exit status. The shell tries again
  /// while the status is 69, no uniterm reachable, since the app may not be listening yet. With
  /// `outside`, the command runs in a background subshell that the script outlives, so the command
  /// descends from no terminal session.
  private func writeScript(
    named name: String, opening folder: String, outside: Bool
  ) throws -> (shell: String, status: String) {
    let command = try bundledCommand()
    let shell = scratch + "-\(name).sh"
    let status = scratch + "-\(name).status"

    let body = """
      attempts=0
      while [ $attempts -lt 100 ]; do
        "\(command)" open --socket "\(testSocket)" "\(folder)" 2> "\(status).err"
        code=$?
        [ $code -ne 69 ] && break
        attempts=$((attempts + 1))
        sleep 0.1
      done
      echo "exit=$code" > "\(status)"
      """

    try write(
      outside ? "(\n  sleep 1\n\(body)\n) < /dev/null > /dev/null 2>&1 &\n" : body + "\n",
      to: shell)

    addTeardownBlock {
      for path in [shell, status, status + ".err"] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    return (shell, status)
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

  /// Catches a command that opens before it is allowed, a question that names no path or offers the
  /// wrong buttons, a pane that lands in another window, and a pane that leaves the keyboard behind.
  /// The command runs from the first terminal and waits. The panel names the folder in full and
  /// offers a session answer. Once the user allows it, a new terminal opens beside the first, in the
  /// folder, the command exits 0, and the new pane takes the focus as the user's own open does.
  func testAnOpenWaitsForTheUserThenOpensAFolderBesideTheCallersPane() throws {
    let target = try makeFolder()
    let script = try writeScript(named: "open", opening: target.url.path, outside: false)

    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)
    XCTAssertFalse(window.groups["pane-2"].exists)
    XCTAssertTrue(isFocused(window.groups["pane-1"]), "the first pane does not start focused")

    runInTerminal(script.shell, in: app)

    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the window never showed the question")

    Thread.sleep(forTimeInterval: 1)

    XCTAssertFalse(window.groups["pane-2"].exists, "a pane opened before the user answered")
    XCTAssertFalse(FileManager.default.fileExists(atPath: script.status), "the command ended early")

    let panel = openQuestion(in: app)
    let detail = panel.staticTexts["pending-requests-detail"]

    XCTAssertTrue(
      waitFor(detail, timeout: 10) { $0.contains(target.url.path) },
      "the question does not name the folder in full")

    XCTAssertTrue(panel.buttons["pending-requests-allow-once"].exists)
    XCTAssertTrue(
      panel.buttons["pending-requests-allow-session"].exists,
      "a command in a terminal session is not offered the session answer")

    let shot = XCTAttachment(screenshot: panel.screenshot())

    shot.name = "script-open-session-question"
    shot.lifetime = .keepAlways
    add(shot)

    panel.buttons["pending-requests-allow-once"].click()
    closePanel(panel)

    let result = try XCTUnwrap(waitForFile(script.status), "the command never finished")

    XCTAssertEqual(result, "exit=0\n")

    let created = window.groups["pane-2"].textViews["terminal"]

    XCTAssertTrue(created.waitForExistence(timeout: 15), "no pane opened beside the first")
    XCTAssertFalse(app.windows["main-window-2"].exists, "the folder opened in a new window")
    XCTAssertTrue(
      waitFor(window.groups["pane-2"], timeout: 10) { $0 == "focused" },
      "the new pane did not take the focus")
    XCTAssertFalse(isFocused(window.groups["pane-1"]), "the first pane kept the focus")

    XCTAssertTrue(waitFor(created, timeout: 40) { $0.contains("% ") }, "no prompt in the new pane")
  }

  /// Catches a command in no terminal session that is offered more than one use. It starts from a
  /// background subshell, which launchd adopts once the script exits. The panel offers Allow Once
  /// and Deny and no session answer, and an allowed open lands in the most recent window.
  func testACommandOutsideEverySessionIsOfferedAllowOnceOnly() throws {
    let target = try makeFolder()
    let script = try writeScript(named: "outside", opening: target.url.path, outside: true)

    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)
    runInTerminal(script.shell, in: app)

    let panel = openQuestion(in: app)
    let detail = panel.staticTexts["pending-requests-detail"]

    XCTAssertTrue(
      waitFor(detail, timeout: 10) { $0.contains(target.url.path) },
      "the question does not name the folder in full")

    XCTAssertTrue(panel.buttons["pending-requests-allow-once"].exists)
    XCTAssertTrue(panel.buttons["Deny"].exists)
    XCTAssertFalse(
      panel.buttons["pending-requests-allow-session"].isHittable,
      "a command outside every session is offered a session answer")

    let shot = XCTAttachment(screenshot: panel.screenshot())

    shot.name = "script-open-outside-session-question"
    shot.lifetime = .keepAlways
    add(shot)

    panel.buttons["pending-requests-allow-once"].click()
    closePanel(panel)

    let result = try XCTUnwrap(waitForFile(script.status), "the command never finished")

    XCTAssertEqual(result, "exit=0\n")
    XCTAssertTrue(
      window.groups["pane-2"].textViews["terminal"].waitForExistence(timeout: 15),
      "no pane opened beside the focused pane")
    XCTAssertFalse(app.windows["main-window-2"].exists, "the folder opened in a new window")
  }
}
