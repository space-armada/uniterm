import AppKit
import AppletKit
import PaneModel
import ScriptHost
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import WindowKit

/// The badge against a real scripting host, wired to the window set the way the app wires it. A
/// raw peer from the test process connects, and the test process stands in for the pane's session
/// root, so the peer binds through ancestry. This proves the badge follows controllers that come
/// and go with no change to the pane tree. It cannot prove what the menu looks like on screen.
@MainActor
final class ControllerBadgeTests: XCTestCase {
  /// Catches a badge whose Revoke Controller stays off, and that names no one, while a program
  /// acts from the pane. A connection that binds through ancestry changes nothing in the tree, so
  /// only the host's report can refresh the badge. When the connection closes, the badge drops it.
  func testTheBadgeNamesAControllerThatBindsAndDropsItWhenItCloses() async throws {
    let fixture = ScriptingFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("wk-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let center = StatusCenter()
    let host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) },
      windows: fixture.scripting)

    host.start()
    addTeardownBlock { @MainActor in host.stop() }
    fixture.windows.wireControllers(to: host)

    let (controller, _) = try fixture.openWindow()
    let pane = controller.focusedPane
    let view = try XCTUnwrap(controller.paneArea.paneView(for: pane))

    TestSessionRoot.record(in: host, window: controller.scriptWindowID, pane: pane)

    XCTAssertEqual(view.controlMark?.revokeAvailable, false)

    let peer = try await ScriptPeer.hello(to: host.instanceAddress)
    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.begin(name: "badge-test").frame())

    await ScriptPeer.settle { view.controlMark?.revokeAvailable == true }

    let mark = try XCTUnwrap(view.controlMark)

    XCTAssertTrue(mark.revokeAvailable, "the badge never offered to revoke the controller")
    XCTAssertEqual(mark.controllers, ["badge-test (PID \(getpid()))"])
    XCTAssertTrue(mark.summary.contains("Controller: badge-test (PID \(getpid()))"))
    XCTAssertEqual(view.currentControlMark?(), mark)

    let revoke = view.controlMenu().items.first { $0.title == "Revoke Controller" }

    XCTAssertEqual(revoke?.isEnabled, true)

    peer.shutdownAndClose()

    await ScriptPeer.settle { view.controlMark?.revokeAvailable == false }

    XCTAssertEqual(view.controlMark?.controllers, [])
    XCTAssertEqual(view.controlMark?.revokeAvailable, false)
  }

  /// Catches an acting pane that no marker names. A connection binds to the first pane through
  /// ancestry and group-less, so only the host's report of who acts from the pane can mark it. The
  /// pane's applet takes sent content, so it carries the controller's grant on the turn it binds.
  /// Disconnecting the pane clears it, though the connection stays open, and the closing
  /// connection clears it too.
  func testAControllerActingFromAPaneMarksItUntilTheUserDisconnectsIt() async throws {
    let fixture = ScriptingFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("wk-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let center = StatusCenter()
    let host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) },
      windows: fixture.scripting)

    host.start()
    addTeardownBlock { @MainActor in host.stop() }
    fixture.windows.wireControllers(to: host)

    let (controller, _) = try fixture.openWindow()
    let pane = controller.focusedPane
    let applet = try XCTUnwrap(controller.paneArea.applet(for: pane) as? FakeApplet)

    TestSessionRoot.record(in: host, window: controller.scriptWindowID, pane: pane)

    XCTAssertEqual(applet.authority.owners, [], "a pane no controller acts from was marked")

    let peer = try await ScriptPeer.hello(to: host.instanceAddress)
    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.begin(name: "marker-test").frame())

    await ScriptPeer.settle { !applet.authority.owners.isEmpty }

    let ids = host.controllers(actingFrom: controller.scriptWindowID, pane: pane)

    XCTAssertEqual(ids.count, 1)
    XCTAssertEqual(
      applet.authority.owners,
      Set(ids.map { AppletCaller(grant: GroupOwner(connection: $0).description) }))
    XCTAssertEqual(applet.publishedTabs.first.markers[.authority]?.owners, applet.authority.owners)
    XCTAssertEqual(
      controller.paneArea.paneView(for: pane)?.paneMarkers.map(\.kind), [.authority])

    controller.disconnect(pane)

    XCTAssertEqual(applet.authority.owners, [], "the disconnected pane stayed marked")
    XCTAssertEqual(controller.paneArea.paneView(for: pane)?.paneMarkers, [])

    controller.enableRemoteControl(pane)

    await ScriptPeer.settle { !applet.authority.owners.isEmpty }

    peer.shutdownAndClose()

    await ScriptPeer.settle { applet.authority.owners.isEmpty }

    XCTAssertEqual(applet.authority.owners, [])
  }
}
