import AppKit
import AppletKit
import AppletTestSupport
import Foundation
import GeoData
import MapKit
import StatusKit
import XCTest

@testable import MapViewerApplet

/// How the map's alerts reach the bar, and what a restore load says.
@MainActor
final class MapAlertsTests: XCTestCase {
  private func mixedFile(_ scratch: GeoScratch) throws -> URL {
    try scratch.write(
      "places.geojson",
      GeoFixtures.collection([GeoFixtures.point("A", 1, 1), GeoFixtures.line]))
  }

  private func restored(
    path: URL, host: RecordingHost
  ) throws -> MapViewerApplet {
    let applet = try MapViewerApplet(
      restoring: MapViewerDescription(path: path.path).appletDescription())

    applet.host = host

    return applet
  }

  // MARK: Restore

  /// Catches a restore load whose warning takes a turn on the bar, or whose info does. At launch,
  /// restore-origin info goes to the history only, and a warning raises attention without a turn.
  /// The origin must survive the asynchronous open, which settles after `start` returns.
  func testARestoreLoadRecordsInfoAndWarnsWithoutATurn() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let host = RecordingHost()
    let applet = try restored(path: file, host: host)

    applet.start(origin: .restore)

    XCTAssertTrue(host.posts.isEmpty, "nothing has loaded yet")

    await applet.opening?.value

    let warnings = applet.statusNotices.filter { $0.level == .warning }.map(\.text)

    XCTAssertFalse(warnings.isEmpty)
    XCTAssertTrue(host.posts.isEmpty, "\(host.posts)")
    XCTAssertEqual(host.attentions.map(\.text), warnings)
    XCTAssertTrue(host.records.isEmpty, "restore warnings are recorded by the attention delivery")
  }

  /// Catches a file found at a new path whose info takes a turn at launch.
  func testARestoreLoadOfAMovedFileRecordsItsInfoOnly() async throws {
    let scratch = try GeoScratch(self)
    let old = try scratch.write(
      "old.geojson", GeoFixtures.collection([GeoFixtures.point("Old", 1, 1)]))

    let original = MapViewerApplet(startDirectory: nil)
    original.replaceSource(with: old, startDirectory: scratch.url.path)
    await original.opening?.value

    let description = original.describe()
    try FileManager.default.moveItem(
      at: old, to: scratch.url.appendingPathComponent("moved.geojson"))

    let host = RecordingHost()
    let applet = try MapViewerApplet(restoring: description)
    applet.host = host
    applet.start(origin: .restore)
    await applet.opening?.value

    XCTAssertTrue(host.posts.isEmpty)
    XCTAssertEqual(host.records.map(\.level), [.info])
    XCTAssertTrue(host.records.first?.text.hasPrefix("Moved. Found at") == true)
  }

  /// Catches a restored pane that loses the unsaved-pins error, which is lost work. Restore-origin
  /// errors use ordinary presentation.
  func testARestoreOriginErrorTakesATurn() async throws {
    let missing = "/nonexistent-folder/pins.geojson"
    let unsaved = Data(GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]).utf8)

    let base = try MapViewerDescription(path: missing).appletDescription()
    let description = AppletDescription(
      type: base.type, version: base.version, payload: base.payload,
      undoState: AppletUndoState(
        MapViewerApplet.undoState(document: unsaved, base: nil, path: missing)))

    let host = RecordingHost()
    let applet = try MapViewerApplet(restoring: description)
    applet.host = host
    applet.start(origin: .restore)
    await applet.opening?.value

    XCTAssertEqual(host.posts.map(\.level), [.error])
    XCTAssertEqual(
      host.attentions.map(\.level), [.warning], "the missing file's own warning is a restore one")
  }

  /// Catches a pane reopened by undo that goes quiet. Only the launch restore sets the origin, so
  /// a reopen builds the same way and its notices post normally.
  func testAReopenedPaneThatWasNotToldItIsAtLaunchPostsNormally() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let host = RecordingHost()
    let applet = try restored(path: file, host: host)

    applet.start(origin: .user)
    await applet.opening?.value

    XCTAssertFalse(host.posts.isEmpty)
    XCTAssertTrue(host.attentions.isEmpty)
  }

  // MARK: Later loads

  /// Catches a user load that inherits the restore. The restored pane loads quietly. A file the
  /// user opens afterwards posts normally.
  func testAUserLoadAfterARestoreNeverInheritsIt() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let other = try scratch.write(
      "other.geojson", GeoFixtures.collection([GeoFixtures.point("B", 2, 2), GeoFixtures.line]))

    let host = RecordingHost()
    let applet = try restored(path: file, host: host)

    applet.start(origin: .restore)
    await applet.opening?.value

    XCTAssertTrue(host.posts.isEmpty)

    applet.replaceSource(with: other, startDirectory: scratch.url.path)
    await applet.opening?.value

    XCTAssertFalse(host.posts.isEmpty, "the user's load was treated as a restore")
    XCTAssertTrue(host.posts.allSatisfy { $0.level == .warning })
  }

  /// Catches a replacement that lands while the restore load is still in flight and then takes
  /// the restore's origin. The old load is cancelled, and the new load posts normally.
  func testAReplacementWhileTheRestoreIsInFlightPostsNormally() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let other = try scratch.write(
      "other.geojson", GeoFixtures.collection([GeoFixtures.point("B", 2, 2), GeoFixtures.line]))

    let host = RecordingHost()
    let applet = try restored(path: file, host: host)

    applet.start(origin: .restore)
    applet.replaceSource(with: other, startDirectory: scratch.url.path)
    await applet.opening?.value

    XCTAssertFalse(host.posts.isEmpty)
    XCTAssertTrue(host.attentions.isEmpty, "\(host.attentions)")
  }

  /// Catches a revert or a watcher reload that inherits the restore. Both read the file again, and
  /// both post normally.
  func testAReloadAfterARestorePostsNormally() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let host = RecordingHost()
    let applet = try restored(path: file, host: host)

    applet.start(origin: .restore)
    await applet.opening?.value

    XCTAssertTrue(host.posts.isEmpty)

    applet.revert()
    await applet.opening?.value

    XCTAssertFalse(host.posts.isEmpty, "a revert was treated as a restore")

    let afterRevert = host.posts.count

    try Data(
      GeoFixtures.collection([GeoFixtures.point("C", 3, 3), GeoFixtures.polygon]).utf8
    ).write(to: file)
    applet.fileChangedOnDisk()
    await applet.checkingDisk?.value
    await applet.opening?.value

    XCTAssertGreaterThan(host.posts.count, afterRevert, "a watcher reload was treated as a restore")
  }

  /// Catches a stored flag that taints a later user edit. A restored pane loads clean. The user
  /// then makes an edit whose read-back skips a shape, and that notice posts normally.
  func testAUserEditOnARestoredPaneIsNotTaintedByTheRestore() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "clean.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))

    let host = RecordingHost()
    let applet = try restored(path: file, host: host)

    applet.start(origin: .restore)
    await applet.opening?.value

    XCTAssertTrue(host.posts.isEmpty)
    XCTAssertTrue(host.attentions.isEmpty)

    let edited = Data(
      GeoFixtures.collection([GeoFixtures.point("A", 1, 1), GeoFixtures.line]).utf8)

    applet.replaceDocument(with: edited, registeringUndo: true, actionName: "Edit")
    await applet.editing?.value

    XCTAssertFalse(host.posts.isEmpty, "the edit's notice was treated as a restore")
    XCTAssertTrue(host.attentions.isEmpty)
  }

  /// Catches a tile failure that takes a restore origin. A tile failure is not a load. A restored
  /// pane posts it once per outage like any other.
  func testATileFailureOnARestoredPaneIsNotARestoreNotice() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "clean.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))

    let host = RecordingHost()
    let applet = try restored(path: file, host: host)

    applet.start(origin: .restore)
    await applet.opening?.value

    let error = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
      userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])

    applet.content.mapViewDidFailLoadingMap(applet.content.mapView, withError: error)
    applet.content.mapViewDidFailLoadingMap(applet.content.mapView, withError: error)

    XCTAssertEqual(host.posts.map(\.level), [.warning])
    XCTAssertTrue(host.attentions.isEmpty)
  }

  private func restoredWithUnsavedPins(
    _ scratch: GeoScratch, host: RecordingHost
  ) throws -> MapViewerApplet {
    let file = try scratch.write(
      "pins.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))

    let base = Data(GeoFixtures.collection([GeoFixtures.point("Old", 9, 9)]).utf8)
    let edited = Data(
      GeoFixtures.collection([GeoFixtures.point("Old", 9, 9), GeoFixtures.point("New", 8, 8)])
        .utf8)

    let plain = try MapViewerDescription(path: file.path).appletDescription()
    let description = AppletDescription(
      type: plain.type, version: plain.version, payload: plain.payload,
      undoState: AppletUndoState(
        MapViewerApplet.undoState(document: edited, base: base, path: file.path)))

    let applet = try MapViewerApplet(restoring: description)
    applet.host = host
    return applet
  }

  /// Catches a changed-on-disk warning that a restore itself produced taking a turn at launch.
  /// The restore compares the unsaved pins' base with the file. That is part of the restore, so
  /// its warning raises attention only.
  func testAChangedOnDiskWarningFromTheRestoreTakesNoTurn() async throws {
    let host = RecordingHost()
    let applet = try restoredWithUnsavedPins(try GeoScratch(self), host: host)

    applet.start(origin: .restore)
    await applet.opening?.value
    await applet.editing?.value

    XCTAssertTrue(applet.statusNotices.contains { $0.text.hasPrefix("The file changed on disk") })
    XCTAssertTrue(host.posts.isEmpty, "\(host.posts)")
    XCTAssertTrue(host.attentions.contains { $0.1.hasPrefix("The file changed on disk") })
  }

  /// Catches a real watcher event that goes quiet because the pane was restored. A change the
  /// file watcher sees after the restore is a reload and posts normally.
  func testAWatcherChangeAfterARestoreStillPostsNormally() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "pins.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))
    let host = RecordingHost()
    let applet = try restored(path: file, host: host)

    applet.start(origin: .restore)
    await applet.opening?.value

    applet.addPin(at: GeoCoordinate(latitude: 4, longitude: 4))
    await applet.editing?.value

    try Data(GeoFixtures.collection([GeoFixtures.point("D", 5, 5)]).utf8).write(to: file)
    applet.fileChangedOnDisk()
    await applet.checkingDisk?.value

    XCTAssertTrue(
      host.posts.contains { $0.text.hasPrefix("The file changed on disk") }, "\(host.posts)")
  }
}
