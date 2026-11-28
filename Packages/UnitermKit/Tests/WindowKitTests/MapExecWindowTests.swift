import AppKit
import AppletKit
import ExecTestSupport
import PaneModel
import ScriptHost
import ScriptWire
import XCTest

@testable import MapViewerApplet
@testable import WindowKit

/// Real windows whose panes hold a real map, a real driver process, and the window side of the host
/// API. The package tests of the map prove each command. These prove the path from a driver's
/// stdout, or a script's call, to the map's layers, and that a driver or caller written for another
/// schema version never reaches them.
@MainActor
final class MapExecWindowTests: XCTestCase {
  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func mapPane(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController
  ) throws -> (pane: NodeID, map: MapViewerApplet) {
    fixture.nextIsMap = true
    controller.openPane(.terminalShell, axis: .row)

    let pane = controller.focusedPane

    return (pane, try XCTUnwrap(controller.paneArea.applet(for: pane) as? MapViewerApplet))
  }

  /// Catches a driven map that shows the authority marker. The driver commands its own pane
  /// through its attached channel, and no connection is acting for it, so the map's one tab carries
  /// no marker whether the pane is disconnected or remote-controlled.
  func testADrivenMapCarriesNoAuthorityMarker() throws {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let controller = try fixture.openWindow()
    let (pane, map) = try mapPane(fixture, controller)

    XCTAssertNil(map.publishedTabs.first.markers[.authority])

    controller.enableRemoteControl(pane)

    XCTAssertEqual(controller.paneAuthority(for: pane).owners, [])
    XCTAssertNil(map.publishedTabs.first.markers[.authority])
  }

  /// Catches a real map pane that shows only one of its two markers when a granted owner can
  /// address it and a driver is attached. Its one tab carries both in kind order, and the window
  /// draws both beside the badge.
  func testARealMapCarriesTheAuthorityMarkerAndTheChipInOrder() throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, map) = try mapPane(fixture, controller)

    controller.enableRemoteControl(pane)
    map.authorityDidChange(
      PaneAuthority(owners: [AppletCaller(grant: "connection 9")], drivers: ["perl (driver)"]))

    XCTAssertEqual(map.publishedTabs.first.markers.ordered.map(\.kind), [.authority, .chip])
    XCTAssertEqual(
      controller.paneArea.paneView(for: pane)?.paneMarkers.map(\.kind), [.authority, .chip])
  }

  private func waitUntil(
    _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)

    while !condition() {
      guard Date() < deadline else {
        return XCTFail("timed out waiting until \(what)", file: file, line: line)
      }

      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func pin(_ id: String, _ latitude: Double, _ longitude: Double) -> String {
    #"{"id":"\#(id)","coordinate":{"latitude":\#(latitude),"longitude":\#(longitude)},"label":"Pin \#(id)"}"#
  }

  private func run(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController, _ pane: NodeID,
    mode: String = "script", schema: String = "0.0", _ messages: [String]
  ) throws {
    try controller.declareExecDriver(
      ExecDeclaration(
        arguments: ExecTestDriver.arguments(mode, type: "map-viewer", schema: schema, messages),
        directory: nil, environmentKeys: []),
      for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)
  }

  /// Catches a driver whose stdout never reaches the map, a map that asks to be confirmed on close
  /// while its driver runs, and a remote caller that reaches a different map. The driver replaces
  /// a layer with set-layer, a script run again replaces its own pins, and a remote add lands in the
  /// same layers through the same dispatch.
  func testADriverPlacesPinsAndARemoteCallerReachesTheSameMap() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, map) = try mapPane(fixture, controller)
    let layer =
      #"{"name":"set-layer","arguments":{"layer":"trucks","pins":[\#(pin("a", 1, 2)),\#(pin("b", 3, 4))]}}"#
    let rerun = #"{"name":"set-layer","arguments":{"layer":"trucks","pins":[\#(pin("c", 5, 6))]}}"#
    let add = #"{"name":"add","arguments":\#(pin("d", 7, 8))}"#

    try run(fixture, controller, pane, [layer, add, rerun])

    await waitUntil("the driver finishes its commands") {
      map.commandLayers.layer(named: "trucks")?.pins.map(\.id) == ["c"]
        && map.commandLayers.layer(named: "default")?.pins.map(\.id) == ["d"]
    }

    XCTAssertFalse(map.isRunningSomething, "closing a map with a driver asks nothing")
    XCTAssertEqual(controller.control(of: pane).driver, .exec)

    do {
      _ = try await fixture.command(
        controller, pane, "clear", "{}", type: "map-viewer",
        version: ScriptSchemaVersion(major: 0))
      XCTFail("a disconnected pane took a remote command")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    controller.enableRemoteControl(pane)

    let reply = try await fixture.command(
      controller, pane, "add",
      #"{"layer":"trucks","id":"e","coordinate":{"latitude":9,"longitude":10}}"#,
      type: "map-viewer",
      version: ScriptSchemaVersion(major: 0))

    XCTAssertEqual(
      reply, .record(["layer": .string("trucks"), "pins": .integer(2)]))
    XCTAssertEqual(map.commandLayers.layer(named: "trucks")?.pins.map(\.id), ["c", "e"])
    XCTAssertEqual(map.record.commandLayerCount, 2)

    for version in [
      ScriptSchemaVersion(major: 1), ScriptSchemaVersion(major: 0, minor: 1),
      ScriptSchemaVersion(major: 2),
    ] {
      do {
        _ = try await fixture.command(
          controller, pane, "clear", #"{"layer":"trucks"}"#, type: "map-viewer",
          version: version)
        XCTFail("\(version) ran")
      } catch let error as ScriptCallError {
        XCTAssertEqual(error.kind, .unsupported)
      }
    }

    XCTAssertEqual(map.commandLayers.layer(named: "trucks")?.pins.map(\.id), ["c", "e"])
  }

  /// Catches a driver written for another schema version, or one that refuses the app's hello,
  /// that still places a pin. Each driver sends an add that must never land.
  func testADriverOnAnotherSchemaOrOneThatRefusesTheAppPlacesNothing() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let add = #"{"name":"add","arguments":\#(pin("x", 1, 2))}"#

    let cases: [(mode: String, schema: String, needle: String)] = [
      ("script", "2.0", "schema version 2.0"),
      ("script", "1.0", "schema version 1.0"),
      ("script", "0.1", "schema version 0.1"),
      ("refuse", "0.0", "needs exec protocol 9"),
    ]

    for (mode, schema, needle) in cases {
      let (pane, map) = try mapPane(fixture, controller)

      try run(fixture, controller, pane, mode: mode, schema: schema, [add])

      await waitUntil("\(mode) \(schema) ends") {
        if case .ended? = controller.execAttachments[pane]?.state { return true }
        return false
      }

      // The channel refuses the hello and ends before it ever connects. It handles a command only
      // while connected, and the end is final, so nothing after the end can reach the map.
      XCTAssertTrue(map.commandLayers.isEmpty, "\(mode) \(schema) placed a pin")

      if case .ended(let why)? = controller.execAttachments[pane]?.state {
        XCTAssertTrue(why.contains(needle), "\(mode) \(schema): \(why)")
      }
    }
  }

  /// Catches a script call past the argument bound that reaches the map. The wire cuts a call at
  /// 32 KiB, so a full layer of ordinary pins arrives as text that is not JSON, and the window
  /// refuses it before the map sees a command.
  func testAScriptCallPastTheArgumentBoundIsRefusedBeforeTheMap() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, map) = try mapPane(fixture, controller)

    controller.enableRemoteControl(pane)

    let cut = String(
      #"{"layer":"big","pins":["#
        + (0..<2_000).map { pin("p\($0)", 1, 2) }.joined(separator: ",") + "]}"
    )
    .prefix(ScriptProtocol.maxCommandArgumentBytes)

    do {
      _ = try await fixture.command(
        controller, pane, "set-layer", String(cut), type: "map-viewer",
        version: ScriptSchemaVersion(major: 0))
      XCTFail("a cut call ran")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .badArgument)
    }

    XCTAssertTrue(map.commandLayers.isEmpty)
  }
}
