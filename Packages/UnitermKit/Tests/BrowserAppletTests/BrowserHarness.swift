import AppKit
import AppletKit
import AppletTestSupport
import BrowserModel
import BrowserTestSupport
import Preferences
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// Stands in for the pane. It records what the applet tells its pane, and it wakes a waiting test at
/// every call, so a test waits for the applet's own report and never polls or sleeps.
@MainActor
final class EventHost: AppletHost {
  let recording = RecordingHost()
  private let events = AsyncStream.makeStream(of: Void.self)

  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String
  ) -> StatusRecordID? {
    defer { events.continuation.yield() }
    return recording.applet(applet, send: delivery, level: level, text: text)
  }

  func appletDidExit(_ applet: any Applet) { recording.appletDidExit(applet) }

  func appletDidChange(_ applet: any Applet) {
    recording.appletDidChange(applet)
    events.continuation.yield()
  }

  func appletTabsDidChange(_ applet: any Applet) {
    recording.appletTabsDidChange(applet)
    events.continuation.yield()
  }

  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool {
    Task { @MainActor [events] in events.continuation.yield() }

    return await recording.applet(applet, confirm: request)
  }

  func issueCloseStamp() -> UInt64 { recording.issueCloseStamp() }

  func applet(
    _ applet: any Applet, sessionStarted tab: AppletTabID, pid: pid_t, started: Int,
    generation: UInt64
  ) {
    recording.applet(
      applet, sessionStarted: tab, pid: pid, started: started, generation: generation)
    events.continuation.yield()
  }

  func applet(_ applet: any Applet, sessionEnded tab: AppletTabID, pid: pid_t, started: Int) {
    recording.applet(applet, sessionEnded: tab, pid: pid, started: started)
    events.continuation.yield()
  }

  /// Returns once `condition` holds. It checks first, then waits for the applet's next report. A
  /// condition that never holds ends the test with a failure after `seconds`, so a hung page fails
  /// instead of hanging the run. The timer runs only on that path.
  func until(
    _ message: String, seconds: Int = 30, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor @escaping () -> Bool
  ) async {
    if condition() { return }

    var timedOut = false

    let timer = Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))

      guard !Task.isCancelled else { return }

      timedOut = true
      events.continuation.yield()
    }

    defer { timer.cancel() }

    for await _ in events.stream {
      if condition() { return }

      if timedOut {
        XCTFail("timed out waiting until \(message)", file: file, line: line)
        return
      }
    }
  }
}

/// An opener that launches nothing. It says which apps would handle which schemes, and records what
/// the browser asked it to open.
@MainActor
final class FakeOpener: URLOpening {
  /// The app name for each scheme this fake pretends a user has an app for.
  var apps: [String: String]

  /// What `open` should answer.
  var succeeds = true

  private(set) var opened: [URL] = []

  init(apps: [String: String] = ["mailto": "Mail", "ssh": "Terminal"]) {
    self.apps = apps
  }

  func applicationName(toOpen url: URL) -> String? {
    url.scheme.flatMap { apps[$0.lowercased()] }
  }

  func open(_ url: URL) -> Bool {
    opened.append(url)
    return succeeds
  }
}

/// A reveal that shows nothing in Finder. It records what the browser asked it to show.
@MainActor
final class FakeRevealer: FileRevealing {
  private(set) var revealed: [URL] = []

  func reveal(_ url: URL) {
    revealed.append(url)
  }
}

extension BrowserServices {
  /// Services for a test: an engine the test can change, a list in memory, an opener that
  /// launches nothing, a reveal that opens no Finder window, and a Downloads folder under the
  /// temporary directory. No test writes to the user's Downloads. The folder is made when a
  /// download needs it, and the harness removes it.
  @MainActor
  static func testing(
    engine: @escaping @MainActor () -> SearchEngine = { .duckDuckGo },
    hsts: HSTSStore = HSTSStore(), opener: FakeOpener = FakeOpener(),
    downloads: URL = FileManager.default.temporaryDirectory.appending(
      path: "uniterm-test-downloads-\(UUID().uuidString)", directoryHint: .isDirectory),
    reveal: FakeRevealer = FakeRevealer(), files: DownloadFileOperations = .live,
    sweeper: DownloadSweeper = DownloadSweeper(), cancelGrace: Duration = .seconds(30),
    clock: @escaping @Sendable () -> Date = Date.init, hang: HangPolicy = .live
  ) -> BrowserServices {
    BrowserServices(
      searchEngine: engine, hsts: hsts, downloadsDirectory: { downloads }, reveal: reveal,
      opener: opener, downloadFiles: files, downloadSweeper: sweeper,
      downloadCancelGrace: cancelGrace, clock: clock, hang: hang)
  }
}

/// One applet against one local server, with a private website data store so no test shares
/// cookies or touches the user's.
@MainActor
final class BrowserHarness {
  let server: FixtureServer
  let host = EventHost()
  let applet: BrowserApplet
  let downloadsDirectory: URL?

  /// The window that hosts the pane's view, when the test asked for one. It keeps the window alive.
  private(set) var window: NSWindow?

  var tab: BrowserTab { applet.tab }
  var posts: [(level: StatusLevel, text: String)] { host.recording.posts }

  /// The records the applet made without a turn on the bar, such as an explanation the pane
  /// already shows.
  var records: [(level: StatusLevel, text: String)] { host.recording.records }

  /// How a test hosts the pane's view.
  enum Hosting {
    /// No window. Most tests need none.
    case none

    /// A window holds the view, and the keyboard stays where it was.
    case window

    /// A window holds the view, and the keyboard is in the page, as when the user is typing.
    case focusedWindow
  }

  static func make(
    services: BrowserServices = .testing(), dataStore: WKWebsiteDataStore = .nonPersistent(),
    hosting: Hosting = .none,
    handler: @escaping FixtureServer.Handler = { _ in .page(titled: "ok") }
  ) async throws -> BrowserHarness {
    let server = try await FixtureServer.start(handler: handler)
    let applet = BrowserApplet(dataStore: dataStore, services: services)
    let harness = BrowserHarness(
      server: server, applet: applet, downloads: services.downloadsDirectory())

    if hosting != .none {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)

      window.contentView = applet.content

      if hosting == .focusedWindow { window.makeFirstResponder(harness.tab.webView) }

      harness.window = window
    }

    return harness
  }

  /// `starting` is false for a test that decides when the pane starts.
  init(
    server: FixtureServer, applet: BrowserApplet, starting: Bool = true, downloads: URL? = nil
  ) {
    self.server = server
    self.applet = applet
    self.downloadsDirectory = downloads

    applet.host = host

    if starting { applet.start(origin: .user) }
  }

  func stop() {
    applet.close()
    server.stop()

    if let downloadsDirectory { try? FileManager.default.removeItem(at: downloadsDirectory) }
  }

  /// The names in the downloads folder, sorted. An empty list when the folder does not exist yet.
  func files() -> [String] {
    guard let downloadsDirectory else { return [] }

    return ((try? FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path)) ?? [])
      .sorted()
  }

  /// Loads `path`, a page with a form, and submits it. Returns once the result page, titled
  /// `Posted`, shows.
  func postResult(from path: String = "/form") async {
    await load(path, expecting: path == "/form" ? "Form" : "LongForm")
    await run("document.forms[0].submit()")
    await host.until("the post result shows") { [applet] in
      applet.title == "Posted" && !applet.tab.isLoading
    }
  }

  /// The pages the server has served for `path`, by method.
  func count(_ method: String, _ path: String) -> Int {
    server.requests.filter { $0.method == method && $0.path == path }.count
  }

  /// Returns once `condition` holds, for what no applet report announces, such as a file WebKit
  /// removes after a cancel. It yields between checks and never sleeps. A condition that never
  /// holds fails the test after `seconds`.
  func eventually(
    _ message: String, seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
  ) async {
    await Self.eventually(message, seconds: seconds, file: file, line: line, condition)
  }

  /// The same wait for a test that has no harness, such as one that reads a spy's decisions.
  static func eventually(
    _ message: String, seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
  ) async {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("timed out waiting until \(message)", file: file, line: line)
        return
      }

      await Task.yield()
    }
  }

  /// Like `eventually`, for a condition that has to ask the page. Each check is a round trip, so
  /// the loop yields between them and never sleeps.
  func eventuallyAsync(
    _ message: String, seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () async -> Bool
  ) async {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while await !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("timed out waiting until \(message)", file: file, line: line)
        return
      }

      await Task.yield()
    }
  }

  func load(_ path: String, expecting title: String) async {
    applet.submit(address: server.url(path).absoluteString)
    await host.until("the page titled \(title) shows") { [applet] in
      applet.title == title && !applet.tab.isLoading
    }
  }

  @discardableResult
  func run(_ script: String) async -> Any? {
    try? await tab.webView.evaluateJavaScript(script)
  }
}

/// Pages the fixture server serves. Each sends no-store, so a move through history asks the server
/// again and a test counts requests exactly.
enum Pages {
  nonisolated static let noStore = [
    ("Cache-Control", "no-store"), ("Content-Type", "text/html"),
  ]

  nonisolated static func page(_ title: String, _ body: String = "") -> FixtureServer.Response {
    FixtureServer.Response(
      status: 200, headers: noStore,
      body: Data("<title>\(title)</title><body>\(body)</body>".utf8))
  }
}
