import AppKit
import AppletFixtures
import AppletKit
import ControllerPackage
import ExecTestSupport
import PaneModel
import ScriptHost
import XCTest

@testable import WindowKit

/// An exec driver and the browser powers. The driver is a real process in a slides fixture's pane.
/// It lays out a pane of a fixture whose commands need browser navigation, and a layout that
/// seeds a browser page. The user answers each question through the calls the Pending Requests
/// panel makes.
///
/// These prove that a driver holds a browser power only through a question the user answered,
/// that Allow for This Run lasts for the run and no longer, and that the driver acts under its
/// own grant. They cannot prove the panel's rows on screen.
@MainActor
final class BrowserDriverTests: XCTestCase {
  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func row(_ fixture: ExecPaneFixture, _ title: String) -> PermissionRequests.Row? {
    fixture.windows.permissionRequests.rows.first { $0.title == title }
  }

  private func startDriver(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController, _ pane: NodeID,
    _ rest: [String]
  ) throws {
    try controller.declareExecDriver(fixture.declaration("layout", rest), for: pane)
    controller.runExecDriver(pane)

    let authority = fixture.windows.launchAuthority

    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowOnce)
  }

  private func powered(_ pane: NodeID, commands: Int) -> [String] {
    let layout =
      #"{"split":"row","children":[{"pane":\#(pane.rawValue)},"#
      + #"{"open":"fixture-powered","control":"remote-controlled"}]}"#
    let go = #"{"leaf":1,"applet":"fixture-powered","schema":[0,0],"name":"go","arguments":{}}"#

    return [layout] + Array(repeating: go, count: commands)
  }

  private var navigation: String { ControllerPermission.browserNavigation.displayText }

  /// Catches a driver's browser command that runs without the user's yes, one that asks again
  /// after Allow for This Run, and a grant that outlives the run. The command reaches the applet
  /// under the driver's own grant, so tabs it opened belong to that run.
  func testADriverHoldsABrowserPowerOnlyThroughAnAnswerAndOnlyForItsRun() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    controller.enableRemoteControl(pane)
    try startDriver(fixture, controller, pane, powered(pane, commands: 2))

    try await waitOrFail("the question waits") { self.row(fixture, self.navigation) != nil }

    let member = try XCTUnwrap(controller.paneIDs.last)
    let applet = try XCTUnwrap(controller.paneArea.applet(for: member) as? PoweredFixture)

    XCTAssertEqual(applet.performed, 0, "a command ran before the user answered")
    XCTAssertEqual(row(fixture, navigation)?.sessionTitle, "Allow for This Run")

    fixture.windows.permissionRequests.decide(
      try XCTUnwrap(row(fixture, navigation)?.id), .allowForSession)

    try await waitOrFail("both commands run") { applet.performed == 2 }

    let attachment = try XCTUnwrap(controller.execAttachments[pane])

    XCTAssertEqual(attachment.browserGrants, [.browserNavigation])
    XCTAssertEqual(
      applet.lastCaller, AppletCaller(grant: try XCTUnwrap(attachment.owner).description))
    XCTAssertNil(row(fixture, navigation), "the second command asked again")

    attachment.channel?.close()

    try await waitOrFail("the run ends") {
      if case .ended? = controller.execAttachments[pane]?.state { return true }
      return false
    }

    XCTAssertEqual(controller.execAttachments[pane]?.browserGrants, [])
  }

  /// Catches a denied browser power that lets the command through, and a driver granted a power
  /// it was refused.
  func testADeniedBrowserPowerRunsNothingAndGrantsNothing() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    controller.enableRemoteControl(pane)
    try startDriver(fixture, controller, pane, powered(pane, commands: 1))

    try await waitOrFail("the question waits") { self.row(fixture, self.navigation) != nil }

    fixture.windows.permissionRequests.decide(
      try XCTUnwrap(row(fixture, navigation)?.id), .deny)

    let member = try XCTUnwrap(controller.paneIDs.last)
    let applet = try XCTUnwrap(controller.paneArea.applet(for: member) as? PoweredFixture)

    try await waitOrFail("the denial is answered") { self.row(fixture, self.navigation) == nil }

    XCTAssertEqual(applet.performed, 0)
    XCTAssertEqual(controller.execAttachments[pane]?.browserGrants, [])
  }

  /// Catches a layout that seeds a browser page for a driver that was never asked, and a refusal
  /// that still publishes the pane.
  func testADriversLayoutThatSeedsAPageAsksAndPublishesNothingWhenDenied() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    controller.enableRemoteControl(pane)

    let layout =
      #"{"split":"row","children":[{"pane":\#(pane.rawValue)},"#
      + #"{"open":"browser","control":"remote-controlled","url":"https://example.com/"}]}"#

    try startDriver(fixture, controller, pane, [layout])

    try await waitOrFail("the question waits") { self.row(fixture, self.navigation) != nil }

    XCTAssertEqual(controller.paneIDs.count, 1, "the pane was built before the answer")

    fixture.windows.permissionRequests.decide(
      try XCTUnwrap(row(fixture, navigation)?.id), .deny)

    try await waitOrFail("the denial is answered") { self.row(fixture, self.navigation) == nil }

    XCTAssertEqual(controller.paneIDs.count, 1, "a denied layout published a pane")
    XCTAssertEqual(controller.execAttachments[pane]?.browserGrants, [])
  }

  /// Catches a driver whose Allow for This Run does not let its seeded layout through.
  func testAllowingTheRunLetsTheSeededLayoutThrough() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    controller.enableRemoteControl(pane)

    let layout =
      #"{"split":"row","children":[{"pane":\#(pane.rawValue)},"#
      + #"{"open":"browser","control":"remote-controlled","url":"https://example.com/"}]}"#

    try startDriver(fixture, controller, pane, [layout])

    try await waitOrFail("the question waits") { self.row(fixture, self.navigation) != nil }

    fixture.windows.permissionRequests.decide(
      try XCTUnwrap(row(fixture, navigation)?.id), .allowForSession)

    try await waitOrFail("the layout is published") { controller.paneIDs.count == 2 }

    XCTAssertEqual(controller.execAttachments[pane]?.browserGrants, [.browserNavigation])
  }
}
