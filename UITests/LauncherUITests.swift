import AppKit
import XCTest

/// Drives the in-pane launcher in the launched app. Each test proves a contract that only real key
/// routing and the window server can show: the first responder, the Window menu's number keys, and
/// the pane that stays after an applet replaces the launcher.
@MainActor
final class LauncherUITests: UnitermUITestCase {
  /// Where the screenshot test also writes its PNGs. The runner may not be allowed to write there,
  /// so the attachments in the result bundle are the record.
  private static let shotsDirectory = URL(
    fileURLWithPath:
      "/private/tmp/claude-501/-Users-ripta-projects-uniterm/9c422818-aa92-4fa3-9745-41242178e836/scratchpad/launcher-shots",
    isDirectory: true)

  private func startedWindow() -> (app: XCUIApplication, window: XCUIElement) {
    let app = launchApp()
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)
    return (app, window)
  }

  /// Catches a launcher that needs a click before it takes keys, or one that does not open a
  /// terminal on Return. Cmd-D shows it, Return alone replaces it with a shell in the same pane.
  func testReturnOpensATerminalInTheSamePane() {
    let (app, window) = startedWindow()

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).appears(timeout: 5), "Cmd-D showed no launcher")
    XCTAssertFalse(window.sheets.firstMatch.exists, "a dialog opened")

    app.typeKey(.return, modifierFlags: [])

    let pane = window.groups["pane-2"]
    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(pane.textViews["terminal"].appears(timeout: 20))
    XCTAssertTrue(
      waitFor(pane.textViews["terminal"], timeout: 40) { $0.contains("% ") },
      "the new pane never showed a prompt")
  }

  /// Catches a split that starts in the app's launch directory, or that leans on libghostty
  /// remembering the last terminal. After cd /tmp in the first pane, Cmd-D and Return start the
  /// new pane in /tmp. Its status bar and its own pwd both say so.
  func testASplitStartsInTheDirectoryOfThePaneItCameFrom() {
    let (app, window) = startedWindow()

    app.typeText("cd /tmp\n")
    let directory = window.descendants(matching: .any).matching(identifier: "status-applet-0")
      .firstMatch
    XCTAssertTrue(
      waitFor(directory, timeout: 15) { $0 == "tmp" },
      "the status bar never showed the new directory")

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))

    app.typeKey(.return, modifierFlags: [])

    let terminal = window.groups["pane-2"].textViews["terminal"]
    XCTAssertTrue(terminal.appears(timeout: 20))
    XCTAssertTrue(waitFor(terminal, timeout: 40) { $0.contains("% ") })

    app.typeText("echo \"D:$(pwd -P):\"\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("D:/private/tmp:") },
      "the new pane did not start in /tmp")
    XCTAssertTrue(waitFor(directory, timeout: 5) { $0 == "tmp" })
  }

  /// Catches an arrow that does not move the selection, a command field that does not take the
  /// keyboard, and a program that opens as a shell. Down, then typing, then Return runs the command
  /// in program mode, where New Tab is off.
  func testArrowTypeAndReturnOpensProgramMode() {
    let (app, window) = startedWindow()

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))

    app.typeKey(.downArrow, modifierFlags: [])
    app.typeText("sleep 300")
    app.typeKey(.return, modifierFlags: [])

    let pane = window.groups["pane-2"]
    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(pane.textViews["terminal"].appears(timeout: 20))

    app.menuBars.menuBarItems["File"].click()
    let newTab = app.menuBars.menuItems["New Tab"]
    XCTAssertTrue(newTab.appears(timeout: 5))
    XCTAssertFalse(newTab.isEnabled, "the pane opened as a shell, not as a program")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Catches an Escape that leaves an empty pane behind.
  func testEscapeClosesTheEmptyPane() {
    let (app, window) = startedWindow()

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))

    app.typeKey(.escape, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertFalse(window.groups["pane-2"].exists)
    XCTAssertTrue(window.textViews["terminal"].exists, "the first pane went away")
  }

  /// Catches Cmd-2 reaching the Window menu's Select Tab 2 instead of the launcher. The number
  /// picks program mode and the keyboard is already in the command field, so typing lands there.
  func testCommandTwoPicksProgramModeAndFocusesTheCommandField() {
    let (app, window) = startedWindow()

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))

    app.typeKey("2", modifierFlags: .command)

    let command = window.textFields["launcher-command"]
    XCTAssertTrue(command.appears(timeout: 5), "Cmd-2 showed no command field")

    app.typeText("htop")
    XCTAssertEqual(command.value as? String, "htop", "the keyboard was not in the command field")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(command), "Escape did not leave the command field")
    XCTAssertTrue(launcher(in: window).exists, "Escape in the command field closed the pane")

    app.typeText("x")
    XCTAssertEqual(
      window.textFields["launcher-filter"].value as? String, "x",
      "the keyboard did not return to the filter")
  }

  /// Keeps a picture of the launcher in light and dark, with the terminal selected and with
  /// program mode open. Unit tests prove the rules. These show that the colors follow the theme.
  func testLauncherLooksRightInLightAndDark() throws {
    let app = launchApp()
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)

    try? FileManager.default.createDirectory(
      at: Self.shotsDirectory, withIntermediateDirectories: true)

    for (name, button) in [("light", "Light"), ("dark", "Dark")] {
      app.typeKey(",", modifierFlags: .command)
      let settings = app.windows["settings-window"]
      XCTAssertTrue(settings.appears(timeout: 5))
      settings.radioGroups["appearance-control"].radioButtons[button].click()
      app.typeKey("w", modifierFlags: .command)
      XCTAssertTrue(waitUntilGone(settings, timeout: 5))

      app.typeKey("d", modifierFlags: .command)
      XCTAssertTrue(launcher(in: window).appears(timeout: 5))
      Thread.sleep(forTimeInterval: 0.5)
      attach(window, named: "launcher-\(name)")

      app.typeKey("2", modifierFlags: .command)
      XCTAssertTrue(window.textFields["launcher-command"].appears(timeout: 5))
      app.typeText("htop")
      Thread.sleep(forTimeInterval: 0.5)
      attach(window, named: "launcher-program-\(name)")

      app.typeKey(.escape, modifierFlags: [])
      app.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(waitUntilGone(launcher(in: window)))
    }
  }

  /// Catches a short pane that clips the filter box or strands entries out of reach, and keeps a
  /// picture of it. Two downward splits leave the newest launcher in a pane about a quarter of
  /// the window tall. Its filter box is on screen. The scroll wheel brings the last entry into
  /// view, and so do the arrow keys once they reach it.
  func testAShortPaneKeepsTheFilterBoxAndScrollsToTheLastEntry() {
    let (app, window) = startedWindow()

    app.typeKey("d", modifierFlags: [.command, .shift])
    XCTAssertTrue(
      launcher(in: window).appears(timeout: 5), "Cmd-Shift-D showed no launcher")
    Thread.sleep(forTimeInterval: 0.5)
    attach(window, named: "launcher-half-height")

    app.typeKey("d", modifierFlags: [.command, .shift])

    let pane = window.groups.matching(
      NSPredicate(format: "identifier BEGINSWITH 'pane-' AND value == 'focused'")
    ).firstMatch
    let filter = pane.textFields["launcher-filter"]

    XCTAssertTrue(filter.appears(timeout: 5), "the second split showed no launcher")
    XCTAssertTrue(filter.isHittable, "the filter box is off screen")
    Thread.sleep(forTimeInterval: 0.5)
    attach(window, named: "launcher-quarter-height")

    let last = pane.buttons["launcher-repl"]

    XCTAssertFalse(last.isHittable, "the pane is tall enough to show every entry")

    // Which way a wheel moves the list follows the machine's scroll direction setting, and CI
    // runners differ in it. The list starts at the top, so a wheel that goes up moves nothing.
    // The wheel then goes the other way. A list that scrolls neither way still fails.
    let list = pane.scrollViews.firstMatch
    var wheels = ["before: \(scrollReport(list, last: last))"]

    // The wheel goes through the shared call, which settles the pointer on the list first. The
    // scroll view itself has no hit point, so the call aims at its middle.
    sendWheel(
      deltaY: -1000, at: list, in: window, context: scrollReport(list, last: last))

    if !waitUntilHittable(last, timeout: 2) {
      wheels.append("after -1000: \(scrollReport(list, last: last))")
      attach(window, named: "launcher-quarter-height-first-wheel")

      sendWheel(
        deltaY: 1000, at: list, in: window, context: scrollReport(list, last: last))
    }

    let scrolled = waitUntilHittable(last)

    if !scrolled {
      wheels.append("after +1000: \(scrollReport(list, last: last))")
      attach(window, named: "launcher-quarter-height-second-wheel")
    }

    XCTAssertTrue(
      scrolled,
      "the scroll wheel did not scroll the list. \(wheels.joined(separator: "; ")). "
        + focusReport(app))
    Thread.sleep(forTimeInterval: 0.5)
    attach(window, named: "launcher-quarter-height-wheel")

    for _ in 1..<8 {
      app.typeKey(.downArrow, modifierFlags: [])
    }

    XCTAssertTrue(
      waitFor(last, timeout: 5) { $0 == "selected" }, "the arrow keys did not reach the last entry")
    XCTAssertTrue(waitUntilHittable(last), "the last entry is out of sight. \(focusReport(app))")
    Thread.sleep(forTimeInterval: 0.5)
    attach(window, named: "launcher-quarter-height-last")
  }

  /// Where the list stands, for a wheel that seemed to move nothing. The scroller's value says
  /// whether the list moved at all, and the last entry's frame against the list's says whether it
  /// moved without the entry turning hittable. The pointer says which list a wheel went to.
  private func scrollReport(_ list: XCUIElement, last: XCUIElement) -> String {
    let scroller = list.scrollBars.firstMatch
    let position = scroller.exists ? "\(scroller.value ?? "none")" : "no scroller"

    return "scroller \(position), list \(list.frame), last entry \(last.frame), "
      + "pointer \(pointerLocation())"
  }

  private func attach(_ element: XCUIElement, named name: String) {
    let screenshot = element.screenshot()

    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)

    try? screenshot.pngRepresentation.write(
      to: Self.shotsDirectory.appendingPathComponent("\(name).png"))
  }
}
