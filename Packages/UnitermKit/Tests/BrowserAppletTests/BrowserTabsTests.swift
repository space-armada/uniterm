import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// Tabs in one pane: opening, switching, closing, reopening, and what each tab's page, address, and
/// buttons show. A real web view loads from a local fixture server.
@MainActor
final class BrowserTabsTests: XCTestCase {
  /// Each path serves a page titled with its name in capitals, so `/a` is "A".
  private nonisolated static func titled() -> FixtureServer.Handler {
    { request in
      switch (request.method, request.path) {
      case ("GET", "/form"):
        return Pages.page("Form", "<form method=post action=/result><input name=a value=1></form>")

      case ("POST", "/result"):
        return Pages.page("Posted")

      default:
        return Pages.page(String(request.path.dropFirst()).uppercased())
      }
    }
  }

  private func harness() async throws -> BrowserHarness {
    try await BrowserHarness.make(handler: Self.titled())
  }

  private func titles(_ harness: BrowserHarness) -> [String] {
    let tabs = harness.applet.publishedTabs

    return ([tabs.first] + tabs.rest).map(\.title)
  }

  /// Catches the tab-opening capability that scripts use. It must return the new tab's own ID, so
  /// a script's reference names that tab, and a browser must say its tabs have no directory, so a
  /// directory a script names is refused instead of dropped.
  func testTheTabOpeningCapabilityReturnsTheNewTabAndSaysTabsHaveNoDirectory() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    let opener: any TabOpening = harness.applet

    XCTAssertTrue(opener.canOpenTab)
    XCTAssertFalse(opener.tabsStartInDirectory)

    let id = try XCTUnwrap(opener.openTab(startingIn: nil))

    XCTAssertEqual(harness.applet.publishedTabs.selected, id)
    XCTAssertEqual(harness.applet.publishedTabs.all.count, 2)
  }

  /// Catches a tab bar that shows for one tab, or that leaves a gap above the toolbar while hidden.
  /// The bar appears with the second tab, takes its height, and gives it back when the second tab
  /// closes.
  func testTheTabBarShowsOnlyWhileThereIsMoreThanOneTab() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    let content = harness.applet.content
    content.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    content.layoutSubtreeIfNeeded()

    XCTAssertTrue(content.tabBar.isHidden)
    XCTAssertEqual(content.tabBar.frame.height, 0)

    harness.applet.openTab()
    content.layoutSubtreeIfNeeded()

    XCTAssertFalse(content.tabBar.isHidden)
    XCTAssertEqual(content.tabBar.frame.height, AppletTabBar.height)

    let result = await harness.applet.closeCurrentTab()
    content.layoutSubtreeIfNeeded()

    XCTAssertEqual(result, .closed)
    XCTAssertTrue(content.tabBar.isHidden)
    XCTAssertEqual(content.tabBar.frame.height, 0)
  }

  /// Catches a toolbar, address bar, title, or palette list that follows the wrong tab. Tab 1 holds
  /// two pages and tab 2 is blank. Each shows its own address and its own Back state, the pane's
  /// title follows the selection, and the palette list holds both tabs with the selected one marked.
  func testTheToolbarAndTitleFollowTheSelectedTab() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")

    let first = harness.applet.tab.id

    harness.applet.openTab()
    let second = harness.applet.tab.id

    XCTAssertNotEqual(first, second)
    XCTAssertEqual(harness.applet.selectedTabIndex, 1)
    XCTAssertEqual(harness.applet.content.addressField.stringValue, "")
    XCTAssertFalse(harness.applet.content.backButton.isEnabled)
    XCTAssertEqual(harness.applet.publishedTabs.selected, second)
    XCTAssertEqual(titles(harness), ["B", "Browser"])

    XCTAssertTrue(harness.applet.selectTab(id: first))

    XCTAssertEqual(harness.applet.title, "B")
    XCTAssertEqual(
      harness.applet.content.addressField.stringValue, harness.server.url("/b").absoluteString)
    XCTAssertTrue(harness.applet.content.backButton.isEnabled)
    XCTAssertEqual(harness.applet.publishedTabs.selected, first)
    XCTAssertFalse(harness.applet.selectTab(id: AppletTabID(epoch: 0, serial: 0)))
  }

  /// Catches an observer dropped by a switch. Tab 1 loads a page while tab 2 is selected. Its title
  /// reaches the palette list, and neither the pane's title nor the address bar changes. Switching
  /// back shows the page it loaded.
  func testABackgroundTabKeepsReportingWhileAnotherTabIsSelected() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    harness.applet.openTab()

    let background = harness.applet.tabs[0]

    await harness.load("/b", expecting: "B")
    background.load(harness.server.url("/a"))

    await harness.host.until("the background title reaches the palette list") {
      harness.applet.publishedTabs.first.title == "A"
    }

    XCTAssertEqual(harness.applet.title, "B")
    XCTAssertEqual(
      harness.applet.content.addressField.stringValue, harness.server.url("/b").absoluteString)

    harness.applet.selectTab(at: 0)

    XCTAssertEqual(harness.applet.title, "A")
    XCTAssertEqual(
      harness.applet.content.addressField.stringValue, harness.server.url("/a").absoluteString)
  }

  /// Catches a switch that leaves the typed text of the tab the user left in the address bar.
  func testSwitchingTabsDropsTheEditInTheAddressBar() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    harness.applet.openTab()

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.contentView = harness.applet.view
    defer { window.orderOut(nil) }

    harness.applet.content.focusAddress()
    harness.applet.content.addressField.stringValue = "typed text"

    harness.applet.selectTab(at: 0)

    XCTAssertEqual(
      harness.applet.content.addressField.stringValue, harness.server.url("/a").absoluteString)
  }

  /// Catches a closed tab whose web view or tab object lives on. Closing a tab drops its observers
  /// and delegates, and nothing of it is left but inert data in the closed list.
  func testClosingATabReleasesItsWebViewAndItself() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    harness.applet.openTab()
    await harness.load("/b", expecting: "B")

    weak var tab: BrowserTab?
    weak var webView: WKWebView?

    do {
      let opened = harness.applet.tab
      tab = opened
      webView = opened.webView
    }

    let result = await harness.applet.closeCurrentTab()

    XCTAssertEqual(result, .closed)
    XCTAssertNil(tab)

    var turns = 0

    while webView != nil, turns < 1000 {
      await Task.yield()
      turns += 1
    }

    XCTAssertNil(webView, "the closed tab's web view is still alive")
    XCTAssertEqual(harness.applet.tabCount, 1)
  }

  /// Catches Cmd-W on the last tab closing it. The applet has no tab to close, so the host closes
  /// the pane.
  func testTheLastTabIsLeftToThePane() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    let result = await harness.applet.closeCurrentTab()

    XCTAssertEqual(result, .nothingToClose)
    XCTAssertEqual(harness.applet.tabCount, 1)
    XCTAssertTrue(harness.applet.closedTabStamps.isEmpty)
  }

  /// Catches a reopen that loses the tab's place or its history. Tab 2 of three holds two pages. It
  /// closes, then reopens at index 1 and selected, and Back goes to the first page.
  func testReopeningATabRestoresItsPlaceAndItsHistory() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    harness.applet.openTab()
    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")
    harness.applet.openTab()
    harness.applet.selectTab(at: 1)

    let result = await harness.applet.closeCurrentTab()

    XCTAssertEqual(result, .closed)
    XCTAssertEqual(harness.applet.tabCount, 2)
    XCTAssertEqual(harness.applet.closedTabStamps.count, 1)

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.first)

    XCTAssertEqual(harness.applet.reopenTab(stamp: stamp), .reopened(title: "B"))
    XCTAssertEqual(harness.applet.selectedTabIndex, 1)
    XCTAssertEqual(harness.applet.tabCount, 3)
    XCTAssertTrue(harness.applet.closedTabStamps.isEmpty)

    await harness.host.until("the history comes back") {
      harness.applet.title == "B" && harness.applet.canGoBack && !harness.tab.isLoading
    }

    harness.applet.goBack()
    await harness.host.until("Back reaches the first page") {
      harness.applet.title == "A" && !harness.tab.isLoading
    }

    XCTAssertEqual(harness.applet.reopenTab(stamp: stamp), .missing)
  }

  /// Catches a closed list that grows past 20, or drops the newest instead of the oldest.
  func testAPaneKeepsAtMostTwentyClosedTabsAndDropsTheOldest() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    var stamps: [UInt64] = []

    for _ in 0..<22 {
      harness.applet.openTab()

      let result = await harness.applet.closeCurrentTab()

      XCTAssertEqual(result, .closed)
      stamps.append(harness.host.recording.lastStamp)
    }

    XCTAssertEqual(harness.applet.closedTabStamps.count, 20)
    XCTAssertEqual(harness.applet.closedTabStamps, Array(stamps.suffix(20).reversed()))
  }

  /// Catches closed tabs in the layout file, or lost with the pane. They ride in the undo-only part
  /// with each tab's history record. A pane rebuilt from that description holds them, and the same
  /// description without the undo-only part holds none.
  func testClosedTabsRideInTheUndoPartAndNeverInTheLayout() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    harness.applet.openTab()
    await harness.load("/b", expecting: "B")

    _ = await harness.applet.closeCurrentTab()

    let described = harness.applet.describe()
    let state = try XCTUnwrap(
      described.undoState?.decoded(as: BrowserDescription.UndoState.self))

    XCTAssertEqual(state.closedTabs.count, 1)
    XCTAssertEqual(state.closedTabs.first?.title, "B")
    XCTAssertNotNil(state.closedTabs.first?.interactionState)
    XCTAssertNil(described.withoutUndoState.undoState)

    let payload = try described.payload.decoded(as: BrowserDescription.self)

    XCTAssertEqual(payload.tabs.count, 1)

    let rebuilt = try BrowserApplet(
      restoring: described, dataStore: .nonPersistent(), services: .testing())
    defer { rebuilt.close() }

    XCTAssertEqual(rebuilt.closedTabStamps, harness.applet.closedTabStamps)

    let bare = try BrowserApplet(
      restoring: described.withoutUndoState, dataStore: .nonPersistent(), services: .testing())
    defer { bare.close() }

    XCTAssertTrue(bare.closedTabStamps.isEmpty)
  }

  /// Catches a description that drops tabs or the selection, and a restore that loads every tab at
  /// once. Three tabs restore with the second selected. Only the selected tab asks the server at
  /// start, and the others ask when first selected.
  func testRestoreLoadsTheSelectedTabAndTheOthersWhenFirstSelected() async throws {
    let server = try await FixtureServer.start(handler: Self.titled())
    defer { server.stop() }

    let records = ["/a", "/b", "/c"].map {
      BrowserDescription.Tab(url: server.url($0).absoluteString, title: String($0.dropFirst()))
    }
    let description = AppletDescription(
      type: BrowserDescription.typeID, version: BrowserDescription.currentVersion,
      payload: try JSONValue(encoding: BrowserDescription(tabs: records, selected: 1)))

    let applet = try BrowserApplet(
      restoring: description, dataStore: .nonPersistent(), services: .testing())
    let harness = BrowserHarness(server: server, applet: applet)
    defer { harness.stop() }

    XCTAssertEqual(applet.tabCount, 3)
    XCTAssertEqual(applet.selectedTabIndex, 1)

    await harness.host.until("the selected tab loads") {
      applet.title == "B" && !applet.tab.isLoading
    }

    XCTAssertEqual(harness.count("GET", "/a"), 0)
    XCTAssertEqual(harness.count("GET", "/b"), 1)
    XCTAssertEqual(harness.count("GET", "/c"), 0)
    XCTAssertEqual(titles(harness), ["a", "B", "c"])

    applet.selectTab(at: 2)
    await harness.host.until("the third tab loads") {
      applet.title == "C" && !applet.tab.isLoading
    }

    XCTAssertEqual(harness.count("GET", "/c"), 1)
    XCTAssertEqual(harness.count("GET", "/a"), 0)

    let described = try applet.describe().payload.decoded(as: BrowserDescription.self)

    XCTAssertEqual(described.selected, 2)
    XCTAssertEqual(described.tabs.map(\.title), ["a", "B", "C"])
  }

  /// Catches Back and Forward missing from the mouse. Button numbers 3 and 4 are the mouse's
  /// buttons 4 and 5. The test calls the web view's handler with real events, since a trackpad
  /// swipe and a physical mouse need hardware.
  func testTheMouseBackAndForwardButtonsStepThroughHistory() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")

    let web = try XCTUnwrap(harness.tab.webView as? BrowserWebView)

    web.otherMouseUp(with: try mouseEvent(button: 3))
    await harness.host.until("the back button steps back") {
      harness.applet.title == "A" && !harness.tab.isLoading
    }

    web.otherMouseUp(with: try mouseEvent(button: 4))
    await harness.host.until("the forward button steps forward") {
      harness.applet.title == "B" && !harness.tab.isLoading
    }

    XCTAssertNil(BrowserWebView.historyButton(forButtonNumber: 2))
    XCTAssertEqual(BrowserWebView.historyButton(forButtonNumber: 3), .back)
    XCTAssertEqual(BrowserWebView.historyButton(forButtonNumber: 4), .forward)
    XCTAssertTrue(web.allowsBackForwardNavigationGestures)
  }

  private func mouseEvent(button: Int) throws -> NSEvent {
    let raw = try XCTUnwrap(CGMouseButton(rawValue: UInt32(button)))
    let cgEvent = try XCTUnwrap(
      CGEvent(
        mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero,
        mouseButton: raw))

    cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))

    return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
  }

  /// Catches a reopened tab that sends a form again. The tab closes on the result of a post, and the
  /// reopened tab never posts again, whichever way WebKit restores the page.
  func testReopeningATabOnAFormPostResultNeverSendsTheFormAgain() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    harness.applet.openTab()
    await harness.load("/form", expecting: "Form")
    await harness.run("document.forms[0].submit()")
    await harness.host.until("the post result shows") {
      harness.applet.title == "Posted" && !harness.tab.isLoading
    }

    XCTAssertEqual(harness.count("POST", "/result"), 1)

    _ = await harness.applet.closeCurrentTab()
    harness.host.recording.forgetSent()

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.first)

    XCTAssertEqual(harness.applet.reopenTab(stamp: stamp), .reopened(title: "Posted"))

    await harness.host.until("the reopened tab settles") {
      !harness.tab.isLoading && (!harness.posts.isEmpty || harness.applet.title == "Posted")
    }

    await harness.load("/barrier", expecting: "BARRIER")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
  }

  /// Catches going back through reopened history onto a post result sending the form or asking. The
  /// tab never saw the post, so the step is refused with a warning and no question.
  func testGoingBackThroughReopenedHistoryOntoAPostNeverResendsOrAsks() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    harness.applet.openTab()
    await harness.load("/form", expecting: "Form")
    await harness.run("document.forms[0].submit()")
    await harness.host.until("the post result shows") {
      harness.applet.title == "Posted" && !harness.tab.isLoading
    }

    await harness.load("/after", expecting: "AFTER")

    _ = await harness.applet.closeCurrentTab()

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.first)

    XCTAssertEqual(harness.applet.reopenTab(stamp: stamp), .reopened(title: "AFTER"))
    await harness.host.until("the reopened page shows") {
      harness.applet.title == "AFTER" && harness.applet.canGoBack && !harness.tab.isLoading
    }

    harness.host.recording.answer = true
    harness.applet.goBack()
    await harness.host.until("the refusal is reported") { !harness.posts.isEmpty }

    XCTAssertTrue(harness.posts.first?.text.contains("send the form again") ?? false)
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)

    await harness.load("/barrier", expecting: "BARRIER")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
  }

  /// Catches an unseen restored post inheriting a yes from a seen post to the same address. The tab
  /// reopens on a post to `/result` it never saw, then posts to `/result` itself. Back twice lands
  /// on the unseen entry. It is refused with a warning and no question, though the seen post shares
  /// its address.
  func testAnUnseenPostCannotBorrowTheAnswerForASeenPostToTheSameAddress() async throws {
    let harness = try await harness()
    defer { harness.stop() }

    harness.applet.openTab()
    await harness.load("/form", expecting: "Form")
    await harness.run("document.forms[0].submit()")
    await harness.host.until("the post result shows") {
      harness.applet.title == "Posted" && !harness.tab.isLoading
    }

    _ = await harness.applet.closeCurrentTab()

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.first)

    XCTAssertEqual(harness.applet.reopenTab(stamp: stamp), .reopened(title: "Posted"))
    await harness.host.until("the reopened tab settles") {
      !harness.tab.isLoading && !harness.posts.isEmpty
    }

    await harness.load("/form", expecting: "Form")
    await harness.run("document.forms[0].submit()")
    await harness.host.until("the second post shows") {
      harness.applet.title == "Posted" && !harness.tab.isLoading
    }

    XCTAssertEqual(harness.count("POST", "/result"), 2)

    harness.host.recording.answer = true
    harness.host.recording.forgetSent()
    harness.applet.goBack()
    await harness.host.until("the form shows again") {
      harness.applet.title == "Form" && !harness.tab.isLoading
    }

    harness.applet.goBack()
    await harness.host.until("the refusal is reported") { !harness.posts.isEmpty }

    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
    XCTAssertEqual(harness.count("POST", "/result"), 2)
  }
}
