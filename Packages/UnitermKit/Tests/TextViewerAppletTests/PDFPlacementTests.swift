import AppKit
import DocumentTestSupport
import PDFKit
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// Proves where a PDF lands in the view. A page's coordinates start at its bottom left, so the top
/// of the view in page space is `currentDestination.point.y`, and a page 792 points tall has its
/// top edge at 792.
@MainActor
final class PDFPlacementTests: XCTestCase {
  private var windows: [NSWindow] = []

  private func host(_ applet: TextViewerApplet) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.contentView = applet.content
    windows.append(window)
  }

  private func topY(_ applet: TextViewerApplet) -> CGFloat? {
    applet.content.pdfView.currentDestination?.point.y
  }

  private func file(in scratch: Scratch) throws -> URL {
    try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["one", "two"]))
  }

  /// Catches a PDF that opens scrolled into its first page. The page's top edge, with PDFKit's page
  /// break margin, shows whether the pane was opened fresh, restored into a pane that already had a
  /// size, or restored into one that was sized later.
  func testAPDFWithNoAnchorStartsAtTheTopHoweverItArrives() async throws {
    let scratch = try Scratch(self)
    let path = try file(in: scratch)
    let pageTop: CGFloat = 792

    let fresh = Harness.applet(startDirectory: scratch.url.path)
    host(fresh)
    try fresh.replaceSource(with: path, startDirectory: scratch.url.path)
    _ = await Harness.settled(fresh)

    let sizedFirst = try Harness.restored(
      TextViewerDescription(startDirectory: scratch.url.path, path: path.path))
    host(sizedFirst)
    sizedFirst.start(origin: .restore)
    _ = await Harness.settled(sizedFirst)

    let sizedLater = try Harness.restored(
      TextViewerDescription(startDirectory: scratch.url.path, path: path.path))
    sizedLater.start(origin: .restore)
    _ = await Harness.settled(sizedLater)
    host(sizedLater)

    for (name, applet) in [
      ("fresh", fresh), ("sized first", sizedFirst), ("sized later", sizedLater),
    ] {
      let atTop = await Harness.eventually(seconds: 1.5) { (self.topY(applet) ?? 0) >= pageTop }

      XCTAssertTrue(atTop, "\(name) opened at y \(topY(applet) ?? -1), not at the top of the page")
    }

    let heights = [fresh, sizedFirst, sizedLater].map { topY($0) ?? 0 }

    XCTAssertEqual(heights[0], heights[1], accuracy: 1)
    XCTAssertEqual(heights[0], heights[2], accuracy: 1)
  }

  /// Catches an anchored restore that lands the stored point somewhere else. The point comes back
  /// where it was saved, in a pane sized before or after the load, and after a reload.
  func testAnAnchoredRestoreAndAReloadKeepTheStoredPoint() async throws {
    let scratch = try Scratch(self)
    let path = try file(in: scratch)

    for sizedFirst in [true, false] {
      let applet = try Harness.restored(
        TextViewerDescription(
          startDirectory: scratch.url.path, path: path.path,
          anchor: .pdf(page: 1, x: 72, y: 500)))

      if sizedFirst { host(applet) }

      applet.start(origin: .restore)
      _ = await Harness.settled(applet)

      if !sizedFirst { host(applet) }

      let landed = await Harness.eventually(seconds: 1.5) {
        abs((self.topY(applet) ?? 0) - 500) < 1
          && applet.content.pdfView.currentPage.flatMap {
            applet.content.pdfView.document?.index(for: $0)
          } == 1
      }

      XCTAssertTrue(landed, "sized first \(sizedFirst): y \(topY(applet) ?? -1)")

      let saved = try TextViewerDescription.decode(applet.describe()).anchor

      XCTAssertEqual(saved?.page, 1)
      XCTAssertEqual(saved?.y ?? 0, 500, accuracy: 1)

      applet.reload()
      _ = await Harness.settled(applet)

      let kept = await Harness.eventually(seconds: 1.5) { abs((self.topY(applet) ?? 0) - 500) < 1 }

      XCTAssertTrue(kept, "sized first \(sizedFirst), after reload: y \(topY(applet) ?? -1)")
    }
  }
}
