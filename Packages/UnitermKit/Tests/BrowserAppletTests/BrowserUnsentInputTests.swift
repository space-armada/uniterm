import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// The unsent-input tracker against a real web view. A trusted `input` event cannot come from a
/// script, since `isTrusted` is false on every event a page makes. The tests type through the web
/// view's `NSTextInputClient`, which is the path an input method or a key press takes, so WebKit
/// itself raises the event. What this proves is the script's logic and the handler's validation in
/// the real isolated world. It does not prove a physical key press through the window server.
@MainActor
final class BrowserUnsentInputTests: XCTestCase {
  private nonisolated static let pages: FixtureServer.Handler = { request in
    switch request.path {
    case "/form":
      return Pages.page(
        "Form",
        """
        <form id=f onsubmit="event.preventDefault()"><input id=a value=draft></form>
        <input id=b value=other><textarea id=t></textarea>
        <input id=c type=checkbox>
        <div id=ce contenteditable>start</div>
        """)

    case "/frames":
      return Pages.page(
        "Frames",
        """
        <input id=main value=m>
        <iframe id=sub src=/frame onload="document.title='Ready'"></iframe>
        """)

    case "/frame":
      return Pages.page("Frame", "<input id=x value=frameval>")

    case "/odd-title":
      return Pages.page("Draft &#x202E;notes\u{0A}  here", "<input id=a value=draft>")

    default:
      return Pages.page("Other")
    }
  }

  private func make() async throws -> BrowserHarness {
    try await BrowserHarness.make(hosting: .focusedWindow, handler: Self.pages)
  }

  /// Focuses the element `script` names and types over its text. `insertText` replaces the
  /// selection, so the script selects first.
  private func type(
    _ text: String, in harness: BrowserHarness, focusing element: String
  ) async {
    await harness.run(
      """
      var e = \(element); e.focus();
      if (e.select) { e.select(); } else {
        var range = document.createRange(); range.selectNodeContents(e);
        var selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
      }
      """)

    (harness.tab.webView as? any NSTextInputClient)?.insertText(
      text, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  private func byID(_ id: String) -> String { "document.getElementById('\(id)')" }

  private func inFrame(_ id: String) -> String {
    "document.getElementById('sub').contentDocument.getElementById('\(id)')"
  }

  private func page(_ harness: BrowserHarness, _ path: String, _ title: String) async {
    await harness.load(path, expecting: title)
  }

  /// Catches a tab that does not notice typed input, and one that notices only a change from a
  /// blank field, since the field starts with a default. A real typed edit marks the tab. The tab
  /// then counts as running something, named by its title.
  func testTypingIntoAFieldMarksTheTab() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")

    XCTAssertFalse(harness.tab.hasUnsentInput)
    XCTAssertFalse(harness.applet.isRunningSomething)

    await type("changed", in: harness, focusing: byID("a"))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    XCTAssertTrue(harness.applet.isRunningSomething)
    XCTAssertEqual(harness.applet.runningLabels, ["Form"])
  }

  /// Catches a mark that stays after the user types the default back. The field returns to its
  /// default value, and the mark clears.
  func testReturningTheFieldToItsDefaultClearsTheMark() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")
    await type("changed", in: harness, focusing: byID("a"))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    await type("draft", in: harness, focusing: byID("a"))
    await harness.host.until("the mark clears") { !harness.tab.hasUnsentInput }

    XCTAssertFalse(harness.applet.isRunningSomething)
    XCTAssertEqual(harness.applet.runningLabels, [])
  }

  /// Catches a tracker that ignores a field that is not a text input: a text area, a checkbox,
  /// and a `contenteditable` element, which has no `value`. Each marks, and each clears when it
  /// returns to its start.
  func testTextAreasCheckboxesAndContentEditableAreTracked() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")

    await type("note", in: harness, focusing: byID("t"))
    await harness.host.until("a text area marks") { harness.tab.hasUnsentInput }

    await type("", in: harness, focusing: byID("t"))
    await harness.host.until("a text area clears") { !harness.tab.hasUnsentInput }

    await type("typed words", in: harness, focusing: byID("ce"))
    await harness.host.until("contenteditable marks") { harness.tab.hasUnsentInput }

    await type("start", in: harness, focusing: byID("ce"))
    await harness.host.until("contenteditable clears") { !harness.tab.hasUnsentInput }
  }

  /// Catches a submit that leaves the mark. The form's own submit event clears its fields, and
  /// the page is left in place when the page cancels the navigation.
  func testSubmittingTheFormClearsTheMark() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")
    await type("changed", in: harness, focusing: byID("a"))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    await harness.run("\(byID("f")).requestSubmit()")
    await harness.host.until("the mark clears") { !harness.tab.hasUnsentInput }

    XCTAssertEqual(harness.applet.title, "Form")
  }

  /// Catches a mark that survives a load. A new page is a new document, so edits on the old one
  /// are gone.
  func testLoadingAnotherPageClearsTheMark() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")
    await type("changed", in: harness, focusing: byID("a"))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    await page(harness, "/other", "Other")

    XCTAssertFalse(harness.tab.hasUnsentInput)
  }

  /// Catches input in a subframe that goes unseen, and one frame clearing another's mark. The
  /// main frame's own field is edited and put back while the subframe's edit stands. Only the
  /// subframe putting its own field back clears the tab.
  func testEditsInASubframeMarkTheTabAndOnlyThatFrameClearsIt() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/frames", "Ready")

    await type("sub-edit", in: harness, focusing: inFrame("x"))
    await harness.host.until("the subframe marks the tab") { harness.tab.hasUnsentInput }

    let world = UnsentInputTracker.world

    _ = try await harness.tab.webView.evaluateJavaScript(
      """
      var handler = window.webkit.messageHandlers.unsentInput;
      var send = handler.postMessage.bind(handler);
      window.seen = [];
      handler.postMessage = function (body) { window.seen.push(body.unsent); send(body); };
      void 0;
      """, in: nil, contentWorld: world)

    await type("edited", in: harness, focusing: byID("main"))
    await type("m", in: harness, focusing: byID("main"))

    await harness.eventuallyAsync("the main frame reported its edit and its clear") {
      let seen = try? await harness.tab.webView.evaluateJavaScript(
        "JSON.stringify(window.seen)", in: nil, contentWorld: world)

      return seen as? String == "[true,false]"
    }

    XCTAssertTrue(harness.tab.hasUnsentInput, "the main frame cleared the subframe's mark")

    await type("frameval", in: harness, focusing: inFrame("x"))
    await harness.host.until("the subframe clears its own mark") { !harness.tab.hasUnsentInput }
  }

  /// Catches a mark that outlives its frame. A marked subframe that its parent removes, and one
  /// that navigates away, each report a clear as the document leaves, so a single-page app that
  /// swaps frames does not make its tab ask on every close. Measured with a real web view.
  func testAMarkedSubframeThatIsRemovedOrNavigatesAwayClearsItsMark() async throws {
    for departure in [
      "document.getElementById('sub').remove(); void 0",
      "document.getElementById('sub').src = '/other'; void 0",
    ] {
      let harness = try await make()
      defer { harness.stop() }

      await page(harness, "/frames", "Ready")
      await type("sub-edit", in: harness, focusing: inFrame("x"))
      await harness.host.until("the subframe marks the tab") { harness.tab.hasUnsentInput }

      await harness.run(departure)
      await harness.host.until("the mark clears with the frame: \(departure)") {
        !harness.tab.hasUnsentInput
      }
    }
  }

  /// Documents a limit. `document.execCommand('insertText')` from a page's script on a focused
  /// field raises a trusted `input` event, so it marks the tab with no typing. Measured with a real
  /// web view. No detector is built, since the cost is a question the user can confirm.
  func testAScriptsInsertTextCommandMarksTheTabAKnownLimit() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")
    await harness.run(
      """
      var e = \(byID("b")); e.focus(); e.select(); document.execCommand('insertText', false, 'forged'); void 0
      """)
    await harness.host.until("the command marks the tab") { harness.tab.hasUnsentInput }
  }

  /// Catches a page that marks its own tab, or clears a mark, with events it makes. An `input`
  /// event a script dispatches is untrusted. The field the page changed and announced never joins
  /// the watched set, so a real edit that is then put back clears the tab, which it could not if the
  /// page's field counted.
  func testAnInputEventAPageDispatchesNeverMarksTheTab() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")

    await harness.run(
      """
      var a = \(byID("a")); a.value = 'forged';
      a.dispatchEvent(new Event('input', {bubbles: true}));
      a.dispatchEvent(new InputEvent('input', {bubbles: true, data: 'x'}));
      document.body.click();
      """)

    await type("changed", in: harness, focusing: byID("b"))
    await harness.host.until("a real edit marks the tab") { harness.tab.hasUnsentInput }

    await type("other", in: harness, focusing: byID("b"))
    await harness.host.until("putting the real edit back clears the tab") {
      !harness.tab.hasUnsentInput
    }

    let forged = await harness.run("\(byID("a")).value")

    XCTAssertEqual(forged as? String, "forged")
  }

  /// Catches a page that can reach the handler. The handler lives in an isolated world, so the
  /// page's own world finds no handler to post to. A post it tries throws, and sends nothing.
  func testThePagesOwnWorldCannotReachTheHandler() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")

    let attempt = await harness.run(
      """
      (function () {
        try {
          window.webkit.messageHandlers.unsentInput.postMessage({frame: 'a'.repeat(32), unsent: true});
          return 'posted';
        } catch (error) {
          return 'blocked';
        }
      })()
      """)

    XCTAssertEqual(attempt as? String, "blocked")

    let handlers = await harness.run(
      "typeof window.webkit === 'undefined' ? 'none' : Object.keys(window.webkit.messageHandlers || {}).join(',')"
    )

    XCTAssertTrue(
      ["none", ""].contains(handlers as? String ?? "?"), "\(String(describing: handlers))")

    await type("changed", in: harness, focusing: byID("b"))
    await harness.host.until("a real edit still marks the tab") { harness.tab.hasUnsentInput }
  }

  /// Catches a native side that takes more than a frame token and a real boolean from the isolated
  /// world. Posting each wrong shape marks nothing. The right shape marks, and a clear for that
  /// frame unmarks.
  func testTheNativeSideAcceptsNothingButAStrictReport() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")

    let world = UnsentInputTracker.world
    let frame = String(repeating: "c", count: 32)

    func post(_ body: String) async {
      _ = try? await harness.tab.webView.evaluateJavaScript(
        "window.webkit.messageHandlers.unsentInput.postMessage(\(body))", in: nil,
        contentWorld: world)
    }

    for wrong in [
      "true", "1", "'yes'", "null", "{}", "[true]", "{frame: '\(frame)', unsent: 1}",
      "{frame: '\(frame)', unsent: 'true'}", "{frame: 'short', unsent: true}",
      "{frame: '\(frame)', unsent: true, extra: 1}", "{unsent: true}",
      "{frame: '\(String(repeating: "C", count: 32))', unsent: true}",
    ] {
      await post(wrong)
    }

    await post("{frame: '\(frame)', unsent: true}")
    await harness.host.until("the strict report marks") { harness.tab.hasUnsentInput }

    await post("{frame: '\(String(repeating: "d", count: 32))', unsent: false}")

    XCTAssertTrue(harness.tab.hasUnsentInput, "another frame's clear took this frame's mark")

    await post("{frame: '\(frame)', unsent: false}")
    await harness.host.until("its own clear unmarks") { !harness.tab.hasUnsentInput }
  }

  /// Catches a flood that reaches the handler one message per flip. A page flips a watched field's
  /// value and clicks in a tight loop. The script coalesces them to a few posts.
  func testAFloodOfFlipsCostsAFewMessages() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")
    await type("changed", in: harness, focusing: byID("a"))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    let world = UnsentInputTracker.world

    _ = try await harness.tab.webView.evaluateJavaScript(
      """
      var handler = window.webkit.messageHandlers.unsentInput;
      window.counted = 0;
      handler.postMessage = function () { window.counted += 1; };
      void 0;
      """, in: nil, contentWorld: world)

    await harness.run(
      """
      var a = \(byID("a"));
      for (var i = 0; i <= 2000; i++) { a.value = i % 2 ? 'changed' : 'draft'; document.body.click(); }
      """)

    await harness.eventuallyAsync("the script posts the final state") {
      let counted = try? await harness.tab.webView.evaluateJavaScript(
        "window.counted", in: nil, contentWorld: world)

      return (counted as? Int ?? 0) >= 1
    }

    let counted = try await harness.tab.webView.evaluateJavaScript(
      "window.counted", in: nil, contentWorld: world)

    XCTAssertEqual(counted as? Int, 1)
  }

  /// Catches a tab counted as running something for a reason that is not unsent input or a download:
  /// a page that is loading.
  func testNothingButInputAndDownloadsCountsAsRunning() async throws {
    let harness = try await make()
    defer { harness.stop() }

    XCTAssertFalse(harness.applet.isRunningSomething)

    harness.applet.submit(address: harness.server.url("/form").absoluteString)

    XCTAssertFalse(harness.applet.isRunningSomething, "a loading page counted")

    await harness.host.until("the page shows") { harness.applet.title == "Form" }

    XCTAssertFalse(harness.applet.isRunningSomething, "a loaded page counted")
    XCTAssertEqual(harness.applet.runningLabels, [])
  }

  // MARK: Closing

  /// Catches a tab with input that closes with no question, whether or not it is selected, and a
  /// question that keeps asking after the input is gone. The question names the tab by its cleaned
  /// title. Cmd-W on the last tab leaves the pane close to the host, which asks through
  /// `isRunningSomething` and `runningLabels`.
  func testClosingATabWithInputAsksUntilTheInputIsGone() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/odd-title", "Draft notes here")
    await type("changed", in: harness, focusing: byID("a"))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    XCTAssertEqual(harness.applet.runningLabels, ["Draft notes here"])

    let last = await harness.applet.closeCurrentTab()

    XCTAssertEqual(last, .nothingToClose)
    XCTAssertTrue(harness.applet.isRunningSomething)

    harness.applet.openTab()
    harness.host.recording.answer = false

    let declined = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(declined, .declined)
    XCTAssertEqual(harness.applet.tabCount, 2)

    let question = try XCTUnwrap(harness.host.recording.confirmations.first)

    XCTAssertTrue(question.detail.contains("Draft notes here"), question.detail)
    XCTAssertFalse(question.detail.unicodeScalars.contains { $0.value == 0x202E })

    harness.applet.selectTab(at: 0)
    await type("draft", in: harness, focusing: byID("a"))
    await harness.host.until("the input is back to its default") { !harness.tab.hasUnsentInput }

    let asked = harness.host.recording.confirmations.count
    let closed = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(closed, .closed)
    XCTAssertEqual(
      harness.host.recording.confirmations.count, asked, "it asked with nothing to lose")
  }

  /// Catches a question that cannot be answered yes. A yes closes the tab, and the input goes
  /// with it.
  func testAYesClosesTheTabWithInput() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await page(harness, "/form", "Form")
    await type("changed", in: harness, focusing: byID("a"))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    harness.applet.openTab()
    harness.host.recording.answer = true

    let closed = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(closed, .closed)
    XCTAssertFalse(harness.applet.isRunningSomething)
  }

  /// Catches a tab that is kept alive by its handler. The script message handler is the one
  /// strong reference WebKit keeps into the app, and it must not lead back to the tab. A tab with a
  /// mark is released after it closes.
  func testAClosedTabWithAMarkIsReleased() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.openTab()
    await page(harness, "/form", "Form")
    await type("changed", in: harness, focusing: byID("a"))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    weak var tab: BrowserTab?
    weak var tracker: UnsentInputTracker?
    weak var webView: WKWebView?

    do {
      let opened = harness.applet.tab
      tab = opened
      tracker = opened.unsent
      webView = opened.webView
    }

    harness.host.recording.answer = true

    let closed = await harness.applet.closeCurrentTab()

    XCTAssertEqual(closed, .closed)

    await harness.eventually("the tab and its tracker are released") {
      tab == nil && tracker == nil && webView == nil
    }
  }
}
