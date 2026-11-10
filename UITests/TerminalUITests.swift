import XCTest

/// Drives the launched app with a real shell in its pane. Each test proves a contract that only the
/// window server and AppKit's key routing can show.
///
/// The tests read marker output that the typed command alone cannot produce. A command such as
/// `echo "T:$TERM:"` shows `T:$TERM:` as typed and `T:xterm-ghostty:` as output.
///
/// The tests type no apostrophes. When a UI test typed one, the logged key event had the Control
/// flag set (flags 262144) and the terminal sent CSI 39;5u. A double quote arrived with the Shift
/// flag only (131072). That points at the synthetic event, but it is an observation and not a
/// proof. The key translation is covered in the package tests.
@MainActor
final class TerminalUITests: UnitermUITestCase {
  /// Catches a pane that does not take keyboard focus, a shell that starts with the wrong TERM, and
  /// bundled terminfo that infocmp cannot find.
  func testShellTakesInputAndReportsGhosttyTerm() {
    let app = launchApp()
    let terminal = waitForTerminal(in: app)

    app.typeText("echo \"T:$TERM:\"; infocmp xterm-ghostty >/dev/null && echo \"I:$((6*7)):\"\n")

    XCTAssertTrue(
      waitFor(terminal, timeout: 40) {
        $0.contains("T:xterm-ghostty:") && $0.contains("I:42:")
      }, "TERM or the bundled terminfo is wrong. Screen: \(terminal.value as? String ?? "")")
  }

  /// Catches a window resize that never reaches the shell. The grid changes, and `stty size` in
  /// the shell reports a different size afterwards.
  func testShellSeesTheWindowSize() {
    let app = launchApp()
    let window = app.windows["main-window"]
    let terminal = waitForTerminal(in: app)

    app.typeText("echo \"A:$(stty size | tr \" \" x):\"\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) {
        $0.range(of: #"A:\d+x\d+:"#, options: .regularExpression) != nil
      }, "no size reported. Screen: \(terminal.value as? String ?? "")")
    let first = firstMatch(#"A:(\d+x\d+):"#, in: terminal.value as? String ?? "")

    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
      CGVector(dx: -2, dy: -2))
    corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -300, dy: -150)))

    app.typeText("echo \"B:$(stty size | tr \" \" x):\"\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) {
        $0.range(of: #"B:\d+x\d+:"#, options: .regularExpression) != nil
      })
    let second = firstMatch(#"B:(\d+x\d+):"#, in: terminal.value as? String ?? "")
    print("TERMINAL SCREEN AFTER RESIZE>>>\n\(terminal.value as? String ?? "")\n<<<")

    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertNotEqual(first, second, "the shell kept its old size after the window shrank")
  }

  /// Catches Ghostty's built-in bindings catching keys before uniterm. With the terminal focused,
  /// Cmd-T opens a tab, which shows the tab bar. Cmd-D and Cmd-Shift-D reach uniterm too, and each
  /// opens the launcher.
  func testCommandKeysReachUnitermWhileTheTerminalIsFocused() {
    let app = launchApp()
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(
      app.descendants(matching: .any)["tab-1"].waitForExistence(timeout: 10),
      "Cmd-T never opened a tab")

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(
      launcher(in: window).waitForExistence(timeout: 5), "Cmd-D never opened the launcher")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(launcher(in: window)))

    app.typeKey("d", modifierFlags: [.command, .shift])
    XCTAssertTrue(
      launcher(in: window).waitForExistence(timeout: 5),
      "Cmd-Shift-D never opened the launcher")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(launcher(in: window)))
  }

  /// Cmd-W closes the pane, and with one pane the window closes. The app keeps running.
  func testCommandWClosesThePaneAndTheWindow() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitUntilGone(mainWindow(in: app), timeout: 15), "the window stayed open")
    XCTAssertEqual(app.state, .runningForeground)
  }

  /// Cmd-Q reaches uniterm while the terminal is focused.
  func testCommandQQuits() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    app.typeKey("q", modifierFlags: .command)

    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
  }

  /// Catches a quit that ignores a running program. With `sleep` running, Cmd-Q asks and names the
  /// pane. Cancel keeps the app and the program. A second Cmd-Q and Quit ends the app. A second
  /// Cmd-Q while the question is open must not stack another one.
  func testCommandQAsksWhileAProgramRunsAndCancelKeepsTheApp() {
    let app = launchApp()
    let window = app.windows["main-window"]
    let terminal = waitForTerminal(in: app)

    app.typeText("sleep 300\n")
    Thread.sleep(forTimeInterval: 2)

    app.typeKey("q", modifierFlags: .command)
    let sheet = window.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "quit never asked")
    XCTAssertEqual(app.state, .runningForeground)

    app.typeKey("q", modifierFlags: .command)
    XCTAssertEqual(window.sheets.count, 1, "a second quit stacked another question")

    sheet.buttons["Cancel"].click()
    XCTAssertTrue(waitForNoSheet(in: window))
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(terminal.exists)

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout: 10))
    window.sheets.firstMatch.buttons["Quit"].click()

    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
  }

  /// Catches a shell exit that leaves an empty pane open.
  func testShellExitClosesThePane() {
    let app = launchApp()
    let terminal = waitForTerminal(in: app)

    app.typeText("echo \"R:$((40+2)):\"\n")
    XCTAssertTrue(waitFor(terminal, timeout: 40) { $0.contains("R:42:") })

    app.typeText("exit\n")

    XCTAssertTrue(waitUntilGone(mainWindow(in: app), timeout: 20), "the window stayed open")
    XCTAssertEqual(app.state, .runningForeground)
  }

  /// Catches a Clear Screen command that does not reach the terminal. It has no default key, so
  /// the test runs it from the palette. The marker leaves the screen.
  func testClearScreenClearsTheTerminal() {
    let app = launchApp()
    let terminal = waitForTerminal(in: app)

    app.typeText("echo \"C:$((40+2)):\"\n")
    XCTAssertTrue(waitFor(terminal, timeout: 40) { $0.contains("C:42:") })

    app.typeKey("k", modifierFlags: .command)
    app.typeText("clear screen\n")

    XCTAssertTrue(waitFor(terminal, timeout: 10) { !$0.contains("C:42:") })
  }

  /// Catches a Ctrl-C that the app never turns into the terminal's interrupt. The shell runs a
  /// foreground `sleep`, and the key must end it, so the echo after it never runs and the prompt
  /// takes the next command. The marker is computed, so only the echo's output can show it.
  func testControlCInterruptsAForegroundProgram() {
    let app = launchApp()
    let terminal = waitForTerminal(in: app)

    app.typeText("sleep 30; echo slept-$((40+2))\n")
    Thread.sleep(forTimeInterval: 1)

    app.typeKey("c", modifierFlags: .control)
    app.typeText("echo after-$((40+2))\n")

    XCTAssertTrue(
      waitFor(terminal, timeout: 5) { $0.contains("after-42") },
      "Ctrl-C did not end the sleep. Screen: \(terminal.value as? String ?? "")")
    XCTAssertFalse(
      (terminal.value as? String ?? "").contains("slept-42"), "the sleep ran to its end")
  }

  /// Catches a Ctrl-F that a window menu item takes before the terminal sees it. macOS adds
  /// Window > Fill with the key fn-Ctrl-F, and a menu match that ignores the fn flag fires it for a
  /// plain Ctrl-F. `cat -v` runs in the foreground, so the pty echoes the byte as `^F` and cat
  /// prints it the same way. Neither shows unless the byte reaches the pty.
  ///
  /// The marker is computed, so only the echo's output shows that the shell has handed the
  /// terminal to cat. It cannot prove that other fn-Control items leave their plain keys alone.
  func testControlFReachesTheTerminal() {
    let app = launchApp()
    let terminal = waitForTerminal(in: app)

    app.typeText("echo ready-$((40+2)); cat -v\n")

    XCTAssertTrue(
      waitFor(terminal, timeout: 10) { $0.contains("ready-42") },
      "the shell never ran the command. Screen: \(terminal.value as? String ?? "")")

    app.typeKey("f", modifierFlags: .control)
    app.typeText("x\n")

    XCTAssertTrue(
      waitFor(terminal, timeout: 5) { $0.contains("^Fx") },
      "Ctrl-F never reached the terminal. Screen: \(terminal.value as? String ?? "")")
  }
}
