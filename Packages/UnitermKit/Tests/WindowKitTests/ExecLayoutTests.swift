import AppKit
import AppletFixtures
import AppletKit
import ExecDriver
import ExecTestSupport
import PaneModel
import ScriptHost
import ScriptWire
import XCTest

@testable import WindowKit

/// An exec driver's layout requests and its commands to the panes it lays out, with a real driver
/// process in a slides fixture's pane and real notes and chart fixtures in the panes it opens.
///
/// These prove what a driver may do beyond its own pane: lay out its subtree once the user has
/// enabled the pane, command the members it owns, and nothing once its run ends. A layout's own
/// declared driver runs only after the user chooses Run. They cannot prove the panes on screen.
@MainActor
final class ExecLayoutTests: XCTestCase {
  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func waitUntil(
    _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
    detail: () -> String = { "" }, _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)

    while !condition() {
      guard Date() < deadline else {
        return XCTFail("timed out waiting until \(what). \(detail())", file: file, line: line)
      }

      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func history(_ controller: MainWindowController) -> [String] {
    controller.statusCenter.history.map(\.text)
  }

  /// The driver's pane beside a column of notes and chart fixtures, both remote-controlled. The
  /// commands go to the notes and the chart once the layout is published.
  private func presentation(_ pane: NodeID) -> [String] {
    let layout =
      #"{"split":"row","children":[{"pane":\#(pane.rawValue)},{"split":"column","children":["#
      + #"{"open":"fixture-notes","control":"remote-controlled"},"#
      + #"{"open":"fixture-chart","control":"remote-controlled"}]}]}"#

    return [
      layout,
      #"{"leaf":1,"applet":"fixture-notes","schema":[0,0],"name":"set-notes","arguments":{"text":"Hi"}}"#,
      #"{"leaf":2,"applet":"fixture-chart","schema":[0,0],"name":"set-series","arguments":{"values":[3,1]}}"#,
    ]
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

  /// Catches a driver whose layout is never published, that wraps the wrong panes, or whose
  /// commands to the panes it opened never land. Its group is its run's, and when the run ends
  /// the group stays with no owner.
  func testADriverLaysOutItsSubtreeAndCommandsTheMembersItOwns() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    controller.enableRemoteControl(pane)
    try startDriver(fixture, controller, pane, presentation(pane))

    await waitUntil("the layout is published") { controller.paneIDs.count == 3 }

    let members = Array(controller.paneIDs.dropFirst())
    let notes = try XCTUnwrap(controller.paneArea.applet(for: members[0]) as? NotesFixture)
    let chart = try XCTUnwrap(controller.paneArea.applet(for: members[1]) as? ChartFixture)

    await waitUntil("the driver commands its members") {
      notes.text == "Hi" && chart.values == [3, 1]
    }

    let group = try XCTUnwrap(controller.paneArea.tree.groups.first)
    let owner = try XCTUnwrap(controller.execAttachments[pane]?.owner)

    XCTAssertEqual(owner.kind, .driver)
    XCTAssertEqual(group.owner, owner)
    XCTAssertEqual(group.source, pane)
    XCTAssertEqual(group.members, Set(members))
    XCTAssertEqual(
      controller.paneArea.paneView(for: members[0])?.controlMark?.owner, "perl (driver)")

    controller.execAttachments[pane]?.channel?.close()

    XCTAssertNil(controller.paneArea.tree.groups.first?.owner, "the ended run kept its group")
    XCTAssertEqual(controller.paneIDs.count, 3)
  }

  /// Catches a driver that lays out from a pane the user has not enabled. The driver's own pane is
  /// disconnected, so the layout is refused, and the tree is as it was.
  func testADriverInADisconnectedPaneCannotLayOut() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    try startDriver(fixture, controller, pane, presentation(pane))

    await waitUntil("the driver hears the refusal") {
      history(controller).contains { $0.contains("layout refused") && $0.contains("disconnected") }
    }

    XCTAssertEqual(controller.paneIDs, [pane])
    XCTAssertTrue(controller.paneArea.tree.groups.isEmpty)
  }

  /// Catches a disconnected anchor whose malformed layout is answered as a bad argument. The
  /// refusal to enable remote control comes before the layout is parsed.
  func testAMalformedLayoutFromADisconnectedPaneIsRefusedForTheDisconnect() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    try controller.declareExecDriver(
      fixture.declaration("script", [#"{"type":"layout","layout":{"bogus":1}}"#]), for: pane)
    controller.runExecDriver(pane)

    let authority = fixture.windows.launchAuthority

    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowOnce)

    await waitUntil("the driver hears the refusal") {
      history(controller).contains {
        $0.contains("error message:") && $0.contains("disconnected")
          && $0.contains("Enable Remote Control")
      }
    }
  }

  /// Catches a disconnected driver that owns no group and is answered as if the pane were missing.
  /// It still hears that the user must enable remote control.
  func testADisconnectedDriverWithNoGroupIsToldToEnableRemoteControl() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let command =
      #"{"type":"command","pane":\#(pane.rawValue),"applet":"fixture-notes","schema":[0,0],"#
      + #""name":"clear"}"#

    try controller.declareExecDriver(fixture.declaration("script", [command]), for: pane)
    controller.runExecDriver(pane)

    let authority = fixture.windows.launchAuthority

    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowOnce)

    await waitUntil("the driver hears the refusal") {
      history(controller).contains {
        $0.contains("error message:") && $0.contains("disconnected")
          && $0.contains("Enable Remote Control")
      }
    }
  }

  /// Catches a driver that loses the members it owns when the user disconnects its own pane. The
  /// group stays the run's, so a later command from the driver still reaches a remote-controlled
  /// member.
  func testADisconnectedDriverStillCommandsTheMembersItOwns() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let later =
      #"{"leaf":1,"later":true,"applet":"fixture-notes","schema":[0,0],"name":"set-notes","#
      + #""arguments":{"text":"after"}}"#

    let (pane, members) = try await presented(fixture, controller, later: [later])
    let notes = try XCTUnwrap(controller.paneArea.applet(for: members[0]) as? NotesFixture)
    let slides = try XCTUnwrap(fixture.slides(controller, pane))

    await waitUntil("the driver commands its members") { notes.text == "Hi" }

    controller.disconnect(pane)

    slides.button.performClick(nil)

    await waitUntil(
      "the disconnected driver commands its member",
      detail: { history(controller).joined(separator: "\n") },
      { notes.text == "after" })
  }

  /// Catches a revoke that leaves a driver its group, or a driver command that reaches a pane
  /// after its group was taken. Revoke Controller on a member takes the group from the driver.
  /// The user then presses the driver's Next, and the driver's clear for the member is refused for
  /// the revoke. The driver keeps its own pane.
  func testRevokeTakesTheGroupAndTheDriverKeepsOnlyItsPane() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let clear = #"{"leaf":1,"later":true,"applet":"fixture-notes","schema":[0,0],"name":"clear"}"#

    controller.enableRemoteControl(pane)
    try startDriver(fixture, controller, pane, presentation(pane) + [clear])

    await waitUntil("the layout is published") { controller.paneIDs.count == 3 }

    let member = controller.paneIDs[1]
    let notes = try XCTUnwrap(controller.paneArea.applet(for: member) as? NotesFixture)
    let slides = try XCTUnwrap(fixture.slides(controller, pane))

    await waitUntil("the driver commands its members") { notes.text == "Hi" }

    XCTAssertTrue(controller.canRevokeController(member))

    controller.revokeController(member)

    XCTAssertNil(controller.owner(of: member))
    XCTAssertEqual(controller.execAttachments[pane]?.channel?.isConnected, true)

    slides.button.performClick(nil)

    await waitUntil("the driver hears its clear refused") { revocations(controller) == 1 }

    XCTAssertEqual(notes.text, "Hi", "a revoked driver cleared the notes")
  }

  /// Catches an authority marker that misstates a driver's reach. A member of the driver's group
  /// is one the driver's commands reach, so its owner set holds the driver's grant. The driver's
  /// own pane is never marked for it, since the driver commands that pane through its attached
  /// channel. Revoking the driver on a member takes the group, and the member's set empties.
  func testADriversMembersCarryItsGrantAndItsOwnPaneNever() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()

    let (pane, members) = try await presented(fixture, controller)
    let owner = try XCTUnwrap(controller.execAttachments[pane]?.owner)
    let grant = AppletCaller(grant: owner.description)

    await waitUntil("the driver commands its members") {
      controller.paneAuthority(for: members[0]).owners == [grant]
    }

    XCTAssertEqual(controller.paneAuthority(for: members[1]).owners, [grant])
    XCTAssertEqual(controller.paneAuthority(for: pane).owners, [])

    controller.revokeController(members[0])

    XCTAssertEqual(controller.paneAuthority(for: members[0]).owners, [])
  }

  private func driverChips(_ controller: MainWindowController, _ pane: NodeID) -> [[String]] {
    (controller.paneArea.paneView(for: pane)?.paneMarkers ?? [])
      .filter { $0.kind == .chip }.map(\.controllers)
  }

  /// Catches a driver whose chip is missing, or stays after the driver's standing ends. The chip
  /// sits at the driver's pane level and names the driver as the badge does, beside the badge. It
  /// goes when the user revokes the driver. A revoked driver owns no group, so it shows none, and
  /// the members carry no chip of their own.
  func testADriversChipShowsAtItsPaneWhileItOwnsAGroupAndGoesOnRevoke() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, members) = try await presented(fixture, controller)

    await waitUntil("the driver's chip shows") {
      driverChips(controller, pane) == [["perl (driver)"]]
    }

    XCTAssertEqual(controller.paneArea.paneView(for: pane)?.controlMark?.controllers.count, 1)
    XCTAssertEqual(driverChips(controller, members[0]), [])
    XCTAssertEqual(controller.paneAuthority(for: pane).controlling, [:])
    XCTAssertEqual(controller.paneAuthority(for: pane).drivers, ["perl (driver)"])
    XCTAssertEqual(controller.paneAuthority(for: members[0]).drivers, [])

    controller.revokeController(members[0])

    XCTAssertEqual(driverChips(controller, pane), [], "the revoked driver kept its chip")
  }

  /// Catches a chip that outlives its driver's group. Closing every member leaves the driver
  /// owning no group, so its chip goes on the turn the last member closes.
  func testADriversChipGoesWhenItsGroupDissolves() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, members) = try await presented(fixture, controller)

    await waitUntil("the driver's chip shows") {
      driverChips(controller, pane) == [["perl (driver)"]]
    }

    controller.closePane(members[0], appletEnded: false)

    XCTAssertEqual(driverChips(controller, pane), [["perl (driver)"]], "one member still holds it")

    controller.closePane(members[1], appletEnded: false)

    XCTAssertTrue(controller.paneArea.tree.groups.isEmpty, "the last member left a group behind")
    XCTAssertEqual(driverChips(controller, pane), [], "the dissolved group kept the chip")
  }

  /// Runs one owner-set state against a real driver command. The driver's presentation is laid
  /// out, `change` moves the first member into the state, and the driver's next command, a notes
  /// update to that member, runs. The marker's owner set and the command must agree: a command the
  /// pane takes lands and the set holds the driver, and a refused one leaves the notes alone and
  /// the set empty.
  private func assertMarkerAgreesWithTheCommand(
    state: String, refusal: String?, file: StaticString = #filePath, line: UInt = #line,
    _ change: (MainWindowController, NodeID, GroupOwner) -> Void
  ) async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let later =
      #"{"leaf":1,"later":true,"applet":"fixture-notes","schema":[0,0],"name":"set-notes","#
      + #""arguments":{"text":"after"}}"#

    let (pane, members) = try await presented(fixture, controller, later: [later])
    let notes = try XCTUnwrap(controller.paneArea.applet(for: members[0]) as? NotesFixture)
    let slides = try XCTUnwrap(fixture.slides(controller, pane))
    let owner = try XCTUnwrap(controller.execAttachments[pane]?.owner)
    let grant = AppletCaller(grant: owner.description)

    await waitUntil("the driver commands its members", file: file, line: line) {
      notes.text == "Hi"
    }

    change(controller, members[0], owner)

    let marked = controller.paneAuthority(for: members[0]).owners == [grant]

    XCTAssertEqual(marked, refusal == nil, "the marker for \(state)", file: file, line: line)

    guard let refusal else {
      slides.button.performClick(nil)

      return await waitUntil("the driver's command lands for \(state)", file: file, line: line) {
        notes.text == "after"
      }
    }

    guard state != "an ended run" else {
      XCTAssertEqual(controller.driverStanding(of: owner), .ended, file: file, line: line)

      return
    }

    slides.button.performClick(nil)

    await waitUntil("the command is refused for \(state)", file: file, line: line) {
      history(controller).contains { $0.contains("error message:") && $0.contains(refusal) }
    }

    XCTAssertEqual(
      notes.text, "Hi", "a refused command landed for \(state)", file: file, line: line)
  }

  /// Catches a marker that disagrees with the command path for a driver. For a live run, a
  /// disconnected member, a revoked run, a run that ended, and a member the run no longer owns,
  /// the owner set and a real driver command must reach the same answer, since both ask the same
  /// shared steps.
  func testTheDriversMarkerAndItsCommandsAgreeInEveryState() async throws {
    try await assertMarkerAgreesWithTheCommand(state: "a live run", refusal: nil) { _, _, _ in }

    try await assertMarkerAgreesWithTheCommand(
      state: "a disconnected member", refusal: "The pane is disconnected"
    ) { controller, member, _ in controller.disconnect(member) }

    try await assertMarkerAgreesWithTheCommand(
      state: "a revoked run", refusal: "You revoked"
    ) { controller, member, _ in controller.revokeController(member) }

    try await assertMarkerAgreesWithTheCommand(
      state: "an ended run", refusal: "the driver no longer drives"
    ) { controller, member, _ in
      controller.execAttachments.values.first?.channel?.close()
    }

    try await assertMarkerAgreesWithTheCommand(
      state: "a member the run no longer owns", refusal: "not open in that window"
    ) { controller, _, owner in controller.ownerEnded(owner) }
  }

  /// Catches a driver's waiting command that never answers, or that outlives its run. The wait
  /// stays pending while the driver's other commands run, and the user's Next sends the command
  /// that ends it. A second wait is failed when the run ends, and the notes are told to drop it.
  func testADriversWaitAnswersLaterAndFailsWhenItsRunEnds() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let wait =
      #"{"leaf":1,"applet":"fixture-notes","schema":[0,0],"name":"wait-for-notes","#
      + #""arguments":{"contains":"later"}}"#
    let never =
      #"{"leaf":1,"applet":"fixture-notes","schema":[0,0],"name":"wait-for-notes","#
      + #""arguments":{"contains":"never"}}"#
    let advance =
      #"{"leaf":1,"later":true,"applet":"fixture-notes","schema":[0,0],"name":"set-notes","#
      + #""arguments":{"text":"later"}}"#

    let (pane, members) = try await presented(fixture, controller, later: [wait, never, advance])
    let notes = try XCTUnwrap(controller.paneArea.applet(for: members[0]) as? NotesFixture)
    let slides = try XCTUnwrap(fixture.slides(controller, pane))

    await waitUntil("both waits are pending") { controller.dispatcher.pendingCount == 2 }

    XCTAssertEqual(notes.waitingCount, 2)

    slides.button.performClick(nil)

    await waitUntil("the first wait is answered") { controller.dispatcher.pendingCount == 1 }

    XCTAssertEqual(notes.text, "later")
    XCTAssertEqual(notes.waitingCount, 1)

    controller.execAttachments[pane]?.channel?.close()

    XCTAssertEqual(controller.dispatcher.pendingCount, 0, "the ended run kept a pending reply")
    XCTAssertEqual(notes.cancelledWaits, 1)
    XCTAssertEqual(notes.waitingCount, 0)
  }

  /// Lays out the presentation from a driver, and returns the driver's pane and its two members.
  private func presented(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController, later: [String] = []
  ) async throws -> (pane: NodeID, members: [NodeID]) {
    let pane = controller.focusedPane

    controller.enableRemoteControl(pane)
    try startDriver(fixture, controller, pane, presentation(pane) + later)

    await waitUntil("the layout is published") { controller.paneIDs.count == 3 }

    return (pane, Array(controller.paneIDs.dropFirst()))
  }

  /// A layout the driver holds for the user's Next. Each `leafN` pane is the pane at leaf N of the
  /// first layout's reply.
  private func later(_ layout: String) -> String {
    #"{"type":"layout","later":true,"layout":\#(layout)}"#
  }

  private func revocations(_ controller: MainWindowController) -> Int {
    history(controller).filter { $0.contains("error message: You revoked") }.count
  }

  /// Catches a revoke a driver can outlive. A second layout waits in its directory check when the
  /// user revokes the driver, and a third comes after the revoke. Both are refused for the revoke,
  /// and neither builds a group, though the driver's run and its own pane carry on.
  func testARevokeHoldsForTheRestOfTheDriversRun() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let gate = DirectoryGate()
    let relayout = later(
      #"{"split":"row","children":[{"pane":"leaf0"},{"pane":"leaf1"},{"pane":"leaf2"},"#
        + #"{"open":"fixture-notes","directory":"/synthetic"}]}"#)
    let fresh = later(#"{"split":"row","children":[{"pane":"leaf0"},{"open":"fixture-chart"}]}"#)

    let (pane, members) = try await presented(fixture, controller, later: [relayout, fresh])
    let slides = try XCTUnwrap(fixture.slides(controller, pane))

    controller.directoryExists = gate.check
    slides.button.performClick(nil)

    let waiting = await gate.waitForCheck()

    XCTAssertTrue(waiting, "the second layout never reached its directory check")

    controller.revokeController(members[0])
    gate.open()

    await waitUntil("the waiting layout is refused") { revocations(controller) == 1 }

    XCTAssertEqual(controller.paneIDs.count, 3, "a layout published after the revoke")

    slides.button.performClick(nil)

    await waitUntil("the fresh layout is refused") { revocations(controller) == 2 }

    XCTAssertEqual(controller.paneIDs.count, 3, "a layout published after the revoke")
    XCTAssertTrue(controller.paneArea.tree.groups.allSatisfy { $0.owner == nil })
    XCTAssertEqual(controller.execAttachments[pane]?.channel?.isConnected, true)
  }

  /// Holds a driver's layout in its directory check, runs `end`, then lets the check finish. The
  /// window has a spare pane beside the driver's, so closing the driver's pane leaves the window
  /// open. Nothing may publish: no new pane and no group.
  private func assertNothingPublishes(
    when what: String, file: StaticString = #filePath, line: UInt = #line,
    _ end: (MainWindowController, NodeID) -> Void
  ) async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let spare = try XCTUnwrap(controller.openPane(.dataViewer, axis: .column, from: pane))
    let gate = DirectoryGate()
    let layout =
      #"{"split":"row","children":[{"pane":\#(pane.rawValue)},"#
      + #"{"open":"fixture-notes","directory":"/synthetic"}]}"#

    controller.directoryExists = gate.check
    controller.enableRemoteControl(pane)
    try startDriver(fixture, controller, pane, [layout])

    let waiting = await gate.waitForCheck()

    XCTAssertTrue(waiting, "the layout never reached its directory check", file: file, line: line)

    end(controller, pane)
    gate.open()

    await waitUntil("the layout settles", file: file, line: line) {
      controller.layoutsInPreparation.isEmpty
    }

    let left = controller.contains(pane: pane) ? [pane, spare] : [spare]

    XCTAssertEqual(
      controller.paneIDs, left, "a layout published after \(what)", file: file, line: line)
    XCTAssertTrue(controller.paneArea.tree.groups.isEmpty, what, file: file, line: line)
  }

  /// Catches a driver run that ends while its layout waits in its directory check, and whose
  /// layout publishes anyway with an owner that no longer runs.
  func testADriverRunEndingDuringPreparationPublishesNothing() async throws {
    try await assertNothingPublishes(when: "the run ended") { controller, pane in
      controller.execAttachments[pane]?.channel?.close()
    }
  }

  /// Catches a layout that publishes after the driver's own pane closed during its directory
  /// check, anchored at a pane that is gone, for a run nothing names any more.
  func testADriversPaneClosingDuringPreparationPublishesNothing() async throws {
    try await assertNothingPublishes(when: "the driver's pane closed") { controller, pane in
      controller.closePane(pane, appletEnded: false)
    }
  }

  /// Catches a driver that floods layouts, each building its applets. While one waits in its
  /// directory check, the next is refused as busy, and only the first publishes.
  func testADriverHasOneLayoutInPreparationAtATime() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let gate = DirectoryGate()
    let layout =
      #"{"type":"layout","layout":{"split":"row","children":[{"pane":\#(pane.rawValue)},"#
      + #"{"open":"fixture-notes","directory":"/synthetic"}]}}"#

    controller.directoryExists = gate.check
    controller.enableRemoteControl(pane)
    try controller.declareExecDriver(fixture.declaration("script", [layout, layout]), for: pane)
    controller.runExecDriver(pane)

    let authority = fixture.windows.launchAuthority

    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowOnce)

    await waitUntil(
      "the second layout is refused as busy", detail: { "History: \(history(controller))" },
      { history(controller).contains("got error busy") })

    gate.open()

    await waitUntil("the first layout publishes") { controller.paneIDs.count == 2 }

    XCTAssertEqual(controller.paneArea.tree.groups.count, 1)
  }

  /// Catches a driver's pane that closes and leaves the driver's groups owned by a run nothing
  /// names any more.
  func testClosingTheDriversPaneReleasesItsGroups() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, members) = try await presented(fixture, controller)

    controller.closePane(pane, appletEnded: false)

    XCTAssertFalse(controller.contains(pane: pane))
    XCTAssertEqual(controller.paneIDs, members)
    XCTAssertTrue(controller.paneArea.tree.groups.allSatisfy { $0.owner == nil })
    XCTAssertFalse(controller.paneArea.tree.groups.isEmpty)
  }

  /// Catches a layout's driver declaration that runs on its own. The new pane shows Run, and no
  /// launch waits for approval until the user chooses Run.
  func testADriverALayoutDeclaresRunsOnlyWhenTheUserChoosesRun() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let caller = fixture.caller(controller, pane)
    let argv = ExecTestDriver.arguments("exit", type: NotesFixture.typeID)
      .map { "\"\($0)\"" }.joined(separator: ",")

    controller.enableRemoteControl(pane)

    let reply = try await fixture.scripting.requestLayout(
      anchor: .pane(ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)),
      layout:
        #"{"split":"row","children":[{"pane":\#(pane.rawValue)},"#
        + #"{"open":"fixture-notes","exec":{"argv":[\#(argv)]}}]}"#,
      caller: caller, stillAllowed: {})

    guard case .record(let fields) = reply, case .array(let panes)? = fields["panes"],
      case .record(let created)? = panes.last, case .integer(let id)? = created["pane"]
    else { return XCTFail("no new pane in \(reply)") }

    let member = NodeID(rawValue: id)

    XCTAssertEqual(controller.execStatus(of: member)?.action, "Run")
    XCTAssertNil(controller.execAttachments[member]?.channel)
    XCTAssertTrue(fixture.windows.launchAuthority.requests.isEmpty)

    controller.runExecDriver(member)

    XCTAssertEqual(fixture.windows.launchAuthority.requests.count, 1)
    XCTAssertNil(controller.execAttachments[member]?.channel, "the driver ran before approval")
  }
}
