import AppKit
import XCTest

/// Drives the Questions pane in the running app. A debug build reads request files from the folder
/// `UNITERM_TEST_QUESTIONS_DIR` names, and opens each form through the window layer's own entry for
/// a script's form, so the placement, the focus, and the badge are the real ones. A test writes a
/// file, the app opens the form, and the form's outcome comes back in a file beside it.
/// `QuestionsWireUITests` drives the same pane from a script through the wire.
///
/// Each test proves a contract that only AppKit's key routing, real controls, and the window
/// server show: where the keyboard goes, which key reaches which button, and how the pane looks.
/// The package tests prove the model beneath them.
@MainActor
final class QuestionsUITests: UnitermUITestCase {
  private var requests: URL { URL(fileURLWithPath: scratch + "-questions", isDirectory: true) }
  private var sequence = 0

  // MARK: Helpers

  private func launchQuestions(arguments: [String] = [], settings: [String: String] = [:])
    -> XCUIApplication
  {
    let folder = requests

    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let app = launchApp(
      environment: ["UNITERM_TEST_QUESTIONS_DIR": folder.path], arguments: arguments,
      settings: settings)

    XCTAssertTrue(mainWindow(in: app).appears(timeout: 10))
    _ = waitForTerminal(in: app)

    return app
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    mainWindow(in: app).descendants(matching: .any)[identifier]
  }

  /// Waits until the element named `identifier` holds the keyboard.
  private func waitForFocus(on identifier: String, in app: XCUIApplication) -> Bool {
    let focused = app.descendants(matching: .any)
      .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch

    return pollUntil(timeout: 5) { focused.exists && focused.identifier == identifier }
  }

  /// Asks a form as a requester. Returns the name of the request, which finds its outcome.
  @discardableResult
  private func ask(
    _ spec: String, requester: String = "build", name: String = "Build script",
    pane: String? = "Pane 1"
  ) throws -> String {
    sequence += 1

    let base = "request-\(sequence)"
    let paneField = pane.map { #", "pane": "\#($0)""# } ?? ""

    try send(
      #"{"requester": "\#(requester)", "name": "\#(name)"\#(paneField), "spec": \#(spec)}"#,
      as: base)

    return base
  }

  private func command(_ command: String, requester: String) throws {
    sequence += 1

    try send(
      #"{"command": "\#(command)", "requester": "\#(requester)"}"#, as: "command-\(sequence)")
  }

  private func send(_ json: String, as base: String) throws {
    try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    try Data(json.utf8).write(
      to: requests.appendingPathComponent(base + ".json"), options: .atomic)
  }

  /// What the app did with a request: `opened`, `reused`, or why it was refused.
  private func opening(of base: String) -> String? {
    pollFile(base + ".opened") { String(decoding: $0, as: UTF8.self) }
  }

  /// The outcome a script would receive, once the form resolves.
  private func outcome(of base: String, timeout: TimeInterval = 15) -> [String: Any]? {
    pollFile(base + ".outcome.json", timeout: timeout) {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? nil
  }

  private func noOutcome(of base: String) -> Bool {
    Thread.sleep(forTimeInterval: 0.6)

    return !FileManager.default.fileExists(
      atPath: requests.appendingPathComponent(base + ".outcome.json").path)
  }

  private func pollFile<T>(_ name: String, timeout: TimeInterval = 15, _ read: (Data) -> T) -> T? {
    let url = requests.appendingPathComponent(name)
    var found: T?

    _ = pollUntil(timeout: timeout) {
      guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }

      found = read(data)

      return true
    }

    return found
  }

  /// Attaches a screenshot of the uniterm window element only, never the screen. A window
  /// screenshot shows whatever is on screen over the window's rectangle, so the app must be in front
  /// first. When it cannot be brought forward, the test fails and attaches nothing, rather than
  /// attach pixels that belong to other applications.
  private func attachWindow(named name: String, in app: XCUIApplication) {
    guard waitForForeground(app, activating: true) else {
      XCTFail("uniterm was not frontmost, so no screenshot was taken: \(name)")
      return
    }

    let attachment = XCTAttachment(screenshot: mainWindow(in: app).screenshot())

    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func answers(_ outcome: [String: Any]?) -> [String: Any] {
    outcome?["answers"] as? [String: Any] ?? [:]
  }

  private let deploy = """
    {"title": "Deploy settings", "items": [
      {"block": "notice", "level": "warning", "text": "This deploys to production."},
      {"id": "region", "text": "Which region?", "detail": "Pick where the build goes.",
       "type": "choice", "choices": ["us-east", "eu-west"], "other": true, "required": true},
      {"id": "replicas", "text": "How many replicas?", "type": "integer", "default": 3,
       "validate": {"minimum": 1, "maximum": 20}},
      {"id": "notes", "text": "Anything else?", "type": "text", "multiline": true,
       "placeholder": "Notes for the team", "validate": {"maxLength": 500}}],
     "actions": [
      {"id": "deploy", "label": "Deploy", "role": "primary"},
      {"id": "skip", "label": "Skip", "validates": false},
      {"id": "cancel", "role": "cancel"}]}
    """

  private let branch = """
    {"title": "New branch", "items": [
      {"id": "name", "text": "Branch name?", "type": "string", "required": true,
       "placeholder": "feature/thing", "validate": {"pattern": "^[a-z0-9/-]+$"}}]}
    """

  // MARK: The pane and its chrome

  /// Catches a bar that shows for one form, a blank strip where it was, and chrome that is missing
  /// the requester. One form shows no tab bar, and the header says who asks and from where. The
  /// question numbers, the notice, and the buttons are there. A second form brings the bar, and
  /// the form moves down by exactly the bar's height, so none of that height was left behind.
  func testOneFormShowsNoTabBarAndNoBlankStripTheRequesterHeaderAndItsNumberedQuestions() throws {
    let app = launchQuestions()
    let request = try ask(deploy, name: "Deploy script")

    XCTAssertEqual(opening(of: request), "opened")

    let header = element("questions-requester-name", in: app)

    XCTAssertTrue(header.appears(timeout: 10), "the form never opened")
    XCTAssertFalse(element("tab-0", in: app).exists, "a single form showed the tab bar")

    let alone = header.frame.minY

    XCTAssertEqual(
      element("questions-requester-name", in: app).value as? String, "Deploy script")
    XCTAssertEqual(
      element("questions-requester-pane", in: app).value as? String, "Asked from Pane 1")
    XCTAssertEqual(
      element("questions-form-title", in: app).value as? String, "Deploy settings")
    XCTAssertEqual(
      element("question-region-caption", in: app).value as? String,
      "Question 1 of 3 \u{00B7} Required")
    XCTAssertEqual(
      element("question-notes-caption", in: app).value as? String,
      "Question 3 of 3 \u{00B7} Optional")
    XCTAssertEqual(
      element("question-region-detail", in: app).value as? String, "Pick where the build goes.")
    XCTAssertTrue(element("form-block-0", in: app).exists, "the notice is missing")
    XCTAssertTrue(element("form-button-deploy", in: app).exists)
    XCTAssertTrue(element("form-button-cancel", in: app).exists)

    try ask(branch, requester: "other", name: "Second script", pane: nil)

    XCTAssertTrue(element("tab-1", in: app).appears(timeout: 10), "two forms showed no bar")
    XCTAssertEqual(element("tab-0", in: app).label, "Deploy script")
    XCTAssertEqual(
      element("questions-requester-name", in: app).frame.minY - alone, 28, accuracy: 1,
      "the bar's height is not what separates one form from two")
  }

  /// Catches the pane in light with unreadable chrome. The screenshots are for the user's look at
  /// the layout and the header's contrast with a permission prompt.
  func testThePaneInLight() throws {
    try capturePane(in: "light")
  }

  /// As `testThePaneInLight`, in dark.
  func testThePaneInDark() throws {
    try capturePane(in: "dark")
  }

  /// Each appearance is its own test and launch, so no other window covers the pane when it is
  /// captured, and no earlier layout adds a second Questions pane.
  private func capturePane(in mode: String) throws {
    let app = launchQuestions(settings: ["appearance": mode])

    try ask(deploy, requester: "deploy", name: "Deploy script")

    XCTAssertTrue(element("question-region-choice-0", in: app).appears(timeout: 10))
    Thread.sleep(forTimeInterval: 0.5)
    attachWindow(named: "questions-one-form-\(mode)", in: app)

    try ask(branch, requester: "other", name: "Terminal session in Pane 2", pane: nil)

    XCTAssertTrue(element("tab-1", in: app).appears(timeout: 10))
    Thread.sleep(forTimeInterval: 0.5)
    attachWindow(named: "questions-two-forms-\(mode)", in: app)
  }

  /// Catches a form whose fields do not take keys at once. The form opens, and typing reaches the
  /// first field with no click, which "Focus when a form arrives" settles.
  func testANewFormTakesKeysAtOnce() throws {
    let app = launchQuestions()

    try ask(branch)

    let field = element("question-name", in: app)

    XCTAssertTrue(field.appears(timeout: 10))

    app.typeText("main")

    XCTAssertTrue(waitFor(field, timeout: 5) { $0 == "main" }, "typing never reached the form")
  }

  // MARK: Answers

  /// Catches an answer type that renders wrong or returns the wrong shape. Three forms in one tab
  /// cover every type except a chosen file, and each outcome is the shape the type table gives. The
  /// file question only has to draw and answer null while nothing is chosen. A chosen file's answer
  /// is proven by `FieldWidgetTests`, since the open panel runs in another process and a test
  /// cannot type into it reliably.
  func testEveryAnswerTypeReturnsItsShape() throws {
    let app = launchQuestions()

    let texts = try ask(
      """
      {"items": [
        {"block": "paragraph", "text": "Plain text only."},
        {"block": "list", "items": ["one", "two"]},
        {"id": "name", "text": "Name?", "type": "string"},
        {"id": "bio", "text": "Bio?", "type": "text", "multiline": true},
        {"id": "count", "text": "Count?", "type": "integer"},
        {"id": "ratio", "text": "Ratio?", "type": "number"}]}
      """)

    XCTAssertTrue(element("question-name", in: app).appears(timeout: 10))

    // The form takes the keyboard a moment after its fields appear. This test is about the answers,
    // and `testANewFormTakesKeysAtOnce` owns how soon keys arrive.
    XCTAssertTrue(waitForFocus(on: "question-name", in: app), "the form never took the keyboard")

    // Tab moves between the fields. The ratio field starts below the form's visible part, and a click
    // on it can land before the scroll that brings it into view does. Its keys then go to the count
    // field, and the button stays disabled. Tab reaches the field however the form is scrolled.
    app.typeText("Ada")
    app.typeKey(.tab, modifierFlags: [])
    app.typeText("a")
    app.typeKey(.return, modifierFlags: [])
    app.typeText("b")
    app.typeKey(.tab, modifierFlags: [])
    app.typeText("7")
    app.typeKey(.tab, modifierFlags: [])
    app.typeText("-0.5")

    element("form-button-ok", in: app).click()

    let first = answers(outcome(of: texts))

    XCTAssertEqual(first["name"] as? String, "Ada")
    XCTAssertEqual(first["bio"] as? String, "a\nb")
    XCTAssertEqual(first["count"] as? Int, 7)
    XCTAssertEqual(first["ratio"] as? Double, -0.5)

    let choices = try ask(
      """
      {"items": [
        {"id": "flag", "text": "Flag?", "type": "boolean", "default": false},
        {"id": "maybe", "text": "Maybe?", "type": "boolean"},
        {"id": "region", "text": "Region?", "type": "choice", "choices": ["us", "eu"]},
        {"id": "size", "text": "Size?", "type": "choice",
         "choices": ["a", "b", "c", "d", "e", "f"]}]}
      """)

    XCTAssertEqual(opening(of: choices), "reused")
    XCTAssertTrue(element("question-flag", in: app).appears(timeout: 10))

    element("question-flag", in: app).click()
    element("question-region-choice-1", in: app).click()
    element("question-size", in: app).click()
    app.menuItems["c"].click()

    XCTAssertEqual(element("question-maybe", in: app).value as? Int, 2)

    element("form-button-ok", in: app).click()

    let second = answers(outcome(of: choices))

    XCTAssertEqual(second["flag"] as? Bool, true)
    XCTAssertTrue(second["maybe"] is NSNull)
    XCTAssertEqual(second["region"] as? String, "eu")
    XCTAssertEqual(second["size"] as? String, "c")

    let rest = try ask(
      """
      {"items": [
        {"id": "tags", "text": "Tags?", "type": "multi", "choices": ["x", "y", "z"]},
        {"id": "accent", "text": "Accent?", "type": "color", "default": "#336699"},
        {"id": "config", "text": "Config?", "type": "file"}]}
      """)

    XCTAssertEqual(opening(of: rest), "reused")
    XCTAssertTrue(element("question-tags-choice-0", in: app).appears(timeout: 10))

    element("question-tags-choice-2", in: app).click()
    element("question-tags-choice-0", in: app).click()

    XCTAssertTrue(element("question-config", in: app).exists, "the file question did not draw")
    XCTAssertEqual(element("question-config-paths", in: app).value as? String, "Nothing chosen")

    element("form-button-ok", in: app).click()

    let last = answers(outcome(of: rest))

    XCTAssertEqual(last["tags"] as? [String], ["x", "z"])
    XCTAssertEqual(last["accent"] as? String, "#336699ff")
    XCTAssertTrue(last["config"] is NSNull, "an unchosen file answered something")
  }

  /// Catches a content block that does not draw. Each block has its own identifier.
  func testEveryContentBlockRenders() throws {
    let app = launchQuestions()

    try ask(
      """
      {"title": "Blocks", "items": [
        {"block": "paragraph", "text": "A paragraph."},
        {"block": "list", "items": ["one", "two"]},
        {"block": "code", "text": "git push origin main"},
        {"block": "table", "rows": {"Branch": "main", "Remote": "origin"}},
        {"block": "notice", "level": "danger", "text": "This cannot be undone."},
        {"id": "q", "text": "Go?", "type": "boolean", "default": true}]}
      """)

    for index in 0..<5 {
      XCTAssertTrue(element("form-block-\(index)", in: app).appears(timeout: 10), "block \(index)")
    }

    XCTAssertEqual(
      element("question-q-caption", in: app).value as? String, "Question 1 of 1 \u{00B7} Optional")
  }

  // MARK: Keys

  /// Catches Return that does not press the primary button outside a multiline field, and Return
  /// that presses it inside one. A checkbox has the keyboard here, so Return reaches the form.
  func testReturnPressesPrimaryOutsideAMultilineFieldAndInsertsANewlineInside() throws {
    let app = launchQuestions()

    let multiline = try ask(
      """
      {"items": [{"id": "bio", "text": "Bio?", "type": "text", "multiline": true}]}
      """)

    let bio = element("question-bio", in: app)

    XCTAssertTrue(bio.appears(timeout: 10))

    app.typeText("one")
    app.typeKey(.return, modifierFlags: [])
    app.typeText("two")

    XCTAssertTrue(noOutcome(of: multiline), "Return in a multiline field submitted the form")
    XCTAssertEqual(bio.value as? String, "one\ntwo")

    element("form-button-ok", in: app).click()

    XCTAssertEqual(answers(outcome(of: multiline))["bio"] as? String, "one\ntwo")

    let checkbox = try ask(
      #"{"items": [{"id": "sure", "text": "Sure?", "type": "boolean", "default": true}]}"#)

    XCTAssertTrue(element("question-sure", in: app).appears(timeout: 10))

    app.typeKey(.return, modifierFlags: [])

    XCTAssertEqual(answers(outcome(of: checkbox))["sure"] as? Bool, true)
    XCTAssertEqual(outcome(of: checkbox)?["action"] as? String, "ok")
  }

  /// Catches Return in a one-line field that does nothing. It presses the primary button.
  func testReturnInAOneLineFieldPressesPrimary() throws {
    let app = launchQuestions()
    let request = try ask(branch)

    XCTAssertTrue(element("question-name", in: app).appears(timeout: 10))

    app.typeText("main")
    app.typeKey(.return, modifierFlags: [])

    XCTAssertEqual(answers(outcome(of: request))["name"] as? String, "main")
  }

  /// Catches Escape that does nothing, and a form with no cancel button that closes anyway.
  func testEscapePressesCancel() throws {
    let app = launchQuestions()
    let request = try ask(branch)

    XCTAssertTrue(element("question-name", in: app).appears(timeout: 10))

    app.typeKey(.escape, modifierFlags: [])

    let result = outcome(of: request)

    XCTAssertEqual(result?["outcome"] as? String, "cancelled")
    XCTAssertEqual(result?["action"] as? String, "cancel")
    XCTAssertNil(result?["answers"])
  }

  /// Catches a destructive button that Return presses. Only a click activates it, and its label is
  /// the script's. The form has no primary button, so Return does nothing.
  func testReturnNeverPressesADestructiveButton() throws {
    let app = launchQuestions()

    let request = try ask(
      """
      {"items": [{"block": "paragraph", "text": "Delete the build?"}],
       "actions": [{"id": "wipe", "label": "Delete", "role": "destructive"},
                   {"id": "cancel", "role": "cancel"}]}
      """)

    let button = element("form-button-wipe", in: app)

    XCTAssertTrue(button.appears(timeout: 10))

    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(noOutcome(of: request), "Return pressed the destructive button")

    button.click()

    XCTAssertEqual(outcome(of: request)?["action"] as? String, "wipe")
  }

  /// Catches Escape that cancels the form while a pop-up is open. The first Escape closes the
  /// menu, and only the next one cancels.
  func testEscapeClosesAnOpenPopUpBeforeItCancels() throws {
    let app = launchQuestions()

    let request = try ask(
      """
      {"items": [{"id": "size", "text": "Size?", "type": "choice",
                  "choices": ["a", "b", "c", "d", "e", "f"]}]}
      """)

    let popup = element("question-size", in: app)

    XCTAssertTrue(popup.appears(timeout: 10))

    popup.click()
    XCTAssertTrue(app.menuItems["c"].appears(timeout: 5))

    app.typeKey(.escape, modifierFlags: [])

    XCTAssertTrue(app.menuItems["c"].disappears(timeout: 5), "Escape left the menu open")
    XCTAssertTrue(noOutcome(of: request), "the Escape that closed the menu also cancelled")

    app.typeKey(.escape, modifierFlags: [])

    XCTAssertEqual(outcome(of: request)?["outcome"] as? String, "cancelled")
  }

  /// Catches Escape that cancels the form while the file panel is open. The panel is a sheet, and
  /// the first Escape closes it.
  func testEscapeClosesTheFilePanelBeforeItCancels() throws {
    let app = launchQuestions()
    let window = mainWindow(in: app)

    let request = try ask(
      #"{"items": [{"id": "config", "text": "Config?", "type": "file"}]}"#)

    let button = element("question-config", in: app)

    XCTAssertTrue(button.appears(timeout: 10))

    button.click()
    XCTAssertTrue(window.sheets.firstMatch.appears(timeout: 20), "the file panel never opened")

    // The panel's contents belong to another process, and a query for its sheet is unreliable. The
    // proof comes from the outcomes and the focus uniterm owns. An Escape that arrives before the
    // panel is ready to take keys is lost, and it leaves the panel up. So the Escape is sent again
    // while the keyboard has not come back to the form's button and the sheet is still there. No
    // Escape sent while the panel is up can cancel the form. Once the keyboard is back on the
    // button, the panel is closed, and the form must be open with no outcome. The next Escape then
    // cancels it.
    let focused = app.descendants(matching: .any)
      .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
    var closed = false

    _ = pollUntil(timeout: 5) { focused.exists && focused.identifier != "question-config" }

    for _ in 0..<3 {
      app.typeKey(.escape, modifierFlags: [])

      if pollUntil(timeout: 5, { focused.exists && focused.identifier == "question-config" }) {
        closed = true
        break
      }

      guard window.sheets.firstMatch.exists else { break }
    }

    XCTAssertTrue(closed, "Escape left the file panel open. \(focusReport(app))")
    XCTAssertTrue(noOutcome(of: request), "the Escape that closed the panel also cancelled")

    app.typeKey(.escape, modifierFlags: [])

    XCTAssertEqual(
      outcome(of: request)?["outcome"] as? String, "cancelled",
      "Escape did not cancel the form with the keyboard on the file button. \(focusReport(app))")
  }

  /// Catches Escape that cancels the form while the color panel is open. The first Escape closes
  /// the panel.
  func testEscapeClosesTheColorPanelBeforeItCancels() throws {
    let app = launchQuestions()

    let request = try ask(
      #"{"items": [{"id": "accent", "text": "Accent?", "type": "color"}]}"#)

    let well = element("question-accent", in: app)

    XCTAssertTrue(well.appears(timeout: 10))

    well.click()

    let panel = app.windows["Colors"]

    XCTAssertTrue(panel.appears(timeout: 10), "the color panel never opened")

    app.typeKey(.escape, modifierFlags: [])

    XCTAssertTrue(panel.disappears(timeout: 5), "Escape left the color panel open")
    XCTAssertTrue(noOutcome(of: request), "the Escape that closed the panel also cancelled")

    app.typeKey(.escape, modifierFlags: [])

    XCTAssertEqual(outcome(of: request)?["outcome"] as? String, "cancelled")
  }

  // MARK: Validation

  /// Catches an error that shows while the user types, one that never shows on leaving the field,
  /// and one that stays after the fix. The button stays disabled until the form passes. The user
  /// leaves the field with Tab, since the form's own container offers no point a click is sure to
  /// reach.
  func testAnErrorShowsOnLeavingTheFieldAndClearsAtOnce() throws {
    let app = launchQuestions()
    let request = try ask(branch)

    let field = element("question-name", in: app)
    let error = element("question-name-error", in: app)
    let ok = element("form-button-ok", in: app)

    XCTAssertTrue(field.appears(timeout: 10))
    XCTAssertFalse(ok.isEnabled, "a required field is empty and the button is live")

    app.typeText("BAD")

    XCTAssertFalse(error.exists, "an error showed while the user typed")
    XCTAssertFalse(ok.isEnabled)

    app.typeKey(.tab, modifierFlags: [])

    XCTAssertTrue(error.appears(timeout: 5), "leaving the field showed no error")
    XCTAssertEqual(error.value as? String, "Does not match the required format.")

    field.click()
    app.typeKey("a", modifierFlags: .command)
    app.typeText("good")

    XCTAssertTrue(error.disappears(timeout: 5), "the error stayed after the fix")
    XCTAssertTrue(waitUntilEnabled(ok), "the button stayed disabled after the form passed")

    ok.click()

    XCTAssertEqual(answers(outcome(of: request))["name"] as? String, "good")
  }

  private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    pollUntil(timeout: timeout) { element.isEnabled }
  }

  /// Catches a click on the disabled button that does nothing, and Return that does nothing on a
  /// form that cannot submit. Each counts as trying to submit: every error shows and the keyboard
  /// goes to the first one.
  func testTryingToSubmitShowsEveryErrorAndFocusesTheFirstOne() throws {
    let app = launchQuestions()

    let request = try ask(
      """
      {"items": [
        {"id": "first", "text": "First?", "type": "string", "required": true},
        {"id": "second", "text": "Second?", "type": "string", "required": true}]}
      """)

    let ok = element("form-button-ok", in: app)

    XCTAssertTrue(ok.appears(timeout: 10))
    XCTAssertFalse(ok.isEnabled)

    element("question-second", in: app).click()
    ok.click()

    XCTAssertTrue(element("question-first-error", in: app).appears(timeout: 5))
    XCTAssertTrue(element("question-second-error", in: app).exists)
    XCTAssertTrue(noOutcome(of: request))

    app.typeText("one")

    XCTAssertTrue(
      waitFor(element("question-first", in: app), timeout: 5) { $0 == "one" },
      "the keyboard did not move to the first error")

    element("question-second", in: app).click()
    app.typeText("two")
    app.typeKey(.return, modifierFlags: [])

    XCTAssertEqual(answers(outcome(of: request))["first"] as? String, "one")
  }

  // MARK: Placement

  private func isFocused(_ pane: XCUIElement) -> Bool {
    (pane.value as? String) == "focused"
  }

  /// Catches a form that opens in a pane that is not beside its asker, or that leaves the keyboard
  /// in the asker's terminal. With no Questions pane in the window, a pane opens in a split beside
  /// the asker and takes focus as a split the user makes does. Typing reaches the form's field, and
  /// a second requester's form joins that pane, with no third pane.
  func testAFormOpensInASplitBesideTheAskerAndTakesFocus() throws {
    let app = launchQuestions()
    let window = mainWindow(in: app)

    XCTAssertFalse(window.groups["pane-2"].exists, "a pane was open before any form")

    try ask(branch, requester: "a", name: "First script")

    XCTAssertTrue(window.groups["pane-2"].appears(timeout: 10), "no pane opened beside the asker")
    XCTAssertTrue(window.groups["pane-1"].exists, "the asker's pane went")
    XCTAssertTrue(
      waitFor(window.groups["pane-2"], timeout: 10) { $0 == "focused" },
      "the split did not take focus. \(focusReport(app))")
    XCTAssertFalse(isFocused(window.groups["pane-1"]), "the asker's pane kept focus")

    app.typeText("main")

    XCTAssertTrue(
      waitFor(element("question-name", in: app), timeout: 5) { $0 == "main" },
      "typing never reached the form")

    mainWindow(in: app).textViews["terminal"].click()

    try ask(branch, requester: "b", name: "Second script")

    XCTAssertTrue(element("tab-1", in: app).appears(timeout: 10), "the second form got no tab")
    XCTAssertFalse(window.groups["pane-3"].exists, "a second requester got a pane of its own")
  }

  /// Catches an asker that shows nothing while its form waits, a badge that does not name the
  /// Questions pane, and one that stays after the form resolves. The asking pane shows the badge,
  /// its label names the Questions pane, and cancelling the form clears it.
  func testTheAskingPaneShowsABadgeUntilTheFormResolves() throws {
    let app = launchQuestions()
    let badge = element("pane-asking-1", in: app)

    XCTAssertFalse(badge.exists, "a badge showed before any form")

    let request = try ask(branch)

    XCTAssertTrue(badge.appears(timeout: 10), "the asking pane showed no badge")
    XCTAssertTrue(
      badge.label.contains("Pane 2"), "the badge says \(badge.label), not the Questions pane")
    XCTAssertFalse(element("pane-asking-2", in: app).exists, "the Questions pane is no asker")

    attachWindow(named: "questions-asking-badge", in: app)

    app.typeKey(.escape, modifierFlags: [])

    XCTAssertEqual(outcome(of: request)?["outcome"] as? String, "cancelled")
    XCTAssertTrue(waitUntilGone(badge), "the badge stayed after the form resolved")
  }

  // MARK: Lifecycle

  /// Catches a second requester that shares the first one's tab, and a next form that opens a
  /// third. A new requester opens a new tab that takes the keyboard, and a requester's next form
  /// reuses its own tab, selects it, and takes the keyboard.
  func testTabsFollowRequestersAndAReusedTabTakesTheKeyboard() throws {
    let app = launchQuestions()

    let first = try ask(branch, requester: "a", name: "First script")

    XCTAssertTrue(element("question-name", in: app).appears(timeout: 10))

    mainWindow(in: app).textViews["terminal"].click()

    let second = try ask(branch, requester: "b", name: "Second script")

    XCTAssertEqual(opening(of: second), "opened")
    XCTAssertTrue(element("tab-1", in: app).appears(timeout: 10))
    XCTAssertEqual(element("tab-1", in: app).value as? String, "selected")
    XCTAssertEqual(
      element("questions-requester-name", in: app).value as? String, "Second script")

    app.typeText("second")

    XCTAssertTrue(
      waitFor(element("question-name", in: app), timeout: 5) { $0 == "second" },
      "the new tab's field took no keys")

    app.typeKey(.return, modifierFlags: [])

    XCTAssertEqual(answers(outcome(of: second))["name"] as? String, "second")
    XCTAssertTrue(
      element("questions-outcome", in: app).appears(timeout: 5),
      "a resolved form did not stay in its tab")

    app.typeKey("1", modifierFlags: .command)

    XCTAssertEqual(element("tab-0", in: app).value as? String, "selected")

    mainWindow(in: app).textViews["terminal"].click()

    let again = try ask(branch, requester: "b", name: "Second script")

    XCTAssertEqual(opening(of: again), "reused")
    XCTAssertFalse(element("tab-2", in: app).exists, "the next form opened a third tab")
    XCTAssertEqual(element("tab-1", in: app).value as? String, "selected")

    app.typeText("next")

    XCTAssertTrue(
      waitFor(element("question-name", in: app), timeout: 5) { $0 == "next" },
      "the reused tab's field took no keys")

    XCTAssertEqual(outcome(of: first, timeout: 1) == nil, true)
  }

  /// Catches a resolved form that sends the keyboard away. After it resolves, the pane still has
  /// the keyboard, so the pane's tab keys work, and nothing typed lands in the asker's terminal.
  func testResolvingKeepsTheKeyboardInTheTab() throws {
    let app = launchQuestions()

    try ask(branch, requester: "a", name: "First script")
    try ask(branch, requester: "b", name: "Second script")

    XCTAssertTrue(element("tab-1", in: app).appears(timeout: 10))

    app.typeText("ok")
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(element("questions-outcome", in: app).appears(timeout: 5))

    app.typeKey(.tab, modifierFlags: .control)

    XCTAssertTrue(
      waitFor(element("tab-0", in: app), timeout: 5) { $0 == "selected" },
      "the pane's tab key did nothing, so the keyboard left the tab")
  }

  /// Catches a close that asks first, a close that tells the script nothing, and a last form whose
  /// close leaves an empty pane. A pane with one form has no tab bar, so Cmd-W is the user's close.
  /// It dismisses the form with no sheet, and the pane closes with it.
  func testCmdWOnTheOnlyFormDismissesItAndClosesThePane() throws {
    let app = launchQuestions()
    let request = try ask(branch)

    let pane = element("questions-applet", in: app)

    XCTAssertTrue(pane.appears(timeout: 10))
    XCTAssertTrue(element("question-name", in: app).appears(timeout: 10))
    XCTAssertFalse(element("tab-close-0", in: app).exists, "a single form showed a tab close")

    app.typeKey("w", modifierFlags: .command)

    let result = outcome(of: request)

    XCTAssertEqual(result?["outcome"] as? String, "dismissed")
    XCTAssertFalse(mainWindow(in: app).sheets.firstMatch.exists, "closing the form asked first")
    XCTAssertTrue(pane.disappears(timeout: 10), "the pane stayed after its only form closed")
  }

  /// Catches a tab whose requester ended that stays, and a close of one of two tabs that closes
  /// the pane. The requester ends, and its tab closes as the user's close does.
  func testARequesterEndingClosesItsTab() throws {
    let app = launchQuestions()

    let first = try ask(branch, requester: "a", name: "First script")

    try ask(branch, requester: "b", name: "Second script")

    XCTAssertTrue(element("tab-1", in: app).appears(timeout: 10))

    try command("end", requester: "a")

    XCTAssertEqual(outcome(of: first)?["outcome"] as? String, "ended")
    XCTAssertTrue(element("tab-1", in: app).disappears(timeout: 10))
    XCTAssertTrue(
      element("tab-0", in: app).disappears(timeout: 10), "one form left, and the bar stayed")
    XCTAssertEqual(
      element("questions-requester-name", in: app).value as? String, "Second script")
    XCTAssertTrue(element("questions-applet", in: app).exists)
  }

  /// Catches a header that keeps naming a pane that closed. The header says the asking pane is
  /// gone and names no other.
  func testTheHeaderSaysWhenTheAskingPaneIsGone() throws {
    let app = launchQuestions()

    try ask(branch)

    XCTAssertTrue(element("questions-requester-pane", in: app).appears(timeout: 10))

    try command("pane-closed", requester: "build")

    XCTAssertTrue(
      waitFor(element("questions-requester-pane", in: app), timeout: 10) {
        $0.contains("the pane that asked is gone")
      })
  }

  /// Catches arrival that posts no status line, and one that carries the script's text.
  func testArrivalPostsAStatusLine() throws {
    let app = launchQuestions()

    try ask(branch, name: "Deploy script")

    let message = mainWindow(in: app).staticTexts["status-message"]

    XCTAssertTrue(
      waitFor(message, timeout: 10) { $0.contains("Deploy script is asking you a question.") })
  }

  // MARK: Restore

  /// Catches a restored Questions pane that sits blank. The layout keeps the pane and no form, and
  /// the relaunched pane says it is empty.
  func testARestoredPaneShowsItsEmptyState() throws {
    let app = launchQuestions(arguments: ["-NSQuitAlwaysKeepsWindows", "NO"])

    try ask(branch)

    XCTAssertTrue(element("questions-applet", in: app).appears(timeout: 10))

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let relaunched = launchApp(
      environment: ["UNITERM_TEST_QUESTIONS_DIR": requests.path],
      arguments: ["-NSQuitAlwaysKeepsWindows", "NO"])

    XCTAssertTrue(mainWindow(in: relaunched).appears(timeout: 20))

    let title = element("questions-empty-title", in: relaunched)

    XCTAssertTrue(title.appears(timeout: 20), "the restored pane shows nothing")
    XCTAssertEqual(title.value as? String, "No questions are open")
    XCTAssertFalse(element("question-name", in: relaunched).exists)
  }
}
