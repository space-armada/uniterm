import AppKit
import BrowserTestSupport
import Darwin
import Theme
import WebKit
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// Drives the Markdown page in a real web view. Each test shows a document and reads what the page
/// built through the parser's own world, so a test sees the same DOM the user sees.
@MainActor
final class MarkdownViewTests: XCTestCase {
  private func scratchFolder() throws -> Scratch {
    try Scratch(self)
  }

  // MARK: Rendering

  /// Catches a README construct that does not render: headings, lists, code blocks, tables, links,
  /// and emphasis from the parser, and a centered header, `<details>`, `<kbd>`, and `<picture>` from
  /// raw HTML on the allowlist.
  func testMarkdownAndAllowlistedHTMLRender() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let text = """
      <h1 align="center">Centered</h1>

      <p align="center"><img src="logo.png" width="64" alt="logo"></p>

      ## Install

      - one
      - two

      ```swift
      let x = 1
      ```

      | Name | Value |
      |:-----|------:|
      | a    | 1     |

      See [the site](https://example.com/docs) and press <kbd>Cmd</kbd>.

      <details><summary>More</summary>

      hidden text

      </details>

      Water is H<sub>2</sub>O and E=mc<sup>2</sup>.
      """

    let shown = await rig.show(text)
    XCTAssertTrue(shown)

    let counts = [
      "h1[align=center]": 1, "h2": 1, "ul > li": 2, "pre > code": 1, "table th": 2,
      "td[align=right]": 1, "th[align=left]": 1, "a[href='https://example.com/docs']": 1,
      "kbd": 1, "details > summary": 1, "sub": 1, "sup": 1, "img[width='64']": 1,
    ]

    for (selector, expected) in counts {
      let found = await rig.count(selector)
      XCTAssertEqual(found, expected, selector)
    }

    XCTAssertEqual(rig.view.headings.map(\.text), ["Centered", "Install"])
    XCTAssertEqual(rig.view.headings.map(\.id), ["centered", "install"])
    XCTAssertEqual(
      rig.view.lineCount, text.split(separator: "\n", omittingEmptySubsequences: false).count)
  }

  /// Catches rendered text that ignores the theme. The page reads the palette's colors, and a theme
  /// change reaches a page that is already showing.
  func testThemeColorsApplyAndFollowAThemeChange() async throws {
    let rig = try await MarkdownRig.make(palette: .latte)
    defer { rig.close() }

    let shown = await rig.show("# Title\n\ntext")
    XCTAssertTrue(shown)

    func background() async -> String? {
      await rig.string("return getComputedStyle(document.body).backgroundColor")
    }

    func dark() async -> Double? {
      await rig.number("return matchMedia('(prefers-color-scheme: dark)').matches ? 1 : 0")
    }

    func rgb(_ color: ThemeColor) -> String {
      "rgb(\(color.red), \(color.green), \(color.blue))"
    }

    let lightBackground = await background()
    let lightDark = await dark()

    XCTAssertEqual(lightBackground, rgb(ThemePalette.latte[.base]))
    XCTAssertEqual(lightDark, 0)

    rig.view.apply(.mocha)

    var darkBackground: String?

    for _ in 0..<100 {
      darkBackground = await background()

      if darkBackground == rgb(ThemePalette.mocha[.base]) { break }

      try await Task.sleep(for: .milliseconds(20))
    }

    let darkNow = await dark()

    XCTAssertEqual(darkBackground, rgb(ThemePalette.mocha[.base]))
    XCTAssertEqual(darkNow, 1, "the page follows the uniterm theme, not the system")
  }

  /// Catches a `<picture>` that picks the dark source under a light theme. The view's appearance
  /// follows the theme, so `prefers-color-scheme` does too, whatever the system shows.
  func testAPictureChoosesItsSourceByTheThemeNotTheSystem() async throws {
    let scratch = try scratchFolder()

    try Pixels.png(width: 3).write(to: scratch.url.appendingPathComponent("light.png"))
    try Pixels.png(width: 5).write(to: scratch.url.appendingPathComponent("dark.png"))

    let text = """
      <picture>
      <source media="(prefers-color-scheme: dark)" srcset="dark.png">
      <img src="light.png" alt="logo">
      </picture>
      """

    for (palette, expected) in [(ThemePalette.latte, 3.0), (ThemePalette.mocha, 5.0)] {
      let rig = try await MarkdownRig.make(palette: palette)
      defer { rig.close() }

      let shown = await rig.show(text, folder: scratch.url)
      XCTAssertTrue(shown)

      let loaded = await rig.imageLoaded("picture img")
      XCTAssertTrue(loaded)

      let width = await rig.number("return document.querySelector('picture img').naturalWidth")

      XCTAssertEqual(width, expected, "\(palette.flavor)")
    }
  }

  // MARK: Sanitizing

  /// Catches markup that runs or navigates: scripts, event handlers, a meta refresh, frames, forms,
  /// objects, media, styles, and data attributes are gone from the document, and the page never
  /// leaves its own URL. Remote images make no request.
  func testHostileMarkupIsDroppedAndRunsNothing() async throws {
    let server = try await FixtureServer.start()
    defer { server.stop() }

    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let remote = server.url("/x").absoluteString
    let text = """
      <script>document.title = 'script ran'</script>
      <script src="\(remote)"></script>
      <meta http-equiv="refresh" content="0;url=\(remote)">
      <base href="\(remote)">
      <link rel="stylesheet" href="\(remote)">
      <style>@import url(\(remote));</style>

      <img src="x" onerror="document.title = 'onerror ran'" onload="document.title = 'onload ran'">

      <iframe src="\(remote)"></iframe>
      <form action="\(remote)"><input name="a"><button>go</button></form>
      <object data="\(remote)"></object>
      <embed src="\(remote)">
      <video src="\(remote)"></video>
      <audio src="\(remote)"></audio>

      <p style="background:url(\(remote))" class="c" data-line="9" onclick="document.title = 'click ran'">kept</p>

      ![remote](\(remote)/a.png)

      <img src="\(remote)/b.png" srcset="\(remote)/c.png 2x" alt="remote srcset">

      <a href="javascript:document.title='js'">js link</a> <a href="ftp://example.com/a">ftp</a>
      """

    let shown = await rig.show(text)
    XCTAssertTrue(shown)

    for tag in [
      "script", "meta", "base", "link", "style", "iframe", "form", "input", "button", "object",
      "embed",
      "video", "audio",
    ] {
      let found = await rig.count("#um-root \(tag)")
      XCTAssertEqual(found, 0, tag)
    }

    let dropped = await rig.count(
      "#um-root :is([onerror],[onload],[onclick],[style],[class],[data-line],[srcset],img[src*='127.0.0.1'])"
    )
    XCTAssertEqual(dropped, 0)

    let kept = await rig.count("p")
    XCTAssertGreaterThan(kept, 0)

    let javascriptLinks = await rig.count("a[href^='javascript']")
    XCTAssertEqual(javascriptLinks, 0)

    await rig.settle()

    XCTAssertEqual(server.requests.count, 0, "\(server.requests.map(\.target))")
    XCTAssertEqual(rig.view.webView.url, MarkdownScheme.pageURL)

    let alt = await rig.string("return document.querySelector('img[alt=remote]')?.alt ?? ''")
    XCTAssertEqual(alt, "remote", "a remote image keeps its alt text")
  }

  /// Catches an allowlist that drifts from GitHub's. The kept elements and attributes from the
  /// pinned source render, and elements off it do not.
  func testTheAllowlistKeepsGitHubsElementsAndDropsTheRest() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let text = """
      <div itemscope itemtype="https://schema.org/Thing"><span title="t" lang="en">s</span></div>

      <table><thead><tr><th colspan="2">h</th></tr></thead><tbody><tr><td>a</td><td>b</td></tr></tbody></table>

      <dl><dt>t</dt><dd>d</dd></dl>

      <ruby>漢<rp>(</rp><rt>kan</rt><rp>)</rp></ruby> <abbr title="x">x</abbr> <mark>m</mark> <q cite="https://e.com">q</q> <s>s</s> <ins>i</ins> <del>d</del>

      <figure><img src="a.png" alt="a" loading="lazy"><figcaption>c</figcaption></figure>

      <blockquote cite="https://e.com">b</blockquote>

      <center>c</center> <font color="red">f</font> <marquee>m</marquee> <svg><circle/></svg> <math><mi>x</mi></math> <textarea>t</textarea> <select><option>o</option></select> <button>b</button>
      """

    let shown = await rig.show(text)
    XCTAssertTrue(shown)

    let kept = [
      "div[itemscope][itemtype]", "span[title][lang]", "th[colspan='2']", "dl dt", "dl dd",
      "ruby rt", "ruby rp", "abbr[title]", "mark", "q[cite]", "s", "ins", "del",
      "figure figcaption",
      "img[loading=lazy]", "blockquote[cite]",
    ]

    for selector in kept {
      let found = await rig.count(selector)
      XCTAssertGreaterThan(found, 0, selector)
    }

    for tag in [
      "center", "font", "marquee", "svg", "math", "textarea", "select", "option", "button",
    ] {
      let found = await rig.count("#um-root \(tag)")
      XCTAssertEqual(found, 0, tag)
    }
  }

  #if DEBUG
    /// Catches a policy that holds only because the sanitizer ran. With the sanitizer replaced by a
    /// pass-through that builds executable markup from the parser's output, a remote image, a remote
    /// srcset, scripts, frames, forms, and media still make no request and run nothing. The page's
    /// policy and the rule list hold alone.
    func testThePolicyHoldsWithTheSanitizerBypassed() async throws {
      let server = try await FixtureServer.start()
      defer { server.stop() }

      let rig = try await MarkdownRig.make(bypass: true)
      defer { rig.close() }

      let remote = server.url("/x").absoluteString
      let text = """
        <img src="\(remote)/img.png" alt="i">

        <img srcset="\(remote)/set.png 1x, \(remote)/set2.png 2x" alt="s">

        <picture><source srcset="\(remote)/source.png"><img alt="p"></picture>

        <script>document.title = 'script ran'</script>

        <script src="\(remote)/script.js"></script>

        <iframe src="\(remote)/frame"></iframe>

        <form id="f" action="\(remote)/form" method="post"><input name="a" value="b"></form>

        <video src="\(remote)/video.mp4" autoplay></video>

        <audio src="\(remote)/audio.mp3" autoplay></audio>

        <object data="\(remote)/object"></object>

        <embed src="\(remote)/embed">

        <link rel="stylesheet" href="\(remote)/link.css">

        <style>@import url(\(remote)/import.css); p { background: url(\(remote)/bg.png) }</style>

        <p style="background:url(\(remote)/inline.png)">p</p>

        <meta http-equiv="refresh" content="0;url=\(remote)/refresh">

        <img src="x" onerror="document.title = 'onerror ran'">
        """

      let shown = await rig.show(text)
      XCTAssertTrue(shown)

      let inserted = await rig.count(
        "#um-root :is(iframe, form, object, embed, video, audio, link, style, meta)")
      XCTAssertGreaterThanOrEqual(inserted, 8, "the bypass inserted the markup the sanitizer drops")

      // WebKit's own fragment parser drops script elements and handlers when page script is off. A
      // script built by hand and appended is the stronger probe.
      _ = await rig.eval(
        """
        const inline = document.createElement('script');
        inline.textContent = "document.title = 'script ran'";
        const remote = document.createElement('script');
        remote.src = url;
        document.body.append(inline, remote);
        return 1
        """, ["url": remote + "/built.js"])

      _ = await rig.eval("document.getElementById('f').submit(); return 1")

      await rig.settle()

      XCTAssertEqual(server.requests.count, 0, "\(server.requests.map(\.target))")
      XCTAssertEqual(rig.view.webView.url, MarkdownScheme.pageURL)

      let title = await rig.string("return document.title")
      XCTAssertEqual(title, "Markdown", "no script ran")
    }
  #endif

  // MARK: Links

  /// Catches a link that opens without a click or opens a scheme the policy refuses. An http,
  /// https, or mailto link activated by the user reaches the pane's link policy and nothing else
  /// navigates. A fragment link scrolls in the page and never leaves it.
  func testLinksFollowThePolicyAndFragmentLinksScroll() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let filler = (0..<120).map { "paragraph \($0)\n" }.joined(separator: "\n")
    let text = """
      [Install](#install) [Web](https://example.com/a) [Mail](mailto:a@example.com) \
      [Sibling](other.md) <a href="#deep">Deep</a> [Ftp](ftp://example.com/x)

      \(filler)

      ## Install

      tail

      <h3 id="deep">Authored</h3>

      more
      """

    let shown = await rig.show(text)
    XCTAssertTrue(shown)
    XCTAssertEqual(rig.links, [], "nothing opens before a click")

    let top = await rig.number("return window.scrollY")
    XCTAssertEqual(top, 0)

    _ = await rig.eval("document.querySelector('a[href=\"#install\"]').click(); return 1")

    var moved = 0.0

    for _ in 0..<100 {
      moved = await rig.number("return window.scrollY") ?? 0

      if moved > 0 { break }

      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertGreaterThan(moved, 0, "the Markdown fragment link scrolls")

    _ = await rig.eval("window.scrollTo(0, 0); return 1")
    _ = await rig.eval("document.querySelector('a[href=\"#deep\"]').click(); return 1")

    for _ in 0..<100 {
      moved = await rig.number("return window.scrollY") ?? 0

      if moved > 0 { break }

      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertGreaterThan(moved, 0, "an authored anchor scrolls")
    XCTAssertEqual(rig.links, [])

    let ftp = await rig.count("a[href^='ftp:']")
    XCTAssertEqual(ftp, 0, "a scheme off the policy keeps no href")

    for selector in [
      "a[href^='https://example.com']", "a[href^='mailto:']",
    ] {
      _ = await rig.eval(
        "document.querySelector(selector).click(); return 1", ["selector": selector])
    }

    let reached = await rig.eventually { rig.links.count == 2 }

    XCTAssertTrue(reached, "\(rig.links)")
    XCTAssertEqual(
      rig.links.map(\.absoluteString), ["https://example.com/a", "mailto:a@example.com"])

    _ = await rig.eval("document.querySelector('a[href=\"other.md\"]').click(); return 1")

    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(rig.links.count, 2, "a relative link opens nothing")
    XCTAssertEqual(
      rig.view.webView.url?.absoluteString.hasPrefix("uniterm-markdown://app/index.html"), true)
  }

  // MARK: Images

  /// Catches an image rule that loads what it should not. A relative image, nested or above the
  /// document's folder, shows. A root-relative, `file:`, remote, non-image, device, pipe,
  /// mount-point, and over-cap path loads nothing.
  func testOnlyRelativeImagesInsideTheVolumeLoad() async throws {
    let scratch = try scratchFolder()
    let docs = scratch.url.appendingPathComponent("docs")

    try FileManager.default.createDirectory(
      at: docs.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Pixels.png(width: 2).write(to: docs.appendingPathComponent("a.png"))
    try Pixels.png(width: 3).write(to: docs.appendingPathComponent("sub/b.png"))
    try Pixels.png(width: 4).write(to: scratch.url.appendingPathComponent("up.png"))
    try (Pixels.png(width: 7) + Data(count: 4096)).write(to: docs.appendingPathComponent("big.png"))
    try Data("text".utf8).write(to: docs.appendingPathComponent("notes.txt"))
    try Pixels.png(width: 6).write(to: docs.appendingPathComponent("with space.png"))

    XCTAssertEqual(mkfifo(docs.appendingPathComponent("pipe.png").path, 0o600), 0)

    for (name, target) in [
      ("zero.png", "/dev/zero"), ("net.png", "/net/host/x.png"),
      ("vol.png", "/Volumes/Other/x.png"),
    ] {
      try FileManager.default.createSymbolicLink(
        atPath: docs.appendingPathComponent(name).path, withDestinationPath: target)
    }

    var limits = TextViewerLimits.standard
    limits.maxMarkdownImageBytes = 1024

    let rig = try await MarkdownRig.make(limits: limits)
    defer { rig.close() }

    let text = """
      ![a](a.png) ![b](sub/b.png) ![up](../up.png) ![space](<with space.png>)

      ![root](/etc/hosts.png) ![remote](https://127.0.0.1:1/x.png) \
      ![txt](notes.txt) ![pipe](pipe.png) ![zero](zero.png) ![net](net.png) ![vol](vol.png) \
      ![big](big.png) ![up2](../../../../../../../../../../../../etc/x.png)

      <img src="file:///etc/hosts.png" alt="file">

      <picture><source srcset="a.png 1x, sub/b.png 2x, /etc/x.png 3x, https://127.0.0.1:1/y.png 4x"><img src="a.png" alt="set"></picture>
      """

    let shown = await rig.show(text, folder: docs)
    XCTAssertTrue(shown)

    for (alt, width) in [("a", 2.0), ("b", 3.0), ("up", 4.0), ("space", 6.0)] {
      let loaded = await rig.imageLoaded("img[alt=\(alt)]")
      let actual = await rig.number(
        "return document.querySelector('img[alt=' + alt + ']').naturalWidth", ["alt": alt])

      XCTAssertTrue(loaded, alt)
      XCTAssertEqual(actual, width, alt)
    }

    for alt in ["root", "file", "remote"] {
      let hasSource = await rig.number(
        "const i = document.querySelector('img[alt=' + alt + ']'); return i && i.hasAttribute('src') ? 1 : 0",
        ["alt": alt])

      XCTAssertEqual(hasSource, 0, "\(alt) keeps no source, so its alt text shows")
    }

    try await Task.sleep(for: .milliseconds(800))

    for alt in ["txt", "pipe", "zero", "net", "vol", "big", "up2"] {
      let width = await rig.number(
        "return document.querySelector('img[alt=' + alt + ']').naturalWidth", ["alt": alt])

      XCTAssertEqual(width, 0, "\(alt) loads nothing")
    }

    let set = await rig.string(
      "return document.querySelector('picture source').getAttribute('srcset')")

    XCTAssertEqual(
      set,
      "uniterm-markdown://app/image?p=a.png 1x, uniterm-markdown://app/image?p=sub%2Fb.png 2x")
  }

  /// Catches an image that reload serves from WebKit's cache. The changed file shows after a reload,
  /// and the handler is asked for it again.
  func testAReloadFetchesImagesAgain() async throws {
    let scratch = try scratchFolder()
    let image = scratch.url.appendingPathComponent("a.png")

    try Pixels.png(width: 2).write(to: image)

    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let shown = await rig.show("![a](a.png)", folder: scratch.url)
    XCTAssertTrue(shown)

    let first = await rig.imageLoaded("img")
    XCTAssertTrue(first)

    try Pixels.png(width: 9).write(to: image)

    let again = await rig.show("![a](a.png)", folder: scratch.url)
    XCTAssertTrue(again)

    var width = 0.0

    for _ in 0..<200 {
      width = await rig.number("return document.querySelector('img').naturalWidth") ?? 0

      if width == 9 { break }

      try await Task.sleep(for: .milliseconds(25))
    }

    XCTAssertEqual(width, 9)
  }

  // MARK: Details

  /// Catches a closed `<details>` that shows its body. The summary and the body are separate
  /// Markdown blocks around a blank line, so sanitizing each block alone closed the element early
  /// and left the body outside it. The body stays inside, hidden while closed, shown once open.
  func testAClosedDetailsHidesItsBodyAndOpensOnItsSummary() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let text = """
      <details><summary>More</summary>

      Hidden until opened.

      - and a list

      </details>

      After the details.
      """

    let shown = await rig.show(text)
    XCTAssertTrue(shown)

    let inside = await rig.count("details > p, details > ul")
    XCTAssertEqual(inside, 2, "the body is inside the element")

    let after = await rig.count("body > main > p")
    XCTAssertEqual(after, 1, "only the paragraph after the element is outside it")

    // A closed element still has boxes for its body in WebKit, so the check reads the height the
    // element takes. Closed, it is the summary's height. Open, the body adds to it.
    func heights() async -> (details: Double, summary: Double, body: Double)? {
      guard
        let list = await rig.eval(
          """
          const d = document.querySelector('details');
          return [d.getBoundingClientRect().height,
                  d.querySelector('summary').getBoundingClientRect().height,
                  d.querySelector('p').getBoundingClientRect().height]
          """) as? [NSNumber]
      else { return nil }

      return (list[0].doubleValue, list[1].doubleValue, list[2].doubleValue)
    }

    let measured = await heights()
    let closed = try XCTUnwrap(measured)
    XCTAssertGreaterThan(closed.summary, 0)
    XCTAssertLessThan(closed.details, closed.summary + 8, "a closed details takes only its summary")

    _ = await rig.eval("document.querySelector('summary').click(); return 1")

    var open = closed

    for _ in 0..<100 {
      open = await heights() ?? closed

      if open.details > closed.details + 8 { break }

      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertGreaterThan(
      open.details, closed.summary + 8, "a click on the summary opens it with page script off")
  }

  // MARK: Generations

  /// Catches a message from an earlier document that changes the current one. After a second
  /// document starts, a late `rendered` or `anchor` from the first is dropped, and the second's
  /// own messages still count.
  func testMessagesFromAnEarlierDocumentAreDropped() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let first = await rig.show("# One")
    XCTAssertTrue(first)

    let stale = rig.view.generation

    rig.view.show(
      document: MarkdownDocument(text: Data("# Two\n\ntext".utf8), folder: nil), anchor: nil)

    XCTAssertEqual(rig.view.generation, stale + 1)
    XCTAssertFalse(rig.view.isRendered)

    let rendered: [String: Any] = [
      "kind": "rendered", "generation": stale, "lines": 99, "headings": [] as [Any],
    ]

    rig.view.receive(rendered)
    XCTAssertFalse(rig.view.isRendered, "a stale rendered does not mark the new document rendered")
    XCTAssertEqual(rig.view.lineCount, 0)

    let done = await rig.eventually { rig.view.isRendered }
    XCTAssertTrue(done)
    XCTAssertEqual(rig.view.lineCount, 3)

    let before = rig.view.anchor

    rig.view.receive(["kind": "anchor", "generation": stale, "line": 77, "fraction": 0.5])
    XCTAssertEqual(rig.view.anchor, before, "a stale anchor does not move the new document")

    rig.view.receive(["kind": "anchor", "line": 77, "fraction": 0.5])
    XCTAssertEqual(rig.view.anchor, before, "a message with no generation is dropped")
  }

  // MARK: Rules

  /// Catches a rule list whose failed compile is remembered. The first compile fails, and the next
  /// ask compiles again and gets the list. A list that compiled is shared, not compiled twice.
  func testAFailedRuleListCompileIsNotRemembered() async throws {
    let list = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "uniterm.markdown.rules.test",
      encodedContentRuleList: """
        [{"trigger": {"url-filter": "^nomatch$"}, "action": {"type": "block"}}]
        """)
    var calls = 0

    let compiler = RuleListCompiler {
      calls += 1

      return calls == 1 ? nil : list
    }

    let failed = await compiler.compiled()
    XCTAssertNil(failed)

    let retried = await compiler.compiled()
    XCTAssertNotNil(retried)
    XCTAssertEqual(calls, 2)

    let shared = await compiler.compiled()
    XCTAssertNotNil(shared)
    XCTAssertEqual(calls, 2, "a compiled list is kept")
  }

  // MARK: Isolation

  /// Catches a pane that shares storage. Each Markdown view has its own non-persistent store, which
  /// is neither another pane's nor WebKit's default.
  func testEachPaneHasItsOwnNonPersistentStore() async throws {
    let first = try await MarkdownRig.make()
    let second = try await MarkdownRig.make()

    defer {
      first.close()
      second.close()
    }

    let one = first.view.webView.configuration.websiteDataStore
    let two = second.view.webView.configuration.websiteDataStore

    XCTAssertFalse(one.isPersistent)
    XCTAssertFalse(two.isPersistent)
    XCTAssertFalse(one === two)
    XCTAssertFalse(one === WKWebsiteDataStore.default())
    XCTAssertFalse(
      first.view.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
  }

  /// Catches a web view that takes file drops itself and loads the file, which would bypass the
  /// pane's one-file rule.
  func testTheWebViewRegistersForNoDrops() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    rig.window.orderBack(nil)

    let shown = await rig.show("text")
    XCTAssertTrue(shown)
    XCTAssertTrue(rig.view.webView.registeredDraggedTypes.isEmpty)
  }

  // MARK: Anchors

  private func tallDocument() -> String {
    (0..<400).map { "## Heading \($0)\n\nparagraph \($0) with some words in it.\n" }
      .joined(separator: "\n")
  }

  /// Catches a scroll position that is lost or misread: a restored anchor lands on its block, the
  /// page reports a scroll, and the report names the block at the top.
  func testAnAnchorRestoresAndScrollsAreReported() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    // Heading n starts at line 4n, so line 800 is heading 200.
    let shown = await rig.show(tallDocument(), anchor: MarkdownAnchor(line: 800, fraction: 0))
    XCTAssertTrue(shown)

    let anchor = rig.view.anchor
    XCTAssertEqual(anchor?.line, 800)
    XCTAssertLessThan(anchor?.fraction ?? 1, 0.05)

    rig.window.orderBack(nil)

    _ = await rig.eval("window.scrollTo(0, 0); return 1")

    let reported = await rig.eventually { rig.view.anchor?.line == 0 }
    XCTAssertTrue(reported, "\(String(describing: rig.view.anchor))")
  }

  /// Catches an anchor that reopening at another width loses: the same block is at the top.
  func testTheSameBlockIsAtTheTopAtAnotherWidth() async throws {
    let narrow = try await MarkdownRig.make(width: 420)
    let wide = try await MarkdownRig.make(width: 1100)

    defer {
      narrow.close()
      wide.close()
    }

    let text = tallDocument()
    let target = MarkdownAnchor(line: 1200, fraction: 0)

    let a = await narrow.show(text, anchor: target)
    let b = await wide.show(text, anchor: target)

    XCTAssertTrue(a && b)
    XCTAssertEqual(narrow.view.anchor?.line, 1200)
    XCTAssertEqual(wide.view.anchor?.line, 1200)
  }

  /// Catches an anchor taken from markup the document wrote. A top block of raw HTML that carries
  /// data attributes naming other lines still reports its own source line, and it restores within
  /// itself by fraction.
  func testDocumentAttributesCannotForgeAnAnchorAndAHTMLBlockRestores() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let lines = (0..<80).map {
      "<p data-line=\"500\" data-source-line=\"500\" data-um-line=\"500\">row \($0)</p>"
    }
    let text = lines.joined(separator: "\n") + "\n\n" + tallDocument()

    let shown = await rig.show(text, anchor: MarkdownAnchor(line: 0, fraction: 0.5))
    XCTAssertTrue(shown)

    let anchor = rig.view.anchor

    XCTAssertEqual(anchor?.line, 0, "the top block is the raw HTML block, at its own line")
    XCTAssertEqual(anchor?.fraction ?? 0, 0.5, accuracy: 0.1)

    let attributes = await rig.count("[data-line],[data-source-line],[data-um-line]")
    XCTAssertEqual(attributes, 0)
  }

  // MARK: Recovery

  /// Catches a dead content process that leaves the pane blank. The view says so, and showing the
  /// document again recovers it.
  func testAnEndedContentProcessIsReportedAndShowRecovers() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let shown = await rig.show("# Alive")
    XCTAssertTrue(shown)
    XCTAssertTrue(rig.killContentProcess())

    let reported = await rig.eventually { rig.terminations == 1 }
    XCTAssertTrue(reported)
    XCTAssertFalse(rig.view.isRendered)

    let again = await rig.show("# Back")
    XCTAssertTrue(again)

    let count = await rig.count("h1")
    XCTAssertEqual(count, 1)
  }

  // MARK: Size

  /// Catches a parse that runs on the main thread. A 20 MB document renders in WebKit's content
  /// process while the main run loop keeps turning, so no gap between turns passes half a second.
  func testATwentyMegabyteDocumentNeverStallsTheMainThread() async throws {
    let rig = try await MarkdownRig.make()
    defer { rig.close() }

    let paragraph = "The quick brown fox jumps over the lazy dog, and then it does so again.\n\n"
    let count = (20 << 20) / paragraph.utf8.count + 1
    let text = String(repeating: paragraph, count: count)

    XCTAssertGreaterThanOrEqual(text.utf8.count, 20 << 20)

    let before = rig.renders

    rig.view.show(document: MarkdownDocument(text: Data(text.utf8), folder: nil), anchor: nil)

    var longest = Duration.zero
    var last = ContinuousClock.now
    let started = last
    let deadline = last + .seconds(180)

    while rig.renders == before, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))

      let now = ContinuousClock.now
      longest = max(longest, now - last)
      last = now
    }

    let elapsed = ContinuousClock.now - started
    print("20 MB Markdown: rendered in \(elapsed), longest main-thread gap \(longest)")

    XCTAssertGreaterThan(rig.renders, before, "the page rendered")
    XCTAssertLessThan(longest, .milliseconds(500))
  }
}
