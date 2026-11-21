import AppKit
import AppletKit
import LayoutKit
import PaneModel
import ScriptHost
import ScriptWire
import XCTest

@testable import WindowKit

/// Layout requests as a script makes them, through the window side of the host API, against real
/// windows of fake applets. Restore and adoption run through the real layout codec.
///
/// The script acts for the first pane, connection 1, which the user has made remote-controlled,
/// unless a test names another caller. These prove the scope rules, staging, and publication.
/// They cannot prove the panes on screen. `PresentationUITests` drives a layout in the app.
@MainActor
final class LayoutRequestTests: XCTestCase {
  private func makeFixture(
    directoryExists: @escaping @Sendable (String) -> Bool = { _ in true }
  ) -> ScriptingFixture {
    let fixture = ScriptingFixture(directoryExists: directoryExists)
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func reference(_ controller: MainWindowController, _ pane: NodeID)
    -> ScriptPaneReference
  {
    ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)
  }

  private func layOut(
    _ fixture: ScriptingFixture, _ layout: String, from anchor: NodeID? = nil,
    as who: ScriptCaller? = nil, stillAllowed: @escaping @MainActor () throws -> Void = {}
  ) async throws -> [NodeID] {
    let caller = who ?? fixture.caller
    let target = ScriptPaneReference(
      window: caller.window, pane: (anchor ?? caller.pane).rawValue)
    let reply = try await fixture.scripting.requestLayout(
      anchor: .pane(target), layout: layout, caller: caller, stillAllowed: stillAllowed)

    guard case .record(let fields) = reply, case .array(let panes)? = fields["panes"] else {
      throw ScriptCallError.failed("no panes in \(reply)")
    }

    return panes.compactMap {
      guard case .record(let pane) = $0, case .integer(let id)? = pane["pane"] else { return nil }

      return NodeID(rawValue: id)
    }
  }

  private func expectError(
    _ kind: ScriptFailureKind, _ fragment: String? = nil, file: StaticString = #filePath,
    line: UInt = #line, _ body: () async throws -> Any
  ) async {
    do {
      let value = try await body()
      XCTFail("the call succeeded with \(value)", file: file, line: line)
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, kind, error.text, file: file, line: line)

      if let fragment {
        XCTAssertTrue(error.text.contains(fragment), error.text, file: file, line: line)
      }
    } catch {
      XCTFail("the call threw \(error)", file: file, line: line)
    }
  }

  /// The source beside a column of two new terminals, the second remote-controlled.
  private func presentation(_ source: NodeID) -> String {
    #"{"split":"row","children":[{"pane":\#(source.rawValue)},"#
      + #"{"split":"column","weight":2,"children":[{"open":"terminal"},"#
      + #"{"open":"terminal","control":"remote-controlled"}]}]}"#
  }

  // MARK: Publishing

  /// Catches a first layout that leaves a pane outside the caller's group, replaces the source's
  /// applet, gives a new pane the wrong control, or starts an applet before it learns its control.
  /// A layout is the user's splits made at once, so its last new pane takes focus, as the last of
  /// those splits would.
  func testAFirstLayoutWrapsTheSourceAndItsNewPanesInTheCallersGroup() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let sourceApplet = try XCTUnwrap(controller.paneArea.applet(for: source))

    let panes = try await layOut(fixture, presentation(source))

    XCTAssertEqual(panes.first, source)
    XCTAssertEqual(controller.paneIDs, panes)
    XCTAssertTrue(controller.paneArea.applet(for: source) === sourceApplet)
    XCTAssertEqual(controller.focusedPane, panes.last)

    let group = try XCTUnwrap(controller.paneArea.tree.groups.first)

    XCTAssertEqual(group.owner, GroupOwner(connection: 1))
    XCTAssertEqual(group.source, source)
    XCTAssertEqual(group.members, Set(panes.dropFirst()))

    let applets = try panes.dropFirst().map {
      try XCTUnwrap(controller.paneArea.applet(for: $0) as? FakeApplet)
    }

    XCTAssertEqual(applets.map(\.started), [true, true])
    XCTAssertEqual(applets.map(\.controlAtStart?.access), [.disconnected, .remoteControlled])
    XCTAssertEqual(controller.control(of: panes[2]).access, .remoteControlled)

    _ = try fixture.prepareSend(to: reference(controller, panes[2]))
  }

  /// Catches an applet view that enters the window at zero size. An applet's own constraints, such
  /// as a stack inset inside its view, cannot hold at zero width, and AppKit breaks one as the
  /// view joins the window. Every way a pane gets its applet is checked: a new window's first
  /// pane, a split, a layout, and a restored window's panes.
  func testEveryPanesAppletEntersTheWindowAtItsPanesSize() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    _ = try XCTUnwrap(controller.openPane(.dataViewer, axis: .column, from: controller.focusedPane))
    _ = try await layOut(fixture, presentation(NodeID(rawValue: pane.pane)))

    let file = Data(
      """
      {"version":3,"windows":[
      {"frame":{"x":0,"y":0,"width":960,"height":640},"highWaterMark":3,"tree":
      {"kind":"split","id":3,"axis":"row","children":[
      {"weight":1,"node":{"kind":"pane","id":1,"applet":{"type":"fake","version":1,"payload":"a"}}},
      {"weight":1,"node":{"kind":"pane","id":2,"applet":{"type":"fake","version":1,"payload":"b"}}}
      ]}}]}
      """.utf8)

    let saved = try LayoutCodec.decode(file)
    let restored = try fixture.windows.open(restoring: RestoredWindow(saved: saved.windows[0]))
    let applets = (controller.paneArea.applets + restored.paneArea.applets).compactMap {
      $0 as? FakeApplet
    }

    XCTAssertEqual(applets.count, 6)

    for applet in applets {
      let size = try XCTUnwrap(applet.sizeOnEntry, "an applet never joined the window")

      XCTAssertGreaterThan(size.width, 0, "an applet entered the window at \(size)")
      XCTAssertGreaterThan(size.height, 0, "an applet entered the window at \(size)")
    }
  }

  /// Catches a layout that imports a pane outside the caller's subtree: a pane the user opened,
  /// another window's pane, a disconnected member, or a member of another caller's group. Each
  /// refusal leaves the tree as it was and builds no applet, the tree's own refusal included.
  func testALayoutOutsideTheCallersSubtreeIsRefusedAndLeavesNothing() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let user = try XCTUnwrap(controller.openPane(.dataViewer, axis: .column, from: source))
    let (other, _) = try fixture.openWindow()

    controller.enableRemoteControl(user)

    let member = try await fixture.openOwned(beside: pane)
    let second = ScriptCaller(connection: 2, window: pane.window, pane: member)
    let theirs = try await fixture.openOwned(beside: reference(controller, member), as: second)

    controller.disconnect(member)

    let before = controller.paneArea.tree
    let made = fixture.made.count

    for (placed, kind) in [
      (#"{"pane":\#(user.rawValue)}"#, ScriptFailureKind.notFound),
      (#"{"pane":\#(theirs.rawValue)}"#, .notFound),
      (#"{"pane":\#(member.rawValue)}"#, .refused),
      (#"{"window":\#(other.scriptWindowID),"pane":1}"#, .notFound),
    ] {
      await expectError(kind) {
        try await self.layOut(
          fixture,
          #"{"split":"row","children":[{"pane":\#(source.rawValue)},\#(placed),{"open":"terminal"}]}"#
        )
      }
    }

    // The caller's group holds the second caller's nested group, so the tree refuses to lay the
    // group out again, before any applet is built.
    await expectError(.refused, "does not own") {
      try await self.layOut(
        fixture,
        #"{"split":"row","children":[{"pane":\#(source.rawValue)},{"open":"terminal"},"#
          + #"{"open":"terminal"}]}"#)
    }

    XCTAssertEqual(controller.paneArea.tree, before)
    XCTAssertEqual(fixture.made.count, made, "a refused layout built an applet")
  }

  /// Catches a layout read loosely: a misspelled key, a split of one child, a bad weight, an
  /// unknown kind, a control the kind does not support, or too many panes. None of them builds
  /// anything.
  func testABadLayoutIsRefusedBeforeAnythingIsBuilt() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = #"{"pane":\#(pane.pane)}"#
    let many = Array(repeating: #"{"open":"terminal"}"#, count: LayoutRequest.maxLeaves)

    let layouts: [(String, ScriptFailureKind, String)] = [
      ("[1]", .badArgument, "not an object"),
      (#"{"split":"row","childs":[]}"#, .badArgument, "unknown key childs"),
      (#"{"split":"row","children":[\#(source)]}"#, .badArgument, "two or more"),
      (#"{"split":"diagonal","children":[\#(source),\#(source)]}"#, .badArgument, "row or column"),
      (
        #"{"split":"row","children":[\#(source),{"open":"terminal","weight":0}]}"#, .badArgument,
        "weight"
      ),
      (
        #"{"split":"row","children":[\#(source),{"open":"spreadsheet"}]}"#, .badArgument, "not know"
      ),
      (
        #"{"split":"row","children":[\#(source),{"open":"data-viewer","control":"remote-controlled"}]}"#,
        .refused, "does not support"
      ),
      (
        #"{"split":"row","children":[\#(source),{"open":"terminal","exec":{"argv":["perl"]}}]}"#,
        .badArgument, "absolute path"
      ),
      (
        #"{"split":"row","children":[\#(source),\#(many.joined(separator: ","))]}"#, .badArgument,
        "more than \(LayoutRequest.maxLeaves) panes"
      ),
      (#"{"pane":\#(pane.pane),"open":"terminal"}"#, .badArgument, "exactly one"),
    ]

    for (layout, kind, fragment) in layouts {
      await expectError(kind, fragment) { try await self.layOut(fixture, layout) }
    }

    XCTAssertEqual(fixture.made.count, 1)
    XCTAssertEqual(controller.paneIDs.count, 1)
  }

  /// Catches a split bound that drifts. Six levels of splits publish in a window large enough to
  /// hold them, and seven are refused by the window's reader, which names the bound.
  func testALayoutNestsAtMostSixSplitsDeep() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    controller.window?.setContentSize(NSSize(width: 3800, height: 2800))
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    func nested(_ levels: Int) -> String {
      guard levels > 0 else { return #"{"pane":\#(pane.pane)}"# }

      let axis = levels.isMultiple(of: 2) ? "column" : "row"

      return #"{"split":"\#(axis)","children":[\#(nested(levels - 1)),{"open":"terminal"}]}"#
    }

    await expectError(.badArgument, "more than \(LayoutRequest.maxDepth) splits deep") {
      try await self.layOut(fixture, nested(LayoutRequest.maxDepth + 1))
    }

    XCTAssertEqual(controller.paneIDs.count, 1)

    let panes = try await layOut(fixture, nested(LayoutRequest.maxDepth))

    XCTAssertEqual(panes.count, LayoutRequest.maxDepth + 1)
    XCTAssertEqual(controller.paneIDs.count, LayoutRequest.maxDepth + 1)
  }

  /// Catches a script that pipelines layouts, each building its applets. While one waits in its
  /// directory check, a second from the same connection is refused as busy and builds nothing.
  func testAScriptHasOneLayoutInPreparationAtATime() async throws {
    let gate = DirectoryGate()
    let fixture = makeFixture(directoryExists: gate.check)
    let (_, pane) = try fixture.openWindow()
    let layout =
      #"{"split":"row","children":[{"pane":\#(pane.pane)},"#
      + #"{"open":"terminal","directory":"/synthetic"}]}"#

    let first = Task { @MainActor in try await self.layOut(fixture, layout) }
    let waiting = await gate.waitForCheck()

    XCTAssertTrue(waiting, "the first layout never reached its directory check")

    let made = fixture.made.count

    await expectError(.busy, "still being prepared") { try await self.layOut(fixture, layout) }

    XCTAssertEqual(fixture.made.count, made, "the busy layout built an applet")

    gate.open()

    let panes = try await first.value

    XCTAssertEqual(panes.count, 2)
  }

  /// Catches a layout that publishes after its authority ended while its directories were
  /// checked. The grant ends, the source is disconnected, or the source closes during the wait,
  /// and each time nothing is published and the staged applets close.
  func testAuthorityEndingDuringPreparationLeavesNoPartialLayout() async throws {
    let gate = DirectoryGate()
    let fixture = makeFixture(directoryExists: gate.check)
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let spare = try XCTUnwrap(controller.openPane(.dataViewer, axis: .row, from: source))
    let layout =
      #"{"split":"row","children":[{"pane":\#(source.rawValue)},"#
      + #"{"open":"terminal","directory":"/synthetic"}]}"#

    var revoked = false

    let endings: [(String, @MainActor () -> Void)] = [
      ("the grant ends", { revoked = true }),
      ("the source is disconnected", { controller.disconnect(source) }),
      ("the source closes", { controller.closePane(source, appletEnded: true) }),
    ]

    for (ending, end) in endings {
      revoked = false
      controller.enableRemoteControl(source)

      let before = controller.paneArea.tree
      let made = fixture.made.count

      let call = Task { @MainActor in
        try await self.layOut(
          fixture, layout,
          stillAllowed: {
            if revoked { throw ScriptCallError.refused("You revoked this program's control.") }
          })
      }

      guard await gate.waitForCheck() else {
        XCTFail("the layout never reached its directory check before \(ending)")
        gate.open()
        _ = try? await call.value
        return
      }

      XCTAssertGreaterThan(fixture.made.count, made, "the layout staged nothing before \(ending)")

      end()
      gate.open()

      do {
        _ = try await call.value
        XCTFail("a layout published after \(ending)")
      } catch is ScriptCallError {
      }

      XCTAssertTrue(fixture.made.dropFirst(made).allSatisfy(\.closed), ending)

      if controller.contains(pane: source) {
        XCTAssertEqual(controller.paneArea.tree, before, ending)
      } else {
        XCTAssertEqual(controller.paneIDs, [spare], ending)
      }
    }
  }

  /// Catches a later layout that replaces a member's applet, or that sweeps up a pane the user
  /// split off. The members move and keep their applets. A layout that makes no pane moves no focus.
  func testALaterLayoutMovesOnlyOwnedMembersAndKeepsTheirApplets() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let panes = try await layOut(fixture, presentation(source))
    let applets = panes.map { controller.paneArea.applet(for: $0) }

    let swapped =
      #"{"split":"column","children":[{"pane":\#(panes[2].rawValue)},"#
      + #"{"pane":\#(source.rawValue)},{"pane":\#(panes[1].rawValue)}]}"#

    controller.enableRemoteControl(panes[1])
    controller.paneArea.focus(source)

    let moved = try await layOut(fixture, swapped)

    XCTAssertEqual(moved, [panes[2], source, panes[1]])
    XCTAssertEqual(controller.focusedPane, source)
    XCTAssertEqual(controller.paneIDs, moved)

    for (index, id) in panes.enumerated() {
      XCTAssertTrue(controller.paneArea.applet(for: id) === applets[index])
    }

    let user = try XCTUnwrap(controller.openPane(.dataViewer, axis: .row, from: panes[1]))
    let before = controller.paneArea.tree

    await expectError(.refused, "does not own") {
      try await self.layOut(fixture, swapped)
    }

    XCTAssertEqual(controller.paneArea.tree, before)
    XCTAssertTrue(controller.contains(pane: user))
  }

  /// Catches a nested layout that merges into the outer group, or that lets either controller
  /// reach the other's panes. A second controller acting from a member lays out beside it.
  func testANestedLayoutMakesANestedGroupThatGrantsNothingAcrossIt() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let outer = try await layOut(fixture, presentation(source))
    let member = outer[2]
    let second = ScriptCaller(connection: 2, window: pane.window, pane: member)

    let inner = try await layOut(
      fixture,
      #"{"split":"row","children":[{"pane":\#(member.rawValue)},"#
        + #"{"open":"terminal","control":"remote-controlled"}]}"#,
      as: second)

    let groups = controller.paneArea.tree.enclosingGroups(of: inner[1])

    XCTAssertEqual(groups.map(\.owner), [GroupOwner(connection: 1), GroupOwner(connection: 2)])
    XCTAssertEqual(groups.last?.source, member)

    await expectError(.notFound) {
      try fixture.prepareSend(to: self.reference(controller, inner[1]))
    }

    controller.enableRemoteControl(outer[1])

    await expectError(.notFound) {
      try fixture.prepareSend(to: self.reference(controller, outer[1]), as: second)
    }
  }

  // MARK: Undo and restore

  /// Catches a pane reopened by undo that comes back with its old ID, as a member of the group it
  /// left, or within reach of the group's owner.
  func testUndoGivesANewUnownedPaneEvenInsideTheGroup() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let panes = try await layOut(fixture, presentation(source))
    let closed = panes[2]

    controller.closePane(closed, appletEnded: true)
    controller.reopenClosed()

    let reopened = try XCTUnwrap(controller.paneIDs.first { !panes.contains($0) })
    let group = try XCTUnwrap(controller.paneArea.tree.groups.first)

    XCTAssertNotEqual(reopened, closed)
    XCTAssertTrue(group.content.paneIDs.contains(reopened), "undo put the pane outside the group")
    XCTAssertFalse(group.members.contains(reopened))
    XCTAssertNil(controller.owner(of: reopened))
    XCTAssertEqual(controller.control(of: reopened).access, .disconnected)

    controller.enableRemoteControl(reopened)

    await expectError(.notFound) {
      try fixture.prepareSend(to: self.reference(controller, reopened))
    }
  }

  /// Catches a saved group whose damaged member list gives a controller more than the group
  /// holds. The file lists a pane twice, a pane outside the group, and the ID of a pane in the
  /// other window. The user gives the restored group to a controller from the badge, and the
  /// controller reaches only the members the group holds, once the user enables them.
  func testSavedMembershipNeverExpandsAGrantAndOnlyTheBadgeAdoptsAGroup() async throws {
    let fixture = makeFixture()
    let authority = FakeControllerAuthority()
    let file = Data(
      """
      {"version":3,"windows":[
      {"frame":{"x":0,"y":0,"width":960,"height":640},"highWaterMark":9,"tree":
      {"kind":"split","id":9,"axis":"row","children":[
      {"weight":1,"node":{"kind":"pane","id":1,"applet":{"type":"fake","version":1,"payload":"a"}}},
      {"weight":1,"node":{"kind":"pane","id":2,"applet":{"type":"fake","version":1,"payload":"b"}}},
      {"weight":1,"node":{"kind":"group","id":3,"source":1,"members":[4,4,2,7],"node":
      {"kind":"split","id":6,"axis":"column","children":[
      {"weight":1,"node":{"kind":"pane","id":4,"control":{"access":"remote-controlled","driver":"none"},
        "applet":{"type":"fake","version":1,"payload":"c"}}},
      {"weight":1,"node":{"kind":"pane","id":5,"applet":{"type":"fake","version":1,"payload":"d"}}}
      ]}}}]}},
      {"frame":{"x":0,"y":0,"width":960,"height":640},"highWaterMark":7,"tree":
      {"kind":"pane","id":7,"applet":{"type":"fake","version":1,"payload":"e"}}}
      ]}
      """.utf8)

    let layout = try LayoutCodec.decode(file)
    let restored = try fixture.windows.open(restoring: RestoredWindow(saved: layout.windows[0]))
    let other = try fixture.windows.open(restoring: RestoredWindow(saved: layout.windows[1]))

    restored.window?.contentView?.layoutSubtreeIfNeeded()
    restored.controllerAuthority = authority
    authority.acting = [restored.scriptWindowID: [5]]

    let group = try XCTUnwrap(restored.paneArea.tree.groups.first)

    XCTAssertNil(group.owner)
    XCTAssertEqual(group.members, [NodeID(rawValue: 4)])

    for id in restored.paneIDs {
      XCTAssertEqual(restored.control(of: id).access, .disconnected)
    }

    let member = NodeID(rawValue: 4)
    let view = try XCTUnwrap(restored.paneArea.paneView(for: member))
    let mark = try XCTUnwrap(view.currentControlMark?())

    XCTAssertEqual(mark.adoptions.map(\.owner), [GroupOwner(connection: 5)])

    restored.runControlAction(.adopt(GroupOwner(connection: 6)), on: member)

    XCTAssertNil(restored.paneArea.tree.groups.first?.owner, "a controller not acting here took it")

    view.controlMark = mark

    let item = try XCTUnwrap(
      view.controlMenu().items.first { $0.accessibilityIdentifier() == "pane-control-adopt-0" })

    XCTAssertEqual(item.title, "Give Group to fake controller 5")
    XCTAssertEqual(item.representedObject as? PaneControlAction, .adopt(GroupOwner(connection: 5)))

    view.onControlAction?(.adopt(GroupOwner(connection: 5)))

    let adopted = try XCTUnwrap(restored.paneArea.tree.groups.first)

    XCTAssertEqual(adopted.owner, GroupOwner(connection: 5))
    XCTAssertEqual(adopted.members, [member])

    for id in restored.paneIDs {
      XCTAssertEqual(restored.control(of: id).access, .disconnected, "adoption enabled \(id)")
    }

    let caller = ScriptCaller(
      connection: 5, window: restored.scriptWindowID, pane: NodeID(rawValue: 1))

    restored.enableRemoteControl(member)
    restored.enableRemoteControl(NodeID(rawValue: 2))
    restored.enableRemoteControl(NodeID(rawValue: 5))
    other.enableRemoteControl(NodeID(rawValue: 7))

    guard
      case .array(let listed) = try fixture.listPanes(window: restored.scriptWindowID, as: caller)
    else { return XCTFail("the controller listed nothing") }

    XCTAssertEqual(listed.count, 1)

    for (window, id) in [(restored, 2), (restored, 5), (other, 7)] {
      await expectError(.notFound) {
        try fixture.prepareSend(
          to: ScriptPaneReference(window: window.scriptWindowID, pane: UInt64(id)), as: caller)
      }
    }
  }
}

/// Stands in for the scripting host's view of who acts where, so a test can name a live
/// controller without a real connection.
@MainActor
final class FakeControllerAuthority: ControllerAuthority {
  /// The connections acting in each window, by window ID.
  var acting: [UInt64: Set<UInt64>] = [:]

  func controllers(actingFrom window: UInt64, pane: NodeID) -> Set<UInt64> { [] }

  func controllers(actingIn window: UInt64) -> Set<UInt64> { acting[window] ?? [] }

  func revokeControllers(_ ids: Set<UInt64>) {}

  func controllerName(_ id: UInt64) -> String? { "fake controller \(id)" }

  /// The launches each connection's run may start without asking, as (executable, directory).
  var launches: [UInt64: Set<String>] = [:]

  func coversLaunch(
    connection: UInt64, executable: String, directory: String, environmentKeys: [String]
  ) async -> Bool {
    launches[connection]?.contains(executable + " in " + directory) == true
  }
}
