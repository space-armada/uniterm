import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import Darwin
import ProcessInspection
import ProcessTestSupport
import StatusKit
import Synchronization
import WebKit
import XCTest

@testable import BrowserApplet

/// Stands in for the timer that bounds a user's reload or navigation. The test fires it by hand, so
/// no test waits for a real bound. It counts what was armed and what a sign of life cancelled.
@MainActor
final class ManualHangTimer {
  private var next = 0

  private(set) var armed: [Int: @MainActor @Sendable () -> Void] = [:]
  private(set) var scheduled = 0
  private(set) var cancelled = 0

  var policy: HangPolicy {
    HangPolicy(bound: .seconds(10)) { [self] _, action in
      next += 1
      scheduled += 1

      let id = next

      armed[id] = action

      return { [self] in
        if armed.removeValue(forKey: id) != nil { cancelled += 1 }
      }
    }
  }

  func fire() {
    let all = armed

    armed = [:]

    for action in all.values { action() }
  }
}

/// Hands each bound to `HangPolicy.sleeping` once the test opens it. Until then an armed bound is
/// held and never fires, so the real clock runs only for the reload the test means to time.
@MainActor
final class SleepingAfterGate {
  var isOpen = false

  var schedule: HangPolicy.Schedule {
    { [self] duration, action in
      guard isOpen else { return {} }

      return HangPolicy.sleeping(duration, action)
    }
  }
}

/// The content processes the tests recorded, so a stand-in for the product's signal seam signals
/// only a process a test learned.
let learnedContent = Mutex<[ProcessRecord]>([])

/// How the tests end a content process and name it. WebKit's `_killWebContentProcess` exists on
/// this macOS and does nothing the navigation delegate hears about, so the tests send SIGKILL to
/// the process that `_webProcessIdentifier` names. That is a real crash from WebKit's side. The
/// product reads the same property in `WebContentProcess`. This helper has its own read, and it
/// signals through `ProcessSender`, so a test that crashes a process does not depend on the
/// product's guards.
@MainActor
enum WebContent {
  /// Ends the view's content process once it has one. A process id of 0 means none was launched
  /// yet, so the call waits for a real id and never signals anything else.
  static func crash(
    _ view: WKWebView, in harness: BrowserHarness, file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    await harness.eventually("the web view has a content process", file: file, line: line) {
      processID(of: view) != nil
    }

    guard let content = record(of: view) else {
      return XCTFail(
        "the web view's content process is not a recorded WebContent process", file: file,
        line: line)
    }

    XCTAssertTrue(
      ProcessSender.signal(SIGKILL, content, expecting: .token, file: file, line: line),
      "the content process was gone before the crash", file: file, line: line)
  }

  /// The view's content process, recorded with its start time. The tests learn a process only
  /// through here, and the path must be WebKit's content process.
  static func record(of view: WKWebView) -> ProcessRecord? {
    guard let pid = processID(of: view),
      ProcessInspection.executablePath(of: pid)?.contains("com.apple.WebKit.WebContent") == true,
      let record = ProcessRecord(pid: pid)
    else { return nil }

    learnedContent.withLock { $0.append(record) }

    return record
  }

  /// Ends a content process the test recorded, through the guarded call. WebContent gives a token,
  /// so the signal goes down the token path. A process that already ended is fine, which suits a cleanup defer. A test that means to crash
  /// a live process uses `crash`.
  static func end(_ record: ProcessRecord) {
    ProcessSender.signal(SIGKILL, record, expecting: .token)
  }

  static func processID(of view: WKWebView) -> pid_t? {
    guard let number = view.value(forKey: "_webProcessIdentifier") as? NSNumber else { return nil }

    let pid = pid_t(number.int32Value)

    return pid > 1 ? pid : nil
  }

  static func isRunning(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno != ESRCH
  }
}

/// A web view whose content process ended or hung. The tab shows the stopped message only for the
/// selected tab. Any other tab goes back to not yet loaded. Recovery always
/// builds a new web view from the tab's address and history, and nothing reloads by itself.
@MainActor
final class BrowserRecoveryTests: XCTestCase {
  private nonisolated static func pages(slow: FixtureServer.Hold? = nil) -> FixtureServer.Handler {
    let slowCount = Mutex(0)

    return { request in
      switch (request.method, request.path) {
      case ("GET", "/slow"):
        let count = slowCount.withLock { value -> Int in
          value += 1
          return value
        }

        var response = Pages.page("Slow", "<p>slow</p>")

        if count > 1 { response.stall = slow }

        return response

      case ("GET", "/untitled"):
        return FixtureServer.Response(
          status: 200, headers: Pages.noStore, body: Data("<body>no title</body>".utf8))

      case ("GET", "/form"):
        return Pages.page("Form", "<form method=post action=/result><input name=a value=1></form>")

      case ("POST", "/result"):
        return Pages.page("Posted")

      case ("GET", "/held"):
        return FixtureServer.Response(
          status: 200,
          headers: [
            ("Content-Type", "application/octet-stream"),
            ("Content-Disposition", "attachment; filename=\"held.bin\""),
          ], body: Data("he".utf8), hold: slow, tail: Data("llo".utf8))

      case ("GET", "/input"):
        return Pages.page("Input", "<input id=a value=draft>")

      case ("GET", "/ssh"):
        return Pages.page("Ssh", "<a id=l href=\"ssh://host/x\">x</a>")

      case ("GET", "/unload"):
        return Pages.page(
          "Unload",
          "<script>window.onbeforeunload = function (e) { return 'stay'; }</script>")

      case ("GET", "/opener"):
        return Pages.page("Opener", "<button id=go onclick=\"window.open('/popup')\">go</button>")

      default:
        return Pages.page(String(request.path.dropFirst()).uppercased())
      }
    }
  }

  private func make(
    services: BrowserServices = .testing(), slow: FixtureServer.Hold? = nil
  ) async throws -> BrowserHarness {
    try await BrowserHarness.make(
      services: services, hosting: .focusedWindow, handler: Self.pages(slow: slow))
  }

  private func hang(_ view: WKWebView) {
    view.evaluateJavaScript("while (true) {}", completionHandler: nil)
  }

  // MARK: A content process that ends

  /// Catches a stopped tab that shows a blank pane, reloads by itself, or comes back without its
  /// history. The message names Reload and appears with no request to the server. Reload builds a
  /// new web view that restores the page and the step back. The old web view is released.
  func testKillingTheSelectedTabShowsTheMessageAndReloadBringsBackItsHistory() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")

    weak let old: WKWebView? = harness.tab.webView

    let before = harness.server.requests.count
    let record = try XCTUnwrap(harness.tab.interactionData)

    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the stopped message shows") { harness.tab.isStopped }

    XCTAssertEqual(harness.tab.interactionData, record, "the stop replaced the history record")

    let undo = try XCTUnwrap(
      harness.applet.describe().undoState?.value(as: BrowserDescription.UndoState.self))

    XCTAssertEqual(undo.tabStates.first ?? nil, record)

    let page = harness.applet.content.errorPage

    XCTAssertFalse(page.isHidden)
    XCTAssertEqual(page.titleLabel.stringValue, "This page stopped")
    XCTAssertFalse(page.reloadButton.isHidden)
    XCTAssertTrue(page.actionButton.isHidden)
    XCTAssertEqual(harness.server.requests.count, before, "a stopped tab reloaded by itself")
    XCTAssertTrue(
      harness.records.contains { $0.text.contains("stopped") }, "\(harness.records)")

    await harness.eventually("the old web view is released") { old == nil }

    page.reloadButton.performClick(nil)

    // The rebuilt view starts with no title, and WebKit reports the new one after the load ends.
    // Until then the tab shows the host, so the wait names the title as well.
    await harness.eventually("the page is back and has its title") {
      harness.tab.currentURL?.path == "/b" && !harness.tab.isLoading && !harness.tab.isStopped
        && harness.applet.title == "B"
    }

    XCTAssertTrue(page.isHidden)
    XCTAssertEqual(harness.applet.title, "B")
    XCTAssertTrue(harness.tab.canGoBack, "the history did not come back")
    XCTAssertEqual(harness.count("GET", "/b"), 2)

    harness.applet.goBack()
    await harness.host.until("the step back works") { harness.applet.title == "A" }
  }

  /// Catches a typed address on a stopped tab that throws away the history the stop kept. The
  /// typed page loads after the history, so Back reaches the page the tab stopped on.
  func testATypedAddressOnAStoppedTabKeepsTheHistoryTheStopKept() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")
    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the stopped message shows") { harness.tab.isStopped }

    harness.applet.submit(address: harness.server.url("/c").absoluteString)
    await harness.host.until("the typed page loads") {
      harness.applet.title == "C" && !harness.tab.isLoading
    }

    XCTAssertFalse(harness.tab.isStopped)
    XCTAssertTrue(harness.tab.canGoBack, "the typed load dropped the history")
    XCTAssertEqual(harness.tab.webView.backForwardList.backList.last?.url.path, "/b")
  }

  /// Catches a Reload that does nothing on a stopped tab that holds history and no address. A
  /// pop-up whose first page is a `blob:` preview stores no address, and no typed load set one. The
  /// stop must stay until the tab knows it will load, and the load takes the history record.
  func testReloadOnAStoppedTabWithHistoryAndNoAddressRestoresTheHistory() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.run(
      """
      window.open(URL.createObjectURL(
        new Blob(['<title>Preview</title>hello'], {type: 'text/html'})))
      """)
    await harness.host.until("the preview pop-up loads") {
      harness.applet.tabCount == 2 && harness.applet.title == "Preview" && !harness.tab.isLoading
    }

    let popup = harness.tab

    XCTAssertNil(popup.record.url, "the preview stored an address")

    await WebContent.crash(popup.webView, in: harness)
    await harness.eventually("the stopped message shows") { popup.isStopped }

    harness.applet.content.errorPage.reloadButton.performClick(nil)

    await harness.eventually("the history came back") {
      popup.currentURL != nil && !popup.isStopped
    }

    XCTAssertTrue(harness.applet.content.errorPage.isHidden)
  }

  /// Catches a tab nobody is looking at that shows a message, or loads while nobody looks. It goes
  /// back to not yet loaded, holds no web view, and loads with its history when it is selected.
  func testKillingAnUnselectedTabLeavesItNotYetLoadedUntilItIsSelected() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")
    harness.applet.openTab()
    await harness.load("/c", expecting: "C")

    let background = harness.applet.tabs[0]

    harness.applet.selectTab(at: 0)

    let selected = harness.applet.tabs[1]

    await WebContent.crash(selected.webView, in: harness)
    await harness.eventually("the background tab lost its content") { selected.generation == 1 }

    XCTAssertFalse(selected.isStopped)
    XCTAssertFalse(selected.isMaterialized)
    XCTAssertFalse(selected.hasBegunLoading)
    XCTAssertTrue(harness.applet.content.errorPage.isHidden)
    XCTAssertEqual(harness.count("GET", "/c"), 1)
    XCTAssertTrue(background === harness.tab)

    let described = harness.applet.describe()

    XCTAssertNotNil(described.undoState, "the history record stays in the description")

    harness.applet.selectTab(at: 1)

    await harness.host.until("the tab loads when selected") {
      harness.tab.currentURL?.path == "/c" && !harness.tab.isLoading
    }

    XCTAssertEqual(harness.count("GET", "/c"), 2)
    XCTAssertFalse(harness.tab.isStopped)
  }

  /// Catches a page that crashes on load being reloaded in a loop, and a second stop that stays
  /// quiet. Each Reload is the user's, and each stop shows the message again.
  func testAPageThatStopsAgainShowsTheMessageAgainAndNeverReloadsItself() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")
    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the first stop shows") { harness.tab.isStopped }

    let tab = harness.tab

    harness.applet.reload()

    XCTAssertFalse(tab.isStopped)

    await WebContent.crash(tab.webView, in: harness)
    await harness.eventually("the second stop shows") {
      tab.isStopped && tab.generation == 2
    }

    XCTAssertFalse(harness.applet.content.errorPage.isHidden)
    XCTAssertEqual(harness.records.filter { $0.text.contains("stopped") }.count, 2)
    XCTAssertFalse(tab.isLoading, "the tab reloaded without the user")

    let requests = harness.server.requests.count

    harness.applet.reload()
    await harness.eventually("the page is back") {
      tab.currentURL?.path == "/b" && !tab.isLoading && !tab.isStopped
    }

    XCTAssertGreaterThan(harness.server.requests.count, requests)
    XCTAssertTrue(tab.canGoBack, "the second stop lost the history the first one kept")
  }

  /// Catches a tab that never loaded showing a message about a page it does not have. A blank tab
  /// stays blank and keeps a web view the pane can show.
  func testABlankTabThatLosesItsContentStaysBlank() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let tab = harness.tab

    tab.webViewWebContentProcessDidTerminate(tab.webView)

    XCTAssertFalse(tab.isStopped)
    XCTAssertTrue(harness.applet.content.errorPage.isHidden)
    XCTAssertEqual(tab.generation, 1)

    await harness.load("/a", expecting: "A")
  }

  // MARK: What a stop leaves waiting

  /// Catches an unsent mark that survives its input, and a download that does not. The input went
  /// with the process, and the network process keeps the download, which still asks on close.
  func testAStopClearsTheUnsentMarkAndKeepsARunningDownload() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(slow: hold)
    defer { harness.stop() }

    await harness.load("/input", expecting: "Input")
    await harness.run("var e = document.getElementById('a'); e.focus(); e.select();")

    (harness.tab.webView as? any NSTextInputClient)?.insertText(
      "typed", replacementRange: NSRange(location: NSNotFound, length: 0))
    await harness.host.until("the tab holds unsent input") { harness.tab.hasUnsentInput }

    harness.applet.submit(address: harness.server.url("/held").absoluteString)
    await harness.host.until("the download has a file") {
      harness.applet.downloads.active.first?.temporary != nil
    }

    weak let old: WKWebView? = harness.tab.webView

    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the tab stopped") { harness.tab.isStopped }

    XCTAssertFalse(harness.tab.hasUnsentInput)
    XCTAssertTrue(harness.applet.isRunningSomething, "the download is still running")
    XCTAssertEqual(harness.applet.runningLabels, ["held.bin"])
    await harness.eventually("the old web view is released") { old == nil }

    harness.applet.openTab()
    harness.host.recording.answer = false

    let declined = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(declined, .declined)
    XCTAssertTrue(
      harness.host.recording.confirmations.last?.detail.contains("held.bin") ?? false,
      "\(harness.host.recording.confirmations)")

    hold.release()
    await harness.host.until("the download finishes") { !harness.posts.isEmpty }

    let saved = try XCTUnwrap(harness.downloadsDirectory)
      .appending(path: "held.bin", directoryHint: .notDirectory)

    XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "hello")
    XCTAssertFalse(harness.applet.isRunningSomething)
  }

  /// Catches a dialog that WebKit never hears back about, or hears about twice. WebKit treats a
  /// handler that is dropped or called twice as a crash. Every held dialog of the tab gets its one
  /// answer, and the pane shows none.
  func testAStopAnswersEveryHeldDialogOnce() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let view = harness.tab.webView
    let result = Task { @MainActor in _ = try? await view.evaluateJavaScript("confirm('x')") }

    await harness.host.until("the dialog shows") {
      harness.applet.content.dialogView.shown != nil
    }

    var answers = 0

    let spy = PageDialog(
      kind: .alert, message: "m", source: "s", tab: harness.tab, completion: { _ in answers += 1 })

    harness.applet.tab(harness.tab, present: spy)

    await WebContent.crash(view, in: harness)
    await harness.eventually("the tab stopped") { harness.tab.isStopped }

    XCTAssertEqual(answers, 1)
    XCTAssertTrue(spy.isAnswered)
    XCTAssertTrue(harness.applet.dialogs.isEmpty)
    XCTAssertNil(harness.applet.content.dialogView.shown)

    harness.applet.content.dialogView.accept()
    spy.answer(.accepted)

    XCTAssertEqual(answers, 1)

    await result.value
  }

  /// Catches a question about sending a form again that outlives its page. The stop resolves it as
  /// no. A yes the user gives afterwards sends nothing.
  func testAStopResolvesAResendQuestionAndALateYesSendsNothing() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.postResult()

    harness.host.recording.holdsQuestions = true
    harness.applet.reload()
    await harness.host.until("the question is asked") {
      harness.host.recording.confirmations.count == 1
    }

    XCTAssertTrue(harness.tab.isAskingToResend)

    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the tab stopped") { harness.tab.isStopped }

    XCTAssertFalse(harness.tab.isAskingToResend, "the stop left the question waiting")

    harness.host.recording.pendingAnswer?.resume(returning: true)
    harness.host.recording.pendingAnswer = nil
    harness.host.recording.holdsQuestions = false

    await harness.load("/barrier", expecting: "BARRIER")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
  }

  /// Catches an app handoff question that opens an app for a page that is gone. The stop ends the
  /// tab's wait, so a later question can ask, and a late yes opens nothing.
  func testAStopEndsAHandoffQuestionAndALateYesOpensNothing() async throws {
    let opener = FakeOpener()
    let harness = try await make(services: .testing(opener: opener))
    defer { harness.stop() }

    await harness.load("/ssh", expecting: "Ssh")

    harness.host.recording.holdsQuestions = true
    harness.tab.noteMouseUp()
    await harness.run("document.getElementById('l').click()")
    await harness.host.until("the question is asked") {
      harness.host.recording.confirmations.count == 1
    }

    XCTAssertTrue(harness.tab.isAskingToOpenApp)

    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the tab stopped") { harness.tab.isStopped }

    XCTAssertFalse(harness.tab.isAskingToOpenApp)

    harness.host.recording.pendingAnswer?.resume(returning: true)
    harness.host.recording.pendingAnswer = nil
    harness.host.recording.holdsQuestions = false

    await harness.load("/barrier", expecting: "BARRIER")

    XCTAssertTrue(opener.opened.isEmpty, "\(opener.opened)")
  }

  /// Catches a tab close that breaks when the tab stops while the question is up. The close goes
  /// ahead on yes, and the closed tab keeps its history for reopening.
  func testAStopWhileACloseQuestionIsUpStillClosesTheTabWithItsHistory() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(slow: hold)
    defer { harness.stop() }

    harness.applet.openTab()
    await harness.load("/a", expecting: "A")
    harness.applet.submit(address: harness.server.url("/held").absoluteString)
    await harness.host.until("the download has a file") {
      harness.applet.downloads.active.first?.temporary != nil
    }

    let target = harness.tab

    harness.applet.selectTab(at: 0)
    harness.host.recording.holdsQuestions = true

    let closing = Task { @MainActor in await harness.applet.closeTab(at: 1) }

    await harness.host.until("the close question is up") {
      harness.host.recording.confirmations.count == 1
    }

    await WebContent.crash(target.webView, in: harness)
    await harness.eventually("the tab lost its content") { target.generation == 1 }

    harness.host.recording.pendingAnswer?.resume(returning: true)

    let result = await closing.value

    XCTAssertEqual(result, .closed)
    XCTAssertEqual(harness.applet.tabCount, 1)

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.first)

    harness.host.recording.holdsQuestions = false

    guard case .reopened = harness.applet.reopenTab(stamp: stamp) else {
      return XCTFail("the closed tab did not reopen")
    }

    await harness.host.until("the reopened tab loads") {
      harness.tab.currentURL?.path == "/a" && !harness.tab.isLoading
    }

    hold.release()
  }

  // MARK: Pop-ups

  /// Catches a pop-up that does not rebuild like any other tab. It loses its opener, which is
  /// unavoidable, and its page comes back on Reload in the browser's store. Each tab handles its
  /// own stop. Measured: a pop-up shares its opener's process here, so ending one ends both. The
  /// selected pop-up shows the message and the background opener waits to be selected.
  func testAPopUpRebuildsWithoutItsOpenerAndEachTabHandlesItsOwnStop() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")

    let opener = harness.tab

    await harness.run("window.open('/popup')")
    await harness.host.until("the pop-up opens") {
      harness.applet.tabCount == 2 && harness.applet.title == "POPUP"
    }

    let popup = harness.tab

    XCTAssertTrue(popup.isPopup)

    await WebContent.crash(popup.webView, in: harness)
    await harness.eventually("the pop-up stopped") { popup.isStopped }

    XCTAssertEqual(popup.generation, 1)

    await harness.eventually("the opener lost its content too") { opener.generation == 1 }

    XCTAssertFalse(opener.isStopped, "the opener is in the background, so it only waits")
    XCTAssertFalse(opener.isMaterialized)

    harness.applet.reload()
    await harness.eventually("the pop-up is back") {
      popup.currentURL?.path == "/popup" && !popup.isLoading && !popup.isStopped
    }

    XCTAssertTrue(popup.isPopup)
    XCTAssertTrue(popup.isMaterialized)
    XCTAssertEqual(harness.count("GET", "/popup"), 2)

    harness.applet.selectTab(at: 0)
    await harness.host.until("the opener loads when selected") {
      opener.currentURL?.path == "/opener" && !opener.isLoading
    }
  }

  // MARK: A content process that hangs

  /// Catches a hung page that Reload cannot recover. The reload never reaches the hung process, so
  /// the server sees nothing and no sign of life cancels the bound. When it runs out the tab
  /// replaces the web view, the page loads again with its history, and the old web view is
  /// released. Measured: WebKit does not end the hung process when its web view is released, and it
  /// was still spinning 100 seconds later. The tab ends the process itself, and
  /// `BrowserHungProcessTests` proves that. This test keeps its own cleanup as a safety net.
  func testAHangThatIgnoresReloadIsReplacedWhenTheBoundRunsOut() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(services: .testing(hang: timer.policy))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")

    XCTAssertTrue(timer.armed.isEmpty, "a load that got its answer left a bound armed")

    var old: WKWebView? = harness.tab.webView

    weak let weakOld: WKWebView? = old

    let content = try XCTUnwrap(WebContent.record(of: try XCTUnwrap(old)))

    defer { WebContent.end(content) }

    hang(try XCTUnwrap(old))

    let before = timer.scheduled

    harness.applet.reload()

    XCTAssertEqual(timer.scheduled, before + 1)
    XCTAssertEqual(timer.armed.count, 1, "the hung process answered, so the bound was cancelled")

    timer.fire()
    old = nil

    await harness.eventually("the page is back in a new web view") {
      harness.tab.generation == 1 && harness.tab.currentURL?.path == "/b"
        && !harness.tab.isLoading
    }

    XCTAssertEqual(harness.count("GET", "/b"), 2, "the hung reload never reached the server")
    XCTAssertTrue(harness.tab.canGoBack)
    XCTAssertFalse(harness.tab.isStopped)
    XCTAssertTrue(harness.applet.content.errorPage.isHidden)

    await harness.eventually("the old web view is released") { weakOld == nil }
  }

  /// Catches a schedule that never fires or fires early in production. Every other test injects
  /// the schedule, so none of them runs `HangPolicy.sleeping` or wires it to a tab. A cheaper layer
  /// cannot show that a real clock reaches the tab, and a short bound keeps this to half a second.
  ///
  /// The first load arms the bound too. A slow runner can take longer than the short bound to start
  /// a content process, so the gate holds every arm until that load is done.
  func testTheRealTimerReplacesAHungWebViewAfterItsBound() async throws {
    let gate = SleepingAfterGate()
    let harness = try await make(
      services: .testing(hang: HangPolicy(bound: .milliseconds(300), schedule: gate.schedule)))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let content = try XCTUnwrap(WebContent.record(of: harness.tab.webView))

    defer { WebContent.end(content) }

    gate.isOpen = true
    hang(harness.tab.webView)
    harness.applet.reload()

    await harness.eventually("the page is back in a new web view") {
      harness.tab.generation == 1 && harness.tab.currentURL?.path == "/a"
        && !harness.tab.isLoading
    }

    XCTAssertEqual(harness.count("GET", "/a"), 2)
  }

  /// Catches a bound that rebuilds a page that is merely slow. The server holds its answer, and the
  /// content process still reports the navigation, so the bound is cancelled long before it would
  /// run out. Firing it afterwards does nothing, and the page finishes in the same web view.
  func testASlowServerNeverFiresTheBound() async throws {
    let timer = ManualHangTimer()
    let stall = FixtureServer.Hold()
    let harness = try await make(services: .testing(hang: timer.policy), slow: stall)
    defer {
      stall.release()
      harness.stop()
    }

    await harness.load("/slow", expecting: "Slow")

    let view = harness.tab.webView
    let cancelled = timer.cancelled
    let scheduled = timer.scheduled

    harness.applet.reload()

    XCTAssertEqual(timer.scheduled, scheduled + 1)

    await harness.eventually("a sign of life cancels the bound") {
      timer.cancelled == cancelled + 1
    }

    timer.fire()

    XCTAssertTrue(harness.tab.webView === view, "a slow page was rebuilt")
    XCTAssertEqual(harness.tab.generation, 0)

    stall.release()
    await harness.host.until("the slow page finishes") { !harness.tab.isLoading }

    XCTAssertEqual(harness.count("GET", "/slow"), 2)
    XCTAssertTrue(harness.tab.webView === view)
  }

  /// Catches a typed address on a hung tab that goes nowhere. The new web view loads what the user
  /// typed and keeps the history of the page that hung.
  func testATypedAddressOnAHungTabLoadsInTheNewWebViewWithItsHistory() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(services: .testing(hang: timer.policy))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let content = try XCTUnwrap(WebContent.record(of: harness.tab.webView))

    defer { WebContent.end(content) }

    hang(harness.tab.webView)
    harness.applet.submit(address: harness.server.url("/c").absoluteString)

    XCTAssertEqual(timer.armed.count, 1)

    timer.fire()

    await harness.host.until("the typed page loads and its title arrives") {
      harness.tab.currentURL?.path == "/c" && !harness.tab.isLoading
        && harness.applet.title == "C"
    }

    XCTAssertTrue(harness.tab.canGoBack, "the history of the hung page was lost")
  }

  /// Catches a rebuilt view that keeps the old page's title. The title belongs to the view that
  /// went, so the new view starts with none. A page with no title never reports one, and the old
  /// page's name would otherwise stay in the tab bar for good. The tab shows the title it stored
  /// until the new page commits. The commit clears it, so the tab shows the host until the new page
  /// names itself. Measured: that title arrives a moment after the load ends, which is why the test
  /// above waits on the title itself.
  func testARebuiltViewDoesNotKeepTheOldPagesTitle() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(services: .testing(hang: timer.policy))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let content = try XCTUnwrap(WebContent.record(of: harness.tab.webView))

    defer { WebContent.end(content) }

    hang(harness.tab.webView)
    harness.applet.submit(address: harness.server.url("/untitled").absoluteString)
    timer.fire()

    await harness.host.until("the untitled page loads") {
      harness.tab.currentURL?.path == "/untitled" && !harness.tab.isLoading
    }

    XCTAssertNil(harness.tab.pageTitle, "the old page's title outlived its view")
  }

  // MARK: What the bound leaves alone

  /// Records that WebKit never raises the "Leave page?" question of a `beforeunload` handler to the
  /// public UI delegate. It answers the question itself, so a reload of such a page ends as any
  /// other and the process answers it. The bound is cancelled by the navigation callbacks.
  func testABeforeUnloadHandlerNeverRaisesADialogAndTheReloadEndsNormally() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(services: .testing(hang: timer.policy))
    defer { harness.stop() }

    await harness.load("/unload", expecting: "Unload")
    await harness.run("document.body.click()")

    harness.applet.reload()

    await harness.host.until("the reload ends") {
      !harness.tab.isLoading && timer.armed.isEmpty
    }

    XCTAssertNil(harness.applet.content.dialogView.shown)
    XCTAssertEqual(harness.tab.generation, 0)
    XCTAssertEqual(harness.count("GET", "/unload"), 2)
  }

  /// Catches a held page dialog that the bound runs over. The process waits for the user inside the
  /// dialog, so the reload never gets an answer, and the bound still must not replace the page.
  func testTheBoundNeverRunsWhileAPageDialogIsHeld() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(services: .testing(hang: timer.policy))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let view = harness.tab.webView
    let result = Task { @MainActor in _ = try? await view.evaluateJavaScript("confirm('x')") }

    await harness.host.until("the dialog shows") {
      harness.applet.content.dialogView.shown != nil
    }

    harness.applet.reload()
    timer.fire()

    XCTAssertEqual(harness.tab.generation, 0, "the bound replaced a page that waits for the user")
    XCTAssertNotNil(harness.applet.content.dialogView.shown)

    harness.applet.content.dialogView.accept()
    await result.value
  }

  /// Catches a busy page that loses input silently. A hung view that holds unsent input is
  /// replaced only when the user says so, in a question that names the tab. A no keeps the view
  /// and the input.
  func testAHungPageWithUnsentInputIsReplacedOnlyOnYes() async throws {
    for answer in [false, true] {
      let timer = ManualHangTimer()
      let harness = try await make(services: .testing(hang: timer.policy))
      defer { harness.stop() }

      await harness.load("/input", expecting: "Input")
      await harness.run("var e = document.getElementById('a'); e.focus(); e.select();")

      (harness.tab.webView as? any NSTextInputClient)?.insertText(
        "typed", replacementRange: NSRange(location: NSNotFound, length: 0))
      await harness.host.until("the tab holds unsent input") { harness.tab.hasUnsentInput }

      let content = try XCTUnwrap(WebContent.record(of: harness.tab.webView))

      defer { WebContent.end(content) }

      harness.host.recording.holdsQuestions = true
      hang(harness.tab.webView)
      harness.applet.reload()
      timer.fire()

      await harness.eventually("the question is asked") {
        harness.host.recording.confirmations.count == 1
      }

      let question = try XCTUnwrap(harness.host.recording.confirmations.first)

      XCTAssertTrue(question.detail.contains("Input"), question.detail)
      XCTAssertEqual(harness.tab.generation, 0, "replaced before the user answered")

      harness.host.recording.pendingAnswer?.resume(returning: answer)
      harness.host.recording.pendingAnswer = nil

      if answer {
        await harness.eventually("the page is replaced") {
          harness.tab.generation == 1 && harness.tab.currentURL?.path == "/input"
            && !harness.tab.isLoading
        }
      } else {
        await harness.eventually("the answer is heard") { !harness.tab.isAskingToReplace }

        XCTAssertEqual(harness.tab.generation, 0)
        XCTAssertTrue(harness.tab.hasUnsentInput)
      }
    }
  }

  /// Catches two questions stacked on one pane. The host queues a second sheet behind the first, so
  /// the later question would appear for a tab that has closed meanwhile, and answering it does
  /// nothing. A question that finds another up is refused, and the first stays the only one.
  func testAQuestionThatFindsAnotherUpIsRefusedAndNeverQueued() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(services: .testing(hang: timer.policy))
    defer { harness.stop() }

    await harness.load("/input", expecting: "Input")
    await harness.run("var e = document.getElementById('a'); e.focus(); e.select();")

    (harness.tab.webView as? any NSTextInputClient)?.insertText(
      "typed", replacementRange: NSRange(location: NSNotFound, length: 0))
    await harness.host.until("the tab holds unsent input") { harness.tab.hasUnsentInput }

    let content = try XCTUnwrap(WebContent.record(of: harness.tab.webView))

    defer { WebContent.end(content) }

    harness.applet.openTab()
    harness.applet.selectTab(at: 0)
    harness.host.recording.holdsQuestions = true

    let closing = Task { @MainActor in await harness.applet.closeTab(at: 0) }

    await harness.eventually("the close question is asked") {
      harness.host.recording.confirmations.count == 1
    }

    hang(harness.tab.webView)
    harness.applet.reload()
    timer.fire()

    await harness.eventually("the second question is settled") {
      harness.host.recording.confirmations.count == 2 || !harness.tab.isAskingToReplace
    }

    guard harness.host.recording.confirmations.count == 1 else {
      XCTFail("a second question was queued")
      harness.host.recording.pendingAnswer?.resume(returning: false)
      return
    }

    harness.host.recording.pendingAnswer?.resume(returning: false)
    harness.host.recording.pendingAnswer = nil

    let result = await closing.value

    XCTAssertEqual(result, .declined)
  }

  /// Catches a bound that wakes a tab nobody looks at. A reload, then a switch to another tab,
  /// then the bound: the hung view goes, the tab is not yet loaded, and nothing is requested until
  /// it is selected.
  func testTheBoundOnATabThatLostTheSelectionDropsTheViewAndLoadsNothing() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(services: .testing(hang: timer.policy))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let tab = harness.tab
    let content = try XCTUnwrap(WebContent.record(of: tab.webView))

    defer { WebContent.end(content) }

    hang(tab.webView)
    harness.applet.reload()
    harness.applet.openTab()
    timer.fire()

    XCTAssertEqual(tab.generation, 1)
    XCTAssertFalse(tab.isMaterialized)
    XCTAssertFalse(tab.isStopped)
    XCTAssertEqual(harness.count("GET", "/a"), 1)

    harness.applet.selectTab(at: 0)

    await harness.host.until("the tab loads when selected") {
      tab.currentURL?.path == "/a" && !tab.isLoading
    }
  }

  /// Catches a callback from a view the tab already replaced. The old view has no delegates, and a
  /// second stop it reports is ignored, so it cannot replace the new view or its state.
  func testTheOldViewReachesNothingOfTheTabAfterARebuild() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let old = harness.tab.webView

    await WebContent.crash(old, in: harness)
    await harness.eventually("the tab stopped") { harness.tab.isStopped }

    XCTAssertNil(old.navigationDelegate)
    XCTAssertNil(old.uiDelegate)

    harness.tab.webViewWebContentProcessDidTerminate(old)

    XCTAssertEqual(harness.tab.generation, 1)
    XCTAssertTrue(harness.tab.isStopped)
  }

  /// Catches a stop that erases the history it should keep. A stopped tab loads a typed address
  /// that has not committed, and its view stops again. The history of the page before the first
  /// stop is still the record.
  func testAStopBeforeAnyCommitKeepsTheHistoryOfTheLastLivePage() async throws {
    let stall = FixtureServer.Hold()
    let harness = try await make(slow: stall)
    defer {
      stall.release()
      harness.stop()
    }

    await harness.load("/slow", expecting: "Slow")
    await harness.load("/b", expecting: "B")

    let record = try XCTUnwrap(harness.tab.interactionData)

    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the tab stopped") { harness.tab.isStopped }

    harness.applet.submit(address: harness.server.url("/slow").absoluteString)
    harness.tab.webViewWebContentProcessDidTerminate(harness.tab.webView)

    XCTAssertEqual(harness.tab.interactionData, record)
  }

  /// Catches a stopped form result that promises a page and shows none. The message says the page
  /// came from a form and that Reload restores it blank. After Reload the pane says that the form
  /// was not sent again, the history is back, and the server saw one post.
  func testAStoppedFormResultSaysWhatReloadWillShowAndWhatItDid() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.postResult()
    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the tab stopped") { harness.tab.isStopped }

    let page = harness.applet.content.errorPage

    XCTAssertTrue(page.detailLabel.stringValue.contains("came from a form"))
    XCTAssertTrue(page.detailLabel.stringValue.contains("blank"))

    harness.applet.reload()
    await harness.eventually("the form note shows") {
      page.titleLabel.stringValue == "This page came from a form" && !page.isHidden
    }
    await harness.load("/barrier", expecting: "BARRIER")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
    XCTAssertTrue(page.isHidden, "the next load clears the note")
  }

  // MARK: No recovery sends a form

  /// Catches a recovery that sends the form again. Reload after a stop restores the history, and
  /// the gate refuses the repeated post with a notice. Even a host that would answer yes is never
  /// asked.
  func testReloadAfterAStopNeverResendsAPost() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.host.recording.answer = true

    await harness.postResult()
    await WebContent.crash(harness.tab.webView, in: harness)
    await harness.eventually("the tab stopped") { harness.tab.isStopped }

    harness.applet.reload()
    await harness.eventually("the page is rebuilt") { !harness.tab.isStopped }
    await harness.load("/barrier", expecting: "BARRIER")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
  }

  /// Catches a hang recovery that sends the form again. The reload that ran into the hang never
  /// reached the process, and the new web view's restore is refused like any other repeat.
  func testAHangRecoveryNeverResendsAPost() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(services: .testing(hang: timer.policy))
    defer { harness.stop() }

    harness.host.recording.answer = true

    await harness.postResult()

    let content = try XCTUnwrap(WebContent.record(of: harness.tab.webView))

    defer { WebContent.end(content) }

    hang(harness.tab.webView)
    harness.applet.reload()
    timer.fire()

    await harness.eventually("the web view is replaced") { harness.tab.generation == 1 }
    await harness.load("/barrier", expecting: "BARRIER")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
  }
}
