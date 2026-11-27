import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import XCTest

@testable import BrowserApplet

/// What a restored pane loads, and when. A restore loads only the selected tab. A refused stored
/// address explains itself in the pane and keeps its text.
@MainActor
final class BrowserLazyRestoreTests: XCTestCase {
  private nonisolated static func titled() -> FixtureServer.Handler {
    { request in Pages.page(String(request.path.dropFirst()).uppercased()) }
  }

  private func restore(
    _ records: [BrowserDescription.Tab], selected: Int = 0
  ) throws -> BrowserApplet {
    let description = AppletDescription(
      type: BrowserDescription.typeID, version: BrowserDescription.currentVersion,
      payload: try JSONValue(encoding: BrowserDescription(tabs: records, selected: selected)))

    return try BrowserApplet(
      restoring: description, dataStore: .nonPersistent(), services: .testing())
  }

  private func records(_ server: FixtureServer, _ paths: [String]) -> [BrowserDescription.Tab] {
    paths.map {
      BrowserDescription.Tab(url: server.url($0).absoluteString, title: String($0.dropFirst()))
    }
  }

  /// Catches a refused stored address that leaves the pane blank and silent. The pane shows an
  /// explanation that names the address. The history gets one warning with no turn on the bar,
  /// since the pane already says it, and the description keeps the address through a save.
  func testARefusedStoredAddressExplainsItselfInThePaneAndKeepsItsText() throws {
    let applet = try restore([.init(url: "file:///etc/hosts", title: "Hosts")])
    let host = EventHost()
    applet.host = host
    defer { applet.close() }

    XCTAssertTrue(applet.content.errorPage.isHidden)

    applet.start(origin: .restore)

    let page = applet.content.errorPage

    XCTAssertFalse(page.isHidden, "the pane has no explanation")
    XCTAssertTrue(page.detailLabel.stringValue.contains("file:///etc/hosts"))
    XCTAssertTrue(page.actionButton.isHidden)

    XCTAssertEqual(host.recording.records.filter { $0.level == .warning }.count, 1)
    XCTAssertTrue(host.recording.posts.isEmpty, "the explanation also took a turn on the bar")

    let stored = try applet.describe().payload.decoded(as: BrowserDescription.self)

    XCTAssertEqual(stored.tabs, [.init(url: "file:///etc/hosts", title: "Hosts")])
  }

  /// Catches an explanation that outlives the user's own address, or a stored address dropped
  /// before the user navigates. A typed address clears the pane's explanation and replaces the
  /// stored address once the page commits.
  func testTheExplanationGoesAwayWhenTheUserNavigates() async throws {
    let server = try await FixtureServer.start(handler: Self.titled())
    defer { server.stop() }

    let applet = try restore([.init(url: "ftp://example.com/x", title: "Old")])
    let harness = BrowserHarness(server: server, applet: applet, starting: false)
    defer { harness.stop() }

    applet.start(origin: .restore)

    XCTAssertFalse(applet.content.errorPage.isHidden)

    applet.reload()

    XCTAssertFalse(applet.content.errorPage.isHidden, "Reload cleared a refused explanation")
    XCTAssertTrue(server.requests.isEmpty)

    await harness.load("/typed", expecting: "TYPED")

    XCTAssertTrue(applet.content.errorPage.isHidden)

    let stored = try applet.describe().payload.decoded(as: BrowserDescription.self)

    XCTAssertEqual(stored.tabs.first?.url, server.url("/typed").absoluteString)
  }

  /// Catches an explanation that follows the pane and not the tab. The refused tab explains
  /// itself. A tab selected from it shows its own page.
  func testTheExplanationBelongsToTheRefusedTab() async throws {
    let server = try await FixtureServer.start(handler: Self.titled())
    defer { server.stop() }

    var tabs = records(server, ["/ok"])
    tabs.insert(.init(url: "javascript:alert(1)", title: "Bad"), at: 0)

    let applet = try restore(tabs, selected: 0)
    let harness = BrowserHarness(server: server, applet: applet, starting: false)
    defer { harness.stop() }

    applet.start(origin: .restore)
    XCTAssertFalse(applet.content.errorPage.isHidden)

    applet.selectTab(at: 1)
    await harness.host.until("the second tab loads") {
      applet.title == "OK" && !applet.tab.isLoading
    }

    XCTAssertTrue(applet.content.errorPage.isHidden)

    applet.selectTab(at: 0)

    XCTAssertFalse(applet.content.errorPage.isHidden)
  }

  /// Catches a close that leaves the tab it selects unloaded, or loads it twice. The neighbour was
  /// restored and never looked at, so the close is its first selection, and it loads once.
  func testClosingATabLoadsTheNeighbourItSelectsOnce() async throws {
    let server = try await FixtureServer.start(handler: Self.titled())
    defer { server.stop() }

    let applet = try restore(records(server, ["/a", "/b", "/c"]), selected: 0)
    let harness = BrowserHarness(server: server, applet: applet, starting: false)
    defer { harness.stop() }

    applet.start(origin: .restore)
    await harness.host.until("the first tab loads") { applet.title == "A" && !applet.tab.isLoading }

    let closedResult = await applet.closeTab(at: 0)

    XCTAssertEqual(closedResult, .closed)

    await harness.host.until("the neighbour loads") { applet.title == "B" && !applet.tab.isLoading }

    XCTAssertEqual(server.requests.map(\.path), ["/a", "/b"])
  }

  /// Catches a refused tab that warns again each time it is selected. The first selection warned
  /// once, and a second visit adds nothing and keeps the explanation.
  func testReselectingARefusedTabAddsNoSecondWarning() async throws {
    let server = try await FixtureServer.start(handler: Self.titled())
    defer { server.stop() }

    var tabs = records(server, ["/ok"])
    tabs.insert(.init(url: "file:///etc/hosts", title: "Bad"), at: 0)

    let applet = try restore(tabs, selected: 0)
    let harness = BrowserHarness(server: server, applet: applet, starting: false)
    defer { harness.stop() }

    applet.start(origin: .restore)
    applet.selectTab(at: 1)
    applet.selectTab(at: 0)

    XCTAssertEqual(harness.host.recording.records.filter { $0.level == .warning }.count, 1)
    XCTAssertFalse(applet.content.errorPage.isHidden)
  }

  /// Catches an undo-only part from another shape that is applied to the wrong tabs. Records for
  /// two tabs do not fit a pane of one, so the tab loads fresh from its address with no history.
  func testRecordsThatDoNotFitTheTabsAreIgnoredAndTheTabLoadsFresh() async throws {
    let first = try await BrowserHarness.make(handler: Self.titled())
    defer { first.stop() }

    await first.load("/a", expecting: "A")
    await first.load("/b", expecting: "B")

    let described = first.applet.describe()
    let state = try XCTUnwrap(described.undoState?.value(as: BrowserDescription.UndoState.self))
    let record = try XCTUnwrap(state.tabStates.first ?? nil)

    first.applet.close()

    let skewed = AppletDescription(
      type: described.type, version: described.version, payload: described.payload,
      undoState: AppletUndoState(
        BrowserDescription.UndoState(closedTabs: [], tabStates: [record, record])))
    let rebuilt = try BrowserApplet(
      restoring: skewed, dataStore: .nonPersistent(), services: .testing())
    let second = BrowserHarness(server: first.server, applet: rebuilt, starting: false)
    defer { rebuilt.close() }

    rebuilt.start(origin: .restore)
    await second.host.until("the tab loads fresh") {
      rebuilt.title == "B" && !rebuilt.tab.isLoading
    }

    XCTAssertFalse(rebuilt.canGoBack, "records for another shape were applied")
  }

  /// Catches a refused address that reaches the pane as a stored layout wrote it. A bidirectional
  /// override, a line break, and a long run of combining marks never show.
  func testARefusedAddressIsCleanedBeforeItReachesThePane() throws {
    let hostile =
      "ftp://x/\u{202E}exe.txt\nsecond" + String(repeating: "\u{0301}", count: 5000)
    let applet = try restore([.init(url: hostile, title: "Bad")])
    let host = EventHost()
    applet.host = host
    defer { applet.close() }

    applet.start(origin: .restore)

    let detail = applet.content.errorPage.detailLabel.stringValue

    XCTAssertFalse(detail.contains("\u{202E}"))
    XCTAssertFalse(detail.contains("\n\n"))
    XCTAssertFalse(detail.contains("exe.txt\nsecond"))
    XCTAssertLessThan(detail.utf8.count, 1000)

    let recorded = host.recording.records.first?.text ?? ""

    XCTAssertFalse(recorded.contains("\u{202E}"))
    XCTAssertLessThan(recorded.utf8.count, 1000)
  }

  /// Catches a restore origin that outlives the restore load. The user's real click on a link in a
  /// restored tab is a user action, so its refusal takes a turn on the bar. Before the fix it
  /// arrived as the lesser unseen signal, as the restore's own notices do.
  func testARefusalAfterARealClickInARestoredTabReachesTheBar() async throws {
    let server = try await FixtureServer.start { request in
      Pages.page("Link", "<a id=l href=\"ftp://example.invalid/x\">x</a>")
    }
    defer { server.stop() }

    let applet = try restore([.init(url: server.url("/link").absoluteString, title: "Link")])
    let harness = BrowserHarness(server: server, applet: applet, starting: false)
    defer { harness.stop() }

    applet.start(origin: .restore)

    await harness.host.until("the restored page loads") {
      applet.title == "Link" && !applet.tab.isLoading
    }

    harness.tab.noteMouseUp()
    await harness.run("document.getElementById('l').click()")
    await harness.host.until("the refusal is delivered") {
      harness.posts.count + harness.host.recording.attentions.count == 1
    }

    XCTAssertEqual(harness.posts.count, 1, "the refusal never took a turn on the bar")
    XCTAssertTrue(harness.host.recording.attentions.isEmpty)
  }
}
