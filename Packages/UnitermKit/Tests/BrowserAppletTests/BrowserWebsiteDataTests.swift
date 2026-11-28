import BrowserModel
import BrowserTestSupport
import WebKit
import XCTest

@testable import BrowserApplet

/// The browser's own website data store, shared by every pane and cleared as one. Real web views
/// load from a local server that sets and echoes a cookie. No test touches the user's store, and
/// none writes to WebKit's default one. A test reads the default store only to show it stays empty.
@MainActor
final class BrowserWebsiteDataTests: XCTestCase {
  private var identifiers: [UUID] = []

  /// Removes each store the test made. WebKit's network process keeps a store in use for a few
  /// dozen milliseconds after its last web view closes, and refuses a removal until then. So the
  /// removal is retried until a deadline.
  ///
  /// A store that is still in use at the deadline fails the test. Left behind, it stays on disk
  /// under the test runner's WebKit folder for good, and every run would add more.
  override func tearDown() async throws {
    for identifier in identifiers {
      try await Self.remove(identifier)
    }

    identifiers = []
  }

  private static func remove(_ identifier: UUID, seconds: Double = 5) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while true {
      do {
        return try await WKWebsiteDataStore.remove(forIdentifier: identifier)
      } catch  where ContinuousClock.now < deadline {
        await Task.yield()
      }
    }
  }

  /// A persistent store of its own. The identifier is a throwaway, so the test never reaches the
  /// browser's real store, and the teardown removes what the test wrote.
  private func persistentStore(_ identifier: UUID? = nil) -> WKWebsiteDataStore {
    let identifier = identifier ?? UUID()

    if !identifiers.contains(identifier) { identifiers.append(identifier) }

    return WKWebsiteDataStore(forIdentifier: identifier)
  }

  /// `/set` answers with a cookie that lasts an hour. `/echo` answers with a title that carries the
  /// cookie header it received, or `none`.
  private nonisolated static func handler(cookie name: String) -> FixtureServer.Handler {
    { request in
      switch request.path {
      case "/set":
        var response = Pages.page("Set")
        response.headers.append(("Set-Cookie", "\(name)=one; Max-Age=3600; Path=/"))
        return response

      case "/echo":
        return Pages.page("cookie:\(request.headers["cookie"] ?? "none")")

      default:
        return Pages.page("other")
      }
    }
  }

  private func cookieNames(in store: WKWebsiteDataStore) async -> [String] {
    await store.httpCookieStore.allCookies().map(\.name)
  }

  /// Catches a changed identifier. WebKit cannot move data between stores, so a new value orphans
  /// every login and all site data. The test pins the value.
  func testTheStoreIdentifierNeverChanges() {
    XCTAssertEqual(
      BrowserWebsiteData.storeIdentifier.uuidString, "6F1B8E3A-2D4C-4A97-B05E-7C93D1A84F26")
  }

  /// Catches a pane that falls back to WebKit's default store, where the text viewer and the canvas
  /// would share the browser's logins. A cookie the page sets lands in the browser's store and
  /// never in the default one.
  func testACookieSetByAPageStaysOutOfWebKitsDefaultStore() async throws {
    let name = "sid-\(UUID().uuidString.prefix(8))"
    let store = persistentStore()
    let harness = try await BrowserHarness.make(
      dataStore: store, handler: Self.handler(cookie: name))
    defer { harness.stop() }

    await harness.load("/set", expecting: "Set")

    let inBrowserStore = await cookieNames(in: store)
    let inDefaultStore = await cookieNames(in: .default())

    XCTAssertTrue(inBrowserStore.contains(name), "the browser's store lost the cookie")
    XCTAssertFalse(inDefaultStore.contains(name), "the cookie reached the default store")
  }

  /// Catches panes with a store each, where logging in one pane leaves the others logged out. A
  /// second pane on the same store sends the first pane's cookie. A pane on another store sends
  /// none.
  func testTwoPanesOnOneStoreShareACookieAndAnotherStoreDoesNot() async throws {
    let name = "sid-\(UUID().uuidString.prefix(8))"
    let shared = persistentStore()
    let first = try await BrowserHarness.make(
      dataStore: shared, handler: Self.handler(cookie: name))
    defer { first.stop() }

    let second = BrowserHarness(
      server: first.server, applet: BrowserApplet(dataStore: shared, services: .testing()))
    defer { second.applet.close() }

    let apart = BrowserHarness(
      server: first.server,
      applet: BrowserApplet(dataStore: .nonPersistent(), services: .testing()))
    defer { apart.applet.close() }

    await first.load("/set", expecting: "Set")
    await second.load("/echo", expecting: "cookie:\(name)=one")
    await apart.load("/echo", expecting: "cookie:none")
  }

  /// Catches a store that forgets what it held. A second instance made over the same identifier
  /// sees the first one's cookie. This runs in one process, so it shows that the identifier names
  /// the data and not that the data outlives a relaunch, which the user checks.
  func testASecondInstanceOverTheSameIdentifierSeesTheCookie() async throws {
    let name = "sid-\(UUID().uuidString.prefix(8))"
    let identifier = UUID()
    let first = persistentStore(identifier)
    let harness = try await BrowserHarness.make(
      dataStore: first, handler: Self.handler(cookie: name))
    defer { harness.stop() }

    await harness.load("/set", expecting: "Set")

    let second = persistentStore(identifier)
    let seen = await cookieNames(in: second)

    XCTAssertTrue(second.isPersistent)
    XCTAssertEqual(second.identifier, identifier)
    XCTAssertTrue(seen.contains(name))
  }

  /// Catches a clear that leaves cookies behind, leaves the list of HTTPS-only hosts, touches
  /// another store, or reloads a tab. The open tab keeps its page and asks the server nothing.
  func testClearRemovesTheCookieAndTheHostsAndReloadsNoTab() async throws {
    let name = "sid-\(UUID().uuidString.prefix(8))"
    let shared = persistentStore()
    let other = persistentStore()
    let hsts = HSTSStore()
    let data = BrowserWebsiteData(store: shared, hsts: hsts)
    let harness = try await BrowserHarness.make(
      dataStore: shared, handler: Self.handler(cookie: name))
    defer { harness.stop() }

    let otherPane = BrowserHarness(
      server: harness.server, applet: BrowserApplet(dataStore: other, services: .testing()))
    defer { otherPane.applet.close() }

    await harness.load("/set", expecting: "Set")
    await otherPane.load("/set", expecting: "Set")
    await harness.run("localStorage.setItem('k', 'v')")
    hsts.record(host: "example.com", header: "max-age=3600")

    let localStorage: Set<String> = [WKWebsiteDataTypeLocalStorage]
    let before = await shared.dataRecords(ofTypes: localStorage)

    XCTAssertFalse(before.isEmpty, "a real page made no local storage to clear")

    let requests = harness.server.requests.count

    XCTAssertEqual(hsts.count, 1)

    try await data.clear()

    let inShared = await cookieNames(in: shared)
    let inOther = await cookieNames(in: other)

    let after = await shared.dataRecords(ofTypes: localStorage)

    XCTAssertTrue(after.isEmpty, "local storage survived the clear")
    XCTAssertFalse(inShared.contains(name), "the cookie survived the clear")
    XCTAssertTrue(inOther.contains(name), "the clear reached another store")
    XCTAssertEqual(hsts.count, 0)
    XCTAssertEqual(harness.server.requests.count, requests, "the clear reloaded a tab")
    XCTAssertEqual(harness.applet.title, "Set")
    XCTAssertFalse(harness.tab.isLoading)
  }

  /// Catches a clear that reports success while the list of HTTPS-only hosts is still on disk. A
  /// file from a newer build is never written, so the clear says so after it removed the site data.
  func testClearSaysSoWhenTheHostsListCannotBeEmptied() async throws {
    let name = "sid-\(UUID().uuidString.prefix(8))"
    let shared = persistentStore()
    let file = FileManager.default.temporaryDirectory
      .appending(path: "uniterm-hsts-\(UUID().uuidString).json")

    try Data(#"{"version": 99, "list": {}}"#.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let data = BrowserWebsiteData(store: shared, hsts: HSTSStore(file: file))
    let harness = try await BrowserHarness.make(
      dataStore: shared, handler: Self.handler(cookie: name))
    defer { harness.stop() }

    await harness.load("/set", expecting: "Set")

    do {
      try await data.clear()
      XCTFail("the clear reported success")
    } catch {
      XCTAssertEqual(error as? BrowserWebsiteData.ClearError, .hostsListKept)
    }

    let remaining = await cookieNames(in: shared)

    XCTAssertFalse(remaining.contains(name), "the site data stayed after a failed clear")
    XCTAssertEqual(
      try Data(contentsOf: file), Data(#"{"version": 99, "list": {}}"#.utf8),
      "the newer file was rewritten")
  }
}
