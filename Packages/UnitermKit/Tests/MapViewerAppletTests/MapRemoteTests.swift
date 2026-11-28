import AppKit
import AppletKit
import AppletTestSupport
import Foundation
import GeoData
import MapKit
import XCTest

@testable import MapViewerApplet

/// Collects the events a pane emits, as an exec driver's channel would receive them.
@MainActor
private final class EventRecorder: AppletEventSink {
  private(set) var events: [(name: String, data: JSONValue)] = []

  func deliver(event name: String, data: JSONValue) { events.append((name, data)) }

  func outletClosed() {}

  func reset() { events = [] }
}

/// One command sent through shared dispatch. The map answers at once, so the result is set when
/// the turn runs.
@MainActor
private final class Call {
  var result: Result<JSONValue, AppletCommandError>?

  var fields: [String: JSONValue] {
    if case .success(.object(let fields))? = result { return fields }

    return [:]
  }

  var code: AppletCommandError.Code? {
    if case .failure(let error)? = result { return error.code }

    return nil
  }
}

/// The map's program commands, sent through the dispatcher a window uses.
///
/// These prove what a command does to the pane, and that a refused one changes nothing. They
/// cannot prove how MapKit draws or clusters the pins.
@MainActor
final class MapRemoteTests: XCTestCase {
  private var turns: [@MainActor () -> Void] = []
  private var dispatcher: ControlDispatcher!

  override func setUp() async throws {
    dispatcher = ControlDispatcher { [weak self] body in self?.turns.append(body) }
  }

  // MARK: Support

  private func send(
    _ name: String, _ arguments: [String: JSONValue] = [:], to applet: MapViewerApplet,
    version: AppletSchemaVersion = AppletSchemaVersion(0, 0)
  ) -> Call {
    let call = Call()
    let submission = AppletCommandSubmission(
      appletType: MapViewerDescription.typeID, schemaVersion: version, name: name,
      arguments: .object(arguments))

    dispatcher.submit(
      submission, to: applet, authority: { nil }, reads: .none, reply: { call.result = $0 })

    let bodies = turns
    turns = []

    for body in bodies { body() }

    return call
  }

  private func pin(
    _ id: String, _ latitude: Double = 10, _ longitude: Double = 20, label: String? = nil,
    accent: String? = nil, glyph: String? = nil
  ) -> JSONValue {
    var fields: [String: JSONValue] = [
      "id": .string(id),
      "coordinate": .object(["latitude": .number(latitude), "longitude": .number(longitude)]),
    ]

    if let label { fields["label"] = .string(label) }

    if let accent { fields["accent"] = .string(accent) }

    if let glyph { fields["glyph"] = .string(glyph) }

    return .object(fields)
  }

  private func add(
    _ id: String, layer: String? = nil, to applet: MapViewerApplet, label: String? = nil,
    accent: String? = nil, glyph: String? = nil
  ) -> Call {
    guard case .object(var fields) = pin(id, label: label, accent: accent, glyph: glyph) else {
      preconditionFailure("not an object")
    }

    if let layer { fields["layer"] = .string(layer) }

    return send("add", fields, to: applet)
  }

  private func ids(_ applet: MapViewerApplet, _ layer: String = "default") -> [String] {
    applet.content.pins(layer: .command(layer)).map(\.id).sorted()
  }

  private func pane(
    file: Bool = false
  ) -> (MapViewerApplet, RecordingHost, EventRecorder) {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    let recorder = EventRecorder()

    applet.host = host
    applet.content.animatesCommands = false
    applet.content.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    applet.content.layoutSubtreeIfNeeded()
    _ = applet.events.connect(recorder)

    return (applet, host, recorder)
  }

  // MARK: Commands

  /// Catches a command that never reaches the map, a default layer that differs by caller, and a
  /// remove or clear that spills into another layer. A command naming no layer uses `default`.
  func testCommandsActOnTheNamedLayerAndTheDefaultLayerOtherwise() {
    let (applet, _, _) = pane()

    XCTAssertNil(add("a", to: applet).code)
    XCTAssertNil(add("b", layer: "other", to: applet).code)
    XCTAssertNil(add("a", layer: "other", to: applet).code)

    XCTAssertEqual(ids(applet), ["a"])
    XCTAssertEqual(ids(applet, "other"), ["a", "b"])

    let removed = send("remove", ["id": .string("a"), "layer": .string("other")], to: applet)

    XCTAssertEqual(removed.fields["removed"], .bool(true))
    XCTAssertEqual(ids(applet), ["a"])
    XCTAssertEqual(ids(applet, "other"), ["b"])

    let missing = send("remove", ["id": .string("zzz")], to: applet)

    XCTAssertEqual(missing.fields["removed"], .bool(false))
    XCTAssertNil(applet.commandLayers.layer(named: "zzz"))

    _ = send("clear", [:], to: applet)

    XCTAssertEqual(ids(applet), [])
    XCTAssertEqual(ids(applet, "other"), ["b"])
  }

  /// Catches an add that keeps the earlier pin's accent or glyph, and one that adds a second pin.
  func testAddWithAnExistingIDReplacesThePinWhole() throws {
    let (applet, _, _) = pane()

    _ = add("a", to: applet, label: "one", accent: "red", glyph: "x")
    _ = add("a", to: applet, label: "two")

    let shown = applet.content.pins(layer: .command("default"))

    XCTAssertEqual(shown.count, 1)
    XCTAssertEqual(shown.first?.label, "two")
    XCTAssertNil(shown.first?.accent)
    XCTAssertNil(shown.first?.glyph)
  }

  /// Catches an unknown accent that changes the map, and a missing SF Symbol that is refused. The
  /// accent is a schema error. The symbol name is well formed, so the pin takes it and the marker
  /// draws the default glyph.
  func testAnUnknownAccentChangesNothingAndAMissingSymbolIsKept() {
    let (applet, _, _) = pane()

    let refused = add("a", to: applet, accent: "chartreuse")

    XCTAssertEqual(refused.code, .badArgument)
    XCTAssertTrue(applet.commandLayers.isEmpty)
    XCTAssertEqual(ids(applet), [])

    XCTAssertNil(add("b", to: applet, glyph: "no.such.symbol.name").code)
    XCTAssertEqual(
      applet.content.pins(layer: .command("default")).first?.glyph?.text, "no.such.symbol.name")
  }

  /// Catches a set-layer that draws part of a layer. One bad pin refuses the whole command, and
  /// the layer's earlier pins stay. A good one swaps the whole layer at once.
  func testSetLayerIsWholeOrNothing() {
    let (applet, _, _) = pane()

    XCTAssertNil(send("set-layer", ["pins": .array([pin("a"), pin("b")])], to: applet).code)
    XCTAssertEqual(ids(applet), ["a", "b"])

    let bad = send(
      "set-layer", ["pins": .array([pin("c"), pin("d"), pin("e", glyph: "no way")])], to: applet)

    XCTAssertEqual(bad.code, .badArgument)
    XCTAssertEqual(ids(applet), ["a", "b"])

    let repeated = send("set-layer", ["pins": .array([pin("c"), pin("c")])], to: applet)

    XCTAssertEqual(repeated.code, .badArgument)
    XCTAssertEqual(ids(applet), ["a", "b"])

    XCTAssertNil(send("set-layer", ["pins": .array([pin("c")])], to: applet).code)
    XCTAssertEqual(ids(applet), ["c"])
  }

  /// Catches a layer cap that forgets empty layers, and a refused layer that is made anyway.
  func testALayerPastTheCapIsRefusedWholeAndEmptyLayersCount() {
    let (applet, _, _) = pane()

    for index in 0..<CommandPinLimits.maxLayersPerPane {
      XCTAssertNil(
        send("set-layer", ["layer": .string("l\(index)"), "pins": .array([])], to: applet).code)
    }

    let refused = send(
      "set-layer", ["layer": .string("extra"), "pins": .array([pin("a")])], to: applet)

    XCTAssertEqual(refused.code, .refused)
    XCTAssertEqual(add("a", layer: "extra", to: applet).code, .refused)
    XCTAssertNil(applet.commandLayers.layer(named: "extra"))
    XCTAssertEqual(ids(applet, "extra"), [])
  }

  /// Catches a layer past the per-layer cap being drawn in part, by the schema or by the model.
  func testALayerPastThePerLayerCapIsRefusedWhole() {
    let (applet, _, _) = pane()
    let tooMany = (0...CommandPinLimits.maxPinsPerLayer).map { pin("p\($0)") }

    XCTAssertEqual(send("set-layer", ["pins": .array(tooMany)], to: applet).code, .badArgument)
    XCTAssertEqual(ids(applet), [])
  }

  /// Catches a command that reaches the file layer. Every pin command that names the file as its
  /// source is refused with a structured error and changes nothing, and no layer name does it.
  func testACommandNamingTheFileSourceIsRefusedAndChangesNothing() {
    let (applet, _, _) = pane()

    _ = add("a", to: applet)

    let before = applet.commandLayers

    let attempts: [(String, [String: JSONValue])] = [
      (
        "add",
        [
          "id": .string("b"), "coordinate": pin("b").objectField("coordinate"),
          "source": .string("file"),
        ]
      ),
      ("remove", ["id": .string("a"), "source": .string("file")]),
      ("clear", ["source": .string("file")]),
      ("set-layer", ["pins": .array([]), "source": .string("file")]),
    ]

    for (name, arguments) in attempts {
      XCTAssertEqual(send(name, arguments, to: applet).code, .refused, name)
    }

    XCTAssertEqual(applet.commandLayers, before)
    XCTAssertEqual(applet.content.pins(layer: .file), [])
    XCTAssertEqual(send("clear", ["source": .string("other")], to: applet).code, .badArgument)
  }

  /// Catches a region the map cannot take reaching MapKit, which raises on it, and a program's
  /// move that is lost at a reopen where the user's identical move is kept.
  func testSetRegionRunsGeoRegionsChecksAndIsSaved() throws {
    let (applet, _, _) = pane()

    func region(_ latitude: Double, _ delta: Double) -> [String: JSONValue] {
      [
        "center": .object(["latitude": .number(latitude), "longitude": .number(10)]),
        "span": .object(["latitude-delta": .number(delta), "longitude-delta": .number(delta)]),
      ]
    }

    XCTAssertEqual(send("set-region", region(89, 10), to: applet).code, .badArgument)
    XCTAssertEqual(send("set-region", region(0, 0), to: applet).code, .badArgument)
    XCTAssertNil(send("set-region", region(48, 2), to: applet).code)
    XCTAssertEqual(applet.content.mapView.region.center.latitude, 48, accuracy: 0.5)
    XCTAssertEqual(applet.record.region?.center.latitude ?? .nan, 48, accuracy: 0.0001)

    let saved = applet.record.region

    applet.content.mapView(applet.content.mapView, regionDidChangeAnimated: false)

    XCTAssertEqual(applet.record.region, saved, "MapKit's report after the set was saved")

    let reopened = try MapViewerApplet(restoring: applet.describe())

    XCTAssertEqual(reopened.record.region, saved)
  }

  /// Catches a refused region that is saved anyway.
  func testARefusedSetRegionIsNotSaved() {
    let (applet, _, _) = pane()

    let off: [String: JSONValue] = [
      "center": .object(["latitude": .number(89), "longitude": .number(10)]),
      "span": .object(["latitude-delta": .number(10), "longitude-delta": .number(10)]),
    ]

    XCTAssertEqual(send("set-region", off, to: applet).code, .badArgument)
    XCTAssertNil(applet.record.region)
  }

  /// Catches a command on a pane that closed, which would draw on a dead map.
  func testAClosedPaneRefusesCommands() {
    let (applet, _, _) = pane()

    applet.close()

    XCTAssertNotNil(add("a", to: applet).code)
  }

  // MARK: Accents and the user's clear

  /// Catches a layer that takes a new accent after a clear, and one that takes the file layer's.
  /// The accent a layer's pins draw with is the layer's, and a reopen keeps it.
  func testALayerKeepsItsAccentAcrossAClearAndAReopen() throws {
    let (applet, _, _) = pane()

    _ = add("a", layer: "one", to: applet)
    _ = add("a", layer: "two", to: applet)

    let accents = applet.commandLayers.layers.map(\.accent)

    XCTAssertNotEqual(accents[0], applet.fileAccent)

    _ = send("clear", ["layer": .string("one")], to: applet)
    _ = add("b", layer: "one", to: applet)

    XCTAssertEqual(applet.commandLayers.layer(named: "one")?.accent, accents[0])

    let reopened = try MapViewerApplet(restoring: applet.describe())

    XCTAssertEqual(reopened.commandLayers.layers.map(\.accent), accents)

    _ = send("add", ["layer": .string("three")].merging(pin("a").objectFields) { $1 }, to: reopened)

    XCTAssertEqual(
      reopened.commandLayers.layer(named: "three")?.accent, PinAccents.layerDefault(at: 3))
  }

  /// Catches a user clear that removes the file's pins, and one that forgets a layer's accent.
  func testClearProgramPinsClearsEveryCommandLayerAndNothingElse() {
    let (applet, _, _) = pane()

    XCTAssertFalse(applet.canClearProgramPins)

    _ = add("a", layer: "one", to: applet)
    _ = add("a", layer: "two", to: applet)

    XCTAssertTrue(applet.canClearProgramPins)

    let accent = applet.commandLayers.layer(named: "two")?.accent

    applet.clearProgramPins()

    XCTAssertEqual(applet.commandLayers.totalPins, 0)
    XCTAssertEqual(ids(applet, "one"), [])
    XCTAssertEqual(ids(applet, "two"), [])
    XCTAssertEqual(applet.commandLayers.layer(named: "two")?.accent, accent)
    XCTAssertFalse(applet.canClearProgramPins)

    let declared = MapViewerApplet.commandSet.commands.map(\.name)

    XCTAssertTrue(declared.contains("clear-program-pins"))
  }

  // MARK: Reopen, restore, and the count

  /// Catches a layout file that carries a layer name, a label, or a pin from a program. Only the
  /// count of layers is in the payload. The undo-only part holds the rest.
  func testNothingFromAProgramIsInTheLayoutPayload() throws {
    let (applet, _, _) = pane()

    _ = add("secret-id", layer: "secret-layer", to: applet, label: "secret-label", accent: "red")

    let description = applet.describe()
    let payload = String(decoding: try JSONEncoder().encode(description.payload), as: UTF8.self)

    for word in ["secret-id", "secret-layer", "secret-label", "red"] {
      XCTAssertFalse(payload.contains(word), word)
    }

    XCTAssertEqual(try MapViewerDescription.decode(description).commandLayerCount, 1)
    XCTAssertNotNil(description.undoState)
  }

  /// Catches a reopen that loses the layers, shows them as fresh, or says something. A reopen
  /// brings the pins back marked as from an earlier run, with a status segment, and no notice. A
  /// source writing the layer clears the mark.
  func testReopenBringsBackLayersMarkedUntilASourceWritesThem() throws {
    let (applet, _, _) = pane()

    _ = add("a", layer: "one", to: applet, label: "A")
    _ = add("b", layer: "two", to: applet, label: "B")

    let reopened = try MapViewerApplet(restoring: applet.describe())
    let host = RecordingHost()

    reopened.host = host
    reopened.start(origin: .user)

    func subtitles(_ layer: String) -> [String?] {
      reopened.content.mapView.annotations.compactMap { $0 as? MapPinAnnotation }
        .filter { $0.layer == .command(layer) }.map(\.subtitle)
    }

    XCTAssertEqual(ids(reopened, "one"), ["a"])
    XCTAssertEqual(subtitles("one"), ["From an earlier run"])
    XCTAssertEqual(subtitles("two"), ["From an earlier run"])
    XCTAssertTrue(reopened.segments.map(\.text).contains("From an earlier run"))
    XCTAssertTrue(host.sent.isEmpty, "a reopen said \(host.sent)")
    XCTAssertEqual(reopened.record.commandLayerCount, 2)

    XCTAssertNil(add("c", layer: "one", to: reopened).code)

    XCTAssertEqual(subtitles("one"), [nil, nil])
    XCTAssertEqual(subtitles("two"), ["From an earlier run"])
    XCTAssertTrue(reopened.segments.map(\.text).contains("From an earlier run"))

    _ = send("clear", ["layer": .string("two")], to: reopened)

    XCTAssertFalse(reopened.segments.map(\.text).contains("From an earlier run"))
  }

  /// Catches a layer counted twice, and a layout rewritten for every pin. A name first holding pins
  /// raises the count and tells the host once. A rerun, an add, or a reopen and rerun does not.
  func testTheCountRisesOncePerLayerPerLaunch() throws {
    let (applet, host, _) = pane()

    func changes(_ body: () -> Void) -> Int {
      let before = host.changes

      body()

      return host.changes - before
    }

    XCTAssertEqual(changes { _ = self.add("a", layer: "one", to: applet) }, 1)
    XCTAssertEqual(changes { _ = self.add("b", layer: "one", to: applet) }, 0)
    XCTAssertEqual(
      changes {
        _ = self.send(
          "set-layer", ["layer": .string("one"), "pins": .array([self.pin("z")])], to: applet)
      }, 0)
    XCTAssertEqual(changes { _ = self.send("clear", ["layer": .string("one")], to: applet) }, 0)
    XCTAssertEqual(changes { _ = self.add("a", layer: "one", to: applet) }, 0)
    XCTAssertEqual(
      changes {
        _ = self.send("set-layer", ["layer": .string("empty"), "pins": .array([])], to: applet)
      }, 0)
    XCTAssertEqual(applet.record.commandLayerCount, 1)

    let reopened = try MapViewerApplet(restoring: applet.describe())
    let reopenedHost = RecordingHost()

    reopened.host = reopenedHost
    reopened.start(origin: .user)

    let saved = reopened.describe().payload

    _ = send("set-layer", ["layer": .string("one"), "pins": .array([pin("q")])], to: reopened)

    XCTAssertEqual(reopened.describe().payload, saved, "a rerun changed the saved description")
    XCTAssertEqual(reopened.record.commandLayerCount, 1)

    let before = reopenedHost.changes

    _ = add("a", layer: "two", to: reopened)

    XCTAssertEqual(reopened.record.commandLayerCount, 2)
    XCTAssertNotEqual(reopened.describe().payload, saved)
    XCTAssertEqual(reopenedHost.changes, before + 1)
  }

  /// Catches a relaunch that says nothing, one that says it twice, a notice that takes a turn on
  /// the bar, and one that claims pins were lost. A rebuild from the layout alone posts one info
  /// notice to the history, resets the count with one rewrite, and shows nothing on the map.
  func testARelaunchSaysHowManyLayersWereNotRestoredOnceAndResetsTheCount() throws {
    let (applet, _, _) = pane()

    _ = add("a", layer: "one", to: applet)
    _ = add("a", layer: "two", to: applet)
    _ = send("clear", ["layer": .string("two")], to: applet)

    let described = applet.describe()
    let layoutOnly = AppletDescription(
      type: described.type, version: described.version, payload: described.payload)
    let relaunched = try MapViewerApplet(restoring: layoutOnly)
    let host = RecordingHost()

    relaunched.host = host
    relaunched.start(origin: .restore)

    let text =
      "2 program layers held pins last session. Restore does not run programs, so they are not shown."

    XCTAssertEqual(host.records.map(\.text), [text])
    XCTAssertEqual(host.records.map(\.level), [.info])
    XCTAssertTrue(host.posts.isEmpty)
    XCTAssertTrue(host.attentions.isEmpty)
    XCTAssertEqual(host.changes, 1)
    XCTAssertEqual(relaunched.record.commandLayerCount, 0)
    XCTAssertTrue(relaunched.commandLayers.isEmpty)
    XCTAssertEqual(relaunched.content.explanationLines, [])

    relaunched.start(origin: .restore)

    XCTAssertEqual(host.records.count, 1)

    let again = try MapViewerApplet(restoring: relaunched.describe())
    let quiet = RecordingHost()

    again.host = quiet
    again.start(origin: .restore)

    XCTAssertTrue(quiet.sent.isEmpty)
  }

  /// Catches a one-layer notice that reads as a plural, and a fresh pane that says anything.
  func testTheRelaunchNoticeNamesOneLayerInTheSingularAndAFreshPaneIsQuiet() throws {
    let (applet, _, _) = pane()

    _ = add("a", to: applet)

    let described = applet.describe()
    let relaunched = try MapViewerApplet(
      restoring: AppletDescription(
        type: described.type, version: described.version, payload: described.payload))
    let host = RecordingHost()

    relaunched.host = host
    relaunched.start(origin: .restore)

    XCTAssertEqual(
      host.records.map(\.text),
      ["1 program layer held pins last session. Restore does not run programs, so it is not shown."]
    )

    let fresh = MapViewerApplet(startDirectory: nil)
    let quiet = RecordingHost()

    fresh.host = quiet
    fresh.start(origin: .user)

    XCTAssertTrue(quiet.sent.isEmpty)
  }

  // MARK: Versions

  /// Catches a command written for another major, or a minor the map lacks, running before it is
  /// refused. A caller written for 1.0, before the reset, is another major.
  func testACommandWrittenForAnotherVersionIsRefusedBeforeAnyEffect() {
    let (applet, _, _) = pane()

    for version in [
      AppletSchemaVersion(1, 0), AppletSchemaVersion(0, 1), AppletSchemaVersion(2, 0),
    ] {
      var fields: [String: JSONValue] = [:]

      if case .object(let pinFields) = pin("a") { fields = pinFields }

      XCTAssertEqual(send("add", fields, to: applet, version: version).code, .unsupportedVersion)
    }

    XCTAssertTrue(applet.commandLayers.isEmpty)
    XCTAssertEqual(applet.record.commandLayerCount, 0)
  }

  // MARK: The published schema

  /// Catches an example that a driver author would copy and the map would refuse, and an event the
  /// channel would drop. Every example validates against its own schema and runs on a fresh pane.
  /// Every event the pane emits validates against the declared event.
  func testEveryExampleRunsAndEveryEventFitsItsSchema() throws {
    let schema = MapViewerApplet.remoteSchema

    XCTAssertEqual(schema.appletType, "map-viewer")
    XCTAssertEqual(schema.version, AppletSchemaVersion(0, 0))
    XCTAssertEqual(
      schema.commands.map(\.name), ["add", "remove", "clear", "set-layer", "set-region"])
    XCTAssertEqual(schema.events.map(\.name), ["map-clicked", "pin-selected"])

    for message in schema.commands + schema.events {
      XCTAssertFalse(message.summary.isEmpty, message.name)
      XCTAssertNotEqual(message.example, .object([:]), message.name)
      XCTAssertNoThrow(
        try AppletValueSchema.object(message.arguments).validate(message.example, at: message.name))
    }

    let (applet, _, recorder) = pane()

    for command in schema.commands {
      guard case .object(let arguments) = command.example else { return XCTFail("not an object") }

      XCTAssertNil(send(command.name, arguments, to: applet).code, command.name)
    }

    _ = add("a", layer: "x", to: applet)

    let annotation = try XCTUnwrap(
      applet.content.mapView.annotations.compactMap { $0 as? MapPinAnnotation }.first)
    let view = MapMarkerView(annotation: annotation, reuseIdentifier: MapMarkerView.pinReuse)

    applet.content.mapView(applet.content.mapView, didSelect: view)
    applet.content.clickBegan(atWindowPoint: NSPoint(x: 100, y: 100), hit: applet.content.mapView)
    applet.content.clickEnded(atWindowPoint: NSPoint(x: 100, y: 100))

    XCTAssertEqual(recorder.events.map(\.name), ["pin-selected", "map-clicked"])

    for event in recorder.events {
      let declared = try XCTUnwrap(schema.event(named: event.name))

      guard case .object(let fields) = event.data else { return XCTFail("not an object") }

      XCTAssertNoThrow(try declared.arguments.validate(fields, at: event.name), "\(event)")
    }
  }

  // MARK: Events

  /// Catches a click event that carries a pin's coordinate, a drag reported as a click, a click on
  /// a pin, a callout, or another view, and a second report of one click.
  func testOnlyASinglePressAndReleaseOnTheEmptyMapIsAClick() throws {
    let (applet, _, recorder) = pane()
    let view = applet.content
    let point = NSPoint(x: 300, y: 200)

    view.clickBegan(atWindowPoint: point, hit: view.mapView)
    view.clickEnded(atWindowPoint: point)

    XCTAssertEqual(recorder.events.count, 1)
    XCTAssertEqual(recorder.events.first?.name, "map-clicked")

    let center = view.mapView.convert(point, toCoordinateFrom: view.mapView)

    guard case .object(let fields)? = recorder.events.first?.data,
      case .number(let latitude)? = fields["latitude"],
      case .number(let longitude)? = fields["longitude"]
    else { return XCTFail("no coordinate") }

    XCTAssertEqual(latitude, center.latitude, accuracy: 0.0001)
    XCTAssertEqual(longitude, center.longitude, accuracy: 0.0001)

    view.clickEnded(atWindowPoint: point)

    XCTAssertEqual(recorder.events.count, 1, "one click reported twice")

    view.clickBegan(atWindowPoint: point, hit: view.mapView)
    view.clickDragged(toWindowPoint: NSPoint(x: 340, y: 200))
    view.clickEnded(atWindowPoint: point)

    XCTAssertEqual(recorder.events.count, 1, "a drag was a click")

    view.clickBegan(atWindowPoint: point, hit: view.mapView)
    view.clickEnded(atWindowPoint: NSPoint(x: 340, y: 200))

    XCTAssertEqual(recorder.events.count, 1, "a press that ended elsewhere was a click")

    let marker = MapMarkerView(annotation: nil, reuseIdentifier: MapMarkerView.pinReuse)
    let inner = NSView()

    marker.addSubview(inner)
    view.mapView.addSubview(marker)

    let outside = NSView()

    for hit in [marker, inner, outside] as [NSView] {
      view.clickBegan(atWindowPoint: point, hit: hit)
      view.clickEnded(atWindowPoint: point)
    }

    view.clickBegan(atWindowPoint: point, hit: nil)
    view.clickEnded(atWindowPoint: point)

    XCTAssertEqual(recorder.events.count, 1, "a click off the empty map was reported")
  }

  /// Catches a command pin that is not named by layer and ID, a file pin that tells the driver
  /// anything from the file, and a cluster that reports a pin. Selecting a cluster zooms to its
  /// members.
  func testSelectionNamesACommandPinMarksAFilePinAndExpandsAClusterSilently() throws {
    let (applet, _, recorder) = pane()
    let view = applet.content

    _ = add("truck-7", layer: "trucks", to: applet)
    _ = add("truck-8", layer: "trucks", to: applet)

    let annotations = view.mapView.annotations.compactMap { $0 as? MapPinAnnotation }
    let first = try XCTUnwrap(annotations.first { $0.pin.id == "truck-7" })

    view.mapView(
      view.mapView,
      didSelect: MapMarkerView(annotation: first, reuseIdentifier: MapMarkerView.pinReuse))

    XCTAssertEqual(
      recorder.events.last?.data,
      .object([
        "source": .string("command"), "layer": .string("trucks"), "id": .string("truck-7"),
      ]))

    let secret = GeoPin(
      id: "3:0", coordinate: GeoCoordinate(latitude: 12.5, longitude: 99.5), label: "Secret home")
    let filePin = MapPinAnnotation(pin: secret, layer: .file, layerAccent: .blue)

    view.mapView(
      view.mapView,
      didSelect: MapMarkerView(annotation: filePin, reuseIdentifier: MapMarkerView.pinReuse))

    XCTAssertEqual(recorder.events.last?.data, .object(["source": .string("file")]))
    XCTAssertEqual(recorder.events.count, 2)

    let before = view.mapView.region.span.latitudeDelta
    let cluster = MKClusterAnnotation(memberAnnotations: annotations)

    view.mapView(
      view.mapView,
      didSelect: MapMarkerView(annotation: cluster, reuseIdentifier: MapMarkerView.clusterReuse))

    XCTAssertEqual(recorder.events.count, 2, "a cluster reported a pin")
    XCTAssertLessThan(view.mapView.region.span.latitudeDelta, before)
  }

  /// Catches a selection restored after a replaced layer that reports itself as the user's, and
  /// events queued for a driver that is not attached.
  func testARedrawnSelectionIsNotReportedAndNoDriverMeansNoEvents() throws {
    let (applet, _, recorder) = pane()
    let view = applet.content

    _ = add("a", layer: "x", to: applet)

    let annotation = try XCTUnwrap(
      view.mapView.annotations.compactMap { $0 as? MapPinAnnotation }.first)

    view.mapView.selectAnnotation(annotation, animated: false)
    recorder.reset()

    _ = send("set-layer", ["layer": .string("x"), "pins": .array([pin("a")])], to: applet)

    let again = try XCTUnwrap(view.mapView.annotations.compactMap { $0 as? MapPinAnnotation }.first)

    XCTAssertTrue(view.mapView.selectedAnnotations.contains { $0 === again })
    XCTAssertTrue(recorder.events.isEmpty, "\(recorder.events)")

    let (quiet, _, _) = pane()

    quiet.events.close()
    quiet.pinSelected(again)
    quiet.mapClicked(at: GeoCoordinate(latitude: 1, longitude: 1))
  }

  /// Catches a press on MapKit's own controls, such as the zoom control, that reports a click on
  /// the map. A control, and a view MapKit names as a control, compass, scale, or legal link, is
  /// not the empty map. A plain view of the map is.
  func testAPressOnAMapControlIsNotAClick() {
    let (applet, _, recorder) = pane()
    let view = applet.content
    let point = NSPoint(x: 300, y: 200)

    final class MKZoomControlStandIn: NSView {}
    final class MKCompassButtonStandIn: NSView {}

    let plain = NSView()
    let button = NSButton(title: "", target: nil, action: nil)
    let zoom = MKZoomControlStandIn()
    let compass = MKCompassButtonStandIn()
    let inner = NSView()

    compass.addSubview(inner)

    for child in [plain, button, zoom, compass] as [NSView] { view.mapView.addSubview(child) }

    for hit in [button, zoom, inner] as [NSView] {
      view.clickBegan(atWindowPoint: point, hit: hit)
      view.clickEnded(atWindowPoint: point)
    }

    XCTAssertTrue(recorder.events.isEmpty, "\(recorder.events)")

    view.clickBegan(atWindowPoint: point, hit: plain)
    view.clickEnded(atWindowPoint: point)

    XCTAssertEqual(recorder.events.count, 1)

    view.clickBegan(atWindowPoint: point, hit: plain, clickCount: 2)
    view.clickEnded(atWindowPoint: point)
    view.clickBegan(atWindowPoint: point, hit: plain, control: true)
    view.clickEnded(atWindowPoint: point)

    XCTAssertEqual(recorder.events.count, 1)
  }

  /// Catches a restored selection that swallows the user's next real one. When MapKit never
  /// reports the restored selection, deselecting the pin clears the mark, so the next selection is
  /// reported.
  func testADeselectClearsARestoredSelectionMarkSoTheNextSelectIsReported() throws {
    let (applet, _, recorder) = pane()
    let view = applet.content

    _ = add("a", layer: "x", to: applet)

    let annotation = try XCTUnwrap(
      view.mapView.annotations.compactMap { $0 as? MapPinAnnotation }.first)
    let marker = MapMarkerView(annotation: annotation, reuseIdentifier: MapMarkerView.pinReuse)

    view.markSelectionRestored(annotation)
    view.mapView(view.mapView, didDeselect: marker)
    view.mapView(view.mapView, didSelect: marker)

    XCTAssertEqual(recorder.events.count, 1)
  }

  /// Catches a pane that leaves its driver attached after it closes.
  func testClosingThePaneClosesItsEventOutlet() {
    let (applet, _, _) = pane()

    applet.close()

    XCTAssertTrue(applet.events.isClosed)
  }
}

extension JSONValue {
  fileprivate var objectFields: [String: JSONValue] {
    if case .object(let fields) = self { return fields }

    return [:]
  }

  fileprivate func objectField(_ name: String) -> JSONValue {
    objectFields[name] ?? .null
  }
}
