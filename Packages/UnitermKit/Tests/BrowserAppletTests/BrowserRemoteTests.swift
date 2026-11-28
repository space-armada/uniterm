import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// A controller's commands against a real browser and a local server, through shared dispatch.
///
/// The dispatcher is the same one a window uses, stepped by hand. These prove what the browser
/// owns: which tabs a grant owns, which addresses it refuses, and that each command ends where the
/// user's matching action does. They cannot prove how a window finds the caller's powers. The
/// window's and the script host's tests prove that.
@MainActor
final class BrowserRemoteTests: XCTestCase {
  private nonisolated static let pages: FixtureServer.Handler = { request in
    switch (request.method, request.path) {
    case ("GET", "/form"):
      return Pages.page("Form", "<form method=post action=/result><input name=a value=1></form>")

    case ("POST", "/result"):
      return Pages.page("Posted")

    case ("GET", "/file"):
      return FixtureServer.Response(
        status: 200,
        headers: [
          ("Content-Type", "application/octet-stream"),
          ("Content-Disposition", "attachment; filename=\"got.txt\""),
        ], body: Data("x".utf8))

    case ("GET", "/draft"):
      return Pages.page("Draft", "<input id=a value=draft>")

    default:
      return Pages.page(String(request.path.dropFirst()).uppercased())
    }
  }

  private let grant = AppletCaller(grant: "connection 1")
  private let other = AppletCaller(grant: "connection 2")
  private var turns: [@MainActor () -> Void] = []

  private lazy var dispatcher = ControlDispatcher { [weak self] body in self?.turns.append(body) }

  private func make(
    hosting: BrowserHarness.Hosting = .window, services: BrowserServices = .testing()
  ) async throws -> BrowserHarness {
    try await BrowserHarness.make(services: services, hosting: hosting, handler: Self.pages)
  }

  /// Sends one command and runs the queue. A tab given by `on` rides as the command's target.
  @discardableResult
  private func send(
    _ harness: BrowserHarness, _ name: String, _ arguments: [String: JSONValue] = [:],
    on tab: String? = nil, as caller: AppletCaller? = nil,
    holding powers: Set<AppletCommandPermission> = [.browserNavigation, .browserRead]
  ) -> Result<JSONValue, AppletCommandError> {
    var result: Result<JSONValue, AppletCommandError>?
    let identity = caller ?? grant

    dispatcher.submit(
      AppletCommandSubmission(
        appletType: BrowserApplet.descriptionTypeID, schemaVersion: AppletSchemaVersion(0, 0),
        name: name, arguments: .object(arguments)),
      to: harness.applet, authority: { nil },
      caller: { CommandCaller(identity: identity, permissions: powers) },
      tab: tab.flatMap(AppletTabID.init(reply:)), reply: { result = $0 })

    let bodies = turns
    turns = []
    for body in bodies { body() }

    return result ?? .failure(AppletCommandError(.failed, "no reply"))
  }

  private func url(_ harness: BrowserHarness, _ path: String) -> JSONValue {
    .string(harness.server.url(path).absoluteString)
  }

  /// Opens a tab and returns its reference and the tab.
  private func open(
    _ harness: BrowserHarness, _ path: String, address: String? = nil,
    as caller: AppletCaller? = nil
  ) throws -> (reference: String, tab: BrowserTab) {
    let argument = address.map { JSONValue.string($0) } ?? url(harness, path)
    let reply = try send(harness, "open", ["url": argument], as: caller).get()

    guard case .object(let fields) = reply, case .string(let reference)? = fields["tab"],
      let id = AppletTabID(reply: reference),
      let tab = harness.applet.tabs.first(where: { $0.id == id })
    else {
      XCTFail("open answered \(reply)")
      throw AppletCommandError(.failed, "open answered no tab")
    }

    return (reference, tab)
  }

  private func code(_ result: Result<JSONValue, AppletCommandError>) -> AppletCommandError.Code? {
    if case .failure(let error) = result { return error.code }

    return nil
  }

  // MARK: Opening

  /// Catches an open that does not select its tab, or that loads late. The tab shows, loads at once,
  /// and the reply names it.
  func testOpenLoadsTheTabAtOnceAndAnswersItsReference() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    XCTAssertEqual(harness.applet.tabs.count, 2)
    XCTAssertEqual(harness.applet.tab, opened, "the new tab is selected")
    XCTAssertEqual(opened.id.replyText, reference)

    await harness.host.until("the page loads") { opened.pageTitle == "A" }

    XCTAssertEqual(harness.count("GET", "/a"), 1)
  }

  /// Catches an open in a pane that holds the keyboard that leaves the new tab behind, or leaves
  /// the keyboard on the user's tab. The user's New Tab with a typed address selects the tab and
  /// puts the keyboard in its page.
  func testOpenInAKeyFocusedPaneSelectsTheTabAndTheKeyboardFollows() async throws {
    let harness = try await make(hosting: .focusedWindow)
    defer { harness.stop() }

    let users = harness.applet.tab
    let (_, opened) = try open(harness, "/a")

    XCTAssertTrue(harness.applet.tab === opened)
    XCTAssertEqual(harness.applet.tabs.firstIndex { $0 === users }, 0)
    XCTAssertEqual(harness.applet.tabs.firstIndex { $0 === opened }, 1, "after the selected tab")
    XCTAssertTrue(harness.window?.firstResponder === opened.webView)

    await harness.host.until("the tab loads") { opened.pageTitle == "A" }
  }

  /// Catches an open that ends anywhere but where the user's New Tab with a typed address does:
  /// the same place in the strip, the same selection, the keyboard in the same place, and the same
  /// address. The expected state is read from the user's own path run in a second pane.
  func testOpenEndsWhereTheUsersNewTabWithATypedAddressEnds() async throws {
    let commanded = try await make(hosting: .focusedWindow)
    defer { commanded.stop() }

    let typed = try await make(hosting: .focusedWindow)
    defer { typed.stop() }

    let (_, opened) = try open(commanded, "/a")

    typed.applet.openTab()
    typed.applet.submit(address: typed.server.url("/a").absoluteString)

    XCTAssertEqual(commanded.applet.tabs.count, typed.applet.tabs.count)
    XCTAssertEqual(commanded.applet.selectedTabIndex, typed.applet.selectedTabIndex)
    XCTAssertEqual(
      commanded.window?.firstResponder === opened.webView,
      typed.window?.firstResponder === typed.applet.tab.webView)
    XCTAssertEqual(opened.record.url?.suffix(2), typed.applet.tab.record.url?.suffix(2))
    XCTAssertEqual(opened.loadOrigin, typed.applet.tab.loadOrigin)
  }

  /// Catches an address that every source refuses opening a tab or loading from a command: script,
  /// data, local file, blob, and about addresses in any letter case and with whitespace, on open
  /// and on navigate. An address for another app is not among them, since typed input hands it off.
  func testScriptDataAndFileAddressesAreRefusedInAnyCaseWithWhitespace() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, _) = try open(harness, "/a")
    let count = harness.applet.tabs.count

    for bad in [
      "javascript:alert(1)", " JaVaScRiPt:alert(1) ", "\tJAVASCRIPT:void(0)\n",
      "data:text/html,<b>x</b>", "  DaTa:text/html,x  ", "file:///etc/hosts",
      " FILE:///etc/hosts\n",
      "\u{A0}file:///etc/hosts", "blob:https://example.com/1", " BLOB:https://example.com/1\n",
      "about:config", "ABOUT:CONFIG",
    ] {
      let opened = send(harness, "open", ["url": .string(bad)])
      let moved = send(harness, "navigate", ["url": .string(bad)], on: reference)

      XCTAssertEqual(code(opened), .badArgument, bad)
      XCTAssertEqual(code(moved), .badArgument, bad)
    }

    XCTAssertEqual(harness.applet.tabs.count, count, "a refused address opened a tab")
  }

  /// Catches a scheme-less address that loads over plain HTTP, or one that is refused. Loopback
  /// keeps HTTP, and the spy reads the HTTPS address without a request leaving the machine.
  func testASchemelessAddressGetsHTTPSAndLoopbackGetsHTTP() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a", address: harness.server.address("/a"))

    await harness.host.until("the loopback page loads") { opened.pageTitle == "A" }

    XCTAssertEqual(opened.record.url?.hasPrefix("http://127.0.0.1"), true)

    let spy = NavigationSpy()

    opened.webView.navigationDelegate = spy

    XCTAssertNil(code(send(harness, "navigate", ["url": .string("example.com/x")], on: reference)))
    await spy.until(count: 1)
    XCTAssertEqual(spy.urls.map(\.absoluteString), ["https://example.com/x"])
  }

  /// Catches a loop of opens that builds a web view and a content process for each call. A grant
  /// holds at most 16 tabs, the 17th is refused as busy before any effect, another grant is not
  /// held to the first one's count, and a tab the user closes frees a place.
  func testAGrantMayHoldOnlyAFixedNumberOfTabs() async throws {
    let harness = try await make()
    defer { harness.stop() }

    var last = ""

    for _ in 0..<BrowserApplet.controllerTabLimit { last = try open(harness, "/a").reference }

    let count = harness.applet.tabCount
    let served = harness.server.requests.count
    let refused = send(harness, "open", ["url": url(harness, "/b")])

    XCTAssertEqual(code(refused), .busy)
    XCTAssertEqual(harness.applet.tabCount, count, "a refused open built a tab")
    XCTAssertEqual(harness.count("GET", "/b"), 0)
    XCTAssertGreaterThanOrEqual(harness.server.requests.count, served)

    XCTAssertNil(code(send(harness, "open", ["url": url(harness, "/c")], as: other)))

    let closing = try XCTUnwrap(harness.applet.tabs.firstIndex { $0.id.replyText == last })

    _ = await harness.applet.closeTab(at: closing)

    XCTAssertNil(code(send(harness, "open", ["url": url(harness, "/d")])))
  }

  // MARK: Ownership

  /// Catches a command that acts on a tab its caller did not open: the user's own tab, and a tab
  /// another grant opened.
  func testACommandOnATabTheCallerDidNotOpenIsRefused() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let users = harness.applet.tab.id.replyText
    let (mine, _) = try open(harness, "/a")

    for name in ["reload", "back", "forward", "select", "read"] {
      XCTAssertEqual(code(send(harness, name, on: users)), .notOwned, name)
      XCTAssertEqual(code(send(harness, name, on: mine, as: other)), .notOwned, name)
    }

    XCTAssertEqual(
      code(send(harness, "navigate", ["url": url(harness, "/b")], on: users)), .notOwned)
    XCTAssertEqual(harness.count("GET", "/b"), 0)
  }

  /// Catches a tab that stops being the controller's once the user types in it. The controller
  /// still reads it. A move is not refused for the input, since the user's own typed address on
  /// that tab is not.
  func testATabStaysTheControllersAfterTheUserTypesInIt() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/draft")

    await harness.host.until("the draft page shows") { opened.pageTitle == "Draft" }

    await harness.host.until("input is marked") {
      Task { @MainActor in
        _ = try? await opened.webView.evaluateJavaScript(
          "var e = document.getElementById('a'); e.focus(); e.select()")
        (opened.webView as? any NSTextInputClient)?.insertText(
          "typed", replacementRange: NSRange(location: NSNotFound, length: 0))
      }

      return opened.hasUnsentInput
    }

    XCTAssertTrue(opened.hasUnsentInput)

    harness.applet.selectTab(at: 0)

    XCTAssertNil(code(send(harness, "read", on: reference)))
    XCTAssertNil(code(send(harness, "navigate", ["url": url(harness, "/b")], on: reference)))
    await harness.host.until("the tab moves on") { opened.pageTitle == "B" }
  }

  /// Catches a tab that is owned without the controller opening it: a tab a page opened from a
  /// controller tab, a tab reopened with Cmd-Shift-T, and a restored tab.
  func testPageOpenedReopenedAndRestoredTabsBelongToNoController() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    await harness.host.until("the page loads") { opened.pageTitle == "A" }

    _ = try? await opened.webView.evaluateJavaScript("window.open('/popup')")
    await harness.host.until("the popup opens") { harness.applet.tabs.count == 3 }

    let popup = try XCTUnwrap(harness.applet.tabs.first { $0.isPopup })

    XCTAssertNil(harness.applet.tabOwners[popup.id], "a page-opened tab was owned")

    let closing = harness.applet.tabs.firstIndex { $0 === opened }!
    _ = await harness.applet.closeTab(at: closing)

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.first)

    XCTAssertEqual(harness.applet.reopenTab(stamp: stamp), .reopened(title: "A"))
    XCTAssertEqual(harness.applet.tabOwners.count, 0, "a reopened tab was owned")
    XCTAssertEqual(code(send(harness, "read", on: reference)), .notFound)

    let restored = try BrowserApplet(
      restoring: harness.applet.describe(), dataStore: .nonPersistent(),
      services: .testing())

    XCTAssertEqual(restored.tabOwners.count, 0)
    restored.close()
  }

  /// Catches ownership that outlives its grant: a new generation of control, a grant that ended,
  /// and a closed tab each leave nothing owned.
  func testOwnershipEndsWithTheGrantTheGenerationAndTheTab() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (first, _) = try open(harness, "/a")

    harness.applet.controlDidChange(
      PaneControl(access: .remoteControlled, driver: .none, generation: 4))

    XCTAssertEqual(code(send(harness, "read", on: first)), .notOwned)

    let (second, _) = try open(harness, "/c")

    harness.applet.controlDidChange(
      PaneControl(access: .remoteControlled, driver: .none, generation: 4))

    XCTAssertNil(code(send(harness, "read", on: second)), "the same generation changes nothing")

    harness.applet.grantDidEnd(other)

    XCTAssertNil(code(send(harness, "read", on: second)), "another grant's end changes nothing")

    harness.applet.grantDidEnd(grant)

    XCTAssertEqual(code(send(harness, "read", on: second)), .notOwned)

    let (third, _) = try open(harness, "/b")
    let closing = try XCTUnwrap(harness.applet.tabs.firstIndex { $0.id.replyText == third })

    _ = await harness.applet.closeTab(at: closing)

    XCTAssertEqual(code(send(harness, "read", on: third)), .notFound)
    XCTAssertEqual(harness.applet.tabOwners.count, 0)
  }

  private func markers(_ harness: BrowserHarness) -> [Bool] {
    harness.applet.publishedTabs.all.map { $0.markers[.authority] != nil }
  }

  /// Catches an authority marker on the wrong browser tab. The host says the grant can act on the
  /// pane. The tab the grant opened carries the marker, and the user's own tab never does. The
  /// marker follows the grant, so it clears when the host drops the grant from the set, and when
  /// the grant ends, and each change tells the host on the same turn.
  func testOnlyTheTabTheGrantOpenedCarriesTheMarkerWhileTheGrantLives() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, _) = try open(harness, "/a")

    XCTAssertEqual(
      markers(harness), [false, false], "a grant the host has not accepted marked a tab")

    var changes = harness.host.recording.tabChanges

    harness.applet.authorityDidChange(PaneAuthority(owners: [grant]))

    XCTAssertEqual(markers(harness), [false, true])
    XCTAssertGreaterThan(harness.host.recording.tabChanges, changes)
    XCTAssertEqual(
      harness.applet.publishedTabs.all[1].markers[.authority]?.owners, [grant])

    harness.applet.authorityDidChange(PaneAuthority(owners: [other]))

    XCTAssertEqual(markers(harness), [false, false], "another grant's authority marked the tab")

    harness.applet.authorityDidChange(PaneAuthority(owners: [grant, other]))
    changes = harness.host.recording.tabChanges

    XCTAssertEqual(markers(harness), [false, true])

    harness.applet.grantDidEnd(grant)

    XCTAssertEqual(markers(harness), [false, false])
    XCTAssertGreaterThan(harness.host.recording.tabChanges, changes)
    XCTAssertEqual(code(send(harness, "read", on: reference)), .notOwned)
  }

  /// Catches an adopted first tab that is marked late, and a closed tab that stays marked. A tab
  /// adopted for the grant is marked on the same turn, a new control generation clears it, and a
  /// closed owned tab leaves the published list.
  func testAdoptionControlChangeAndCloseUpdateTheMarkerOnTheSameTurn() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.authorityDidChange(PaneAuthority(owners: [grant]))

    XCTAssertEqual(markers(harness), [false])

    harness.applet.adoptFirstTab(for: grant)

    XCTAssertEqual(markers(harness), [true])

    harness.applet.controlDidChange(
      PaneControl(access: .remoteControlled, driver: .none, generation: 9))

    XCTAssertEqual(markers(harness), [false])

    let (_, opened) = try open(harness, "/b")
    let index = try XCTUnwrap(harness.applet.tabs.firstIndex { $0 === opened })

    XCTAssertEqual(markers(harness), [false, true])

    _ = await harness.applet.closeTab(at: index)

    XCTAssertEqual(markers(harness), [false])
  }

  /// Catches a bar that shows a marked tab with no marker. The shared bar draws the marker the
  /// browser published, beside the title of the marked tab only.
  func testTheBarDrawsTheMarkerOfTheOwnedTabOnly() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.authorityDidChange(PaneAuthority(owners: [grant]))
    _ = try open(harness, "/a")

    let content = harness.applet.content
    content.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    content.layoutSubtreeIfNeeded()

    func ids(_ view: NSView) -> [String] {
      view.subviews.flatMap {
        ($0 as? AppletMarkerView).map { [$0.accessibilityIdentifier()] } ?? ids($0)
      }
    }

    XCTAssertEqual(ids(content.tabBar), ["tab-1-marker-authority"])
  }

  /// Catches a pane a layout created whose first tab is not its controller's, and one that keeps
  /// it for the wrong grant.
  func testTheFirstTabOfALayoutPaneBelongsToTheLayoutsCaller() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.adoptFirstTab(for: grant)

    let first = harness.applet.tab.id.replyText

    XCTAssertNil(code(send(harness, "read", on: first)))
    XCTAssertEqual(code(send(harness, "read", on: first, as: other)), .notOwned)
  }

  // MARK: Powers

  /// Catches a browser power that unlocks the other's commands, and a command that runs without
  /// its power.
  func testEachBrowserPowerUnlocksOnlyItsOwnCommands() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, _) = try open(harness, "/a")

    XCTAssertEqual(
      code(send(harness, "open", ["url": url(harness, "/x")], holding: [.browserRead])),
      .permissionMissing)
    XCTAssertEqual(
      code(send(harness, "read", on: reference, holding: [.browserNavigation])),
      .permissionMissing)
    XCTAssertEqual(code(send(harness, "reload", on: reference, holding: [])), .permissionMissing)
    XCTAssertEqual(harness.count("GET", "/x"), 0)
    XCTAssertEqual(harness.applet.tabs.count, 2)
  }

  // MARK: Moves

  /// Catches a navigate, reload, back, or forward that does not act on the controller's tab, and
  /// a reply that does not carry what the page shows.
  func testNavigateReloadBackAndForwardMoveTheControllersTab() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    await harness.host.until("a loads") { opened.pageTitle == "A" }

    XCTAssertNil(code(send(harness, "navigate", ["url": url(harness, "/b")], on: reference)))
    await harness.host.until("b loads") { opened.pageTitle == "B" && !opened.isLoading }

    XCTAssertNil(code(send(harness, "back", on: reference)))
    await harness.host.until("back shows a") { opened.pageTitle == "A" && !opened.isLoading }

    XCTAssertNil(code(send(harness, "forward", on: reference)))
    await harness.host.until("forward shows b") { opened.pageTitle == "B" && !opened.isLoading }

    let served = harness.count("GET", "/b")

    XCTAssertNil(code(send(harness, "reload", on: reference)))
    await harness.eventually("the reload asks the server again") {
      harness.count("GET", "/b") == served + 1
    }

    guard case .success(.object(let read)) = send(harness, "read", on: reference) else {
      return XCTFail("read failed")
    }

    XCTAssertEqual(read["title"], .string("B"))
    XCTAssertEqual(read["url"], url(harness, "/b"))
  }

  /// Catches a back or forward with nowhere to go that answers as if it moved.
  func testHistoryWithNowhereToGoIsAFailureNotAMove() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    await harness.host.until("a loads") { opened.pageTitle == "A" }

    XCTAssertEqual(code(send(harness, "back", on: reference)), .failed)
    XCTAssertEqual(code(send(harness, "forward", on: reference)), .failed)
  }

  /// Catches a command refused because the pane holds the keyboard. Navigate on the tab shown, and
  /// select of another tab, run as the user's typed address and click do.
  func testAKeyFocusedPaneAcceptsMovesOnItsShownTabAndSelect() async throws {
    let harness = try await make(hosting: .focusedWindow)
    defer { harness.stop() }

    harness.applet.adoptFirstTab(for: grant)

    let shown = harness.applet.tab
    let (background, tab) = try open(harness, "/a")

    XCTAssertNil(code(send(harness, "select", on: shown.id.replyText)))
    XCTAssertTrue(harness.applet.tab === shown)

    XCTAssertNil(
      code(send(harness, "navigate", ["url": url(harness, "/b")], on: shown.id.replyText)))
    await harness.host.until("the shown tab moves") { shown.pageTitle == "B" }

    XCTAssertNil(code(send(harness, "reload", on: shown.id.replyText)))
    XCTAssertEqual(
      code(send(harness, "forward", on: shown.id.replyText)), .failed, "nothing is later")

    XCTAssertNil(code(send(harness, "select", on: background)))
    XCTAssertTrue(harness.applet.tab === tab)
  }

  /// Catches a select that behaves unlike the user's click on the tab. The tab shows, and the
  /// keyboard follows when the pane held it, as it does for the click.
  func testSelectShowsTheTabAsAClickDoes() async throws {
    let harness = try await make(hosting: .focusedWindow)
    defer { harness.stop() }

    let users = harness.applet.tab
    let (reference, opened) = try open(harness, "/a")

    await harness.host.until("the page loads") { opened.pageTitle == "A" }

    harness.applet.selectTab(at: 0)
    XCTAssertTrue(harness.applet.tab === users)

    XCTAssertNil(code(send(harness, "select", on: reference)))
    XCTAssertTrue(harness.applet.tab === opened)
    XCTAssertTrue(harness.window?.firstResponder === opened.webView)
  }

  /// Catches a navigate that treats search text, or an address for another app, as a refusal. It
  /// resolves as typed input does: text searches with the engine, `mailto:` opens at once, and any
  /// other app asks first.
  func testNavigateResolvesSearchAndAppAddressesAsTypedInputDoes() async throws {
    let opener = FakeOpener()
    let harness = try await make(services: .testing(opener: opener))
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    await harness.host.until("the page loads") { opened.pageTitle == "A" }

    let spy = NavigationSpy()

    opened.webView.navigationDelegate = spy

    XCTAssertNil(
      code(send(harness, "navigate", ["url": .string("swift concurrency")], on: reference)))
    await spy.until(count: 1)
    XCTAssertEqual(
      spy.urls.map(\.absoluteString), ["https://duckduckgo.com/?q=swift%20concurrency"])

    let mail = URL(string: "mailto:someone@example.com")!

    XCTAssertNil(
      code(send(harness, "navigate", ["url": .string(mail.absoluteString)], on: reference)))
    XCTAssertEqual(opener.opened, [mail], "mailto: opens without asking")
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)

    harness.host.recording.answer = true

    let ssh = URL(string: "ssh://host.example")!

    XCTAssertNil(
      code(send(harness, "navigate", ["url": .string(ssh.absoluteString)], on: reference)))
    await harness.host.until("the question is asked") {
      harness.host.recording.confirmations.count == 1
    }
    await harness.eventually("the app opens on yes") { opener.opened == [mail, ssh] }
  }

  /// Catches a layout seed that loads search text as an address, or one that opens another app
  /// without the user's question. A seed runs the typed-address path in the first tab.
  func testASeedOfSearchTextSearchesAndAnAppAddressAsks() async throws {
    let server = try await FixtureServer.start(handler: Self.pages)
    defer { server.stop() }

    let searching = BrowserApplet(
      dataStore: .nonPersistent(), services: .testing(), seed: "swift concurrency")
    let searchHarness = BrowserHarness(server: server, applet: searching, starting: false)
    let spy = NavigationSpy()

    searching.tab.webView.navigationDelegate = spy
    searching.start(origin: .user)
    await spy.until(count: 1)

    XCTAssertEqual(
      spy.urls.map(\.absoluteString), ["https://duckduckgo.com/?q=swift%20concurrency"])
    searchHarness.stop()

    let opener = FakeOpener()
    let asking = BrowserApplet(
      dataStore: .nonPersistent(), services: .testing(opener: opener), seed: "ssh://host.example")
    let askHarness = BrowserHarness(server: server, applet: asking, starting: false)

    defer { askHarness.stop() }

    askHarness.host.recording.answer = true
    asking.start(origin: .user)

    await askHarness.host.until("the question is asked") {
      askHarness.host.recording.confirmations.count == 1
    }
    await askHarness.eventually("the app opens on yes") {
      opener.opened == [URL(string: "ssh://host.example")!]
    }
  }

  /// Catches an app handoff from a tab that is not on screen. The user's own rule lets only the
  /// page on screen ask, so the controller's tab behind another one opens nothing.
  func testAnAppAddressInATabBehindAnotherOpensNothing() async throws {
    let opener = FakeOpener()
    let harness = try await make(services: .testing(opener: opener))
    defer { harness.stop() }

    let (reference, _) = try open(harness, "/a")

    harness.applet.selectTab(at: 0)

    let mail = "mailto:someone@example.com"

    XCTAssertNil(code(send(harness, "navigate", ["url": .string(mail)], on: reference)))
    XCTAssertEqual(opener.opened, [])
    XCTAssertTrue(harness.posts.last?.text.contains("Only the page you are looking at") ?? false)
  }

  // MARK: Forms

  /// Catches a reload of a form's result that sends the form again without asking, or that never
  /// asks. A command's reload asks the user as the tab's own reload does, and resends only on yes.
  func testAControllersReloadOfAFormAsksAsTheUsersDoes() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/form")

    await harness.host.until("the form shows") { opened.pageTitle == "Form" && !opened.isLoading }
    _ = try? await opened.webView.evaluateJavaScript("document.forms[0].submit()")
    await harness.host.until("the post result shows") {
      opened.pageTitle == "Posted" && !opened.isLoading
    }

    XCTAssertEqual(harness.count("POST", "/result"), 1)

    harness.host.recording.answer = false

    XCTAssertNil(code(send(harness, "reload", on: reference)))
    await harness.host.until("the reload asks") { harness.host.recording.confirmations.count == 1 }

    XCTAssertEqual(harness.count("POST", "/result"), 1, "a no still resent the form")

    harness.host.recording.answer = true

    XCTAssertNil(code(send(harness, "reload", on: reference)))
    await harness.host.until("the reload asks again") {
      harness.host.recording.confirmations.count == 2
    }
    await harness.eventually("a yes sends the form again") {
      harness.count("POST", "/result") == 2
    }
  }

  // MARK: Questions

  /// Catches a controller's tab that follows another rule for an app handoff than any tab does.
  /// `mailto:` opens a draft at once in the user's tab and in the controller's.
  func testAppHandoffInAControllerTabFollowsTheRulesOfAnyTab() async throws {
    let opener = FakeOpener()
    let harness = try await make(services: .testing(opener: opener))
    defer { harness.stop() }

    let mail = URL(string: "mailto:someone@example.com")!

    harness.applet.tab(harness.applet.tab, handOff: mail)
    XCTAssertEqual(opener.opened, [mail])

    let (_, owned) = try open(harness, "/a")

    harness.applet.tab(owned, handOff: mail)
    XCTAssertEqual(opener.opened, [mail, mail], "a controller's tab asked before a draft")
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
  }

  /// Catches a download that a command starts being held for a question. A navigate is a typed
  /// load, so its download starts at once, as the user's does.
  func testADownloadFromANavigateStartsAsATypedLoadsDoes() async throws {
    let harness = try await BrowserHarness.make(handler: Self.pages)
    defer { harness.stop() }

    let (reference, owned) = try open(harness, "/a")

    await harness.host.until("a loads") { owned.pageTitle == "A" }

    XCTAssertNil(code(send(harness, "navigate", ["url": url(harness, "/file")], on: reference)))
    await harness.eventually("the file arrives") { harness.files() == ["got.txt"] }

    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
  }

  // MARK: Seeds and programs

  /// Catches a seeded pane that loads nothing, or an unseeded one that requests a page.
  func testASeededPaneLoadsItsPageAtStartAndAnUnseededOneLoadsNothing() async throws {
    let server = try await FixtureServer.start(handler: Self.pages)
    defer { server.stop() }

    let seeded = BrowserApplet(
      dataStore: .nonPersistent(), services: .testing(), seed: server.url("/seed").absoluteString)
    let host = EventHost()

    seeded.host = host
    seeded.start(origin: .user)
    await host.until("the seed loads") { seeded.title == "SEED" }
    seeded.close()

    let blank = BrowserApplet(dataStore: .nonPersistent(), services: .testing())

    blank.start(origin: .user)
    XCTAssertNil(blank.tab.record.url)
    blank.close()

    XCTAssertEqual(server.requests.filter { $0.path == "/seed" }.count, 1)
  }

  /// Catches a generic tab open from a program that reaches the browser, and a user's New Tab that
  /// the program rule blocks.
  func testAProgramMayNotOpenATabThroughTheGenericOpen() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let refusal = try XCTUnwrap(harness.applet.programOpenRefusal)

    XCTAssertTrue(refusal.contains("open"), refusal)
    XCTAssertTrue(refusal.contains("browser-navigation"), refusal)
    XCTAssertNotNil(harness.applet.openTab(startingIn: nil), "the user's New Tab still works")
  }

  /// Catches a browser that takes an exec driver, or loses remote control.
  func testTheBrowserSupportsRemoteControlAndNoExecDriver() {
    XCTAssertEqual(
      BrowserApplet.typeDeclaration.controlSupport,
      [.disconnected, .remoteControlled])
    XCTAssertFalse(
      BrowserApplet.typeDeclaration.controlSupport.contains(
        ControlCombination(access: .remoteControlled, driver: .exec)))
    XCTAssertFalse(
      BrowserApplet.typeDeclaration.controlSupport.contains(
        ControlCombination(access: .disconnected, driver: .exec)))
  }

  /// Catches a command with no summary, an example that its own schema refuses, or a command that
  /// names no power. The schema is what a driver author reads.
  func testEveryCommandIsDescribedAndItsExampleFitsItsSchema() throws {
    let schema = BrowserApplet.remoteSchema

    XCTAssertEqual(
      schema.commands.map(\.name),
      ["open", "navigate", "reload", "back", "forward", "select", "read"])

    for command in schema.commands {
      XCTAssertFalse(command.summary.isEmpty, command.name)
      XCTAssertNotNil(command.permission, command.name)
      XCTAssertEqual(command.permission == .browserRead, command.name == "read", command.name)
      XCTAssertFalse(command.mayWait, command.name)

      guard case .object(let fields) = command.example else {
        return XCTFail("\(command.name) has no example object")
      }

      XCTAssertNoThrow(try command.arguments.validate(fields, at: command.name), command.name)
    }
  }
}
