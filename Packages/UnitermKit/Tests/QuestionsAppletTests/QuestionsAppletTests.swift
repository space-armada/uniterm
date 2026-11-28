import AppKit
import AppletKit
import AppletTestSupport
import QuestionForm
import StatusKit
import XCTest

@testable import QuestionsApplet

/// Proves the Questions applet's contract with its host: how a form opens, which tab it takes,
/// and how each way a form ends reaches the asker. It drives the buttons and fields through the
/// views, the way a user does. It cannot prove how the pane looks, which the UI tests attach.
@MainActor
final class QuestionsAppletTests: XCTestCase {
  private let simple = try! FormSpecReader.decode(
    Data(
      """
      {"title": "Settings", "items": [
        {"id": "name", "text": "Name?", "type": "string", "required": true}]}
      """.utf8))

  private func requester(_ key: String, name: String? = nil) -> QuestionsRequester {
    QuestionsRequester(key: key, name: name ?? "Script \(key)")
  }

  private func makeApplet(cap: Int = 3) -> (QuestionsApplet, RecordingHost) {
    let applet = QuestionsApplet(cap: cap)
    let host = RecordingHost()

    applet.host = host

    return (applet, host)
  }

  private func find(_ identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier { return view }

    for subview in view.subviews {
      if let found = find(identifier, in: subview) { return found }
    }

    return nil
  }

  private func fill(_ applet: QuestionsApplet, _ id: String, _ text: String) throws {
    let field = try XCTUnwrap(find("question-\(id)", in: applet.view) as? NSTextField)

    field.stringValue = text
    field.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: field))
  }

  private func press(_ applet: QuestionsApplet, _ id: String) throws {
    let button = try XCTUnwrap(find("form-button-\(id)", in: applet.view) as? NSButton)

    button.performClick(nil)
  }

  private func panel(in applet: QuestionsApplet) -> FormPanelView? {
    func search(_ view: NSView) -> FormPanelView? {
      if let panel = view as? FormPanelView { return panel }

      for subview in view.subviews {
        if let found = search(subview) { return found }
      }

      return nil
    }

    return search(applet.view)
  }

  /// Holds a panel without keeping it alive. The lookup runs in its own pool, so a test never keeps
  /// the panel alive through an autoreleased reference.
  private final class PanelWatch {
    weak var panel: FormPanelView?
  }

  private func watchPanel(in applet: QuestionsApplet) -> PanelWatch {
    let watch = PanelWatch()

    autoreleasepool { watch.panel = panel(in: applet) }

    return watch
  }

  /// A window that holds the applet, so the keyboard has somewhere to go. It is never shown.
  private func hold(_ applet: QuestionsApplet) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.isReleasedWhenClosed = false
    window.contentView = applet.view
    applet.view.layoutSubtreeIfNeeded()

    return window
  }

  // MARK: Opening

  /// Catches a pane that sits blank with no tab. A new, restored, or reopened pane has nothing to
  /// show, and it says so.
  func testAPaneWithNoTabShowsItsEmptyState() throws {
    let (applet, _) = makeApplet()

    XCTAssertNotNil(find("questions-empty-title", in: applet.view))
    XCTAssertEqual(applet.publishedTabs.all.count, 1)
    XCTAssertNil(panel(in: applet))

    let restored = try QuestionsApplet(restoring: applet.describe())

    XCTAssertNotNil(find("questions-empty-title", in: restored.view))
    XCTAssertEqual(restored.tabCount, 0)
  }

  /// Catches a bar that shows for one question, or leaves a blank strip where it was. With no
  /// question or one, the bar is hidden and takes no height, and the form starts at the pane's top
  /// edge. Two questions show the bar with both tabs, and closing one hides it again.
  func testTheBarShowsOnlyForTwoOrMoreQuestionsAndLeavesNoStripBelowTwo() throws {
    let (applet, _) = makeApplet()
    let window = hold(applet)
    defer { window.close() }

    let bar = applet.content.tabBar

    XCTAssertTrue(bar.isHidden)
    XCTAssertEqual(bar.frame.height, 0)
    XCTAssertEqual(applet.publishedTabs.all.count, 1, "an empty book still publishes one tab")

    _ = applet.open(simple, for: requester("a")) { _ in }
    applet.view.layoutSubtreeIfNeeded()

    let form = try XCTUnwrap(panel(in: applet))

    XCTAssertTrue(bar.isHidden)
    XCTAssertEqual(bar.frame.height, 0)
    XCTAssertEqual(applet.view.convert(form.frame, from: form.superview).minY, 0, accuracy: 0.5)

    _ = applet.open(simple, for: requester("b")) { _ in }
    applet.view.layoutSubtreeIfNeeded()

    XCTAssertFalse(bar.isHidden)
    XCTAssertEqual(bar.frame.height, AppletTabBar.height)
    XCTAssertEqual(applet.publishedTabs.all.count, 2)

    applet.closeTab(at: 0)
    applet.view.layoutSubtreeIfNeeded()

    XCTAssertTrue(bar.isHidden)
    XCTAssertEqual(bar.frame.height, 0)
  }

  /// Catches a reselect that leaves the selected question's tab out of view. The user scrolls the
  /// selected tab off the bar, then selects it again from the keyboard or the palette. The tab is
  /// already selected, yet it comes back into view.
  func testReselectingTheSelectedTabScrollsItBackIntoView() throws {
    let (applet, _) = makeApplet(cap: 14)
    let window = hold(applet)
    defer { window.close() }

    for index in 0..<14 { _ = applet.open(simple, for: requester("k\(index)")) { _ in } }

    applet.view.layoutSubtreeIfNeeded()

    let bar = try XCTUnwrap(TabBarProbe.bar(in: applet.view))
    let last = applet.tabCount - 1

    XCTAssertEqual(applet.selectedTabIndex, last)
    XCTAssertTrue(TabBarProbe.isFullyInView(bar, tab: last))

    TabBarProbe.scroll(bar, by: -10_000)
    XCTAssertFalse(TabBarProbe.isFullyInView(bar, tab: last))

    applet.selectTab(at: last)
    applet.view.layoutSubtreeIfNeeded()

    XCTAssertTrue(TabBarProbe.isFullyInView(bar, tab: last))

    TabBarProbe.scroll(bar, by: -10_000)
    XCTAssertTrue(applet.selectTab(id: applet.publishedTabs.selected))
    applet.view.layoutSubtreeIfNeeded()

    XCTAssertTrue(TabBarProbe.isFullyInView(bar, tab: last), "the palette's reselect")
  }

  /// Catches a description that carries form content or a requester, which "The Questions pane"
  /// forbids, and a restore that accepts another applet's description.
  func testTheDescriptionHoldsNothingAndRefusesOtherTypes() throws {
    let (applet, _) = makeApplet()

    _ = applet.open(simple, for: requester("a")) { _ in }

    let description = applet.describe()

    XCTAssertEqual(description.type, "questions")
    XCTAssertEqual(description.payload, .object([:]))

    XCTAssertThrowsError(
      try QuestionsApplet(
        restoring: AppletDescription(type: "terminal", version: 1, payload: .object([:]))))
    XCTAssertThrowsError(
      try QuestionsApplet(
        restoring: AppletDescription(type: "questions", version: 2, payload: .object([:]))))
  }

  /// Catches a tab title or header that the script could write, and a status line that carries the
  /// script's own text. The tab names the requester as the host gave it.
  func testTheTabNamesTheRequesterAndArrivalPostsAStatusLine() throws {
    let (applet, host) = makeApplet()

    let result = applet.open(simple, for: requester("a", name: "Build script")) { _ in }

    guard case .opened(let tab, let reused) = result else { return XCTFail("did not open") }

    XCTAssertFalse(reused)
    XCTAssertEqual(applet.publishedTabs.all.map(\.title), ["Build script"])
    XCTAssertEqual(applet.publishedTabs.selected, tab)
    XCTAssertEqual(applet.title, "Build script")
    XCTAssertEqual(host.posts.map(\.text), ["Build script is asking you a question."])

    let name = try XCTUnwrap(find("questions-requester-name", in: applet.view) as? NSTextField)

    XCTAssertEqual(name.stringValue, "Build script")
  }

  /// Catches a requester that can hold two open forms, and a second requester that is refused. The
  /// refusal changes nothing on screen.
  func testASecondFormFromTheSameRequesterIsRefusedAndChangesNothing() {
    let (applet, host) = makeApplet()

    _ = applet.open(simple, for: requester("a")) { _ in }

    let tabs = applet.publishedTabs
    let posts = host.posts.count
    let result = applet.open(simple, for: requester("a")) { _ in XCTFail("refused form ran") }

    XCTAssertEqual(result, .busy(.requesterHasOpenForm))
    XCTAssertEqual(applet.publishedTabs, tabs)
    XCTAssertEqual(host.posts.count, posts)

    XCTAssertNotEqual(
      applet.open(simple, for: requester("b")) { _ in }, .busy(.requesterHasOpenForm))
  }

  /// Catches a pane that takes more open forms than its cap.
  func testAFormPastTheCapIsRefusedAsBusy() {
    let (applet, _) = makeApplet(cap: 2)

    _ = applet.open(simple, for: requester("a")) { _ in }
    _ = applet.open(simple, for: requester("b")) { _ in }

    XCTAssertEqual(applet.open(simple, for: requester("c")) { _ in }, .busy(.paneFull))
  }

  // MARK: Ending

  /// Catches an answer that never reaches the asker, a callback that runs twice, and a button that
  /// stays live after the form resolved. The submitted form shows its outcome in its own tab.
  func testSubmittingResolvesOnceAndTheTabShowsTheOutcome() throws {
    let (applet, _) = makeApplet()
    var outcomes: [FormOutcome] = []

    _ = applet.open(simple, for: requester("a", name: "Build script")) { outcomes.append($0) }

    try fill(applet, "name", "Ada")
    try press(applet, "ok")

    XCTAssertEqual(
      outcomes, [.submitted(submission: 1, action: "ok", answers: ["name": .text("Ada")])])
    XCTAssertEqual(applet.openFormCount, 0)
    XCTAssertEqual(applet.tabCount, 1)

    let outcome = try XCTUnwrap(find("questions-outcome", in: applet.view) as? NSTextField)

    XCTAssertTrue(outcome.stringValue.contains("Build script"))
    XCTAssertNil(find("form-button-ok", in: applet.view))
  }

  func testCancelResolvesAsCancelledWithNoAnswers() throws {
    let (applet, _) = makeApplet()
    var outcomes: [FormOutcome] = []

    _ = applet.open(simple, for: requester("a")) { outcomes.append($0) }

    try press(applet, "cancel")

    XCTAssertEqual(outcomes, [.cancelled(action: "cancel")])
  }

  /// Catches a validating button that submits an invalid form. A click on the disabled button
  /// shows the errors and sends the keyboard to the first one.
  func testAClickOnTheDisabledButtonShowsErrorsAndFocusesTheFirstOne() throws {
    let (applet, _) = makeApplet()
    let window = hold(applet)

    defer { window.close() }

    _ = applet.open(simple, for: requester("a")) { _ in XCTFail("an empty form submitted") }

    let button = try XCTUnwrap(find("form-button-ok", in: applet.view) as? FormPushButton)

    XCTAssertFalse(button.isEnabled)

    window.makeFirstResponder(applet.view)

    let click = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1))

    button.mouseDown(with: click)

    let error = try XCTUnwrap(find("question-name-error", in: applet.view) as? NSTextField)

    XCTAssertFalse(error.isHidden)
    XCTAssertEqual(error.stringValue, FormChecker.required)
    XCTAssertEqual(panel(in: applet)?.question(holding: window.firstResponder), "name")
  }

  /// Catches a second request for the keyboard that ends the first field's editing. A host that
  /// focuses the pane after the form opened would blur the empty required field, and its error
  /// would show before the user typed. The field keeps the keyboard and shows no error.
  func testFocusingAgainNeverBlursTheFirstFieldOrShowsItsError() throws {
    let (applet, _) = makeApplet()
    let window = hold(applet)

    defer { window.close() }

    _ = applet.open(simple, for: requester("a")) { _ in }

    let field = try XCTUnwrap(find("question-name", in: applet.view) as? NSTextField)

    XCTAssertNotNil(field.currentEditor(), "the field never took the keyboard")

    applet.focus()
    applet.focus()

    XCTAssertNotNil(field.currentEditor(), "focusing again ended the field's editing")
    XCTAssertTrue(
      (find("question-name-error", in: applet.view) as? NSTextField)?.isHidden ?? true,
      "an error showed before the user typed")
  }

  /// Catches Return that does nothing on a form that cannot submit, and Return that submits it.
  /// Return counts as trying, so every error shows and nothing is sent.
  func testReturnOnAnInvalidFormTriesToSubmitAndSendsNothing() throws {
    let (applet, _) = makeApplet()
    let window = hold(applet)

    defer { window.close() }

    _ = applet.open(simple, for: requester("a")) { _ in XCTFail("an empty form submitted") }

    let field = try XCTUnwrap(find("question-name", in: applet.view) as? NSTextField)
    let handled = field.delegate?.control?(
      field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))

    XCTAssertEqual(handled, true)
    XCTAssertFalse((find("question-name-error", in: applet.view) as? NSTextField)?.isHidden ?? true)
  }

  /// Catches Return and Escape that miss their buttons. Return presses the primary button, and
  /// Escape the cancel button, from any control that is not a field.
  func testReturnPressesPrimaryAndEscapePressesCancelFromAnyControl() throws {
    let (applet, _) = makeApplet()
    var outcomes: [FormOutcome] = []
    let spec = try FormSpecReader.decode(
      Data(
        """
        {"items": [{"id": "ok?", "text": "Sure?", "type": "boolean", "default": true}]}
        """.utf8))

    _ = applet.open(spec, for: requester("a")) { outcomes.append($0) }

    let panel = try XCTUnwrap(panel(in: applet))

    panel.keyDown(with: try key(36))

    XCTAssertEqual(
      outcomes, [.submitted(submission: 1, action: "ok", answers: ["ok?": .boolean(true)])])

    _ = applet.open(spec, for: requester("a")) { outcomes.append($0) }

    try XCTUnwrap(self.panel(in: applet)).keyDown(with: try key(53))

    XCTAssertEqual(outcomes.last, .cancelled(action: "cancel"))
  }

  private func key(_ code: UInt16) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: code))
  }

  /// Catches Escape that stops at a control and never reaches the form's cancel button. Each
  /// control that can hold the keyboard gets the key through the window, as a real key press
  /// arrives, and the form cancels.
  func testEscapeCancelsFromEveryControlThatCanHoldTheKeyboard() throws {
    let spec = try FormSpecReader.decode(
      Data(
        """
        {"items": [
          {"id": "config", "text": "Config?", "type": "file"},
          {"id": "accent", "text": "Accent?", "type": "color"},
          {"id": "flag", "text": "Flag?", "type": "boolean", "default": false},
          {"id": "pick", "text": "Pick?", "type": "choice", "choices": ["a", "b"]},
          {"id": "many", "text": "Many?", "type": "choice",
           "choices": ["a", "b", "c", "d", "e", "f"]}]}
        """.utf8))

    for identifier in [
      "question-config", "question-accent", "question-flag", "question-pick-choice-0",
      "question-many",
    ] {
      let (applet, _) = makeApplet()
      var outcomes: [FormOutcome] = []

      _ = applet.open(spec, for: requester("a")) { outcomes.append($0) }

      let window = hold(applet)
      let control = try XCTUnwrap(find(identifier, in: applet.view), identifier)

      XCTAssertTrue(window.makeFirstResponder(control), "\(identifier) refused the keyboard")

      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))

      window.sendEvent(event)

      XCTAssertEqual(outcomes, [.cancelled(action: "cancel")], "Escape stopped at \(identifier)")
    }
  }

  /// Catches a Tab that leaves the form's order. Without a chain of its own, Tab goes wherever
  /// AppKit's guess sends it, which depends on the machine's keyboard setting. The chain runs
  /// through every question in reading order, then the buttons, and wraps to the first field. A
  /// radio group is one stop, on its selected radio, and the stop follows a new selection.
  func testTabRunsThroughTheQuestionsThenTheButtonsAndWraps() throws {
    let (applet, _) = makeApplet()
    let spec = try FormSpecReader.decode(
      Data(
        """
        {"items": [
          {"id": "name", "text": "Name?", "type": "string"},
          {"id": "bio", "text": "Bio?", "type": "text", "multiline": true},
          {"id": "count", "text": "Count?", "type": "integer"},
          {"id": "pick", "text": "Pick?", "type": "choice", "choices": ["a", "b"],
           "default": "b"},
          {"id": "ratio", "text": "Ratio?", "type": "number"}]}
        """.utf8))

    _ = applet.open(spec, for: requester("a")) { _ in }

    let first = try XCTUnwrap(find("question-name", in: applet.view))

    func chain() -> [String] {
      var names: [String] = []
      var view: NSView? = first

      repeat {
        names.append(view?.accessibilityIdentifier() ?? "?")
        view = view?.nextKeyView
      } while view != nil && view !== first && names.count < 20

      if view === first { names.append("wraps") }

      return names
    }

    XCTAssertEqual(
      chain(),
      [
        "question-name", "question-bio", "question-count", "question-pick-choice-1",
        "question-pick-clear", "question-ratio", "form-button-ok", "form-button-cancel", "wraps",
      ])

    let a = try XCTUnwrap(find("question-pick-choice-0", in: applet.view) as? NSButton)

    a.performClick(nil)

    XCTAssertEqual(
      chain().dropFirst(3).first, "question-pick-choice-0", "the stop stayed on the old radio")
  }

  /// Catches a destructive button that Return presses. Return presses the primary button only, so
  /// a form with a destructive button and no primary button ignores Return.
  func testReturnNeverPressesADestructiveButton() throws {
    let (applet, _) = makeApplet()
    let spec = try FormSpecReader.decode(
      Data(
        """
        {"items": [{"block": "paragraph", "text": "Delete everything?"}],
         "actions": [{"id": "wipe", "label": "Delete", "role": "destructive"},
                     {"id": "cancel", "role": "cancel"}]}
        """.utf8))

    _ = applet.open(spec, for: requester("a")) { _ in XCTFail("Return pressed a destructive button")
    }

    try XCTUnwrap(panel(in: applet)).keyDown(with: try key(36))

    XCTAssertEqual(applet.openFormCount, 1)
  }

  // MARK: Tabs

  /// Catches a next form that opens a second tab, and one that leaves the old outcome on screen.
  /// The requester's own tab takes it, selects, and shows the new form.
  func testARequestersNextFormReusesItsTab() throws {
    let (applet, _) = makeApplet()

    let firstResult = applet.open(simple, for: requester("a")) { _ in }

    guard case .opened(let first, _) = firstResult else { return XCTFail("did not open") }

    _ = applet.open(simple, for: requester("b")) { _ in }

    XCTAssertEqual(applet.selectedRequesterKey, "b")

    applet.selectTab(at: 0)
    try fill(applet, "name", "Ada")
    try press(applet, "ok")

    applet.selectTab(at: 1)

    let result = applet.open(simple, for: requester("a")) { _ in }

    XCTAssertEqual(result, .opened(tab: first, reusedTab: true))
    XCTAssertEqual(applet.tabCount, 2)
    XCTAssertEqual(applet.selectedRequesterKey, "a")
    XCTAssertNotNil(find("form-button-ok", in: applet.view))
  }

  /// Catches a close that asks, a close that tells the asker nothing, and a form that outlives its
  /// tab. Closing a tab with an open form dismisses it, never asks, and leaves the other tab.
  func testClosingATabDismissesItsFormWithoutAsking() async throws {
    let (applet, host) = makeApplet()
    var outcomes: [String: FormOutcome] = [:]

    _ = applet.open(simple, for: requester("a")) { outcomes["a"] = $0 }
    _ = applet.open(simple, for: requester("b")) { outcomes["b"] = $0 }

    XCTAssertFalse(applet.isRunningSomething)
    XCTAssertEqual(applet.runningLabels, [])

    let result = await applet.closeCurrentTab()

    XCTAssertEqual(result, .closed)
    XCTAssertEqual(outcomes, ["b": .dismissed])
    XCTAssertEqual(host.confirmations.count, 0)
    XCTAssertEqual(applet.requesterKeys, ["a"])
    XCTAssertFalse(host.exited)
  }

  /// Catches a last tab that closes without closing the pane, and one that closes the pane from
  /// the applet when the host's own close should. Cmd-W on the last tab is the host's, and the
  /// close button on the last tab exits the applet. Both dismiss the form.
  func testTheLastTabClosingClosesThePaneEitherWay() async throws {
    let (applet, host) = makeApplet()
    var outcomes: [FormOutcome] = []

    _ = applet.open(simple, for: requester("a")) { outcomes.append($0) }

    let nothing = await applet.closeCurrentTab()

    XCTAssertEqual(nothing, .nothingToClose)
    XCTAssertEqual(outcomes, [])

    applet.close()

    XCTAssertEqual(outcomes, [.dismissed])

    let (second, secondHost) = makeApplet()

    _ = second.open(simple, for: requester("a")) { outcomes.append($0) }
    second.closeTab(at: 0)

    XCTAssertEqual(outcomes, [.dismissed, .dismissed])
    XCTAssertTrue(secondHost.exited)
    XCTAssertFalse(host.exited)
    XCTAssertEqual(second.publishedTabs.all.count, 1)
  }

  /// Catches an end that submits or dismisses. The asker ended, so the form ends with nothing
  /// submitted, and the tab closes as a user's close does.
  func testARequesterEndingEndsItsFormAndClosesItsTab() {
    let (applet, host) = makeApplet()
    var outcomes: [FormOutcome] = []

    _ = applet.open(simple, for: requester("a")) { outcomes.append($0) }
    _ = applet.open(simple, for: requester("b")) { _ in }

    applet.end(requester: "a")

    XCTAssertEqual(outcomes, [.ended])
    XCTAssertEqual(applet.requesterKeys, ["b"])

    applet.end(requester: "b")

    XCTAssertTrue(host.exited)
  }

  /// Catches a discard that closes the tab. A discarded form ends and the tab stays, saying so, for
  /// the requester's next form.
  func testDiscardingAFormEndsItAndKeepsTheTab() throws {
    let (applet, _) = makeApplet()
    var outcomes: [FormOutcome] = []

    let result = applet.open(simple, for: requester("a")) { outcomes.append($0) }

    guard case .opened(let tab, _) = result else { return XCTFail("did not open") }

    XCTAssertTrue(applet.discard(tab: tab))
    XCTAssertFalse(applet.discard(tab: tab))
    XCTAssertEqual(outcomes, [.ended])
    XCTAssertEqual(applet.tabCount, 1)
    XCTAssertNotNil(find("questions-outcome", in: applet.view))
  }

  /// Catches an eviction that leaves the evicted tab on the bar or its panel alive. The order of
  /// eviction is `QuestionsBookTests`'s. This proves the applet applies it: the tab leaves the bar,
  /// the new form takes the selection, and the evicted panel is freed.
  func testAnEvictedTabLeavesTheBarAndFreesItsPanel() throws {
    let (applet, _) = makeApplet(cap: 2)
    var evicted: PanelWatch?

    try autoreleasepool {
      _ = applet.open(simple, for: requester("a")) { _ in }
      _ = applet.open(simple, for: requester("b")) { _ in }

      applet.selectTab(at: 0)
      try fill(applet, "name", "x")
      try press(applet, "ok")

      evicted = watchPanel(in: applet)

      applet.selectTab(at: 1)
      _ = applet.open(simple, for: requester("c")) { _ in }
    }

    XCTAssertNil(evicted?.panel, "the evicted tab's panel is still alive")
    XCTAssertEqual(applet.requesterKeys, ["b", "c"])
    XCTAssertEqual(applet.selectedRequesterKey, "c")
  }

  /// Catches a panel that outlives its tab or its pane. A closed tab and a closed pane free their
  /// panels, so no form keeps its widgets, observers, or key monitors after it is gone.
  func testAClosedTabAndAClosedPaneFreeTheirPanels() throws {
    let (applet, _) = makeApplet()
    var second: PanelWatch?
    var first: PanelWatch?

    autoreleasepool {
      _ = applet.open(simple, for: requester("a")) { _ in }
      _ = applet.open(simple, for: requester("b")) { _ in }

      second = watchPanel(in: applet)
      applet.closeTab(at: 1)
      first = watchPanel(in: applet)
    }

    XCTAssertNil(second?.panel, "a closed tab's panel is still alive")

    autoreleasepool { applet.close() }

    XCTAssertNil(first?.panel, "a closed pane's panel is still alive")
  }

  /// Catches a late call on a closed pane. The host sends `end` at run end, which can come after
  /// the user closed the pane. It does nothing then, and it never exits the applet a second time. A
  /// callback that ends its own requester while the pane closes does not re-enter.
  func testEveryEntryPointDoesNothingAfterTheClose() {
    let (applet, host) = makeApplet()
    var outcomes: [FormOutcome] = []

    _ = applet.open(simple, for: requester("a")) { outcome in
      outcomes.append(outcome)
      applet.end(requester: "a")
    }

    applet.close()

    XCTAssertEqual(outcomes, [.dismissed])
    XCTAssertEqual(applet.tabCount, 0)

    applet.end(requester: "a")
    applet.askingPaneDidClose(forRequester: "a")

    XCTAssertFalse(applet.discard(tab: AppletTabID.make()))
    XCTAssertFalse(host.exited)
    XCTAssertEqual(outcomes, [.dismissed])
  }

  /// Catches a disabled validating button that a screen reader cannot try. The dimmed button
  /// takes no press, so it offers the try to submit as an action, and the action shows the error
  /// and ties it to the field's help.
  func testADisabledButtonOffersTheTryToSubmitToAssistiveTechnology() throws {
    let (applet, _) = makeApplet()

    _ = applet.open(simple, for: requester("a")) { _ in XCTFail("an empty form submitted") }

    let button = try XCTUnwrap(find("form-button-ok", in: applet.view) as? NSButton)
    let action = try XCTUnwrap(button.accessibilityCustomActions()?.first)

    XCTAssertTrue(action.handler?() ?? false)

    let field = try XCTUnwrap(find("question-name", in: applet.view))

    XCTAssertEqual(field.accessibilityHelp(), FormChecker.required)
  }

  /// Catches Return that is swallowed when the form has no primary button, and Escape when it has
  /// no cancel button. The key goes on to the next responder.
  func testKeysWithNoButtonToPressPassUp() throws {
    let (applet, _) = makeApplet()
    let spec = try FormSpecReader.decode(
      Data(
        """
        {"items": [{"block": "paragraph", "text": "Hi"}],
         "actions": [{"id": "go", "label": "Go", "role": "normal"}]}
        """.utf8))

    _ = applet.open(spec, for: requester("a")) { _ in XCTFail("a key pressed a button") }

    let panel = try XCTUnwrap(panel(in: applet))
    let catcher = KeyCatcher()

    catcher.addSubview(applet.view)

    panel.keyDown(with: try key(36))
    panel.keyDown(with: try key(53))

    XCTAssertEqual(catcher.keys, [36, 53])
  }

  /// Catches an asking pane that closes and leaves the header pointing at it as if it were open.
  func testTheHeaderSaysWhenTheAskingPaneIsGone() throws {
    let (applet, _) = makeApplet()
    let asked = QuestionsRequester(key: "a", name: "Script", askingPane: .open(label: "Pane 3"))

    _ = applet.open(simple, for: asked) { _ in }

    let line = try XCTUnwrap(find("questions-requester-pane", in: applet.view) as? NSTextField)

    XCTAssertEqual(line.stringValue, "Asked from Pane 3")

    applet.askingPaneDidClose(forRequester: "a")

    XCTAssertEqual(line.stringValue, "Pane 3 closed, so the pane that asked is gone")
  }

  /// Catches tab keys that wrap wrongly or select a tab that is not there.
  func testTabCommandsStepAndNumberTheTabs() {
    let (applet, _) = makeApplet()

    _ = applet.open(simple, for: requester("a")) { _ in }
    _ = applet.open(simple, for: requester("b")) { _ in }
    _ = applet.open(simple, for: requester("c")) { _ in }

    applet.step(by: 1)

    XCTAssertEqual(applet.selectedRequesterKey, "a")

    applet.step(by: -1)

    XCTAssertEqual(applet.selectedRequesterKey, "c")

    applet.selectTab(number: 2)

    XCTAssertEqual(applet.selectedRequesterKey, "b")

    applet.selectTab(number: 9)

    XCTAssertEqual(applet.selectedRequesterKey, "c")

    applet.selectTab(number: 7)

    XCTAssertEqual(applet.selectedRequesterKey, "c")
  }

  // MARK: Focus

  /// Catches a form that opens without the keyboard, which "Focus when a form arrives" forbids. A
  /// new tab takes the keyboard into its first field, and typing reaches it at once.
  func testANewFormTakesTheKeyboardIntoItsFirstField() {
    let (applet, _) = makeApplet()
    let window = hold(applet)

    defer { window.close() }

    _ = applet.open(simple, for: requester("a")) { _ in }

    XCTAssertEqual(panel(in: applet)?.question(holding: window.firstResponder), "name")
  }

  /// Catches a requester's next form that leaves the keyboard on the old tab, and a resolved form
  /// that drops the keyboard out of the pane.
  func testResolvingKeepsTheKeyboardInTheTabAndTheNextFormTakesItAgain() throws {
    let (applet, _) = makeApplet()
    let window = hold(applet)

    defer { window.close() }

    _ = applet.open(simple, for: requester("a")) { _ in }

    try fill(applet, "name", "Ada")
    try press(applet, "ok")

    let responder = try XCTUnwrap(window.firstResponder as? NSView)

    XCTAssertTrue(responder.isDescendant(of: applet.view))

    _ = applet.open(simple, for: requester("a")) { _ in }

    XCTAssertEqual(panel(in: applet)?.question(holding: window.firstResponder), "name")
  }

  /// Catches a pane close that leaves the asker waiting. Every open form is dismissed, once.
  func testClosingThePaneDismissesEveryOpenForm() {
    let (applet, _) = makeApplet()
    var outcomes: [String: FormOutcome] = [:]

    _ = applet.open(simple, for: requester("a")) { outcomes["a"] = $0 }
    _ = applet.open(simple, for: requester("b")) { outcomes["b"] = $0 }

    applet.close()
    applet.close()

    XCTAssertEqual(outcomes, ["a": .dismissed, "b": .dismissed])
    XCTAssertEqual(applet.open(simple, for: requester("c")) { _ in }, .busy(.unavailable))
  }
}

/// Stands above the applet's view and records the keys that reach it.
private final class KeyCatcher: NSView {
  var keys: [UInt16] = []

  override func keyDown(with event: NSEvent) {
    keys.append(event.keyCode)
  }
}
