import AppKit
import OSLog
import XCTest

/// The base class of every UI test. It launches the app in an isolated environment.
///
/// The app reads a throwaway plist for its preferences and writes its terminal config and its saved
/// layout to scratch folders, so no test touches the developer's settings or layout. The layout
/// folder lasts for the whole test, so a test can quit the app and launch it again over the same
/// saved layout.
///
/// The shell reads a fixture folder through `ZDOTDIR` and never the developer's dotfiles. Those may
/// prompt for an ssh passphrase or run anything else. Ghostty's zsh integration restores `ZDOTDIR`
/// for the startup files, so the integration stays on. The production app still starts the user's
/// real login shell.
@MainActor
class UnitermUITestCase: XCTestCase {
  private(set) var scratch = ""

  /// The folder for the app's script socket. A socket path holds 104 bytes, and `scratch` is too
  /// long to hold one, so this sits directly under `/tmp`. The app creates it.
  private(set) var scriptDirectory = ""
  private var launched: [XCUIApplication] = []

  /// Whether the last launch kept the system's open panel. See `launchApp`.
  private var usesRealOpenPanel = false

  /// The file the app's open panel reads its answer from, when the test answers it.
  private var openPanelAnswer: String { scratch + "-open-panel" }

  /// Logger for test marks, issue marks, and frontmost tracking.
  private let logger = Logger(subsystem: "dev.uniterm.uitests", category: "test-marks")
  private let issueLogger = Logger(subsystem: "dev.uniterm.uitests", category: "issue-marks")
  private let frontmostLogger = Logger(subsystem: "dev.uniterm.uitests", category: "frontmost")

  /// Observer for workspace activation notifications.
  private var activationObserver: NSObjectProtocol?

  /// The frontmost record for attaching to failing tests.
  private let frontmostRecord = FrontmostRecord()

  override func invokeTest() {
    // Log the test's start before setup and its end after teardown, so the marks bracket every
    // gesture.
    //
    // The name includes the class and method.
    logger.log("Test start: \(self.name, privacy: .public)")
    super.invokeTest()
    logger.log("Test end: \(self.name, privacy: .public)")
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
    scratch = NSTemporaryDirectory() + "uniterm-ui-\(UUID().uuidString)"
    scriptDirectory = "/tmp/ut-\(UUID().uuidString.prefix(8))"

    try FileManager.default.createDirectory(
      atPath: scratch + "-shell", withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: scratch + "-shell/.zshrc"))

    // Record the frontmost app at test start and observe activation changes.
    startFrontmostTracking()
  }

  /// A leftover instance would be logged at the next launch, so every test ends its app.
  override func tearDownWithError() throws {
    stopFrontmostTracking()

    let record = frontmostRecord.lines
    if !record.isEmpty {
      let attachment = XCTAttachment(string: record.joined(separator: "\n"))
      attachment.name = "frontmost-record.txt"
      attachment.lifetime = .deleteOnSuccess
      add(attachment)
    }

    for app in launched where app.state != .notRunning {
      app.terminate()
    }

    launched = []
    try? FileManager.default.removeItem(atPath: scratch + "-shell")
    try? FileManager.default.removeItem(atPath: scratch + "-terminal")
    try? FileManager.default.removeItem(atPath: scratch + "-layout")
    try? FileManager.default.removeItem(atPath: scratch + "-browser")
    try? FileManager.default.removeItem(atPath: scratch + "-controller-policy")
    try? FileManager.default.removeItem(atPath: openPanelAnswer)
    try? FileManager.default.removeItem(atPath: openPanelAnswer + ".asked")
    try? FileManager.default.removeItem(atPath: scriptDirectory)
  }

  override func record(_ issue: XCTIssue) {
    issueLogger.log(
      "Issue in \(self.name, privacy: .public): \(issue.compactDescription, privacy: .public)")
    super.record(issue)
  }

  /// The folder the app saves its layout in during this test.
  var layoutDirectory: URL {
    URL(fileURLWithPath: scratch + "-layout", isDirectory: true)
  }

  /// Records the frontmost app at test start and observes activation changes.
  ///
  /// The observer runs on a background queue because XCTest can block the main thread while waiting
  /// on a synthesized event's confirmation.
  private func startFrontmostTracking() {
    let initial = Self.describeFrontmost()
    frontmostLogger.log("At test start: \(initial, privacy: .public)")

    frontmostRecord.start(with: "At test start: \(initial)")

    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated

    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: queue
    ) { [frontmostLogger, frontmostRecord] notification in
      let frontmost = UnitermUITestCase.describeFrontmost()
      let timestamp = Date().timeIntervalSinceReferenceDate

      frontmostLogger.log("Activation: \(frontmost, privacy: .public)")
      frontmostRecord.append("Activation at \(timestamp): \(frontmost)")
    }
  }

  private func stopFrontmostTracking() {
    if let observer = activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      activationObserver = nil
    }
  }

  private static func describeFrontmost() -> String {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      return "none"
    }

    let bundle = app.bundleIdentifier ?? "no bundle ID"
    let name = app.localizedName ?? "unnamed"
    return "\(name) (\(bundle), pid \(app.processIdentifier))"
  }

  /// Writes a layout file before the app launches.
  func plantLayout(_ json: String) throws {
    try FileManager.default.createDirectory(at: layoutDirectory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: layoutDirectory.appendingPathComponent("layout.json"))
  }

  /// Launches the app. The app stores `settings` in its isolated defaults before it reads them, as
  /// `defaults write` would, so a test starts with a setting such as `paletteMode` already chosen.
  ///
  /// The app writes the seed itself. A seed the runner wrote into the plist would keep answering
  /// reads on macOS 26.7, even after the app changed the setting.
  ///
  /// The app's open panel answers through `choose` unless `realOpenPanel` is set. Only a test about
  /// the system's panel itself should set it. See `choose`.
  func launchApp(
    environment: [String: String] = [:], arguments: [String] = [], settings: [String: String] = [:],
    realOpenPanel: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    if !settings.isEmpty {
      guard let seed = try? JSONEncoder().encode(settings) else {
        preconditionFailure("a dictionary of strings always encodes")
      }

      app.launchEnvironment["UNITERM_DEFAULTS_SEED"] = String(decoding: seed, as: UTF8.self)
    }

    for (key, value) in environment {
      app.launchEnvironment[key] = value
    }

    app.launchArguments += arguments

    app.launchEnvironment["UNITERM_DEFAULTS_PATH"] = scratch
    app.launchEnvironment["UNITERM_TERMINAL_DIR"] = scratch + "-terminal"
    app.launchEnvironment["UNITERM_LAYOUT_DIR"] = scratch + "-layout"
    app.launchEnvironment["UNITERM_BROWSER_DIR"] = scratch + "-browser"
    app.launchEnvironment["UNITERM_BROWSER_STORE"] = "memory"
    app.launchEnvironment["UNITERM_SCRIPT_DIR"] = scriptDirectory
    app.launchEnvironment["UNITERM_CONTROLLER_RUNS_DIR"] = scratch + "-controller-runs"
    app.launchEnvironment["UNITERM_CONTROLLER_POLICY_DIR"] = scratch + "-controller-policy"
    app.launchEnvironment["SHELL"] = "/bin/zsh"
    app.launchEnvironment["ZDOTDIR"] = scratch + "-shell"

    // XCUITest types one key at a time, so a typed scratch path of about 150 characters took 5 s on
    // CI. The shell inherits this name for the scratch prefix, and `runInTerminal` types it instead.
    // It rides in the environment, not `.zshrc`, because tests write their own `.zshrc`.
    app.launchEnvironment["UT_SCRATCH"] = scratch
    app.launchEnvironment["SSH_AUTH_SOCK"] = ""
    app.launchEnvironment["UNITERM_PLACE_NAMES"] = "off"

    // The app records each input event it takes to the unified log, so a failed run's kept log
    // shows which of XCTest's events reached it.
    app.launchEnvironment["UNITERM_RECORD_INPUT"] = "1"

    usesRealOpenPanel = realOpenPanel
    if !realOpenPanel { app.launchEnvironment["UNITERM_OPEN_PANEL_ANSWER"] = openPanelAnswer }
    app.launch()
    app.activate()
    launched.append(app)
    return app
  }

  // MARK: Waiting

  /// The nth main window in the order opened, counting from 1. The first is `main-window`. A
  /// number is never reused, so a window opened after a close takes the next one.
  func mainWindow(_ number: Int = 1, in app: XCUIApplication) -> XCUIElement {
    app.windows[number == 1 ? "main-window" : "main-window-\(number)"]
  }

  /// Waits for the window's first terminal to show a prompt. Windows other than the first need
  /// their own number.
  func waitForTerminal(in app: XCUIApplication, window number: Int = 1) -> XCUIElement {
    let terminal = mainWindow(number, in: app).textViews["terminal"]
    XCTAssertTrue(terminal.appears(timeout: 15))

    // Keys typed before the shell reads its terminal can be lost. The fixture's zsh prompt ends in
    // "% ", so wait for it.
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { $0.contains("% ") }, "the shell never showed a prompt")

    // A synthesized key event goes nowhere while the app is in the background, and the launch-time
    // activation may not have landed yet. Activate once, then wait for the state to settle.
    XCTAssertTrue(waitForForeground(app, activating: true), "the app never became frontmost")
    return terminal
  }

  /// The bundled `uniterm` command of the app the tests drive. The app sits beside the test runner
  /// in the build products folder. `UNITERM_APP_PATH` names another build.
  func bundledCommand() throws -> String {
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

  /// The test instance's well-known socket, in the folder the app listens in.
  var testSocket: String { scriptDirectory + "/uniterm.sock" }

  /// Types the path of a shell script into the terminal and runs it. A script under `scratch` is
  /// typed through the shell's `UT_SCRATCH` name, which expands to the same full path.
  func runInTerminal(_ script: String, in app: XCUIApplication) {
    if script.hasPrefix(scratch) {
      app.typeText("sh ${UT_SCRATCH}\(script.dropFirst(scratch.count))\n")
    } else {
      app.typeText("sh \(script)\n")
    }
  }

  func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }

  /// Waits for a file the shell writes, and returns what it holds. A file that has not appeared in
  /// 60 seconds fails the test, so a script that never ran cannot hang it.
  ///
  /// The shell's `echo ... > file` creates the file empty before it writes the line. So the file
  /// counts only once it ends in a newline, which every writer's `echo` adds.
  func waitForFile(_ path: String, timeout: TimeInterval = 60) -> String? {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if let text = try? String(contentsOfFile: path, encoding: .utf8), text.hasSuffix("\n") {
        return text
      }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return nil
  }

  /// Answers the oldest review in the Pending Requests panel as a user does: opens the panel from the
  /// Window menu, selects its first row, and presses the button named `identifier`. The panel
  /// closes after, so the terminal takes the keys again. A test that runs a declared script file
  /// calls it once the script is started, since the file runs no code until its powers are allowed.
  func answerFirstReview(in app: XCUIApplication, pressing identifier: String) {
    app.menuBars.menuBarItems["Window"].click()
    app.menuBars.menuItems["Pending Requests\u{2026}"].click()

    let panel = app.windows["pending-requests-window"]

    XCTAssertTrue(panel.appears(timeout: 5), "the Pending Requests panel never opened")

    let row = panel.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(row.appears(timeout: 30), "the review never reached the panel")
    XCTAssertTrue(
      waitUntilHittable(row), "the review's row cannot take a click. \(focusReport(app))")
    row.click()

    let button = panel.buttons[identifier]

    XCTAssertTrue(button.appears(timeout: 5), "the review offers no \(identifier)")
    button.click()

    let close = panel.buttons[XCUIIdentifierCloseWindow]

    if close.isHittable { close.click() }
  }

  /// Enables remote control on the focused pane from the File menu, as a user does, and waits for
  /// the pane's control badge. Every new pane starts disconnected, so a script that acts from it
  /// needs this first.
  func enableRemoteControl(pane: Int, in app: XCUIApplication, window number: Int = 1) {
    app.menuBars.menuItems["Enable Remote Control"].click()

    XCTAssertTrue(
      mainWindow(number, in: app).buttons["pane-control-\(pane)"].appears(timeout: 10),
      "the pane never showed its control badge")
  }

  /// Waits until the app reports `runningForeground`. State reads lag a window change, so a single
  /// read right after a close can still say background. With `activating`, the app is asked to
  /// activate once when the first read is not foreground. Without it, only the app's own behavior
  /// can bring it forward, which is what a test of a window close needs to prove.
  func waitForForeground(
    _ app: XCUIApplication, activating: Bool = false, timeout: TimeInterval = 10
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var asked = false

    while Date() < deadline {
      if app.state == .runningForeground { return true }

      if activating && !asked {
        app.activate()
        asked = true
      }

      Thread.sleep(forTimeInterval: 0.1)
    }

    return app.state == .runningForeground
  }

  func waitFor(
    _ element: XCUIElement, timeout: TimeInterval, _ condition: @escaping (String) -> Bool
  ) -> Bool {
    // Reading `value` of an element that does not exist yet fails the test outright, so a wait that
    // starts before the element appears must check for it first.
    pollUntil(timeout: timeout) {
      guard element.exists, let value = element.value as? String else { return false }

      return condition(value)
    }
  }

  func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
    else { return nil }

    return String(text[range])
  }

  /// True when `marker` is on screen with a shell prompt below it, as saved output shows above a
  /// fresh shell's first prompt.
  func promptFollows(_ marker: String, in text: String) -> Bool {
    guard let shown = text.range(of: marker), let prompt = text.range(of: "% ", options: .backwards)
    else { return false }

    return shown.upperBound <= prompt.lowerBound
  }

  func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    element.disappears(timeout: timeout)
  }

  /// Opens Settings, picks a status bar position, and closes Settings so a main window is key
  /// again.
  func chooseStatusBarPosition(_ title: String, in app: XCUIApplication) {
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.appears(timeout: 5))

    let control = settings.radioGroups["status-bar-position-control"]
    XCTAssertTrue(control.appears(timeout: 5))
    control.radioButtons[title].click()

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(settings, timeout: 5))
  }

  /// Waits until the element can take a click. An element can exist before it is on screen: a
  /// closed menu's items have no frame, and a list still settling after a scroll has not moved its
  /// rows into view yet.
  func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    pollUntil(timeout: timeout) { element.exists && element.isHittable }
  }

  func waitForNoSheet(in window: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    window.sheets.firstMatch.disappears(timeout: timeout)
  }

  /// Keeps a screenshot of uniterm's own element with the test results, never of the screen.
  func keepElementScreenshot(_ element: XCUIElement, named name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  // MARK: Diagnostics

  /// Who held the keyboard when a key seemed to go nowhere: the app's state, the frontmost app,
  /// and the element in the app with keyboard focus. A wait that follows a key names this in its
  /// failure. Then the failure says whether another app took the key or the app sent it elsewhere.
  func focusReport(_ app: XCUIApplication) -> String {
    let front = NSWorkspace.shared.frontmostApplication.map {
      let bundle = $0.bundleIdentifier ?? "no bundle ID"
      return "\($0.localizedName ?? "unnamed") (\(bundle), pid \($0.processIdentifier))"
    }

    let focused = app.descendants(matching: .any)
      .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
    let label = focused.label.isEmpty ? "" : ", labeled '\(focused.label)',"
    let holder = focused.exists ? "'\(focused.identifier)'\(label)" : "nothing"

    return "The app is \(Self.describe(app.state)). The frontmost app is \(front ?? "none"). "
      + "In the app, \(holder) has keyboard focus."
  }

  private static func describe(_ state: XCUIApplication.State) -> String {
    switch state {
    case .runningForeground: return "in the foreground"
    case .runningBackground: return "in the background"
    case .notRunning: return "not running"
    case .unknown: return "in an unknown state"
    @unknown default: return "in state \(state.rawValue)"
    }
  }

  // MARK: Launcher

  /// The launcher in a window. It is the whole content of a new pane until an applet is chosen.
  func launcher(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["launcher"]
  }

  /// Presses a split key, waits for the launcher, then accepts its default, a terminal in shell
  /// mode.
  func openPane(
    in app: XCUIApplication, window number: Int = 1, keys: String,
    modifiers: XCUIElement.KeyModifierFlags
  ) {
    let window = mainWindow(number, in: app)

    app.typeKey(keys, modifierFlags: modifiers)
    XCTAssertTrue(
      launcher(in: window).appears(timeout: 5),
      "the launcher never opened. \(focusReport(app))")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(launcher(in: window), timeout: 10), "Return left the launcher")
  }

  /// Chooses `file` in the open panel that the last action asked for. The panel must hang from a
  /// window, as a sheet.
  ///
  /// By default the app's panel is answered through a file, and the system's panel never shows.
  /// That panel runs in another process, and each accessibility query while it shows takes 1.5 to
  /// 5 s. A test about what uniterm does with a chosen file has no use for that cost. A test that
  /// launched with `realOpenPanel` drives the system's panel instead.
  func choose(_ file: URL, in app: XCUIApplication, window: XCUIElement) {
    guard usesRealOpenPanel else {
      answerOpenPanel(with: file)
      return
    }

    chooseInSystemPanel(file, in: app, window: window)
  }

  private func answerOpenPanel(with file: URL) {
    let asked = openPanelAnswer + ".asked"
    let request = waitForFile(asked, timeout: 10)
    XCTAssertNotNil(request, "the app never asked for an open panel")
    XCTAssertTrue(
      request?.hasPrefix("sheet ") ?? false,
      "the open panel would not hang from the window: \(request ?? "")")

    try? FileManager.default.removeItem(atPath: asked)

    do {
      try (file.path + "\n").write(toFile: openPanelAnswer, atomically: true, encoding: .utf8)
    } catch {
      XCTFail("could not answer the open panel: \(error)")
    }
  }

  /// Chooses a file in the system's open panel that is already showing, by entering its path in
  /// the go-to-folder sheet. The path is typed. Pasting it would rewrite the developer's clipboard,
  /// which may hold secrets. The field autocompletes a typed path against sibling folders, so the
  /// entry is slow and the path is checked after it.
  ///
  /// Each query while the panel shows takes 1.5 to 5 s, so each wait on the panel allows 20 s. That
  /// holds several queries, where 5 s held one and failed whenever the first came too early.
  private func chooseInSystemPanel(_ file: URL, in app: XCUIApplication, window: XCUIElement) {
    let panel = window.sheets.firstMatch
    XCTAssertTrue(panel.appears(timeout: 20), "no open panel")

    app.typeKey("g", modifierFlags: [.command, .shift])

    let goTo = panel.sheets.firstMatch
    XCTAssertTrue(goTo.appears(timeout: 20), "no go-to-folder sheet. \(focusReport(app))")

    let pasteboardChanges = NSPasteboard.general.changeCount

    app.typeText(file.path)

    XCTAssertEqual(
      NSPasteboard.general.changeCount, pasteboardChanges,
      "entering the path rewrote the user's clipboard")

    // Check the entered path, because a path the field changed sends the panel nowhere.
    let typed = goTo.textFields.firstMatch
    XCTAssertTrue(
      waitFor(typed, timeout: 20) { $0 == file.path },
      "the go-to field holds \(String(describing: typed.value)), not \(file.path)")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(
      waitUntilGone(goTo, timeout: 20),
      "the go-to-folder sheet never closed. \(focusReport(app)) "
        + "The sheet: \(goTo.debugDescription)")

    // The go-to sheet closes before the panel moves its selection to the file. A Return in that gap
    // closes the panel without opening the file, so wait for the file's row to show as selected.
    let name = file.lastPathComponent
    let shown = NSPredicate(format: "value == %@ OR label == %@ OR title == %@", name, name, name)
    let selected = panel.descendants(matching: .any)
      .matching(NSPredicate(format: "selected == true"))
      .containing(shown).firstMatch
    XCTAssertTrue(
      selected.appears(timeout: 20), "the panel never selected \(name). \(focusReport(app))")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitForNoSheet(in: window, timeout: 20), "the panel never closed")
  }
}

/// The lines of a test's frontmost record. The activation observer appends from its own queue while
/// the test reads the lines at teardown on the main thread, so every access goes through one serial
/// queue. That queue is what makes the unchecked conformance safe.
private final class FrontmostRecord: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.uniterm.uitests.frontmost-record")
  private var stored: [String] = []

  var lines: [String] { queue.sync { stored } }

  func start(with line: String) {
    queue.sync { stored = [line] }
  }

  func append(_ line: String) {
    queue.sync { stored.append(line) }
  }
}
