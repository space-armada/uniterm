import AppKit
import AppletKit
import AppletTestSupport
import Foundation
import GeoData
import MapKit
import Theme
import XCTest

@testable import MapViewerApplet

/// A scratch folder for GeoJSON files. It goes away with the test.
final class GeoScratch {
  let url: URL

  init(_ test: XCTestCase) throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-geo-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

    let folder = url
    test.addTeardownBlock {
      var info = stat()

      if stat(folder.path, &info) == 0 { chmod(folder.path, 0o700) }

      try? FileManager.default.removeItem(at: folder)
    }
  }

  /// A file of `bytes` that holds no data, so a size bound is crossed without writing the bytes.
  @discardableResult
  func writeSparse(_ name: String, bytes: Int) throws -> URL {
    let file = url.appendingPathComponent(name)
    FileManager.default.createFile(atPath: file.path, contents: nil)

    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(bytes))
    try handle.close()

    return file
  }

  @discardableResult
  func write(_ name: String, _ text: String) throws -> URL {
    let file = url.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    return file
  }
}

enum GeoFixtures {
  static func collection(_ features: [String]) -> String {
    #"{"type":"FeatureCollection","features":["# + features.joined(separator: ",") + "]}"
  }

  static func point(_ name: String?, _ longitude: Double, _ latitude: Double, extra: String = "")
    -> String
  {
    let label = name.map { #""name":"\#($0)""# } ?? ""
    let properties = [label, extra].filter { !$0.isEmpty }.joined(separator: ",")

    return
      #"{"type":"Feature","properties":{\#(properties)},"geometry":{"type":"Point","coordinates":[\#(longitude),\#(latitude)]}}"#
  }

  static let multiPoint =
    #"{"type":"Feature","properties":{"name":"Pair"},"geometry":{"type":"MultiPoint","coordinates":[[10,20],[11,21]]}}"#

  static let line =
    #"{"type":"Feature","properties":{"name":"Road"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}"#

  static let polygon =
    #"{"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}}"#
}

/// The file source through the applet: one entry point, off-main parsing, one layer, restore.
@MainActor
final class MapFileTests: XCTestCase {
  private func load(_ applet: MapViewerApplet, _ file: URL) async throws {
    applet.replaceSource(with: file, startDirectory: file.deletingLastPathComponent().path)
    await applet.opening?.value
  }

  /// What the map says about a file: what the pane explains, and the notices for the status bar.
  private func notices(_ applet: MapViewerApplet) -> [String] {
    applet.content.explanationLines + applet.statusNotices.map(\.text)
  }

  // MARK: Loading

  /// Catches a file whose points do not show, a skipped shape that goes uncounted, and a map that
  /// does not move to the pins. Points and MultiPoint members become pins with the documented IDs,
  /// the line and the polygon are skipped with a count in the pane, and the fitted region is
  /// saved with the pane.
  func testAFileLoadsItsPointsAndSkipsOtherShapesWithACount() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "pins.geojson",
      GeoFixtures.collection([
        GeoFixtures.point("Home", -122.4, 37.8), GeoFixtures.multiPoint, GeoFixtures.line,
        GeoFixtures.polygon,
      ]))

    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    try await load(applet, file)

    XCTAssertEqual(applet.filePinsShown.map(\.id), ["0:0", "1:0", "1:1"])
    XCTAssertEqual(applet.filePinsShown.map(\.label), ["Home", "Pair", "Pair"])
    XCTAssertEqual(applet.content.pins(layer: .file).count, 3)
    XCTAssertEqual(
      notices(applet), ["Skipped 2 shapes that are not points. The map shows points only."])
    XCTAssertEqual(applet.title, "pins.geojson")
    XCTAssertEqual(applet.segments.map(\.text), ["Standard", "3 pins", "2 hidden"])

    let stored = try MapViewerDescription.decode(applet.describe())

    XCTAssertEqual(stored.path, file.path)
    XCTAssertEqual(stored.fileAccent, "blue")
    XCTAssertNotNil(stored.bookmark)
    XCTAssertNotNil(stored.region)
    XCTAssertGreaterThan(host.changes, 0)
  }

  /// Catches a second file that adds to the first, or one that touches another layer. The file
  /// layer is replaced and a command's layer keeps its pins, even one that is named "file".
  func testLoadingASecondFileReplacesOnlyTheFileLayer() async throws {
    let scratch = try GeoScratch(self)
    let first = try scratch.write(
      "a.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))
    let second = try scratch.write(
      "b.geojson",
      GeoFixtures.collection([GeoFixtures.point("B", 2, 2), GeoFixtures.point("C", 3, 3)]))

    let applet = MapViewerApplet(startDirectory: nil)
    let other = GeoPin(id: "x", coordinate: GeoCoordinate(latitude: 5, longitude: 5), label: "X")

    applet.content.replacePins(layer: .command("file"), pins: [other], defaultAccent: .green)

    try await load(applet, first)
    XCTAssertEqual(applet.content.pins(layer: .file).map(\.label), ["A"])

    try await load(applet, second)

    XCTAssertEqual(applet.content.pins(layer: .file).map(\.label).sorted(), ["B", "C"])
    XCTAssertEqual(applet.content.pins(layer: .command("file")), [other])
    XCTAssertEqual(applet.title, "b.geojson")
  }

  /// Catches a file that can stall or crash the pane, or a message that blames the file as
  /// corrupt. Malformed text, a missing file, a folder, a pipe, and an unreadable file each show a
  /// message that says which, and the pane stays usable. A pipe is refused without being read.
  func testBadFilesShowAMessageThatSaysWhichAndNeverSayCorrupt() async throws {
    let scratch = try GeoScratch(self)
    let bad = try scratch.write("bad.geojson", "{ not json")
    let missing = scratch.url.appendingPathComponent("gone.geojson")
    let folder = scratch.url.appendingPathComponent("dir.geojson", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let pipe = scratch.url.appendingPathComponent("pipe.geojson")
    XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)

    let locked = try scratch.write("locked.geojson", GeoFixtures.collection([]))
    XCTAssertEqual(chmod(locked.path, 0o000), 0)

    let applet = MapViewerApplet(startDirectory: nil)

    let cases: [(URL, String)] = [
      (bad, "is not valid GeoJSON"), (missing, "is missing"), (folder, "is a folder"),
      (pipe, "is a pipe"), (locked, "does not have permission"),
    ]

    for (file, expected) in cases {
      try await load(applet, file)

      let text = notices(applet).joined(separator: "\n")

      XCTAssertTrue(text.contains(expected), "\(file.lastPathComponent): \(text)")
      XCTAssertFalse(text.lowercased().contains("corrupt"), text)
      XCTAssertTrue(applet.filePinsShown.isEmpty)
    }

    try await load(
      applet,
      try scratch.write("ok.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)])))

    XCTAssertEqual(applet.filePinsShown.count, 1)
    XCTAssertFalse(notices(applet).contains { $0.contains("not valid") })
  }

  /// Catches a huge file that is read whole. A file past the size bound is refused before it is
  /// parsed, and the message names the bound.
  func testAFilePastTheSizeBoundIsRefused() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.writeSparse("big.geojson", bytes: GeoJSONLimits().maxBytes + 1)

    let applet = MapViewerApplet(startDirectory: nil)

    try await load(applet, file)

    XCTAssertTrue(applet.filePinsShown.isEmpty)
    XCTAssertTrue(
      notices(applet).joined().contains("reads GeoJSON files up to"), "\(notices(applet))")
  }

  /// Catches a bookmark lost when the read fails after the file was found. A file too large to
  /// read, or not valid GeoJSON, still leaves the pane holding the path and a bookmark that names
  /// the file, so a later restore can find it after a move.
  func testAFileFoundButNotReadKeepsItsBookmark() async throws {
    let scratch = try GeoScratch(self)
    let big = try scratch.writeSparse("big.geojson", bytes: GeoJSONLimits().maxBytes + 1)
    let bad = try scratch.write("bad.geojson", "{ not json")

    let applet = MapViewerApplet(startDirectory: nil)

    for file in [big, bad] {
      try await load(applet, file)

      let stored = try MapViewerDescription.decode(applet.describe())

      XCTAssertEqual(stored.path, file.path)
      XCTAssertNotNil(stored.bookmark, file.lastPathComponent)
    }
  }

  /// Catches a file past the point bound that loads nothing or loads without saying so. The first
  /// points load and the pane says the file has more.
  func testAFilePastThePointBoundLoadsItsFirstPointsAndSaysSo() async throws {
    let scratch = try GeoScratch(self)
    let bound = GeoJSONLimits().maxPoints
    let features = (0...bound).map { GeoFixtures.point("P\($0)", Double($0 % 360) - 180, 0) }
    let file = try scratch.write("many.geojson", GeoFixtures.collection(features))

    let applet = MapViewerApplet(startDirectory: nil)

    try await load(applet, file)

    XCTAssertEqual(applet.filePinsShown.count, bound)
    XCTAssertEqual(applet.filePinsShown.first?.label, "P0")
    XCTAssertEqual(applet.filePinsShown.last?.label, "P\(bound - 1)")
    let count = bound.formatted()

    XCTAssertEqual(
      notices(applet), ["The file has more than \(count) points. Showing the first \(count)."])
  }

  /// Catches style values that are dropped without a word. Two unusable values add up to one
  /// notice, and the pins use the layer default.
  func testUnusableStyleValuesAreCountedInOneNotice() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "style.geojson",
      GeoFixtures.collection([
        GeoFixtures.point("A", 1, 1, extra: #""marker-color":"nope""#),
        GeoFixtures.point("B", 2, 2, extra: #""uniterm:accent":"chartreuse""#),
        GeoFixtures.point("C", 3, 3, extra: ##""marker-color":"#d20f39","marker-symbol":"K""##),
      ]))

    let applet = MapViewerApplet(startDirectory: nil)

    try await load(applet, file)

    XCTAssertEqual(
      notices(applet),
      ["2 pin style values could not be used. Those pins use the default color or glyph."])
    XCTAssertEqual(applet.filePinsShown.map(\.accent), [nil, nil, .red])
    XCTAssertEqual(applet.filePinsShown.last?.glyph, .text("K"))
  }

  // MARK: Clear and restore

  /// Catches a clear that leaves the file to come back. Clearing removes the pins and drops the
  /// stored path and bookmark, so a rebuilt pane has nothing to load. The layer keeps its default
  /// accent.
  func testClearingTheFileLayerDropsThePathAndBookmark() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "a.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))

    let applet = MapViewerApplet(startDirectory: nil)

    XCTAssertFalse(applet.canClearFile)

    try await load(applet, file)

    XCTAssertTrue(applet.canClearFile)

    applet.clearFile()

    XCTAssertTrue(applet.filePinsShown.isEmpty)
    XCTAssertTrue(applet.content.pins(layer: .file).isEmpty)
    XCTAssertFalse(applet.canClearFile)

    let stored = try MapViewerDescription.decode(applet.describe())

    XCTAssertNil(stored.path)
    XCTAssertNil(stored.bookmark)
    XCTAssertEqual(stored.fileAccent, "blue")

    let rebuilt = try MapViewerApplet(restoring: applet.describe())
    rebuilt.start(origin: .user)
    await rebuilt.opening?.value

    XCTAssertTrue(rebuilt.filePinsShown.isEmpty)
  }

  /// Catches a clear that a slow load undoes. A load still running when the layer is cleared must
  /// not bring its pins back.
  func testAClearDuringALoadWins() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "a.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))

    let applet = MapViewerApplet(startDirectory: nil)

    applet.replaceSource(with: file, startDirectory: scratch.url.path)
    let running = applet.opening
    applet.clearFile()
    await running?.value

    XCTAssertTrue(applet.filePinsShown.isEmpty)
    XCTAssertNil(try MapViewerDescription.decode(applet.describe()).path)
  }

  /// Catches a restore that reads the disk before the pane starts, or one that does not bring the
  /// pins back. The pins load in `start()`, from the stored path, and the saved region stays.
  func testRestoreLoadsThePinsInStartAndKeepsTheSavedRegion() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "a.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))

    let original = MapViewerApplet(startDirectory: nil)
    try await load(original, file)

    let description = original.describe()
    let region = try MapViewerDescription.decode(description).region

    let restored = try MapViewerApplet(restoring: description)

    XCTAssertTrue(restored.filePinsShown.isEmpty)
    XCTAssertEqual(restored.describe(), description)

    restored.start(origin: .user)
    await restored.opening?.value

    XCTAssertEqual(restored.filePinsShown.map(\.label), ["A"])
    XCTAssertEqual(try MapViewerDescription.decode(restored.describe()).region, region)
  }

  /// Catches a moved file that reports missing, and a new file at the old path that loses to the
  /// bookmark. The bookmark finds a moved file and the pane says where. A different file at the
  /// stored path wins over the bookmark of the old one. The resolver's own tests prove the lookup.
  /// This one owns what they cannot: the notice text in the pane and the bookmark the pane stores.
  func testAMovedFileIsFoundAndANewFileAtTheStoredPathWins() async throws {
    let scratch = try GeoScratch(self)
    let old = try scratch.write(
      "old.geojson", GeoFixtures.collection([GeoFixtures.point("Old", 1, 1)]))

    let original = MapViewerApplet(startDirectory: nil)
    try await load(original, old)

    let description = original.describe()
    let moved = scratch.url.appendingPathComponent("moved.geojson")
    try FileManager.default.moveItem(at: old, to: moved)

    let found = try MapViewerApplet(restoring: description)
    let host = RecordingHost()
    found.host = host
    found.start(origin: .user)
    await found.opening?.value

    XCTAssertEqual(found.filePinsShown.map(\.label), ["Old"])
    XCTAssertEqual(
      host.posts.filter { $0.text.hasPrefix("Moved") }.map(\.level), [.info],
      "a file found at a new path changes nothing on screen")
    XCTAssertEqual(
      notices(found).filter { $0.hasPrefix("Moved. Found at") }.count, 1, "\(notices(found))")
    XCTAssertEqual(
      URL(fileURLWithPath: try XCTUnwrap(MapViewerDescription.decode(found.describe()).path))
        .resolvingSymlinksInPath().path, moved.path)

    _ = try scratch.write(
      "old.geojson", GeoFixtures.collection([GeoFixtures.point("Fresh", 2, 2)]))

    let wins = try MapViewerApplet(restoring: description)
    wins.start(origin: .user)
    await wins.opening?.value

    XCTAssertEqual(wins.filePinsShown.map(\.label), ["Fresh"])
    XCTAssertFalse(notices(wins).contains { $0.hasPrefix("Moved") })
  }

  /// Catches a restore of a vanished file that drops the path. The pane says the file is missing
  /// and keeps the stored path, so the file can come back.
  func testARestoredFileThatIsGoneSaysSoAndKeepsItsPath() async throws {
    let path = "/nonexistent-folder/pins.geojson"
    let description = try MapViewerDescription(path: path).appletDescription()

    let applet = try MapViewerApplet(restoring: description)
    applet.start(origin: .user)
    await applet.opening?.value

    XCTAssertTrue(notices(applet).joined().contains("is missing"))
    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).path, path)
  }

  /// Catches a stored accent that is not an accent. It reads as the first default and is stored
  /// again once a file loads. The accent tests prove which names validate. This one owns the
  /// wiring, that the applet reads and writes the stored accent through that check.
  func testAStoredAccentOutsideTheSetReadsAsTheDefault() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "a.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))

    let applet = try MapViewerApplet(
      restoring: MapViewerDescription(fileAccent: "base").appletDescription())

    XCTAssertEqual(applet.fileAccent, .blue)
    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).fileAccent, "base")

    try await load(applet, file)

    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).fileAccent, "blue")

    let kept = try MapViewerApplet(
      restoring: MapViewerDescription(fileAccent: "teal").appletDescription())

    XCTAssertEqual(kept.fileAccent, .teal)
  }

  // MARK: Entry points

  /// Catches an Open command that starts in the panel's own remembered folder, or one that skips
  /// the one entry point. The panel starts in the file's folder, and the chosen file loads.
  func testTheOpenCommandStartsInTheCurrentDirectoryAndLoadsTheChosenFile() async throws {
    let scratch = try GeoScratch(self)
    let start = scratch.url.appendingPathComponent("start", isDirectory: true)
    try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)

    let file = try scratch.write(
      "chosen.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))

    let applet = MapViewerApplet(startDirectory: start.path)
    var requested: OpenPanelRequest?

    await SourceOpening.open(
      applet,
      picker: { request, _ in
        requested = request
        return [file]
      })

    await applet.opening?.value

    XCTAssertEqual(requested?.directory.path, start.path)
    XCTAssertEqual(requested?.allowsMultipleSelection, false)
    XCTAssertEqual(applet.filePinsShown.count, 1)
    XCTAssertEqual(applet.currentDirectory, scratch.url.path)
  }

  /// Catches a drop that bypasses the entry point, and several files taken at once. One file
  /// loads. Several are refused with a warning and the pane keeps what it showed.
  func testADropOfOneFileLoadsAndSeveralAreRefused() async throws {
    let scratch = try GeoScratch(self)
    let first = try scratch.write(
      "a.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))
    let second = try scratch.write(
      "b.geojson", GeoFixtures.collection([GeoFixtures.point("B", 1, 1)]))

    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    XCTAssertFalse(applet.handleDrop([]))
    XCTAssertFalse(applet.handleDrop([first, second]))
    XCTAssertEqual(host.posts.map(\.level), [.warning])
    XCTAssertTrue(applet.filePinsShown.isEmpty)

    XCTAssertTrue(applet.handleDrop([first]))
    await applet.sourceSwap.pending?.value
    await applet.opening?.value

    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A"])
  }

  /// Catches an Open in This Pane that drops the pane's pins when the chosen file cannot be read.
  /// The pane keeps its pins and its saved path, and the status bar names the file that failed.
  func testAFailedOpenInThisPaneKeepsTheOldFileAndWarns() async throws {
    let scratch = try GeoScratch(self)
    let good = try scratch.write(
      "a.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))
    let bad = try scratch.write("broken.geojson", #"{ "type": "FeatureCollection", "features": ["#)

    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    applet.replaceSource(with: good, startDirectory: scratch.url.path)
    await applet.opening?.value
    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A"])

    await applet.replaceSource(withChosen: bad).value
    await applet.opening?.value

    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A"])
    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).path, good.path)

    let warned = host.sent.contains { $0.level == .warning && $0.text.contains("broken.geojson") }
    XCTAssertTrue(warned, "\(host.sent)")
  }

  /// Catches a map that binds Cmd-O, a missing Open command, and a clear that is always on. Open is
  /// in File with no key, and Clear File Pins is off until there is something to clear.
  func testTheCommandsDeclareOpenWithNoKeyAndClearWhenThereIsAFile() async throws {
    let commands = Dictionary(
      uniqueKeysWithValues: MapViewerApplet.commandSet.commands.map { ($0.name, $0) })
    let open = try XCTUnwrap(commands["open"])
    let clear = try XCTUnwrap(commands["clear-file"])

    XCTAssertNil(open.key)
    XCTAssertEqual(open.title, "Open in This Pane\u{2026}")
    XCTAssertNil(clear.key)

    let applet = MapViewerApplet(startDirectory: nil)

    XCTAssertTrue(open.isAvailable(applet))
    XCTAssertFalse(clear.isAvailable(applet))

    let scratch = try GeoScratch(self)
    try await load(
      applet, try scratch.write("a.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)]))
    )

    XCTAssertTrue(clear.isAvailable(applet))
    clear.run(applet)
    XCTAssertTrue(applet.filePinsShown.isEmpty)
  }

  /// Catches a Zoom to Fit Pins that misses a pin, is offered with nothing to fit, or is not saved.
  /// After the user moves away from two loaded pins, the command brings both back into view and the
  /// pane records the fitted region.
  func testZoomToFitPinsShowsEveryPinAndIsSaved() async throws {
    let fit = try XCTUnwrap(MapViewerApplet.commandSet.commands.first { $0.name == "zoom-to-pins" })
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    XCTAssertFalse(fit.isAvailable(applet))

    let scratch = try GeoScratch(self)
    try await load(
      applet,
      try scratch.write(
        "two.geojson",
        GeoFixtures.collection([GeoFixtures.point("A", 10, 40), GeoFixtures.point("B", 12, 44)])))

    let away = try XCTUnwrap(
      GeoRegion(
        center: GeoCoordinate(latitude: -30, longitude: 150),
        span: GeoSpan(latitudeDelta: 1, longitudeDelta: 1)))
    applet.content.onRegionSettled?(away)
    let changes = host.changes

    XCTAssertTrue(fit.isAvailable(applet))
    fit.run(applet)

    let saved = try XCTUnwrap(MapViewerDescription.decode(applet.describe()).region)

    for (longitude, latitude) in [(10.0, 40.0), (12.0, 44.0)] {
      XCTAssertLessThanOrEqual(abs(saved.center.latitude - latitude), saved.span.latitudeDelta / 2)
      XCTAssertLessThanOrEqual(
        abs(saved.center.longitude - longitude), saved.span.longitudeDelta / 2)
    }

    XCTAssertEqual(host.changes, changes + 1)
  }

  /// Catches a declaration that drifts. The map owns GeoJSON.
  func testTheMapOwnsGeoJSON() {
    XCTAssertEqual(
      MapViewerApplet.typeDeclaration.opens, [OpenedType("public.geojson", rank: .owner)])
  }
}

/// Where the map says what a load left out: the status bar, not over the map.
@MainActor
final class MapNoticePlacementTests: XCTestCase {
  private func load(_ applet: MapViewerApplet, _ file: URL) async throws {
    applet.replaceSource(with: file, startDirectory: file.deletingLastPathComponent().path)
    await applet.opening?.value
  }

  /// Catches a load notice drawn over the map, where it covered MapKit's attribution, and one
  /// posted again on every refresh. The pane shows nothing, the status bar gets the sentence once
  /// as a warning, and a segment says how many shapes are hidden.
  func testLoadNoticesGoToTheStatusBarOnce() async throws {
    let scratch = try GeoScratch(self)
    let file = try scratch.write(
      "mixed.geojson",
      GeoFixtures.collection([GeoFixtures.point("A", 1, 1), GeoFixtures.line, GeoFixtures.polygon]))
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    applet.replaceSource(with: file, startDirectory: scratch.url.path)
    await applet.opening?.value

    let skipped = "Skipped 2 shapes that are not points. The map shows points only."
    XCTAssertEqual(applet.content.explanationLines, [])
    XCTAssertEqual(
      host.posts.filter { $0.text == skipped }.map(\.level), [.warning],
      "shapes the map does not show are a warning")
    XCTAssertTrue(applet.segments.contains { $0.text == "2 hidden" }, "\(applet.segments)")

    applet.addPin(at: GeoCoordinate(latitude: 3, longitude: 3))
    await applet.editing?.value
    applet.choose(style: .hybrid)

    XCTAssertEqual(host.posts.filter { $0.text == skipped }.count, 1, "the notice posted again")

    applet.replaceSource(with: file, startDirectory: scratch.url.path)
    await applet.asking?.value
    host.answer = true
    applet.replaceSource(with: file, startDirectory: scratch.url.path)
    await applet.asking?.value
    await applet.opening?.value

    XCTAssertEqual(host.posts.filter { $0.text == skipped }.count, 2, "a new load did not post")
  }

  private func fileWithHiddenShapes(_ scratch: GeoScratch) throws -> URL {
    try scratch.write(
      "mixed.geojson",
      GeoFixtures.collection([GeoFixtures.point("A", 1, 1), GeoFixtures.line, GeoFixtures.polygon]))
  }

  /// Catches a failure box drawn over a map that still shows content. With tiles that load, the
  /// failure is one warning on the status bar and one history entry. The pane says nothing, and a
  /// segment holds while the failure does. A good load ends the segment.
  func testAFailureOverUsableTilesIsOneWarningAndASegment() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    applet.replaceSource(
      with: scratch.url.appendingPathComponent("missing.geojson"), startDirectory: scratch.url.path)
    await applet.opening?.value
    applet.choose(style: .hybrid)

    XCTAssertEqual(host.posts.map(\.level), [.warning])
    XCTAssertTrue(host.posts[0].text.contains("is missing"), "\(host.posts)")
    XCTAssertTrue(host.records.isEmpty, "a posted failure is not recorded twice")
    XCTAssertEqual(applet.content.explanationLines, [])
    XCTAssertTrue(applet.segments.contains { $0.text == "File not opened" }, "\(applet.segments)")

    try await load(
      applet,
      try scratch.write("ok.geojson", GeoFixtures.collection([GeoFixtures.point("A", 1, 1)])))

    XCTAssertFalse(applet.segments.contains { $0.text == "File not opened" })
  }

  /// Catches an empty map that says nothing, or one that says it twice. With no tiles and no pins,
  /// the pane explains the failure and the history gets one warning. The bar takes no turn for it.
  func testAFailureWithNothingElseOnTheMapIsExplainedInThePaneAndRecordedOnce() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    applet.content.onTilesChanged?("The map could not load: offline.")
    host.forgetSent()

    applet.replaceSource(
      with: scratch.url.appendingPathComponent("missing.geojson"), startDirectory: scratch.url.path)
    await applet.opening?.value
    applet.choose(style: .hybrid)
    applet.content.onTilesChanged?("The map could not load: still offline.")

    XCTAssertTrue(applet.content.explanationLines.joined().contains("is missing"))
    XCTAssertTrue(host.posts.filter { $0.text.contains("is missing") }.isEmpty, "\(host.posts)")
    XCTAssertEqual(host.records.map(\.level), [.warning])
    XCTAssertTrue(host.records[0].text.contains("is missing"))
  }

  /// Catches a pane that explains a failure over a map that still has command pins. They are
  /// content, so the failure goes to the bar instead.
  func testCommandPinsKeepAFailureOffThePane() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host
    let pin = GeoPin(id: "x", coordinate: GeoCoordinate(latitude: 5, longitude: 5), label: "X")

    applet.content.onTilesChanged?("The map could not load: offline.")
    applet.content.replacePins(layer: .command("demo"), pins: [pin], defaultAccent: .green)

    applet.replaceSource(
      with: scratch.url.appendingPathComponent("missing.geojson"), startDirectory: scratch.url.path)
    await applet.opening?.value

    XCTAssertEqual(applet.content.explanationLines, [])
    XCTAssertEqual(host.posts.filter { $0.text.contains("is missing") }.map(\.level), [.warning])
    XCTAssertTrue(host.records.isEmpty)
  }

  /// Catches a stale failure that stays on the bar while the next file loads. A new load shows its
  /// wait at once and drops the old failure's segment.
  func testANewLoadReplacesTheOldFailureAtOnce() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    applet.replaceSource(
      with: scratch.url.appendingPathComponent("missing.geojson"), startDirectory: scratch.url.path)
    await applet.opening?.value
    XCTAssertTrue(applet.segments.contains { $0.text == "File not opened" })

    let changes = host.changes
    applet.replaceSource(
      with: try fileWithHiddenShapes(scratch), startDirectory: scratch.url.path)

    XCTAssertEqual(applet.content.explanationLines, ["Opening\u{2026}"])
    XCTAssertFalse(applet.segments.contains { $0.text == "File not opened" }, "\(applet.segments)")
    XCTAssertGreaterThan(host.changes, changes, "the host was not told the load started")

    await applet.opening?.value
    XCTAssertEqual(applet.content.explanationLines, [])
  }

  /// Catches a load that was replaced mid-flight and still reports. The second load wins, and the
  /// first one's failure is never posted, recorded, or shown.
  func testALoadReplacedInFlightNeverReportsItsFailure() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    applet.replaceSource(
      with: scratch.url.appendingPathComponent("missing.geojson"), startDirectory: scratch.url.path)
    let stale = applet.opening
    applet.replaceSource(
      with: try fileWithHiddenShapes(scratch), startDirectory: scratch.url.path)

    await stale?.value
    await applet.opening?.value

    XCTAssertFalse(host.posts.contains { $0.text.contains("is missing") }, "\(host.posts)")
    XCTAssertTrue(host.records.isEmpty)
    XCTAssertFalse(applet.segments.contains { $0.text == "File not opened" })
    XCTAssertEqual(applet.filePinsShown.count, 1)
  }

  /// Catches a clear that leaves the old file's counts on the bar, and a cancelled load that still
  /// reports. After the clear, no hidden-points segment and no failure remain.
  func testClearingForgetsTheCountsAndACancelledLoadStaysQuiet() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    try await load(applet, try fileWithHiddenShapes(scratch))
    XCTAssertTrue(applet.segments.contains { $0.text == "2 hidden" })

    applet.clearFile()
    await applet.asking?.value

    XCTAssertEqual(applet.segments.map(\.text), ["Standard"])

    applet.replaceSource(
      with: scratch.url.appendingPathComponent("missing.geojson"), startDirectory: scratch.url.path)
    let cancelled = applet.opening
    applet.clearFile()
    await cancelled?.value

    XCTAssertEqual(applet.segments.map(\.text), ["Standard"])
    XCTAssertEqual(applet.content.explanationLines, [])
    XCTAssertFalse(host.posts.contains { $0.text.contains("is missing") }, "\(host.posts)")
  }
}
