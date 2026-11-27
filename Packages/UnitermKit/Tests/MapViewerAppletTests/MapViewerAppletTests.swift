import AppKit
import AppletKit
import AppletTestSupport
import GeoData
import MapKit
import StatusKit
import Theme
import XCTest

@testable import MapViewerApplet

/// The applet through its public contract: styles, palette, region, restore, and describe.
@MainActor
final class MapViewerAppletTests: XCTestCase {
  private func region(_ latitude: Double, _ longitude: Double, _ delta: Double = 1) -> GeoRegion {
    GeoRegion(
      center: GeoCoordinate(latitude: latitude, longitude: longitude),
      span: GeoSpan(latitudeDelta: delta, longitudeDelta: delta))!
  }

  private func configurationName(_ applet: MapViewerApplet) -> String {
    switch applet.content.mapView.preferredConfiguration {
    case is MKHybridMapConfiguration: return "hybrid"
    case is MKImageryMapConfiguration: return "satellite"
    case is MKStandardMapConfiguration: return "standard"
    default: return "other"
    }
  }

  private func restore(_ description: MapViewerDescription) throws -> MapViewerApplet {
    try MapViewerApplet(restoring: description.appletDescription())
  }

  // MARK: Styles

  /// Catches a style command that does not reach the map, one that is not stored, or one that
  /// does not tell the pane. Each style maps to its MapKit configuration, the status bar names it,
  /// and a repeat of the same style does not rewrite the layout.
  func testEachStyleCommandSwitchesTheMapAndIsDescribed() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    XCTAssertEqual(configurationName(applet), "standard")
    XCTAssertEqual(applet.segments.map(\.text), ["Standard"])

    let commands = Dictionary(
      uniqueKeysWithValues: MapViewerApplet.commandSet.commands.map { ($0.name, $0) })

    for (name, expected, label) in [
      ("style-satellite", "satellite", "Satellite"), ("style-hybrid", "hybrid", "Hybrid"),
      ("style-standard", "standard", "Standard"),
    ] {
      let before = host.changes

      try XCTUnwrap(commands[name]).run(applet)

      XCTAssertEqual(configurationName(applet), expected, name)
      XCTAssertEqual(applet.segments.map(\.text), [label], name)
      XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).style.rawValue, expected)
      XCTAssertEqual(host.changes, before + 1, name)
    }

    let before = host.changes

    try XCTUnwrap(commands["style-standard"]).run(applet)

    XCTAssertEqual(host.changes, before)
  }

  /// Catches a stored style that does not come back as the map's configuration, and an unknown one
  /// that does not show the standard map.
  func testRestoringShowsTheStoredStyleAndAnUnknownOneShowsStandard() throws {
    for style in MapStyle.allCases {
      let applet = try restore(MapViewerDescription(style: style))

      XCTAssertEqual(configurationName(applet), style.rawValue)
    }

    let unknown = AppletDescription(
      type: "map-viewer", version: 1, payload: .object(["style": .string("terrain")]))
    let applet = try MapViewerApplet(restoring: unknown)

    XCTAssertEqual(configurationName(applet), "standard")
  }

  // MARK: Palette

  /// Catches a map that inherits its window's appearance, and a flavor that maps to the wrong
  /// look. Every flavor sets the map's own appearance, and a switch flips it with no relaunch.
  func testThePaletteSetsTheMapsAppearanceForEveryFlavor() {
    let applet = MapViewerApplet(startDirectory: nil)

    XCTAssertFalse(ThemeFlavor.allCases.isEmpty)

    for flavor in ThemeFlavor.allCases + ThemeFlavor.allCases.reversed() {
      applet.apply(ThemePalette(flavor: flavor))

      let name = applet.content.appearance?.name

      XCTAssertEqual(name, flavor.isDark ? .darkAqua : .aqua, "\(flavor)")
    }

    applet.apply(.mocha)
    XCTAssertEqual(applet.content.appearance?.name, .darkAqua)

    applet.apply(.latte)
    XCTAssertEqual(applet.content.appearance?.name, .aqua)
  }

  // MARK: Region

  /// Catches a region saved at every frame, a region the user moved that is not described, and a
  /// stored region that restores out of place. The delegate's settle is the only trigger, and a
  /// settle on the region already stored tells the pane nothing.
  func testASettledRegionIsDescribedOnceAndTellsThePane() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    XCTAssertNil(try MapViewerDescription.decode(applet.describe()).region)

    let moved = region(10, 20, 2)
    applet.content.onRegionSettled?(moved)

    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).region, moved)
    XCTAssertEqual(host.changes, 1)

    applet.content.onRegionSettled?(moved)
    applet.content.onRegionSettled?(region(10.0001, 20.0001, 2))

    XCTAssertEqual(host.changes, 1)

    applet.content.onRegionSettled?(region(11, 20, 2))

    XCTAssertEqual(host.changes, 2)
  }

  /// Lays the pane out at a real size, as a window would.
  private func layOut(_ applet: MapViewerApplet, width: Double = 600, height: Double = 400) {
    applet.content.frame = NSRect(x: 0, y: 0, width: width, height: height)
    applet.content.layoutSubtreeIfNeeded()
  }

  /// Reports the region the map shows now, as MapKit's delegate does after a settle.
  private func settle(_ applet: MapViewerApplet) {
    applet.content.mapView(applet.content.mapView, regionDidChangeAnimated: false)
  }

  /// A move by the user: the gesture, then the map's own settle.
  private func move(_ applet: MapViewerApplet, toLatitude latitude: Double) {
    applet.content.noteUserGesture()
    applet.content.mapView.setRegion(
      MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: latitude, longitude: 2.35),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)),
      animated: false)
    settle(applet)
  }

  /// Catches a user move that never reaches the pane, and a settle reported twice. A move reports
  /// once, with the region the map shows, and a settle with no gesture before it reports nothing.
  func testAMoveByTheUserIsReportedOnce() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    layOut(applet)
    move(applet, toLatitude: 48.85)

    XCTAssertEqual(host.changes, 1)
    XCTAssertEqual(
      try XCTUnwrap(MapViewerDescription.decode(applet.describe()).region).center.latitude, 48.85,
      accuracy: 0.01)

    settle(applet)

    XCTAssertEqual(host.changes, 1)

    move(applet, toLatitude: 49.5)

    XCTAssertEqual(host.changes, 2)
  }

  private func command(_ name: String) throws -> AppletCommand {
    try XCTUnwrap(MapViewerApplet.commandSet.commands.first { $0.name == name }, name)
  }

  /// Catches a zoom command that moves the wrong way, zooms by a different step each time, or is
  /// not saved. Zoom In halves the camera's distance and Zoom Out doubles it. The map's settle
  /// after each one is the user's move, so the layout records it.
  func testZoomCommandsStepTheCameraAndAreSaved() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host
    applet.content.animatesCommands = false

    layOut(applet)
    move(applet, toLatitude: 48.85)

    let start = applet.content.mapView.camera.centerCoordinateDistance
    let startSpan = try XCTUnwrap(MapViewerDescription.decode(applet.describe()).region).span

    try command("zoom-in").run(applet)
    settle(applet)

    XCTAssertEqual(
      applet.content.mapView.camera.centerCoordinateDistance, start / 2, accuracy: start * 0.01)
    XCTAssertEqual(host.changes, 2)
    XCTAssertLessThan(
      try XCTUnwrap(MapViewerDescription.decode(applet.describe()).region).span.latitudeDelta,
      startSpan.latitudeDelta * 0.75)

    try command("zoom-out").run(applet)
    settle(applet)

    XCTAssertEqual(
      applet.content.mapView.camera.centerCoordinateDistance, start, accuracy: start * 0.01)
    XCTAssertEqual(host.changes, 3)
  }

  /// Catches a Face North that leaves the map turned, or one offered on a map that already faces
  /// north.
  func testFaceNorthTurnsTheMapBackAndIsOfferedOnlyWhenTurned() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    applet.content.animatesCommands = false
    let north = try command("face-north")

    layOut(applet)
    move(applet, toLatitude: 48.85)

    XCTAssertFalse(north.isAvailable(applet))

    let turned = applet.content.mapView.camera.copy() as! MKMapCamera
    turned.heading = 90
    applet.content.mapView.setCamera(turned, animated: false)

    XCTAssertTrue(north.isAvailable(applet))

    north.run(applet)

    XCTAssertEqual(applet.content.mapView.camera.heading, 0, accuracy: 0.001)
    XCTAssertFalse(north.isAvailable(applet))
  }

  /// Catches a restore, a resize, or MapKit's own default region that rewrites a pane nobody
  /// touched, and a gesture that goes unreported. MapKit reports a region after each of those, in
  /// any number, and none follows a gesture. Removing the gesture gate makes the first settle
  /// report a change.
  func testSettlesWithNoGestureAreIgnored() throws {
    let stored = region(35, 139, 0.4)
    let restored = try restore(MapViewerDescription(region: stored))
    let empty = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    restored.host = host
    empty.host = host

    for applet in [restored, empty] {
      layOut(applet)

      for _ in 0..<3 { settle(applet) }

      layOut(applet, width: 800, height: 500)
      settle(applet)
    }

    XCTAssertEqual(host.changes, 0)
    XCTAssertEqual(try MapViewerDescription.decode(restored.describe()).region, stored)
    XCTAssertNil(try MapViewerDescription.decode(empty.describe()).region)

    move(restored, toLatitude: 36)

    XCTAssertEqual(host.changes, 1)
  }

  /// Catches a gesture that moved nothing and leaves its mark behind. A click, or a command key
  /// such as Cmd-O, is a gesture the map does not act on. A resize after it must not save the
  /// layout, and neither must a region the pane sets itself, such as the fit after a file load.
  func testAGestureThatMovesNothingDoesNotClaimALaterProgrammaticSettle() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    layOut(applet)

    applet.content.noteUserGesture()
    layOut(applet, width: 800, height: 500)
    settle(applet)

    XCTAssertEqual(host.changes, 0, "a resize after a click saved the layout")

    applet.content.noteUserGesture()
    applet.content.show(region: region(48.85, 2.35, 0.5))
    settle(applet)

    XCTAssertEqual(host.changes, 0, "a fit after a click saved the layout")
    XCTAssertNil(try MapViewerDescription.decode(applet.describe()).region)
  }

  /// Catches a command key that counts as a map gesture. Cmd-O and Cmd-K reach the map while it
  /// has focus, and neither moves it. An arrow key does.
  func testACommandKeyIsNotAMapGesture() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.contentView = applet.content
    window.makeFirstResponder(applet.content.mapView)

    func key(_ flags: NSEvent.ModifierFlags, _ characters: String) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    try XCTSkipUnless(try key([], "a").window === window, "the test window has no number")

    applet.content.observe(try key(.command, "o"))

    XCTAssertFalse(applet.content.userIsMoving)

    applet.content.observe(try key([], String(UnicodeScalar(NSLeftArrowFunctionKey)!)))

    XCTAssertTrue(applet.content.userIsMoving)
  }

  /// Catches a restored region that matches the map already showing, where MapKit may report
  /// nothing. No flag waits for a report, so the user's first move still counts.
  func testARestoredRegionThatChangesNothingDoesNotSwallowTheFirstMove() throws {
    let applet = try restore(MapViewerDescription(region: region(35, 139, 0.4)))
    let host = RecordingHost()
    applet.host = host

    layOut(applet)
    applet.content.show(region: region(35, 139, 0.4))
    move(applet, toLatitude: 36)

    XCTAssertEqual(host.changes, 1)
  }

  // MARK: Describe

  /// Catches a describe that touches the disk or changes state. Two calls on an unchanged pane
  /// are equal, and the pane's folder is never read to answer, so a folder that does not exist
  /// still describes.
  func testDescribeReadsMemoryOnlyAndRepeats() {
    let applet = MapViewerApplet(startDirectory: "/uniterm-no-such-folder")

    XCTAssertEqual(applet.describe(), applet.describe())

    applet.content.onRegionSettled?(region(1, 2))
    applet.apply(.mocha)

    XCTAssertEqual(applet.describe(), applet.describe())
  }

  /// Catches a restore that changes the description. A reopen or a relaunch rebuilds the pane from
  /// its description, and the new pane describes itself the same way.
  func testARestoredPaneDescribesItselfAsItWasSaved() throws {
    let original = MapViewerDescription(
      startDirectory: "/work", region: region(51.5, -0.12, 0.3), style: .satellite,
      commandLayerCount: 3)
    let applet = try restore(original)

    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()), original)
    XCTAssertEqual(applet.describe(), try original.appletDescription())
  }

  /// Catches a restore that runs anything. A description that names a file never reads it in
  /// this milestone, so a missing file restores as it was saved.
  func testRestoringNamesNoFileToRead() throws {
    let original = MapViewerDescription(
      startDirectory: "/work", path: "/uniterm-no-such-file.geojson", bookmark: Data([9]))
    let applet = try restore(original)

    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()), original)
  }

  // MARK: Directory

  /// Catches an empty pane that loses its start directory, a start directory that no longer
  /// exists being reported, and an open file's folder losing to it.
  func testTheCurrentDirectoryIsTheFileFolderThenTheStartDirectory() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-map-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    XCTAssertEqual(MapViewerApplet(startDirectory: folder.path).currentDirectory, folder.path)
    XCTAssertNil(MapViewerApplet(startDirectory: folder.path + "/gone").currentDirectory)
    XCTAssertNil(MapViewerApplet(startDirectory: nil).currentDirectory)

    let reopened = try restore(MapViewerDescription(startDirectory: folder.path))

    XCTAssertEqual(reopened.currentDirectory, folder.path)

    let withFile = try restore(
      MapViewerDescription(startDirectory: "/", path: folder.path + "/places.geojson"))

    XCTAssertEqual(withFile.currentDirectory, folder.path)
  }

  // MARK: Failure

  /// Catches a map whose tiles fail to load and says nothing, a banner over the map, and a
  /// warning posted again on each of MapKit's failure reports. One warning goes to the status bar
  /// per outage, and a segment says so until the map loads. The next outage posts again.
  func testATileFailurePostsOnceAndShowsASegmentUntilTheMapLoads() {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    let error = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
      userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
    let failing = {
      applet.content.mapViewDidFailLoadingMap(applet.content.mapView, withError: error)
    }
    let notLoading = { applet.segments.filter { $0.text == "Map not loading" } }

    let before = host.changes
    failing()
    failing()

    XCTAssertEqual(host.changes, before + 1, "the bar was not told the segment changed")
    XCTAssertEqual(host.posts.map(\.level), [.warning])
    XCTAssertTrue(host.posts.first?.text.contains("offline") == true)
    XCTAssertEqual(notLoading().map(\.style), [.warning], "\(applet.segments)")
    XCTAssertEqual(
      visibleText(in: applet.content).filter { $0.contains("could not load") }, [],
      "the failure covers the map")

    applet.content.mapViewDidFinishLoadingMap(applet.content.mapView)

    XCTAssertEqual(notLoading().count, 0)

    failing()

    XCTAssertEqual(host.posts.count, 2, "a new outage did not post")
  }

  private func visibleText(in view: NSView) -> [String] {
    var texts: [String] = []

    if let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor {
      texts.append(field.stringValue)
    }

    for subview in view.subviews { texts += visibleText(in: subview) }

    return texts
  }

  // MARK: Contract

  /// Catches an applet that claims to run something, which would make closing it ask first.
  func testTheMapIsNeverRunningSomethingAndClosesCleanly() {
    let applet = MapViewerApplet(startDirectory: nil)

    XCTAssertFalse(applet.isRunningSomething)
    XCTAssertEqual(applet.runningLabels, [])
    XCTAssertEqual(applet.typeID, "map-viewer")
    XCTAssertEqual(applet.title, "Map")

    applet.start(origin: .user)
    applet.close()
    applet.content.onRegionSettled?(region(1, 1))
  }
}
