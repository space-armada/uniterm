import CryptoKit
import XCTest

@testable import TextViewerApplet

final class MarkdownPureTests: XCTestCase {
  // MARK: Messages

  /// Catches a page message that the host would accept with a wrong shape. A bad kind, a missing
  /// field, a fraction outside 0 through 1, a boolean standing in for a number, and too many headings
  /// are dropped or clamped.
  func testMessagesAreCheckedFieldByField() {
    XCTAssertEqual(MarkdownMessage(body: ["kind": "ready"]), .ready)
    XCTAssertNil(MarkdownMessage(body: ["kind": "other"]))
    XCTAssertNil(MarkdownMessage(body: "ready"))
    XCTAssertNil(MarkdownMessage(body: ["kind": "anchor", "line": 3]))
    XCTAssertNil(MarkdownMessage(body: ["kind": "anchor", "line": true, "fraction": 0.5]))
    XCTAssertNil(MarkdownMessage(body: ["kind": "anchor", "line": -1, "fraction": 0.5]))
    XCTAssertNil(MarkdownMessage(body: ["kind": "anchor", "line": 1.5, "fraction": 0.5]))

    XCTAssertEqual(
      MarkdownMessage(body: ["kind": "anchor", "line": 7, "fraction": 4.0]),
      .anchor(MarkdownAnchor(line: 7, fraction: 1)))

    let heading: [String: Any] = ["level": 2, "text": "Install", "id": "install", "line": 4]

    XCTAssertNil(
      MarkdownMessage(
        body: [
          "kind": "rendered", "lines": 10, "headings": [heading],
          "anchor": ["line": -2, "fraction": 0],
        ] as [String: Any]))

    XCTAssertEqual(
      MarkdownMessage(
        body: ["kind": "rendered", "lines": 10, "headings": [heading]] as [String: Any]),
      .rendered(
        lines: 10, headings: [MarkdownHeading(level: 2, text: "Install", id: "install", line: 4)],
        anchor: nil))

    var wrong = heading
    wrong["level"] = 9

    XCTAssertNil(
      MarkdownMessage(body: ["kind": "rendered", "lines": 1, "headings": [wrong]] as [String: Any]))

    let many = Array(repeating: heading, count: MarkdownMessage.maxHeadings + 1)

    XCTAssertNil(
      MarkdownMessage(body: ["kind": "rendered", "lines": 1, "headings": many] as [String: Any]))
  }

  // MARK: Policy

  /// Catches a policy that loosens: the page may load images, styles, and its own document from its
  /// scheme only, and no script, frame, form, object, or media.
  func testThePolicyAllowsOnlyTheSchemeAndNoScriptFramesFormsObjectsOrMedia() {
    let policy = MarkdownScheme.contentSecurityPolicy
    let directives = Dictionary(
      uniqueKeysWithValues: policy.components(separatedBy: "; ").map { entry -> (String, String) in
        let parts = entry.split(separator: " ", maxSplits: 1).map(String.init)

        return (parts[0], parts.count > 1 ? parts[1] : "")
      })

    XCTAssertEqual(directives["default-src"], "'none'")
    XCTAssertEqual(directives["img-src"], "uniterm-markdown:")
    XCTAssertEqual(directives["script-src"], "'none'")

    for name in ["frame-src", "object-src", "media-src", "form-action", "base-uri"] {
      XCTAssertEqual(directives[name], "'none'", name)
    }
  }

  func testOnlyThePageItselfIsANavigationTheViewerAllows() {
    XCTAssertTrue(MarkdownScheme.isPage(URL(string: "uniterm-markdown://app/index.html")!))
    XCTAssertTrue(MarkdownScheme.isPage(URL(string: "uniterm-markdown://app/index.html#install")!))
    XCTAssertFalse(MarkdownScheme.isPage(URL(string: "uniterm-markdown://app/other.md")!))
    XCTAssertFalse(MarkdownScheme.isPage(URL(string: "uniterm-markdown://evil/index.html")!))
    XCTAssertFalse(MarkdownScheme.isPage(URL(string: "https://app/index.html")!))
  }

  /// Catches a non-image served as an image: only an extension that is an image type has a MIME
  /// type, so a link to a text file or a script loads nothing.
  func testOnlyImageExtensionsAreServed() {
    XCTAssertEqual(MarkdownSchemeHandler.imageType(forName: "a.png"), "image/png")
    XCTAssertEqual(MarkdownSchemeHandler.imageType(forName: "dir/B.JPG"), "image/jpeg")
    XCTAssertEqual(MarkdownSchemeHandler.imageType(forName: "x.svg"), "image/svg+xml")

    for name in ["notes.txt", "run.js", "page.html", "noext", "a.png.txt"] {
      XCTAssertNil(MarkdownSchemeHandler.imageType(forName: name), name)
    }
  }

  // MARK: Pins

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  private func pin() throws -> [String: String] {
    let text = try String(
      contentsOf: repositoryRoot.appendingPathComponent("web-assets.pin"), encoding: .utf8)
    var values: [String: String] = [:]

    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
      let parts = line.split(separator: "=", maxSplits: 1).map(String.init)

      if parts.count == 2 { values[parts[0]] = parts[1] }
    }

    return values
  }

  private func hash(of file: String) throws -> String {
    let url = repositoryRoot.appendingPathComponent(
      "Packages/UnitermKit/Sources/TextViewerApplet/Resources/web/\(file)")
    let data = try Data(contentsOf: url)

    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Catches an edit to a bundled parser or sanitizer that the pin file does not know about, and a
  /// pin edit with no new file behind it. A bump is a reviewed change to both.
  func testTheBundledAssetsMatchTheirPins() throws {
    let pins = try pin()

    XCTAssertEqual(try hash(of: "markdown-it.umd.min.js"), pins["MARKDOWN_IT_SHA256"])
    XCTAssertEqual(try hash(of: "purify.min.js"), pins["DOMPURIFY_SHA256"])
    XCTAssertNotNil(pins["MARKDOWN_IT_VERSION"])
    XCTAssertNotNil(pins["DOMPURIFY_VERSION"])
    XCTAssertNotNil(pins["MARKDOWN_IT_TARBALL_SHA256"])
    XCTAssertNotNil(pins["DOMPURIFY_TARBALL_SHA256"])
    XCTAssertNotNil(pins["ALLOWLIST_SOURCE"])
    XCTAssertNotNil(pins["ALLOWLIST_COMMIT"])
  }

  /// Catches resources that build but never reach the bundle the app reads.
  func testTheBuildCopiesEveryAssetIntoTheBundle() {
    switch MarkdownAssets.shared {
    case .failure(let error):
      XCTFail("missing \(error)")

    case .success(let assets):
      XCTAssertTrue(assets.parser.contains("markdownit"))
      XCTAssertTrue(assets.sanitizer.contains("DOMPurify"))
      XCTAssertTrue(assets.viewer.contains("umViewer"))
      XCTAssertTrue(assets.page.contains("um-root"))
    }
  }
}
