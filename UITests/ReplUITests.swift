import XCTest

/// Drives the REPL applet in the launched app, as a user would: from the launcher, typing into the
/// pane. Each test proves a contract that only the real app shows. The REPL's helper runs against
/// the test instance's own listener, and the pane's terminal, key routing, and close dialog are
/// the real ones. The package tests replace the terminal with a fake and the helper with a raw
/// peer, so they cannot show any of it.
///
/// The REPL starts in the home folder and has no capabilities, so nothing here touches a file.
/// A side effect that a restored line could repeat is a pane a script opens.
@MainActor
final class ReplUITests: UnitermUITestCase {
  private func openRepl(in app: XCUIApplication) -> (window: XCUIElement, terminal: XCUIElement) {
    let window = app.windows["main-window"]

    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5), "Cmd-D showed no launcher")

    app.typeText("repl")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(launcher(in: window), timeout: 10), "Return left the launcher")

    let terminal = window.groups["pane-2"].textViews["terminal"]

    XCTAssertTrue(terminal.waitForExistence(timeout: 20), "the REPL pane never showed a terminal")
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { $0.contains("repl:1:> ") },
      "the REPL never showed its prompt")

    return (window, terminal)
  }

  /// True when some line of the terminal's text is exactly `line`.
  private func hasLine(_ line: String, in text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains {
      $0.trimmingCharacters(in: .whitespaces) == line
    }
  }

  private func paneGroups(in window: XCUIElement) -> XCUIElementQuery {
    window.groups.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-'"))
  }

  private func waitForPaneCount(_ count: Int, in window: XCUIElement, timeout: TimeInterval = 20)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if paneGroups(in: window).count == count { return true }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  /// The terminal of whichever pane holds a REPL prompt, wherever the pane sits.
  private func replTerminal(in window: XCUIElement) -> XCUIElement? {
    window.textViews.matching(identifier: "terminal").allElementsBoundByIndex.first {
      ($0.value as? String)?.contains("repl:") == true
    }
  }

  /// Catches a REPL that does not evaluate what is typed, one whose host calls do not reach the
  /// app, and one whose results never reach the screen. A sum prints, a status post reaches the
  /// status bar, and a listing through the host API counts the window's two panes.
  func testTypingAnExpressionShowsItsResultAndHostCallsTakeEffect() {
    let app = launchApp()
    let (window, terminal) = openRepl(in: app)

    app.typeText("(+ 1 2)\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { self.hasLine("3", in: $0) }, "the sum never printed")

    app.typeText("(uniterm/post-status :info \"hi from the repl\")\n")

    let message = window.staticTexts["status-message"]

    XCTAssertTrue(
      waitFor(message, timeout: 20) { $0.contains("hi from the repl") },
      "the status bar never showed the REPL's message")

    app.typeText("(length (uniterm/list-panes (first (uniterm/list-windows))))\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { self.hasLine("2", in: $0) },
      "the listing through the host API never printed")
  }

  /// Catches a close that asks about a REPL sitting at its prompt. Cmd-W closes the pane at once,
  /// with no sheet.
  func testClosingAtAnIdlePromptDoesNotAsk() {
    let app = launchApp()
    let (window, _) = openRepl(in: app)

    app.typeText("(+ 1 1)\n")
    XCTAssertTrue(
      waitFor(window.groups["pane-2"].textViews["terminal"], timeout: 20) {
        self.hasLine("2", in: $0)
      })

    app.typeKey("w", modifierFlags: .command)

    XCTAssertFalse(window.sheets.firstMatch.waitForExistence(timeout: 2), "closing asked")
    XCTAssertTrue(waitUntilGone(window.groups["pane-2"], timeout: 15), "the pane never closed")
  }

  /// Catches Ctrl-C that does not stop a loop, and a REPL that does not report its evaluation to
  /// the app. While `(while true)` runs, Cmd-W asks first, and Cancel keeps the pane. Ctrl-C stops
  /// the loop and the prompt returns with the earlier definition. Cmd-W then closes with no
  /// question.
  func testCtrlCStopsARunningEvaluationAndTheCloseAsksOnlyWhileItRuns() {
    // A debug helper then writes `[sigint evaluating]` or `[sigint idle]` for each SIGINT it gets.
    // The failure message shows the screen, so it says whether the signal arrived at all.
    let app = launchApp(environment: ["UNITERM_REPL_TRACE_SIGINT": "1"])
    let (window, terminal) = openRepl(in: app)

    app.typeText("(def kept 41)\n")
    app.typeText("(while true)\n")

    // The loop never ends, so two seconds is long enough for the app to have heard of it.
    Thread.sleep(forTimeInterval: 2)

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(
      window.sheets.firstMatch.waitForExistence(timeout: 10),
      "closing a running evaluation did not ask")

    let cancel = window.sheets.firstMatch.buttons["Cancel"]

    XCTAssertTrue(cancel.exists, "the close question has no Cancel button")
    cancel.click()
    XCTAssertTrue(waitForNoSheet(in: window, timeout: 10), "Cancel left the question up")
    XCTAssertTrue(window.groups["pane-2"].exists, "Cancel closed the pane")

    window.groups["pane-2"].textViews["terminal"].click()
    app.typeKey("c", modifierFlags: .control)

    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("interrupted") },
      "Ctrl-C never stopped the loop. Screen: \(terminal.value as? String ?? "")")

    app.typeText("(+ kept 1)\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { self.hasLine("42", in: $0) },
      "the prompt did not return with its definitions")

    app.typeKey("w", modifierFlags: .command)

    XCTAssertFalse(window.sheets.firstMatch.waitForExistence(timeout: 2), "an idle close asked")
    XCTAssertTrue(waitUntilGone(window.groups["pane-2"], timeout: 15))
  }

  /// Catches a form stuck in a C call that nothing can end. `(file/read stdin 1)` waits on the
  /// terminal in one C call, which Janet's interrupt flag never reaches. The first Ctrl-C leaves it
  /// running. A second, a second later, ends the helper. The pane stays open with the reason and a
  /// Restart button, and keeps its history.
  func testASecondCtrlCEndsAFormStuckInACallThatIgnoresTheFirst() {
    let app = launchApp()
    let (window, _) = openRepl(in: app)

    app.typeText("(file/read stdin 1)\n")

    // The app must have heard that the form runs, and the first press must come well before the
    // second, since a double tap is read as one.
    Thread.sleep(forTimeInterval: 2)
    app.typeKey("c", modifierFlags: .control)
    Thread.sleep(forTimeInterval: 1.5)

    let message = window.staticTexts["repl-ended-message"]

    XCTAssertFalse(message.exists, "one Ctrl-C ended a REPL that was stuck in a C call")

    app.typeKey("c", modifierFlags: .control)

    XCTAssertTrue(message.waitForExistence(timeout: 20), "the second Ctrl-C did not end the REPL")
    XCTAssertTrue(
      message.label.contains("Ctrl-C twice"), "the pane gave another reason: \(message.label)")
    XCTAssertTrue(window.groups["pane-2"].exists, "the pane closed")
    XCTAssertTrue(window.buttons["repl-restart-button"].exists, "the pane offered no restart")
  }

  /// Catches a history that does not survive close and undo, a restore that runs a saved line, and
  /// a restored REPL that cannot recall. The first line opens a pane through the host API, and a
  /// repeat would make a fourth. After Cmd-W and Cmd-Shift-T the REPL is back with a fresh helper,
  /// no pane was opened again, and Up Arrow recalls the newest line.
  func testHistorySurvivesCloseAndUndoWithoutRunningAgain() throws {
    let app = launchApp()
    let (window, terminal) = openRepl(in: app)

    app.typeText(
      "(uniterm/open-pane :text-viewer (first (uniterm/list-panes (first (uniterm/list-windows)))))\n"
    )
    XCTAssertTrue(waitForPaneCount(3, in: window), "the script's pane never opened")

    window.groups["pane-2"].click()

    app.typeText("(+ 40 2)\n")
    XCTAssertTrue(waitFor(terminal, timeout: 20) { self.hasLine("42", in: $0) })

    app.typeKey("w", modifierFlags: .command)
    XCTAssertFalse(window.sheets.firstMatch.waitForExistence(timeout: 2), "closing asked")
    XCTAssertTrue(waitForPaneCount(2, in: window), "the REPL pane never closed")

    app.typeKey("t", modifierFlags: [.command, .shift])
    XCTAssertTrue(waitForPaneCount(3, in: window), "undo never reopened the REPL")

    let restored = try XCTUnwrap(
      waitForRestoredRepl(in: window), "the restored REPL never showed its prompt")

    XCTAssertFalse(
      waitForPaneCount(4, in: window, timeout: 4), "a restored line opened another pane")

    app.typeKey(.upArrow, modifierFlags: [])
    XCTAssertTrue(
      waitFor(restored, timeout: 20) { $0.contains("repl:1:> (+ 40 2)") },
      "Up Arrow did not recall the newest line")

    app.typeKey(.upArrow, modifierFlags: [])

    // The editor draws one row and scrolls it to keep the cursor at the line's end. A pane
    // narrower than the recalled line shows its tail, so the check looks for the tail.
    XCTAssertTrue(
      waitFor(restored, timeout: 20) { $0.contains("windows)))))") },
      "Up Arrow did not recall the older line")
    XCTAssertTrue(waitForPaneCount(3, in: window), "recalling a line ran it")
  }

  private func waitForRestoredRepl(in window: XCUIElement) -> XCUIElement? {
    let deadline = Date().addingTimeInterval(40)

    while Date() < deadline {
      if let terminal = replTerminal(in: window),
        (terminal.value as? String)?.contains("repl:1:> ") == true
      {
        return terminal
      }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return nil
  }

  /// Catches a pane that closes when its helper ends, one that offers no way back, and a restart
  /// that loses the history. `(os/exit 0)` ends the helper, the pane stays with a message, and
  /// Restart starts a fresh helper that recalls the line that ended the last one.
  func testWhenTheHelperEndsThePaneStaysAndRestartKeepsTheHistory() {
    let app = launchApp()
    let (window, _) = openRepl(in: app)

    app.typeText("(os/exit 0)\n")

    let message = window.staticTexts["repl-ended-message"]

    XCTAssertTrue(message.waitForExistence(timeout: 20), "the pane showed no message")
    XCTAssertTrue(window.groups["pane-2"].exists, "the pane closed")

    let restart = window.buttons["repl-restart-button"]

    XCTAssertTrue(restart.exists, "the pane offered no restart")
    XCTAssertFalse(
      waitUntilGone(message, timeout: 3), "the REPL restarted without the user pressing Restart")

    restart.click()

    XCTAssertTrue(waitUntilGone(message, timeout: 15), "Restart left the message up")

    let terminal = window.groups["pane-2"].textViews["terminal"]

    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { $0.contains("repl:1:> ") },
      "the restarted REPL never showed its prompt")

    app.typeKey(.upArrow, modifierFlags: [])
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("repl:1:> (os/exit 0)") },
      "the restarted REPL did not keep the history")
  }
}
