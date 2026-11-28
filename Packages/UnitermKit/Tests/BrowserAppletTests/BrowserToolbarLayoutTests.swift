import AppKit
import AppletKit
import XCTest

@testable import BrowserApplet

/// The toolbar of a real browser view, laid out in a window, and measured through converted frames
/// and the rects the buttons draw their glyphs in.
///
/// A stack view's own vertical insets sit at a priority just under its hugging priority, so the
/// stack shrank to the field's height. The field then filled the toolbar edge to edge and the page
/// began at its lower edge. These tests catch that and any layout that clips the field.
@MainActor
final class BrowserToolbarLayoutTests: XCTestCase {
  private static let padding: CGFloat = 6

  private func make(height: CGFloat, tabs: Int) -> (NSWindow, BrowserView, NSView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    let view = BrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: height))
    let page = NSView()

    window.isReleasedWhenClosed = false
    window.contentView = view
    view.show(page: page)
    view.show(
      tabs: (0..<tabs).map { _ in AppletTab(id: .make(), title: "Tab") }, selected: 0)
    view.layoutSubtreeIfNeeded()

    return (window, view, page)
  }

  private func check(
    height: CGFloat, tabs: Int, file: StaticString = #filePath, line: UInt = #line
  ) {
    let (window, view, page) = make(height: height, tabs: tabs)
    defer { window.close() }

    func frame(_ other: NSView) -> NSRect { view.convert(other.bounds, from: other) }

    let toolbar = frame(view.toolbar)
    let field = frame(view.addressField)
    let name = "height \(height), \(tabs) tab(s)"

    XCTAssertGreaterThanOrEqual(
      toolbar.maxY - field.maxY, Self.padding - 0.5, "no padding above the field, \(name)",
      file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      field.minY - toolbar.minY, Self.padding - 0.5, "no padding below the field, \(name)",
      file: file, line: line)
    XCTAssertEqual(
      toolbar.height, field.height + 2 * Self.padding, accuracy: 0.5,
      "the toolbar lost its height, \(name)", file: file, line: line)

    XCTAssertLessThanOrEqual(
      frame(page).maxY, toolbar.minY + 0.5, "the page starts inside the toolbar, \(name)",
      file: file, line: line)

    // A button's frame carries its bezel's alignment insets, which differ from symbol to symbol,
    // so a frame's centre is not where its glyph is drawn. The line is measured on the rect the
    // button's cell draws its image in. The field draws no image, so its frame stands for it.
    func drawn(_ other: NSView) -> NSRect {
      guard let button = other as? NSButton, let cell = button.cell else { return frame(other) }

      return view.convert(cell.imageRect(forBounds: button.bounds), from: button)
    }

    let controls: [NSView] = [
      view.backButton, view.forwardButton, view.reloadButton, view.addressField,
      view.profileButton,
    ]
    let centers = controls.map { drawn($0).midY }

    // An odd-height control lands on a whole point at 1x, so its centre can sit a point off.

    for center in centers {
      XCTAssertEqual(
        center, toolbar.midY, accuracy: 1, "a control is off the line, \(name)", file: file,
        line: line)
    }

    let frames = controls.map(frame)

    for (left, right) in zip(frames, frames.dropFirst()) {
      XCTAssertEqual(
        right.minX - left.maxX, 6, accuracy: 0.5, "uneven spacing, \(name)", file: file,
        line: line)
    }
  }

  func testTheFieldSitsInsideTheToolbarWithItsPaddingAndTheControlsShareALine() {
    check(height: 400, tabs: 1)
  }

  func testTheToolbarKeepsItsHeightBelowTheTabBar() {
    check(height: 400, tabs: 3)
  }

  func testAShortPaneKeepsTheToolbarWholeAndLetsThePageGiveWay() {
    check(height: 30, tabs: 1)
    check(height: 50, tabs: 3)
  }

  func testTheToolbarCarriesItsIdentifier() {
    let (window, view, _) = make(height: 400, tabs: 1)
    defer { window.close() }

    XCTAssertEqual(view.toolbar.accessibilityIdentifier(), "browser-toolbar")
  }
}
