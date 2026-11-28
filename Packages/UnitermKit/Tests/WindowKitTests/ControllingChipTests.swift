import AppKit
import AppletKit
import HelperWire
import PaneModel
import ProcessInspection
import ScriptHost
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import WindowKit

/// The controlling chip against a real scripting host, wired to the window set the way the app
/// wires it. A raw peer from the test process connects, and the test process stands in for the
/// session root of a pane's tab, so the peer binds through ancestry. These prove which tab holds
/// the chip and when it comes and goes. They cannot prove how the chip looks on screen.
@MainActor
final class ControllingChipTests: XCTestCase {
  /// A window with a real host, and a fake applet with two tabs in its first pane.
  @MainActor
  private struct Rig {
    let fixture: ScriptingFixture
    let host: ScriptHost
    let controller: MainWindowController
    let pane: NodeID
    let applet: FakeApplet
    let reference: ScriptPaneReference
    let address: String

    var tabs: [AppletTabID] { applet.tabIDs }

    func startSession(
      in tab: AppletTabID, generation: UInt64 = 1,
      identity: ProcessIdentity = TestSessionRoot.identity
    ) {
      controller.applet(
        applet, in: pane, sessionStarted: tab, pid: identity.pid, started: identity.started,
        generation: generation)
    }

    func endSession(in tab: AppletTabID, identity: ProcessIdentity = TestSessionRoot.identity) {
      controller.applet(
        applet, in: pane, sessionEnded: tab, pid: identity.pid, started: identity.started)
    }

    var firstController: UInt64? {
      host.controllers(actingFrom: controller.scriptWindowID, pane: pane).first
    }

    func chipNames(onTab index: Int) -> [String] {
      applet.publishedTabs.all[index].markers[.chip]?.controllers ?? []
    }
  }

  private var peers: [FramedSocket] = []

  override func tearDown() async throws {
    for peer in peers { peer.shutdownAndClose() }

    peers = []
  }

  private func makeRig(tabCount: Int = 2) throws -> Rig {
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
    fixture.windows.wireSessionReporting(
      onStarted: { [weak host] window, pane, _, pid, started, generation in
        host?.recordSessionRoot(
          ProcessIdentity(pid: pid, started: started), sessionGeneration: generation,
          window: window, pane: pane)
      },
      onEnded: { [weak host] window, pane, _, pid, started in
        host?.removeSessionRoot(
          ProcessIdentity(pid: pid, started: started), window: window, pane: pane)
      },
      onWindowClosed: { [weak host] window in host?.windowClosed(window) })

    let (controller, reference) = try fixture.openWindow()
    let pane = controller.focusedPane
    let applet = try XCTUnwrap(controller.paneArea.applet(for: pane) as? FakeApplet)

    applet.tabCount = tabCount
    controller.refreshControlMarks()

    return Rig(
      fixture: fixture, host: host, controller: controller, pane: pane, applet: applet,
      reference: reference, address: host.instanceAddress)
  }

  private func connect(_ rig: Rig, name: String) async throws -> FramedSocket {
    let peer = try await ScriptPeer.hello(to: rig.address)

    peers.append(peer)

    try peer.send(ScriptHelperMessage.begin(name: name).frame())

    return peer
  }

  private func name(_ script: String) -> String { "\(script) (PID \(getpid()))" }

  /// Catches a chip on the wrong tab, on every tab, or at the pane level beside a visible bar. A
  /// controller started in the second tab of a two-tab pane puts the chip on that tab only, on the
  /// turn it binds, and names the controller as the badge does. The pane shows a bar, so no marker
  /// sits beside the badge.
  func testAControllerStartedInTheSecondTabMarksThatTabOnly() async throws {
    let rig = try makeRig()

    rig.startSession(in: rig.tabs[1])

    XCTAssertEqual(rig.chipNames(onTab: 1), [])

    _ = try await connect(rig, name: "second")

    await ScriptPeer.settle { !rig.chipNames(onTab: 1).isEmpty }

    XCTAssertEqual(rig.chipNames(onTab: 1), [name("second")])
    XCTAssertEqual(rig.chipNames(onTab: 0), [])
    XCTAssertEqual(rig.controller.paneArea.paneView(for: rig.pane)?.paneMarkers, [])
    XCTAssertEqual(
      rig.controller.controlMark(for: rig.pane).controllers, [name("second")],
      "the chip and the badge named the controller differently")
  }

  /// Catches a one-tab pane whose chip is left out of the pane-level markers. The pane has no
  /// bar, so the chip sits beside the badge, and it names the controller. The fake takes commands, so
  /// the pane carries the authority marker too, and the two draw in kind order.
  func testAOneTabPaneShowsItsChipBesideTheBadge() async throws {
    let rig = try makeRig(tabCount: 1)

    rig.startSession(in: rig.tabs[0])

    _ = try await connect(rig, name: "solo")

    await ScriptPeer.settle { !rig.chipNames(onTab: 0).isEmpty }

    let markers = try XCTUnwrap(rig.controller.paneArea.paneView(for: rig.pane)?.paneMarkers)

    XCTAssertEqual(markers.map(\.kind), [.authority, .chip])
    XCTAssertEqual(markers.last?.controllers, [name("solo")])
  }

  /// Catches a chip that lingers after its session ends, or one that fails to return in a restarted
  /// session. Ending the session clears the chip on that turn though the connection stays open.
  /// A controller that connects after the restart gets the chip on the same tab.
  func testASessionEndingClearsTheChipAndARestartedSessionShowsItAgainOnTheSameTab() async throws {
    let rig = try makeRig()

    rig.startSession(in: rig.tabs[1])

    _ = try await connect(rig, name: "first")

    await ScriptPeer.settle { !rig.chipNames(onTab: 1).isEmpty }

    XCTAssertEqual(rig.chipNames(onTab: 1), [name("first")])

    let id = try XCTUnwrap(rig.firstController)

    rig.endSession(in: rig.tabs[1])

    XCTAssertEqual(rig.chipNames(onTab: 1), [], "the chip outlived its session")
    XCTAssertNotNil(
      rig.host.controllerName(id), "the connection closed")

    rig.startSession(in: rig.tabs[1], generation: 2)

    _ = try await connect(rig, name: "again")

    await ScriptPeer.settle { !rig.chipNames(onTab: 1).isEmpty }

    XCTAssertEqual(rig.chipNames(onTab: 1), [name("again")])
    XCTAssertEqual(rig.chipNames(onTab: 0), [])
  }

  /// Catches a connection whose bind is applied before the chip is, so the chip trails the bind by
  /// a turn. The host reports every change of who acts through one callback, and the window
  /// refreshes inside it. A test hook after the window's own refresh records, on each report,
  /// whether the connection acts for the pane and what the chip shows right then. Every report
  /// that sees the connection acting also sees the chip. This proves the chip is drawn inside the
  /// bind's own report. It cannot say when the socket delivered the bind.
  func testTheChipIsDrawnInsideTheReportThatTheConnectionBinds() async throws {
    let rig = try makeRig()
    var reports: [(acting: Bool, chip: [String])] = []
    let window = rig.controller.scriptWindowID
    let previous = rig.host.onControllersChanged

    rig.host.onControllersChanged = {
      previous?()
      reports.append(
        (
          !rig.host.controllers(actingFrom: window, pane: rig.pane).isEmpty,
          rig.chipNames(onTab: 1)
        ))
    }

    rig.startSession(in: rig.tabs[1])
    _ = try await connect(rig, name: "sameturn")

    await ScriptPeer.settle { reports.contains { $0.acting } }

    let acting = reports.filter(\.acting)

    XCTAssertFalse(acting.isEmpty, "the bind never reported")
    XCTAssertTrue(
      acting.allSatisfy { !$0.chip.isEmpty }, "a report saw the connection acting with no chip")
  }

  /// Catches a chip that survives its script's lapsed ancestry, and a lapse that unbinds on any
  /// path but the next call. The controller binds through its parent, which is recorded as the
  /// session root. Recording the test process as a nearer root leads its ancestry elsewhere. The
  /// host's query then names no root, but the binding stands until the connection's next call,
  /// which is refused and unbinds it. The unbind ends the controller's authority, and the window's
  /// refresh inside that same call takes the chip away. So the chip is gone by the time the refusal
  /// is read. No refresh runs between the lapse and the call, so that call is the turn that drops
  /// it.
  func testALapsedAncestryLosesTheChipByTheEndOfTheNextCall() async throws {
    let rig = try makeRig()
    let parentPid = getppid()
    let parent = ProcessIdentity(
      pid: parentPid, started: try XCTUnwrap(ProcessInspection.startTime(of: parentPid)))

    rig.startSession(in: rig.tabs[1], identity: parent)

    let peer = try await connect(rig, name: "lapse")

    await ScriptPeer.settle { !rig.chipNames(onTab: 1).isEmpty }

    let id = try XCTUnwrap(rig.firstController)

    XCTAssertEqual(rig.chipNames(onTab: 1), [name("lapse")])

    rig.startSession(in: rig.tabs[0])

    XCTAssertNil(rig.host.controllerSessionRoot(id), "the query still named the lapsed root")
    XCTAssertEqual(
      rig.chipNames(onTab: 1), [name("lapse")], "the chip dropped before the controller's next call"
    )

    try peer.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    let frame = try await Task.detached {
      try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    }.value
    let reply = try ScriptAppMessage.decode(type: frame.type, body: frame.body)

    guard case .reply(1, .failure(.refused, _)) = reply else {
      return XCTFail("the call after the lapse was not refused: \(reply)")
    }

    XCTAssertEqual(rig.chipNames(onTab: 1), [], "the chip outlived the refused call")
    XCTAssertEqual(
      rig.host.controllers(actingFrom: rig.controller.scriptWindowID, pane: rig.pane), [])
  }

  /// Catches a session record that outlives its pane. A session whose end its applet never reports
  /// leaves an entry, and a pane that closes must drop it. A window's entries go with its
  /// controller, which holds them. The record is kept for another pane only while it runs.
  func testClosingAPaneDropsTheSessionRecordsItNeverReportedEnding() async throws {
    let rig = try makeRig(tabCount: 1)
    let spare = try await rig.fixture.openOwned(beside: rig.reference)
    let other = try XCTUnwrap(rig.controller.paneArea.applet(for: spare) as? FakeApplet)
    let sleeper = ProcessIdentity(pid: getppid(), started: 7)

    rig.controller.applet(
      other, in: spare, sessionStarted: other.tabIDs[0], pid: sleeper.pid, started: sleeper.started,
      generation: 1)
    rig.startSession(in: rig.tabs[0])

    XCTAssertEqual(rig.controller.sessionTabs.count, 2)

    rig.controller.closePane(spare, appletEnded: false)

    XCTAssertEqual(rig.controller.sessionTabs.count, 1, "the closed pane's record stayed")
    XCTAssertEqual(rig.controller.sessionTabs.values.first?.pane, rig.pane)
  }

  /// Catches a chip that stays after the user disconnects the controller's pane while it owns no
  /// group. The badge still names the controller. Enabling the pane again brings the chip back on
  /// the same turn.
  func testDisconnectingTheSourcePaneOfAGrouplessControllerClearsTheChip() async throws {
    let rig = try makeRig()

    rig.startSession(in: rig.tabs[1])
    _ = try await connect(rig, name: "groupless")

    await ScriptPeer.settle { !rig.chipNames(onTab: 1).isEmpty }

    rig.controller.disconnect(rig.pane)

    XCTAssertEqual(rig.chipNames(onTab: 1), [])
    XCTAssertEqual(rig.controller.controlMark(for: rig.pane).controllers, [name("groupless")])

    rig.controller.enableRemoteControl(rig.pane)

    XCTAssertEqual(rig.chipNames(onTab: 1), [name("groupless")])
  }

  /// Catches a chip that survives Revoke Controller, or one that ends the connection to clear. The
  /// connection stays open, and the chip goes on the turn of the revoke.
  func testRevokingAControllerClearsItsChipWhileItsConnectionStaysOpen() async throws {
    let rig = try makeRig()

    rig.startSession(in: rig.tabs[1])

    _ = try await connect(rig, name: "revoked")

    await ScriptPeer.settle { !rig.chipNames(onTab: 1).isEmpty }

    let id = try XCTUnwrap(rig.firstController)

    rig.controller.revokeController(rig.pane)

    XCTAssertEqual(rig.chipNames(onTab: 1), [])
    XCTAssertNotNil(rig.host.controllerName(id), "the revoke closed the connection")
  }

  /// Catches a chip that follows only the pane's mode. A connection that owns a group keeps its
  /// chip when the user disconnects its pane, and loses it when the group's owner changes. Closing
  /// the last member dissolves the group, which clears the chip of a controller that owns no other.
  func testAnOwnedGroupKeepsTheChipWhilePaneIsDisconnectedUntilTheOwnerChanges() async throws {
    let rig = try makeRig()

    rig.startSession(in: rig.tabs[1])
    _ = try await connect(rig, name: "owner")

    await ScriptPeer.settle { !rig.chipNames(onTab: 1).isEmpty }

    let id = try XCTUnwrap(
      rig.host.controllers(actingFrom: rig.controller.scriptWindowID, pane: rig.pane).first)

    rig.fixture.caller = ScriptCaller(
      connection: id, window: rig.controller.scriptWindowID, pane: rig.pane)

    let member = try await rig.fixture.openOwned(beside: rig.reference)

    rig.controller.disconnect(rig.pane)

    XCTAssertEqual(rig.chipNames(onTab: 1), [name("owner")], "owning a group did not keep the chip")

    rig.controller.closePane(member, appletEnded: false)

    XCTAssertEqual(rig.chipNames(onTab: 1), [], "the dissolved group kept the chip")

    rig.controller.enableRemoteControl(rig.pane)

    let again = try await rig.fixture.openOwned(beside: rig.reference)

    rig.controller.disconnect(rig.pane)

    XCTAssertEqual(rig.chipNames(onTab: 1), [name("owner")])

    rig.controller.ownerEnded(GroupOwner(connection: id))

    XCTAssertEqual(rig.chipNames(onTab: 1), [], "the owner change kept the chip")
    XCTAssertTrue(rig.controller.contains(pane: again))
  }

  /// Catches an explicit grant whose chip lands on the wrong tab. A program outside the panes asks
  /// for access, the user grants it the pane, and the chip shows on the tab of the pane's newest
  /// running session. The test process cannot be both the ancestor and the outsider, so a sleep
  /// process stands in for the session root.
  func testAnExplicitGrantMarksTheTabOfTheNewestSession() async throws {
    let rig = try makeRig()
    let sleeper = Process()

    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["120"]
    try sleeper.run()
    addTeardownBlock { sleeper.terminate() }

    let identity = ProcessIdentity(
      pid: sleeper.processIdentifier,
      started: try XCTUnwrap(ProcessInspection.startTime(of: sleeper.processIdentifier)))

    rig.startSession(in: rig.tabs[0], generation: 1, identity: identity)

    let peer = try await connect(rig, name: "granted")

    try peer.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())
    _ = try await Task.detached {
      try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    }.value

    let request = try XCTUnwrap(rig.host.allPendingRequests().first)

    XCTAssertEqual(
      rig.host.grantAccess(
        connection: request.id, window: rig.controller.scriptWindowID, pane: rig.pane), .granted)

    XCTAssertEqual(rig.chipNames(onTab: 0), [name("granted")])
    XCTAssertEqual(rig.chipNames(onTab: 1), [])

    rig.endSession(in: rig.tabs[0], identity: identity)

    XCTAssertEqual(rig.chipNames(onTab: 0), [], "the grant's chip outlived its session")
  }

  /// Catches a REPL helper that shows a chip while its pane is disconnected, or none while the
  /// pane is controlled. The helper attaches through its channel's token, as the app's helper does.
  func testAReplsAttachedHelperShowsNoChipWhileItsPaneIsDisconnected() async throws {
    let rig = try makeRig(tabCount: 1)

    rig.startSession(in: rig.tabs[0])
    rig.controller.disconnect(rig.pane)

    let channel = rig.host.openRepl(history: [])

    TestSessionRoot.set(on: channel)

    let token = try XCTUnwrap(Self.decodeHex(channel.launch.token))
    let peer = try await ScriptPeer.hello(to: rig.address)

    peers.append(peer)

    try peer.send(ScriptHelperMessage.attach(token: token).frame())

    await ScriptPeer.settle {
      !rig.host.controllers(actingFrom: rig.controller.scriptWindowID, pane: rig.pane).isEmpty
    }

    XCTAssertEqual(rig.chipNames(onTab: 0), [], "a disconnected pane showed the REPL's chip")
    XCTAssertEqual(rig.controller.controlMark(for: rig.pane).controllers, [name("repl")])

    rig.controller.enableRemoteControl(rig.pane)

    XCTAssertEqual(rig.chipNames(onTab: 0), [name("repl")])
  }

  private static func decodeHex(_ text: String) -> Data? {
    var data = Data()
    var index = text.startIndex

    while index < text.endIndex {
      guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
        let byte = UInt8(text[index..<next], radix: 16)
      else { return nil }

      data.append(byte)
      index = next
    }

    return data
  }

  /// Catches a driven, remote-controlled pane that shows one marker, or shows them out of order, or
  /// whose badge reach leaves one out. A pane that a granted owner can address and a driver is
  /// attached to carries the authority marker and the chip. They draw beside the badge in kind
  /// order, and the reach sent to the applet covers the leading edge of both. The fake publishes
  /// through the same shared helper the image and map viewers use.
  func testADrivenPaneCarriesBothMarkersAndTheReachCoversBoth() throws {
    let fixture = ScriptingFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let (controller, _) = try fixture.openWindow()
    let pane = controller.focusedPane
    let applet = try XCTUnwrap(controller.paneArea.applet(for: pane) as? FakeApplet)
    let view = try XCTUnwrap(controller.paneArea.paneView(for: pane))

    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.layoutSubtreeIfNeeded()
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    applet.authorityDidChange(
      PaneAuthority(owners: [AppletCaller(grant: "connection 9")], drivers: ["perl (driver)"]))

    XCTAssertEqual(view.paneMarkers.map(\.kind), [.authority, .chip])
    XCTAssertEqual(view.paneMarkers.last?.controllers, ["perl (driver)"])

    let views = view.subviews.compactMap { $0 as? AppletMarkerView }
      .sorted { $0.frame.minX < $1.frame.minX }

    XCTAssertEqual(views.map(\.kind), [.authority, .chip], "the markers drew out of order")

    let reach = try XCTUnwrap(applet.badgeReaches.last)

    XCTAssertGreaterThan(applet.view.frame.width, 0)

    for marker in views {
      XCTAssertGreaterThanOrEqual(
        reach, applet.view.frame.maxX - marker.frame.minX, "the reach left out \(marker.kind)")
    }

    XCTAssertEqual(
      reach,
      PaneFrameView.badgeReach(
        badge: NSRect(x: views[0].frame.minX, y: 0, width: 0, height: 0),
        appletFrame: applet.view.frame))
  }

  /// Catches a driver's chip drawn only while the pane has no bar. The drivers' chip joins the
  /// markers of a one-tab pane, and shows beside a visible bar too, where the tabs carry nothing
  /// of their own.
  func testADriversChipShowsWhetherOrNotThePaneHasABar() {
    let one = AppletTabList(first: AppletTab(id: .make(), title: "one"))
    let two = AppletTabList(
      first: AppletTab(id: .make(), title: "a"), rest: [AppletTab(id: .make(), title: "b")])
    let driver = ["perl (driver)"]

    XCTAssertEqual(
      MainWindowController.paneLevelMarkers(of: one, driverNames: driver),
      [AppletMarker(kind: .chip, controllers: driver)])
    XCTAssertEqual(
      MainWindowController.paneLevelMarkers(of: two, driverNames: driver),
      [AppletMarker(kind: .chip, controllers: driver)])
    XCTAssertEqual(MainWindowController.paneLevelMarkers(of: two, driverNames: []), [])

    var published = AppletTab(id: .make(), title: "one")

    published.markers.insert(AppletMarker(kind: .chip, controllers: driver))

    XCTAssertEqual(
      MainWindowController.paneLevelMarkers(
        of: AppletTabList(first: published), driverNames: driver),
      [AppletMarker(kind: .chip, controllers: driver)], "a published chip showed its driver twice")
  }

  /// Catches a chip and the authority marker that disagree about order, or a driven pane that
  /// shows one of them. A one-tab pane carrying the authority marker and a driver's chip draws
  /// both, authority first.
  func testAPaneWithBothMarkersDrawsThemInOrder() {
    var tab = AppletTab(id: .make(), title: "one")

    tab.markers.insert(AppletMarker(kind: .authority, owners: [AppletCaller(grant: "x")]))

    let markers = MainWindowController.paneLevelMarkers(
      of: AppletTabList(first: tab), driverNames: ["perl (driver)"])

    XCTAssertEqual(markers.map(\.kind), [.authority, .chip])
  }
}
