import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// JavaScript alerts, confirmations, and prompts against a real web view. The page's script
/// blocks until the dialog is answered, so each test runs the script in a task and answers through
/// the pane's own dialog view.
@MainActor
final class BrowserDialogTests: XCTestCase {
  private nonisolated static let handler: FixtureServer.Handler = { _ in
    Pages.page("Dialogs", "<p>page</p>")
  }

  private func make() async throws -> BrowserHarness {
    let harness = try await BrowserHarness.make(handler: Self.handler)

    await harness.load("/", expecting: "Dialogs")

    return harness
  }

  /// What a script returned, carried out of the task that waited for it. It is read on the main
  /// actor only.
  struct Outcome: @unchecked Sendable {
    var value: Any?
  }

  /// Runs `script` in the selected tab's web view, in a task, since it blocks on a dialog.
  private func start(_ script: String, in tab: BrowserTab? = nil, _ harness: BrowserHarness)
    -> Task<Outcome, Never>
  {
    let view = (tab ?? harness.tab).webView

    return Task { @MainActor in Outcome(value: try? await view.evaluateJavaScript(script)) }
  }

  private func shown(_ harness: BrowserHarness) -> PageDialog? {
    harness.applet.content.dialogView.shown
  }

  private func waitForDialog(_ harness: BrowserHarness) async {
    await harness.host.until("a dialog shows") { self.shown(harness) != nil }
  }

  /// Catches an alert that never reaches the user, a message that is the page's raw text, and a
  /// script that does not continue after OK. The dialog shows inside the pane and never asks the
  /// host, so it blocks no other pane.
  func testAnAlertShowsInThePaneAndTheScriptContinuesAfterOK() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let result = start("alert('hello'); 'done'", harness)

    await waitForDialog(harness)

    let view = harness.applet.content.dialogView

    XCTAssertEqual(view.messageLabel.stringValue, "hello")
    XCTAssertEqual(view.sourceLabel.stringValue, "127.0.0.1 says")
    XCTAssertTrue(view.cancelButton.isHidden)
    XCTAssertFalse(view.isHidden)
    XCTAssertEqual(harness.host.recording.confirmations.count, 0)

    view.accept()

    let value = await result.value.value

    XCTAssertEqual(value as? String, "done")
    XCTAssertTrue(view.isHidden)
    XCTAssertTrue(harness.applet.dialogs.isEmpty)
  }

  /// Catches a confirmation whose answer does not reach the page. OK is true, and Cancel is false.
  func testAConfirmationAnswersTrueOrFalse() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let view = harness.applet.content.dialogView

    let accepted = start("confirm('sure?')", harness)
    await waitForDialog(harness)

    XCTAssertFalse(view.cancelButton.isHidden)

    view.accept()

    let yes = await accepted.value.value

    XCTAssertEqual(yes as? Bool, true)

    let declined = start("confirm('sure?')", harness)
    await waitForDialog(harness)

    view.cancel()

    let no = await declined.value.value

    XCTAssertEqual(no as? Bool, false)
  }

  /// Catches a prompt that returns its default whatever the user types, and one that answers
  /// with an empty string where the user cancelled. Cancel is null.
  func testAPromptReturnsTheTypedTextOrNullOnCancel() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let view = harness.applet.content.dialogView

    let typed = start("prompt('name?', 'default')", harness)
    await waitForDialog(harness)

    XCTAssertFalse(view.field.isHidden)
    XCTAssertEqual(view.field.stringValue, "default")

    view.field.stringValue = "ripta"
    view.accept()

    let name = await typed.value.value

    XCTAssertEqual(name as? String, "ripta")

    let cancelled = start("String(prompt('name?', 'default'))", harness)
    await waitForDialog(harness)

    view.cancel()

    let none = await cancelled.value.value

    XCTAssertEqual(none as? String, "null")
  }

  /// Catches a page's own words reaching the pane uncleaned: a bidirectional override, a control
  /// character, and a very long message.
  func testAPagesMessageIsCleanedAndCut() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let long = String(repeating: "x", count: 5000)
    let result = start("alert('a\\u202Eb\\u0007c\\n' + '\(long)'); 1", harness)

    await waitForDialog(harness)

    let message = harness.applet.content.dialogView.messageLabel.stringValue

    XCTAssertTrue(message.hasPrefix("ab c\n"), message)
    XCTAssertFalse(message.unicodeScalars.contains { $0.value == 0x202E })
    XCTAssertLessThanOrEqual(message.count, DialogText.maximumCharacters + 1)
    XCTAssertTrue(message.hasSuffix("\u{2026}"))

    harness.applet.content.dialogView.accept()
    _ = await result.value.value
  }

  // MARK: Closing

  /// Catches a closed tab that leaves its page blocked on a dialog. The tab's dialogs are answered
  /// before its web view goes, and a dialog of another tab is not.
  func testClosingATabAnswersItsDialogsAndOnlyItsOwn() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let keep = start("confirm('keep')", harness)
    await waitForDialog(harness)

    harness.applet.openTab()
    await harness.load("/", expecting: "Dialogs")

    let drop = start("confirm('drop')", harness)

    await harness.host.until("both dialogs are held") { harness.applet.dialogs.pending.count == 2 }

    let closed = await harness.applet.closeCurrentTab()

    XCTAssertEqual(closed, .closed)

    let dropped = await drop.value.value

    XCTAssertEqual(dropped as? Bool, false)
    XCTAssertEqual(harness.applet.dialogs.pending.count, 1)
    XCTAssertNotNil(shown(harness), "the other tab's dialog shows now it is selected")

    harness.applet.content.dialogView.accept()

    let kept = await keep.value.value

    XCTAssertEqual(kept as? Bool, true)
  }

  /// Catches a pane close that leaves a page's script blocked. Every waiting dialog, in every tab,
  /// is answered, and none twice. Only the selected tab's dialog was on show.
  func testClosingThePaneAnswersEveryWaitingDialog() async throws {
    let harness = try await make()
    defer { harness.stop() }

    for _ in 0..<2 {
      harness.applet.openTab()
      await harness.load("/", expecting: "Dialogs")
    }

    let first = start("alert('a'); 'a-done'", in: harness.applet.tabs[0], harness)
    let second = start("confirm('b')", in: harness.applet.tabs[1], harness)
    let third = start("String(prompt('c', 'd'))", in: harness.applet.tabs[2], harness)

    await harness.host.until("three dialogs wait") { harness.applet.dialogs.pending.count == 3 }

    harness.applet.close()

    let a = await first.value.value
    let b = await second.value.value
    let c = await third.value.value

    XCTAssertEqual(a as? String, "a-done")
    XCTAssertEqual(b as? Bool, false)
    XCTAssertEqual(c as? String, "null")
    XCTAssertTrue(harness.applet.dialogs.isEmpty)
  }

  /// Catches a dialog from a tab the user is not looking at taking over the pane. It waits for its
  /// tab to be selected.
  func testABackgroundTabsDialogWaitsUntilItsTabIsSelected() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let background = harness.tab

    harness.applet.openTab()
    await harness.load("/", expecting: "Dialogs")

    let result = start("confirm('background')", in: background, harness)

    await harness.host.until("the dialog is held") { !harness.applet.dialogs.isEmpty }

    XCTAssertNil(shown(harness))

    harness.applet.selectTab(at: 0)

    XCTAssertNotNil(shown(harness))

    harness.applet.content.dialogView.accept()

    let value = await result.value.value

    XCTAssertEqual(value as? Bool, true)
  }

  // MARK: Bounds

  /// Catches a page that holds the pane hostage with a loop of alerts, and a browser that decides
  /// for the user. The first dialog offers nothing. The second and every later one offers to stop.
  /// A sixth dialog shows, since there is no count limit. Choosing the offer answers the dialog as
  /// Cancel would, dismisses the rest, and warns once. The next load starts over.
  func testALoopOfAlertsOffersToStopFromTheSecondDialogAndTheChoiceHoldsUntilTheNextLoad()
    async throws
  {
    let harness = try await make()
    defer { harness.stop() }

    harness.host.recording.forgetSent()

    let result = start(
      "var shown = 0; for (var i = 0; i < 20; i++) { alert('n' + i); shown += 1; } shown", harness)
    let view = harness.applet.content.dialogView

    XCTAssertEqual(view.stopButton.accessibilityIdentifier(), "browser-dialog-stop")
    XCTAssertEqual(
      view.stopButton.accessibilityLabel(), "Don\u{2019}t show more dialogs from this page")

    for index in 1...6 {
      await waitForDialog(harness)

      XCTAssertEqual(view.stopButton.isHidden, index == 1, "the offer at dialog \(index)")

      view.accept()
      await harness.host.until("the dialog goes") { self.shown(harness) == nil }
    }

    await waitForDialog(harness)

    XCTAssertEqual(view.messageLabel.stringValue, "n6", "a seventh dialog shows after six")
    XCTAssertTrue(harness.posts.filter { $0.level == .warning }.isEmpty)

    view.stopButton.performClick(nil)

    let value = await result.value.value

    XCTAssertEqual(value as? Int, 20)
    XCTAssertEqual(harness.posts.filter { $0.level == .warning }.count, 1)
    XCTAssertTrue(harness.applet.dialogs.isEmpty)
    XCTAssertTrue(view.isHidden)

    await harness.load("/again", expecting: "Dialogs")

    let fresh = start("confirm('first') && confirm('second')", harness)

    await waitForDialog(harness)

    XCTAssertTrue(view.stopButton.isHidden, "a new load starts with no offer")

    view.accept()
    await harness.host.until("the dialog goes") { self.shown(harness) == nil }
    await waitForDialog(harness)

    XCTAssertFalse(view.stopButton.isHidden)

    view.accept()

    let outcome = await fresh.value.value

    XCTAssertEqual(outcome as? Bool, true)
    XCTAssertEqual(harness.posts.filter { $0.level == .warning }.count, 1)
  }

  /// Catches a stop that answers the current dialog as OK, or that leaves the page's later
  /// dialogs unanswered. The dialog the user stops from reads as Cancel, and the later ones
  /// read as dismissed.
  func testStoppingAnswersTheCurrentDialogAsCancelAndDismissesTheRest() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let result = start(
      "var a = confirm('a'); var b = confirm('b'); var c = confirm('c'); [a, b, c].join()",
      harness)
    let view = harness.applet.content.dialogView

    await waitForDialog(harness)
    view.accept()
    await harness.host.until("the first dialog goes") { self.shown(harness) == nil }
    await waitForDialog(harness)
    view.stopButton.performClick(nil)

    let value = await result.value.value

    XCTAssertEqual(value as? String, "true,false,false")
  }

  /// Catches a stop that reaches a page the user did not stop. Stopping one tab's dialogs leaves
  /// another tab's dialogs showing, with their offer.
  func testStoppingOneTabsDialogsLeavesAnotherTabsAlone() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let first = harness.tab

    harness.applet.openTab()
    await harness.load("/other", expecting: "Dialogs")

    let second = harness.tab
    let view = harness.applet.content.dialogView
    let loop = start("alert(1); alert(2); alert(3); 'done'", in: first, harness)

    harness.applet.selectTab(at: 0)
    await waitForDialog(harness)
    view.accept()
    await harness.host.until("the dialog goes") { self.shown(harness) == nil }
    await waitForDialog(harness)
    view.stopButton.performClick(nil)

    _ = await loop.value.value

    harness.applet.selectTab(at: 1)

    let other = start("alert('a'); alert('b'); 'ok'", in: second, harness)

    await waitForDialog(harness)
    view.accept()
    await harness.host.until("the dialog goes") { self.shown(harness) == nil }
    await waitForDialog(harness)

    XCTAssertEqual(view.messageLabel.stringValue, "b")

    view.accept()

    let value = await other.value.value

    XCTAssertEqual(value as? String, "ok")
  }

  // MARK: Ownership

  /// Catches a completion handler called twice, which WebKit treats as a crash, or not at all.
  /// Each answer path reaches it once, and a second answer does nothing.
  func testADialogAnswersItsHandlerExactlyOnce() {
    let tab = BrowserTab(
      id: .make(), record: BrowserDescription.Tab(), dataStore: .nonPersistent(),
      hsts: HSTSStore())
    var answers: [PageDialog.Answer] = []

    let dialog = PageDialog(
      kind: .confirm, message: "m", source: "s", tab: tab, completion: { answers.append($0) })

    dialog.answer(.accepted)
    dialog.answer(.dismissed)
    dialog.answer(.text("late"))

    XCTAssertEqual(answers, [.accepted])
    XCTAssertTrue(dialog.isAnswered)
  }

  /// Catches an unbounded list of held dialogs, and a dialog over the bound that WebKit never
  /// hears about. The one over the bound is dismissed at once. Every other one is answered by
  /// the sweep, once.
  func testTheHeldListIsBoundedAndEveryDialogIsAnsweredOnce() {
    let tab = BrowserTab(
      id: .make(), record: BrowserDescription.Tab(), dataStore: .nonPersistent(),
      hsts: HSTSStore())
    let dialogs = PageDialogs()
    var counts = [Int](repeating: 0, count: PageDialogs.heldLimit + 3)

    for index in counts.indices {
      let dialog = PageDialog(
        kind: .alert, message: "m", source: "s", tab: tab, completion: { _ in counts[index] += 1 })

      dialogs.hold(dialog)
    }

    XCTAssertEqual(dialogs.pending.count, PageDialogs.heldLimit)
    XCTAssertEqual(counts.suffix(3), [1, 1, 1], "the ones over the bound were dismissed at once")

    dialogs.dismissAll()
    dialogs.dismissAll()

    XCTAssertEqual(counts, [Int](repeating: 1, count: counts.count))
    XCTAssertTrue(dialogs.isEmpty)
  }
}
