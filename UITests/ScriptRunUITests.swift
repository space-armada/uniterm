import XCTest

/// Runs the bundled `uniterm` command against the launched app, from a terminal pane in that app,
/// as a user would.
///
/// The UI test runner is sandboxed, and a process it starts inherits the sandbox, so it can
/// neither connect to the app's socket nor copy the command. The app is not sandboxed, and the
/// shell in its terminal is the app's child. The tests therefore write a small shell script into
/// the scratch folder, type its path into the terminal, and read the files the script writes.
///
/// The app listens in a folder of its own, so the command's address is the test instance's
/// well-known socket in that folder. No test connects to the user's real address, and every run
/// names its socket. What only the real app shows is the wiring of the scripting host to the
/// windows, which the package tests replace with a stand-in.
@MainActor
final class ScriptRunUITests: UnitermUITestCase {
  private var testSocket: String { scriptDirectory + "/uniterm.sock" }

  /// The app the tests drive sits beside the test runner in the build products folder.
  /// `UNITERM_APP_PATH` names another build.
  private func bundledCommand() throws -> String {
    if let path = ProcessInfo.processInfo.environment["UNITERM_APP_PATH"], !path.isEmpty {
      return path + "/Contents/Helpers/uniterm"
    }

    var folder = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()

    for _ in 0..<8 {
      let app = folder.appendingPathComponent("uniterm.app")

      if FileManager.default.fileExists(atPath: app.path) {
        return app.path + "/Contents/Helpers/uniterm"
      }

      folder.deleteLastPathComponent()
    }

    throw XCTSkip("uniterm.app was not found beside the test runner")
  }

  private func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }

  /// Types the path of a shell script into the terminal and runs it.
  private func runInTerminal(_ script: String, in app: XCUIApplication) {
    app.typeText("sh \(script)\n")
  }

  /// Waits for a file the shell writes, and returns what it holds. A file that has not appeared in
  /// 60 seconds fails the test, so a script that never ran cannot hang it.
  private func waitForFile(_ path: String, timeout: TimeInterval = 60) -> String? {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return nil
  }

  /// Catches a scripting host that is not wired to the real windows. One script posts a status
  /// message, lists the windows and panes, and opens a pane. The status bar shows the message, a
  /// second pane appears, and the listing reaches the command's own standard output.
  ///
  /// The shell runs the command again while it exits 69, no uniterm reachable, for up to ten
  /// seconds. A bound socket file exists before the app listens, so the retry is a real connect.
  /// A script that ran is never run again, since it exits with another status.
  func testARunDrivesTheRealAppFromTheBundledCommand() throws {
    let command = try bundledCommand()
    let app = launchApp()
    let window = app.windows["main-window"]

    _ = waitForTerminal(in: app)
    XCTAssertFalse(window.groups["pane-2"].exists)

    let fixture = scratch + "-run.janet"
    let shell = scratch + "-run.sh"
    let output = scratch + "-run.out"
    let errors = scratch + "-run.err"
    let status = scratch + "-run.status"

    try write(
      """
      (import uniterm)

      (def windows (uniterm/list-windows))
      (def window ((windows 0) :window))
      (def panes (uniterm/list-panes (windows 0)))
      (def made (uniterm/open-pane :terminal {:window window :pane ((panes 0) :pane)}))

      (uniterm/post-status :info "status from a ui test script")
      (print "windows " (length windows))
      (print "panes " (length panes))
      (print "opened " (made :pane))
      (print "args " (string/join (slice (dyn :args) 1) " "))
      """, to: fixture)

    try write(
      """
      attempts=0
      while [ $attempts -lt 100 ]; do
        "\(command)" run --socket "\(testSocket)" "\(fixture)" one two > "\(output)" 2> "\(errors)"
        code=$?
        [ $code -ne 69 ] && break
        attempts=$((attempts + 1))
        sleep 0.1
      done
      echo "exit=$code" > "\(status)"
      """, to: shell)

    defer {
      for path in [fixture, shell, output, errors, status] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    runInTerminal(shell, in: app)

    let result = try XCTUnwrap(waitForFile(status), "the shell never finished the command")
    let errorText = (try? String(contentsOfFile: errors, encoding: .utf8)) ?? ""

    XCTAssertEqual(result, "exit=0\n", errorText)

    let printed = try String(contentsOfFile: output, encoding: .utf8)

    XCTAssertEqual(
      printed.split(separator: "\n").map(String.init),
      ["windows 1", "panes 1", "opened 2", "args one two"])

    XCTAssertTrue(window.groups["pane-2"].waitForExistence(timeout: 10), "the pane never opened")

    let message = window.staticTexts["status-message"]

    XCTAssertTrue(
      waitFor(message, timeout: 10) { $0.contains("status from a ui test script") },
      "the status bar never showed the script's message")
  }

  /// Catches a command that hangs or misleads when no app listens, and a copy of the command that
  /// runs anyway. A missing socket is reported as no app with the status no other failure uses.
  /// A copy of the bundled command, outside any bundle, is refused with a message to reinstall.
  func testTheBundledCommandReportsNoAppAndRefusesACopyOfItself() throws {
    let command = try bundledCommand()
    let app = launchApp()

    _ = waitForTerminal(in: app)

    let fixture = scratch + "-noop.janet"
    let shell = scratch + "-refuse.sh"
    let copy = scratch + "-uniterm-copy"
    let missing = scriptDirectory + "/missing.sock"
    let noneOut = scratch + "-none.err"
    let refusedOut = scratch + "-refused.err"
    let status = scratch + "-refuse.status"

    try write("(print 1)\n", to: fixture)

    try write(
      """
      "\(command)" run --socket "\(missing)" "\(fixture)" > /dev/null 2> "\(noneOut)"
      none=$?
      cp "\(command)" "\(copy)"
      "\(copy)" run --socket "\(missing)" "\(fixture)" > /dev/null 2> "\(refusedOut)"
      refused=$?
      echo "none=$none refused=$refused" > "\(status)"
      """, to: shell)

    defer {
      for path in [fixture, shell, copy, noneOut, refusedOut, status] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    runInTerminal(shell, in: app)

    let result = try XCTUnwrap(waitForFile(status), "the shell never finished the commands")

    XCTAssertEqual(result, "none=69 refused=78\n")

    let none = try String(contentsOfFile: noneOut, encoding: .utf8)
    let refused = try String(contentsOfFile: refusedOut, encoding: .utf8)

    XCTAssertTrue(none.contains("no uniterm is reachable"), none)
    XCTAssertTrue(refused.contains("Reinstall"), refused)
  }
}
