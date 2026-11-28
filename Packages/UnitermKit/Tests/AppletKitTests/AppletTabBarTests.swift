import AppKit
import XCTest

@testable import AppletKit

/// The shared tab bar, with real views at real sizes. These prove the bar's own layout and the
/// markers it draws. Whether each symbol resolves on the app's minimum macOS is for a person to
/// check, since these run on the machine's own system.
@MainActor
final class AppletTabBarTests: XCTestCase {
  private func tabs(_ count: Int, markers: [Int: [AppletMarker]] = [:]) -> [AppletTab] {
    (0..<count).map {
      AppletTab(id: .make(), title: "Tab \($0)", markers: AppletMarkerSet(markers[$0] ?? []))
    }
  }

  private func makeBar(
    width: CGFloat, tabs list: [AppletTab], selected: Int = 0, canOpenTab: Bool = true
  ) -> AppletTabBar {
    let bar = AppletTabBar(frame: NSRect(x: 0, y: 0, width: width, height: AppletTabBar.height))

    bar.update(tabs: list, selected: selected, canOpenTab: canOpenTab)
    bar.layoutSubtreeIfNeeded()

    return bar
  }

  private func assertInView(
    _ bar: AppletTabBar, tab index: Int, newButtonHidden: Bool = false,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let frame = bar.frame(ofTab: index)

    XCTAssertGreaterThanOrEqual(
      frame.minX, bar.viewport.minX - 0.5, "tab \(index)", file: file, line: line)
    XCTAssertLessThanOrEqual(
      frame.maxX, bar.viewport.maxX + 0.5, "tab \(index)", file: file, line: line)

    guard !newButtonHidden else { return }

    XCTAssertLessThanOrEqual(
      bar.viewport.maxX, bar.frameOfNewButton.minX + 0.5, "the viewport reaches the new-tab button",
      file: file, line: line)
  }

  // MARK: Overflow

  /// Catches tabs laid out past the bar's trailing edge, out of reach. Eight tabs in a bar 500
  /// points wide need more than the bar has. Every tab must be reachable by scrolling, the
  /// selected one must start in view, and the new-tab button must stay inside the bar.
  func testEightTabsInAFiveHundredPointBarAreAllReachable() {
    let bar = makeBar(width: 500, tabs: tabs(8), selected: 7)

    assertInView(bar, tab: 7)
    XCTAssertLessThanOrEqual(bar.frameOfNewButton.maxX, bar.bounds.width)

    bar.scroll(by: -10_000)

    assertInView(bar, tab: 0)
    XCTAssertEqual(bar.scrollOffset, 0)

    bar.scroll(by: 10_000)

    assertInView(bar, tab: 7)
  }

  /// Catches a bar that scrolls with no cue. A fade shows at each edge that has more tabs past it,
  /// and not at an edge where the tabs end.
  func testAnEdgeFadeShowsOnlyWhereMoreTabsLiePastIt() {
    let bar = makeBar(width: 500, tabs: tabs(8), selected: 0)

    XCTAssertFalse(bar.isLeadingFadeShowing)
    XCTAssertTrue(bar.isTrailingFadeShowing)

    bar.scroll(by: 10_000)

    XCTAssertTrue(bar.isLeadingFadeShowing)
    XCTAssertFalse(bar.isTrailingFadeShowing)

    let fits = makeBar(width: 500, tabs: tabs(3))

    XCTAssertFalse(fits.isLeadingFadeShowing)
    XCTAssertFalse(fits.isTrailingFadeShowing)
  }

  /// Catches a selection that leaves its tab out of view. A tab selected from the keyboard or the
  /// palette, a tab that opens, and a pane that shrinks each bring the selected tab fully in view,
  /// with its marker slot, clear of the new-tab button.
  func testTheSelectedTabIsFullyInViewAfterSelectionOpenAndResize() {
    let marker = AppletMarker(kind: .authority)
    var list = tabs(8, markers: [5: [marker]])
    let bar = makeBar(width: 500, tabs: list, selected: 0)

    bar.update(tabs: list, selected: 5, canOpenTab: true)
    bar.layoutSubtreeIfNeeded()
    assertInView(bar, tab: 5)

    for frame in bar.markerFrames(inTab: 5) {
      let tab = bar.frame(ofTab: 5)
      XCTAssertGreaterThanOrEqual(frame.minX, 0)
      XCTAssertLessThanOrEqual(frame.maxX, tab.width)
    }

    bar.update(tabs: list, selected: 0, canOpenTab: true)
    bar.layoutSubtreeIfNeeded()
    assertInView(bar, tab: 0)

    list.append(AppletTab(id: .make(), title: "New"))
    bar.update(tabs: list, selected: 8, canOpenTab: true)
    bar.layoutSubtreeIfNeeded()
    assertInView(bar, tab: 8)

    bar.setFrameSize(NSSize(width: 300, height: AppletTabBar.height))
    bar.layoutSubtreeIfNeeded()
    assertInView(bar, tab: 8)
  }

  /// Catches a bar that a shift-held wheel cannot scroll. A wheel has no sideways part, so Shift
  /// with an upward wheel turn moves the tabs back toward the start, and a downward turn moves them
  /// on. The same wheel without Shift moves nothing.
  func testAShiftHeldWheelScrollsTheTabsSideways() throws {
    let bar = makeBar(width: 500, tabs: tabs(8), selected: 0)
    let scroller = try XCTUnwrap(bar.descendants(ofType: NSScrollView.self).first)

    func wheel(_ delta: Int32, shift: Bool) throws -> NSEvent {
      let cg = try XCTUnwrap(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: 0,
          wheel3: 0))

      cg.flags = shift ? .maskShift : []

      return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    scroller.scrollWheel(with: try wheel(-40, shift: false))

    XCTAssertEqual(bar.scrollOffset, 0)

    scroller.scrollWheel(with: try wheel(-40, shift: true))

    XCTAssertEqual(bar.scrollOffset, 40)

    scroller.scrollWheel(with: try wheel(15, shift: true))

    XCTAssertEqual(bar.scrollOffset, 25)
  }

  /// Catches a selected tab whose marker slot runs under the control badge. The new-tab button is
  /// hidden and the badge reserves 24 points at the trailing edge. The selected tab's markers end
  /// before the reserve, whether the tab starts in view or is scrolled to, and a wider reserve
  /// moves them in.
  func testTheSelectedTabsMarkersStayClearOfTheBadgeWithNoNewTabButton() {
    let marker = AppletMarker(kind: .authority)
    let bar = makeBar(
      width: 500, tabs: tabs(8, markers: [7: [marker], 3: [marker]]), selected: 7,
      canOpenTab: false)

    func markersEnd(ofTab index: Int) -> CGFloat {
      let tab = bar.frame(ofTab: index)

      return tab.minX + (bar.markerFrames(inTab: index).map(\.maxX).max() ?? 0)
    }

    bar.trailingReserve = 24
    bar.layoutSubtreeIfNeeded()

    XCTAssertLessThanOrEqual(markersEnd(ofTab: 7), bar.bounds.width - 24)
    assertInView(bar, tab: 7, newButtonHidden: true)

    bar.update(tabs: tabs(8, markers: [7: [marker], 3: [marker]]), selected: 3, canOpenTab: false)
    bar.layoutSubtreeIfNeeded()

    XCTAssertLessThanOrEqual(markersEnd(ofTab: 3), bar.bounds.width - 24)

    bar.trailingReserve = 60
    bar.layoutSubtreeIfNeeded()

    XCTAssertLessThanOrEqual(markersEnd(ofTab: 3), bar.bounds.width - 60)
  }

  /// Catches a click on a run-end marker in a tab that opens a menu. The click selects the tab,
  /// and the marker carries no menu.
  func testAClickOnARunEndMarkerInATabSelectsTheTabAndOpensNoMenu() throws {
    let bar = makeBar(
      width: 400,
      tabs: tabs(2, markers: [1: [AppletMarker(kind: .runEnded, actions: [.rebuildTab])]]))
    var selected: [Int] = []

    bar.onSelect = { selected.append($0) }

    let marker = try XCTUnwrap(bar.descendants(ofType: AppletMarkerView.self).first)
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

    marker.mouseDown(with: event)

    XCTAssertEqual(selected, [1])
    XCTAssertNil(marker.menu)
    XCTAssertEqual(marker.kind, .runEnded)
  }

  /// Catches a layout that snaps the bar back after the user scrolls it. A scroll the user makes
  /// stays until the selection, the tabs, or the size change.
  func testAUserScrollStaysUntilSomethingChanges() {
    let bar = makeBar(width: 500, tabs: tabs(8), selected: 0)

    bar.scroll(by: 120)
    let offset = bar.scrollOffset

    bar.needsLayout = true
    bar.layoutSubtreeIfNeeded()

    XCTAssertEqual(bar.scrollOffset, offset)
  }

  // MARK: Hiding

  /// Catches a bar that shows for one tab. The shared rule hides it below two tabs, and the host
  /// reads the same rule.
  func testTheBarHidesItselfBelowTwoTabs() {
    let bar = makeBar(width: 400, tabs: tabs(1))

    XCTAssertTrue(bar.isHidden)

    bar.update(tabs: tabs(2), selected: 0, canOpenTab: true)
    XCTAssertFalse(bar.isHidden)

    XCTAssertFalse(AppletTabList.barShows(forTabCount: 0))
    XCTAssertFalse(AppletTabList.barShows(forTabCount: 1))
    XCTAssertTrue(AppletTabList.barShows(forTabCount: 2))
  }

  /// Catches a pane-level tab chosen while a bar shows, which would draw a marker twice.
  func testOnlyAListWithoutABarHasAPaneLevelTab() {
    let one = AppletTabList(first: AppletTab(id: .make(), title: "One"))
    let two = AppletTabList(
      first: AppletTab(id: .make(), title: "A"), rest: [AppletTab(id: .make(), title: "B")])

    XCTAssertEqual(one.paneLevelTab, one.first)
    XCTAssertNil(two.paneLevelTab)
  }

  // MARK: Markers

  /// Catches a tab that draws no marker, or draws it under the title. A marked tab shows one image
  /// element per marker, in kind order, with the kind's meaning as tooltip and label and an
  /// identifier keyed by tab index and kind. The tab's value stays selected or unselected.
  func testAMarkedTabDrawsItsMarkersAsLabeledImages() throws {
    let list = tabs(
      2,
      markers: [
        1: [AppletMarker(kind: .runEnded, actions: [.rebuildTab]), AppletMarker(kind: .authority)]
      ])
    let bar = makeBar(width: 400, tabs: list, selected: 1)

    let markers = bar.descendants(ofType: AppletMarkerView.self)

    XCTAssertEqual(markers.map(\.kind), [.authority, .runEnded])
    XCTAssertEqual(
      markers.map { $0.accessibilityIdentifier() },
      ["tab-1-marker-authority", "tab-1-marker-runEnded"])
    XCTAssertEqual(
      markers.map { $0.accessibilityLabel() }, markers.map { $0.kind.accessibilityLabel })
    XCTAssertEqual(markers.map { $0.toolTip ?? "" }, markers.map { $0.kind.meaning })
    XCTAssertTrue(markers.allSatisfy { $0.accessibilityRole() == .image })

    let item = try XCTUnwrap(bar.descendants(ofType: AppletTabItem.self).last)

    XCTAssertEqual(item.accessibilityValue() as? String, "selected")
    XCTAssertEqual(
      bar.descendants(ofType: AppletTabItem.self).first?.accessibilityValue() as? String,
      "unselected")
  }

  /// Catches a tab with no marker that changes. An unmarked tab has no marker views, so it draws
  /// as before.
  func testAnUnmarkedTabDrawsNoMarkerViews() {
    let bar = makeBar(width: 400, tabs: tabs(3))

    XCTAssertTrue(bar.descendants(ofType: AppletMarkerView.self).isEmpty)
  }

  /// Catches a marker cut by a narrow tab. At the narrowest tab width, every marker lies whole
  /// inside the tab, clear of the close button, and the title gives up room instead.
  func testMarkersStayWholeAtTheNarrowestTab() throws {
    let both = [AppletMarker(kind: .authority), AppletMarker(kind: .runEnded)]
    let bar = makeBar(width: 500, tabs: tabs(8, markers: [0: both]))

    let item = try XCTUnwrap(bar.descendants(ofType: AppletTabItem.self).first)
    let close = try XCTUnwrap(item.subviews.first { $0 is NSButton })
    let frames = bar.markerFrames(inTab: 0)

    XCTAssertEqual(item.frame.width, 80)
    XCTAssertEqual(frames.count, 2)

    for frame in frames {
      XCTAssertGreaterThanOrEqual(frame.minX, 0)
      XCTAssertLessThanOrEqual(frame.maxX, close.frame.minX)
      XCTAssertEqual(frame.size, AppletMarkerView.size)
    }

    let label = try XCTUnwrap(item.subviews.first { $0 is NSTextField })

    XCTAssertLessThanOrEqual(label.frame.maxX, frames[0].minX)
  }

  /// Catches a marker that swallows its click. A click on a marker in a tab selects the tab and
  /// opens no menu.
  func testAClickOnAMarkerSelectsItsTab() throws {
    let bar = makeBar(width: 400, tabs: tabs(2, markers: [1: [AppletMarker(kind: .authority)]]))
    var selected: [Int] = []

    bar.onSelect = { selected.append($0) }

    let marker = try XCTUnwrap(bar.descendants(ofType: AppletMarkerView.self).first)
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

    marker.mouseDown(with: event)

    XCTAssertEqual(selected, [1])
  }

  // MARK: Kinds

  /// Catches a kind with no symbol on this machine, or a kind a tab can carry twice. Each kind
  /// resolves its symbol, a set keeps one marker of each kind in kind order, and a kind drops
  /// actions it does not have. This cannot show the symbols exist on the app's minimum macOS.
  func testEachKindResolvesAndASetKeepsOneOfEachInOrder() {
    for kind in AppletMarkerKind.allCases {
      XCTAssertNotNil(
        NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil), "\(kind)")
      XCTAssertFalse(kind.meaning.isEmpty)
      XCTAssertFalse(kind.accessibilityLabel.isEmpty)
    }

    let set = AppletMarkerSet([
      AppletMarker(kind: .runEnded, actions: [.rebuildTab]),
      AppletMarker(kind: .authority, actions: [.rebuildTab]),
      AppletMarker(kind: .runEnded),
    ])

    XCTAssertEqual(set.ordered.map(\.kind), [.authority, .runEnded])
    XCTAssertEqual(set[.authority]?.actions, [])
    XCTAssertEqual(set[.runEnded]?.actions, [])
    XCTAssertEqual(AppletMarker(kind: .runEnded, actions: [.rebuildTab]).actions, [.rebuildTab])
    XCTAssertEqual(AppletMarkerKind.runEnded.possibleActions.map(\.title), ["Rebuild Tab"])
    XCTAssertTrue(AppletMarkerKind.runEnded.isSlashed)
    XCTAssertFalse(AppletMarkerKind.authority.isSlashed)
    XCTAssertNotEqual(
      AppletMarkerKind.authority.accessibilityLabel, AppletMarkerKind.runEnded.accessibilityLabel)
  }

  /// Catches a run-end marker that looks like the live one, or a slash that vanishes. The slashed
  /// picture must differ from the plain gears, and it must keep a transparent gap beside the slash
  /// so it shows on any background. It also writes both pictures, enlarged, to the temporary
  /// folder for a person to look at. A person must still judge the slash against Apple's own.
  func testTheRunEndMarkerDrawsASlashOverTheGears() throws {
    let color = NSColor(srgbRed: 0.98, green: 0.7, blue: 0.53, alpha: 1)
    let size = AppletMarkerView.size

    func render(_ kind: AppletMarkerKind) throws -> NSBitmapImageRep {
      let image = AppletMarkerView.image(for: kind, color: color, size: size)
      let scale = 8
      let rep = try XCTUnwrap(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
          pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0))

      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      NSGraphicsContext.current?.imageInterpolation = .none
      image.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
      NSGraphicsContext.restoreGraphicsState()

      let folder = FileManager.default.temporaryDirectory
      try rep.representation(using: .png, properties: [:])?
        .write(to: folder.appendingPathComponent("marker-\(kind.rawValue).png"))

      return rep
    }

    let plain = try render(.authority)
    let slashed = try render(.runEnded)

    XCTAssertNotEqual(plain.tiffRepresentation, slashed.tiffRepresentation)

    func opaque(_ rep: NSBitmapImageRep) -> Int {
      var count = 0

      for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
          count += 1
        }
      }

      return count
    }

    XCTAssertGreaterThan(opaque(plain), 0)
    XCTAssertGreaterThan(opaque(slashed), 0)
  }

  /// Catches an authority marker that stands for the wrong grants. A tab owned by a grant the host
  /// accepts carries the marker with that owner, and a tab owned by another grant carries none.
  func testAnOwnedTabCarriesTheMarkerOnlyWhileItsOwnerIsGranted() {
    let mine = AppletCaller(grant: "connection 1")
    let other = AppletCaller(grant: "connection 2")
    let authority = PaneAuthority(owners: [mine])

    XCTAssertEqual(authority.marker(forTabOwnedBy: mine)?.owners, [mine])
    XCTAssertNil(authority.marker(forTabOwnedBy: other))
    XCTAssertNil(authority.marker(forTabOwnedBy: nil))
    XCTAssertNil(PaneAuthority.none.marker(forTabOwnedBy: mine))

    let tab = AppletTab(id: .make(), title: "One")

    XCTAssertNotNil(authority.applyingOneTabMarker(to: tab).markers[.authority])
    XCTAssertTrue(
      PaneAuthority.none.applyingOneTabMarker(to: authority.applyingOneTabMarker(to: tab)).markers
        .isEmpty)
  }
}

extension NSView {
  fileprivate func descendants<T: NSView>(ofType type: T.Type) -> [T] {
    subviews.flatMap { ($0 as? T).map { [$0] } ?? [] }
      + subviews.flatMap { $0.descendants(ofType: type) }
  }
}
