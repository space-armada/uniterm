import AppKit
import AppletKit
import PaneModel
import QuestionsApplet
import XCTest

@testable import WindowKit

/// The authority marker as the window computes it and draws it, with real windows, real groups,
/// and fake applets. These prove what the host hands each applet and what a pane draws beside its
/// badge. They cannot prove how the marker looks on screen.
@MainActor
final class PaneAuthorityTests: XCTestCase {
  private func makeFixture() -> ScriptingFixture {
    let fixture = ScriptingFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func fake(_ controller: MainWindowController, _ pane: NodeID) throws -> FakeApplet {
    try XCTUnwrap(controller.paneArea.applet(for: pane) as? FakeApplet)
  }

  private func markers(_ controller: MainWindowController, _ pane: NodeID) -> [AppletMarkerKind] {
    (controller.paneArea.paneView(for: pane)?.paneMarkers ?? []).map(\.kind)
  }

  private let connection = AppletCaller(grant: GroupOwner(connection: 1).description)

  /// Catches a viewer pane that is marked while no one can address it, or left marked after the
  /// user disconnects it. The member of a controller's group carries the marker and draws it
  /// beside the badge. Disconnecting it clears both on the same turn, though the group's owner
  /// stays connected, and enabling it again brings both back.
  func testAMemberCarriesTheOwnersMarkerUntilTheUserDisconnectsIt() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)
    let applet = try fake(controller, member)

    XCTAssertEqual(applet.authority.owners, [connection])
    XCTAssertEqual(applet.publishedTabs.first.markers[.authority]?.owners, [connection])
    XCTAssertEqual(markers(controller, member), [.authority])

    controller.disconnect(member)

    XCTAssertEqual(applet.authority.owners, [])
    XCTAssertTrue(applet.publishedTabs.first.markers.isEmpty)
    XCTAssertEqual(markers(controller, member), [])

    controller.enableRemoteControl(member)

    XCTAssertEqual(markers(controller, member), [.authority])
  }

  /// Catches a terminal marked as controlled. A terminal owns its input, so it takes neither
  /// commands nor sent content, and a controller's group never marks it.
  func testAnAppletThatOwnsItsInputNeverCarriesTheMarker() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    fixture.make = { OwnedInputApplet() }

    let member = try await fixture.openOwned(beside: pane)
    let applet = try fake(controller, member)

    XCTAssertEqual(controller.owner(of: member), GroupOwner(connection: 1))
    XCTAssertEqual(applet.authority.owners, [])
    XCTAssertEqual(markers(controller, member), [])
  }

  /// Catches a pane marked because remote control is on. The user enables a pane and no controller
  /// is connected, so no grant can act on it.
  func testRemoteControlWithNoControllerMarksNothing() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()
    let user = try XCTUnwrap(
      controller.openPane(.dataViewer, axis: .column, from: controller.focusedPane))

    controller.enableRemoteControl(user)

    XCTAssertEqual(try fake(controller, user).authority.owners, [])
    XCTAssertEqual(markers(controller, user), [])
  }

  /// Catches a marker that flickers with a window question. A sheet holds the window's attention
  /// and refuses pane actions, but it does not change who may act, so the marker stays.
  func testAnOpenWindowQuestionDoesNotChangeTheMarker() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)
    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled],
      backing: .buffered, defer: false)

    sheet.isReleasedWhenClosed = false
    controller.window?.beginSheet(sheet, completionHandler: nil)

    defer { controller.window?.endSheet(sheet) }

    XCTAssertFalse(controller.paneActionsEnabled)

    controller.refreshControlMarks()

    XCTAssertEqual(markers(controller, member), [.authority])
  }

  /// Catches a marker that follows a power question the user has yet to answer. The owner's
  /// request for a power waits in the Pending Requests rows. The owners the pane carries and the
  /// marker it draws stay as they were while it waits, and after the user denies it. Only
  /// authorization decides them.
  func testAPendingPowerRequestDoesNotChangeTheOwnersOrTheMarker() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)
    let applet = try fake(controller, member)
    let requests = fixture.windows.permissionRequests

    XCTAssertEqual(applet.authority.owners, [connection])
    XCTAssertEqual(markers(controller, member), [.authority])

    _ = requests.ask(
      .init(requester: .connection(1), power: "clipboard-read"), subject: "build.janet",
      title: "Read the clipboard", detail: "", sessionTitle: "Allow for This Run",
      answer: { _ in })
    controller.refreshControlMarks()

    XCTAssertEqual(requests.rows.count, 1, "the request did not wait")
    XCTAssertEqual(applet.authority.owners, [connection], "a waiting request changed the owners")
    XCTAssertEqual(markers(controller, member), [.authority], "a waiting request moved the marker")

    requests.decide(try XCTUnwrap(requests.rows.first?.id), .deny)
    controller.refreshControlMarks()

    XCTAssertEqual(applet.authority.owners, [connection], "a denial changed the owners")
    XCTAssertEqual(markers(controller, member), [.authority], "a denial moved the marker")
  }

  /// Catches a pane-level marker that moves when the asking badge comes and goes. With no control
  /// badge showing, the marker takes the badge's corner, and the asking badge sits leading of it.
  /// Showing the control badge moves the marker one slot leading, and nothing else moves it.
  func testThePaneLevelMarkerMovesOnlyWhenTheBadgeAppearsOrGoes() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()
    let view = try XCTUnwrap(controller.paneArea.paneView(for: controller.focusedPane))

    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.controlMark = nil
    view.paneMarkers = [AppletMarker(kind: .runEnded, actions: [.rebuildTab])]

    let marker = try XCTUnwrap(view.subviews.compactMap { $0 as? AppletMarkerView }.first)
    let corner = PaneFrameView.badgeFrame(in: view.bounds)

    XCTAssertTrue(view.controlBadge.isHidden)
    XCTAssertEqual(marker.frame.origin.x + marker.frame.width, corner.maxX)
    XCTAssertEqual(marker.frame.minY, corner.minY)

    view.askingMark = PaneAskingMark(questionsPane: "pane-q")

    XCTAssertEqual(marker.frame.maxX, corner.maxX, "the asking badge moved the marker")
    XCTAssertLessThan(view.askingBadge.frame.maxX, marker.frame.minX)

    view.askingMark = nil
    view.controlMark = PaneControlMark(
      access: .remoteControlled, driver: .none, owner: nil, inUnownedGroup: false,
      enableAvailable: false, revokeAvailable: false)

    XCTAssertFalse(view.controlBadge.isHidden)
    XCTAssertLessThan(marker.frame.maxX, view.controlBadge.frame.minX)
    XCTAssertEqual(view.controlBadge.frame, corner)
  }

  /// Catches a pane-level marker that lets a click through to the applet beneath it, or one that
  /// the badge's reach leaves out. The marker eats the click, and the applet is told to keep its
  /// trailing controls clear of it.
  func testAPaneLevelMarkerEatsItsClickAndJoinsTheBadgeReach() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()
    let applet = try fake(controller, controller.focusedPane)
    let view = try XCTUnwrap(controller.paneArea.paneView(for: controller.focusedPane))

    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.controlMark = nil
    view.paneMarkers = []

    let before = applet.badgeReaches.last ?? 0

    view.paneMarkers = [AppletMarker(kind: .authority)]

    let marker = try XCTUnwrap(view.subviews.compactMap { $0 as? AppletMarkerView }.first)

    XCTAssertEqual(
      applet.badgeReaches.last,
      PaneFrameView.badgeReach(badge: marker.frame, appletFrame: applet.view.frame))
    XCTAssertGreaterThan(applet.badgeReaches.last ?? 0, before)
    XCTAssertFalse(marker.forwardsClicks)
    XCTAssertTrue(view.hitTest(NSPoint(x: marker.frame.midX, y: marker.frame.midY)) === marker)
    XCTAssertEqual(
      marker.accessibilityIdentifier(), "pane-marker-authority-\(controller.focusedPane)")
  }

  /// Catches a click on a pane-level run-end marker that rebuilds, opens a menu, or reaches the
  /// applet. The marker sits in the corner with no badge showing. A click on it opens no menu and
  /// performs no action, and the applet is not called. The call itself answers false for an applet
  /// that offers no such action.
  func testAClickOnAPaneLevelRunEndMarkerCallsNothing() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()
    let applet = try fake(controller, controller.focusedPane)
    let view = try XCTUnwrap(controller.paneArea.paneView(for: controller.focusedPane))

    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.controlMark = nil
    applet.extraMarkers = [AppletMarker(kind: .runEnded, actions: [.rebuildTab])]

    XCTAssertEqual(markers(controller, controller.focusedPane), [.runEnded])
    XCTAssertTrue(view.controlBadge.isHidden)

    let marker = try XCTUnwrap(view.subviews.compactMap { $0 as? AppletMarkerView }.first)
    let corner = PaneFrameView.badgeFrame(in: view.bounds)

    XCTAssertEqual(marker.frame.maxX, corner.maxX, "with no badge the marker takes its corner")
    XCTAssertNil(marker.menu)

    let click = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

    marker.mouseDown(with: click)

    XCTAssertEqual(applet.performedMarkerActions, [])
  }

  /// Catches a default that performs an action nobody implements. An applet that offers no marker
  /// action refuses every request for one, whatever the tab, kind, or action.
  func testAnAppletWithNoMarkerActionsRefusesEveryRequest() {
    let applet: any Applet = QuestionsApplet()
    let tab = applet.publishedTabs.first.id

    XCTAssertFalse(applet.performMarkerAction(.rebuildTab, kind: .runEnded, on: tab))
    XCTAssertFalse(applet.performMarkerAction(.rebuildTab, kind: .authority, on: .make()))
  }
}
