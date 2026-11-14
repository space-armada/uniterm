import AppKit
import AppletKit
import AppletTestSupport
import Darwin
import DocumentTestSupport
import FileWatching
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// Drives the pane around the Markdown page: opening, the description, link policy, and recovery.
@MainActor
final class MarkdownAppletTests: XCTestCase {
  private var windows: [NSWindow] = []

  private func host(_ applet: TextViewerApplet) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.contentView = applet.content
    windows.append(window)
  }

  private func rendered(_ applet: TextViewerApplet) async -> Bool {
    await Harness.eventually { applet.content.markdownView?.isRendered == true }
  }

  private func tall() -> String {
    (0..<300).map { "## Heading \($0)\n\nparagraph \($0) with some words in it.\n" }
      .joined(separator: "\n")
  }

  private func open(
    _ text: String, named name: String = "README.md", opener: RecordingOpener = RecordingOpener(),
    limits: TextViewerLimits = .standard, watching: WatchPolicy = Harness.silentWatch,
    in scratch: Scratch
  ) async throws -> TextViewerApplet {
    let file = try scratch.write(name, Data(text.utf8))
    let applet = Harness.applet(
      startDirectory: scratch.url.path, settings: Harness.settings(limits: limits), opener: opener,
      watching: watching)

    host(applet)
    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    return applet
  }

  /// Catches Markdown that does not reach the page, a title that is not the file's name, a pane
  /// that spawns a document helper for it, and a PDF pane that builds a web view it never uses.
  func testAMarkdownFileRendersInThePaneAndAPDFBuildsNoWebView() async throws {
    let scratch = try Scratch(self)

    for name in ["README.md", "notes.markdown", "README"] {
      let applet = try await open("# Title\n\nbody\n", named: name, in: scratch)
      let done = await rendered(applet)

      XCTAssertTrue(done, name)
      XCTAssertEqual(applet.content.body, .markdown, name)
      XCTAssertEqual(applet.title, name)
      XCTAssertEqual(applet.segments.first?.text, "3 lines", name)
      XCTAssertEqual(applet.helperStarts, 0, name)

      applet.close()
    }

    let pdf = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["one"]))
    let applet = Harness.applet(startDirectory: scratch.url.path)

    try applet.replaceSource(with: pdf, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)

    XCTAssertNil(applet.content.markdownView, "a PDF pane starts no web content process")
  }

  /// Catches a Markdown file past the cap, a pipe named README, and a missing file that load
  /// silently.
  func testMarkdownFilesThatCannotLoadShowAMessage() async throws {
    let scratch = try Scratch(self)
    var limits = TextViewerLimits.standard
    limits.maxMarkdownBytes = 64

    let big = try await open(String(repeating: "x", count: 500), limits: limits, in: scratch)
    _ = await Harness.settled(big)

    XCTAssertTrue(
      Harness.message(big)?.contains("opens files up to") ?? false, "\(Harness.message(big) ?? "")")
    XCTAssertNil(big.content.markdownView)

    let pipe = scratch.url.appendingPathComponent("pipe.md")
    XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)

    let applet = Harness.applet(startDirectory: scratch.url.path)

    try applet.replaceSource(with: pipe, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("not a file with data in it") ?? false)
  }

  /// Catches a link the policy would refuse that opens anyway, and a safe one that does not. A
  /// click on an http link reaches the opener. An ftp link keeps no href, so nothing opens.
  func testOnlySafeLinksOpenInTheDefaultBrowser() async throws {
    let scratch = try Scratch(self)
    let opener = RecordingOpener()
    let applet = try await open(
      "[web](https://example.com/a) [ftp](ftp://example.com/b) [mail](mailto:a@example.com)",
      opener: opener, in: scratch)

    let done = await rendered(applet)
    XCTAssertTrue(done)
    XCTAssertEqual(opener.opened, [], "nothing opens without a click")

    let view = try XCTUnwrap(applet.content.markdownView)

    for selector in ["a[href^='https:']", "a[href^='mailto:']"] {
      _ = await view.run(
        "document.querySelector(selector).click(); return 1", ["selector": selector])
    }

    let opened = await Harness.eventually { opener.opened.count == 2 }

    XCTAssertTrue(opened)
    XCTAssertEqual(
      opener.opened.map(\.absoluteString), ["https://example.com/a", "mailto:a@example.com"])
  }

  /// Catches a description that holds Markdown contents or loses the position. A save taken after the
  /// page's scroll report describes the scrolled position, and a pane restored from it lands there.
  func testAScrollThenAnImmediateSaveRestoresThePosition() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(tall(), in: scratch)
    let done = await rendered(applet)

    XCTAssertTrue(done)

    let view = try XCTUnwrap(applet.content.markdownView)

    _ = await view.run("window.scrollTo(0, 6000); return 1")

    // A save taken the moment the scroll is issued may still hold the old position. The page
    // reports the scroll from its scroll handler, one message later.
    _ = applet.describe()

    let reported = await Harness.eventually { (view.anchor?.line ?? 0) > 100 }
    XCTAssertTrue(reported)

    let saved = applet.describe()
    let description = try TextViewerDescription.decode(saved)
    let line = try XCTUnwrap(description.anchor?.sourceLine)

    XCTAssertGreaterThan(line, 100)
    XCTAssertLessThan(
      try JSONEncoder().encode(description).count, 4096, "the document is not in the description")

    let again = try Harness.restored(
      description, settings: Harness.settings())

    host(again)
    again.start(origin: .restore)

    let back = await rendered(again)
    XCTAssertTrue(back)
    XCTAssertEqual(again.content.markdownView?.anchor?.line, line)

    // Until the page has put the anchor back, a save describes the restored one.
    let early = try Harness.restored(description, settings: Harness.settings())

    XCTAssertEqual(try TextViewerDescription.decode(early.describe()).anchor, description.anchor)
  }

  /// Catches a pane left blank when WebKit's content process ends. It says so and offers Reload,
  /// keeps its position in the description, and Reload brings the page back at that position.
  func testWhenTheContentProcessEndsReloadRecovers() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(tall(), in: scratch)
    let done = await rendered(applet)

    XCTAssertTrue(done)

    let view = try XCTUnwrap(applet.content.markdownView)

    _ = await view.run("window.scrollTo(0, 6000); return 1")

    let moved = await Harness.eventually { (view.anchor?.line ?? 0) > 100 }
    XCTAssertTrue(moved)

    let line = try XCTUnwrap(view.anchor?.line)
    XCTAssertTrue(MarkdownRig.killContentProcess(of: view))

    let ended = await Harness.eventually { Harness.message(applet)?.contains("stopped") == true }

    XCTAssertTrue(ended, "\(applet.content.body)")

    if case .message(_, _, let offersReload) = applet.content.body {
      XCTAssertTrue(offersReload)
    }

    XCTAssertEqual(
      try TextViewerDescription.decode(applet.describe()).anchor?.sourceLine, line,
      "the position survives in the description")

    applet.reload()

    let back = await rendered(applet)
    XCTAssertTrue(back)
    XCTAssertEqual(applet.content.markdownView?.anchor?.line, line)
  }

  /// Catches a Markdown reload that sends the reader to the top, or one that tears the page down.
  /// A save appends a line, the page shows it, and the same block is at the top.
  func testASaveReloadsMarkdownAtTheSameLine() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(tall(), watching: Harness.fastWatch, in: scratch)
    let done = await rendered(applet)

    XCTAssertTrue(done)

    let view = try XCTUnwrap(applet.content.markdownView)

    _ = await view.run("window.scrollTo(0, 6000); return 1")

    let moved = await Harness.eventually { (view.anchor?.line ?? 0) > 100 }
    XCTAssertTrue(moved)

    let line = try XCTUnwrap(view.anchor?.line)
    let before = view.lineCount
    let file = scratch.url.appendingPathComponent("README.md")

    try Data((tall() + "\nappended\n").utf8).write(to: file)

    let reloaded = await Harness.eventually {
      applet.content.markdownView?.lineCount ?? 0 > before
        && applet.content.markdownView?.isRendered == true
    }
    XCTAssertTrue(reloaded)
    XCTAssertTrue(applet.content.markdownView === view, "the page is kept, not rebuilt")

    let landed = await Harness.eventually {
      abs((applet.content.markdownView?.anchor?.line ?? 0) - line) <= 4
    }
    XCTAssertTrue(landed)
    applet.close()
  }

  /// Catches a drop that the web view swallows. Dropping a PDF on rendered Markdown replaces it, and
  /// the Markdown page goes away with its web content process.
  func testADropOnRenderedMarkdownOpensTheFileInThePane() async throws {
    let scratch = try Scratch(self)
    let applet = try await open("# Title", in: scratch)
    let done = await rendered(applet)

    XCTAssertTrue(done)

    let pdf = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["one"]))

    XCTAssertTrue(applet.handleDrop([pdf]))

    let switched = await Harness.eventually { applet.content.body == .pdf }

    XCTAssertTrue(switched)
    XCTAssertNil(applet.content.markdownView)
  }

  /// Catches a closed pane that keeps its web view alive.
  func testClosingThePaneEndsThePage() async throws {
    let scratch = try Scratch(self)
    let applet = try await open("# Title", in: scratch)
    let done = await rendered(applet)

    XCTAssertTrue(done)

    applet.close()

    XCTAssertNil(applet.content.markdownView)
  }
}
