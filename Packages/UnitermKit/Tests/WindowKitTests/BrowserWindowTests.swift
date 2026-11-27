import AppKit
import AppletFixtures
import AppletKit
import BrowserModel
import BrowserTestSupport
import ControllerPackage
import PaneModel
import ScriptHost
import ScriptWire
import XCTest

@testable import BrowserApplet
@testable import WindowKit

/// A script's browser commands and a layout's browser seed, through the window side of the host
/// API against a real browser pane and a local server.
///
/// These prove how the window finds the caller: its grant, the tab its target names, the powers
/// it holds, and what a reply says about a new tab. The browser's own tests prove what the
/// browser does with them. They cannot prove the pane on screen. The control badge's clearance is
/// proved by the UI test.
@MainActor
final class BrowserWindowTests: XCTestCase {
  private var server: FixtureServer!

  override func setUp() async throws {
    server = try await FixtureServer.start { request in
      .page(titled: String(request.path.dropFirst()).uppercased())
    }
  }

  override func tearDown() async throws {
    server.stop()
  }

  private func makeFixture() -> ScriptingFixture {
    let fixture = ScriptingFixture(
      declarations: ScriptingFixture.declarations + [BrowserApplet.typeDeclaration]
        + AppletFixtures.declarations)

    fixture.makeReal = { choice in
      switch choice {
      case .browser:
        return BrowserApplet(dataStore: .nonPersistent(), services: Self.services)

      case .browserPage(let text):
        return BrowserApplet(dataStore: .nonPersistent(), services: Self.services, seed: text)

      case .hosted(let typeID):
        return AppletFixtures.make(typeID: typeID)

      default:
        return nil
      }
    }

    addTeardownBlock { @MainActor in fixture.cleanUp() }

    return fixture
  }

  private static var services: BrowserServices {
    BrowserServices(
      searchEngine: { .duckDuckGo }, hsts: HSTSStore(), downloadsDirectory: { nil },
      reveal: NoReveal(), opener: NoOpener())
  }

  private let both: Set<ControllerPermission> = [.paneControl, .browserNavigation, .browserRead]

  private func openBrowser(
    _ fixture: ScriptingFixture, _ controller: MainWindowController, _ pane: ScriptPaneReference,
    access: ScriptPaneAccess = .remoteControlled
  ) async throws -> (NodeID, BrowserApplet) {
    let reply = try await fixture.openPane(
      kind: "browser", beside: pane, axis: nil, directory: nil, access: access)

    guard case .record(let fields) = reply, case .integer(let id)? = fields["pane"],
      let applet = controller.paneArea.applet(for: NodeID(rawValue: id)) as? BrowserApplet
    else { throw ScriptCallError.failed("no browser pane in \(reply)") }

    return (NodeID(rawValue: id), applet)
  }

  private func command(
    _ fixture: ScriptingFixture, _ controller: MainWindowController, _ pane: NodeID,
    _ name: String, _ arguments: String = "{}", tab: UInt64? = nil, as caller: ScriptCaller? = nil,
    holding powers: Set<ControllerPermission>? = nil
  ) async throws -> ScriptValue {
    var reference = ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)

    reference.tab = tab

    let held = powers ?? both

    return try await fixture.scripting.sendCommand(
      to: .pane(reference), appletType: "browser", schemaVersion: ScriptSchemaVersion(major: 0),
      command: name, arguments: arguments, caller: caller ?? fixture.caller,
      powers: { held }, stillAllowed: {})
  }

  private func failure(
    _ body: () async throws -> ScriptValue
  ) async -> ScriptCallError? {
    do {
      _ = try await body()
      return nil
    } catch let error as ScriptCallError {
      return error
    } catch {
      return ScriptCallError.failed("\(error)")
    }
  }

  private func eventually(
    _ message: String, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
  ) async {
    let deadline = ContinuousClock.now + .seconds(15)

    while !condition() {
      guard ContinuousClock.now < deadline else {
        return XCTFail("timed out waiting until \(message)", file: file, line: line)
      }

      await Task.yield()
    }
  }

  private func url(_ path: String) -> String {
    #"{"url":"\#(server.url(path).absoluteString)"}"#
  }

  // MARK: Commands

  /// Catches a reply to open that a script cannot use to address the tab, an owner that is not the
  /// caller's connection, and a read that works for another connection. The reply is a full
  /// reference, and the next command names the tab by its number.
  func testOpenAnswersAReferenceTheNextCommandUsesAndOnlyTheOpenerMayRead() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()
    let (pane, applet) = try await openBrowser(fixture, controller, first)

    let reply = try await command(fixture, controller, pane, "open", url("/a"))

    guard case .record(let fields) = reply, case .integer(let tab)? = fields["tab"],
      case .integer(let window)? = fields["window"], case .integer(let named)? = fields["pane"]
    else { return XCTFail("open answered \(reply)") }

    XCTAssertEqual(window, controller.scriptWindowID)
    XCTAssertEqual(named, pane.rawValue)

    await eventually("the page loads") {
      applet.title == "A" || applet.tabCount == 2
    }

    let read = try await command(fixture, controller, pane, "read", tab: tab)

    guard case .record(let page) = read else { return XCTFail("read answered \(read)") }

    XCTAssertEqual(page["url"], .string(server.url("/a").absoluteString))

    let stranger = ScriptCaller(connection: 2, window: fixture.caller.window, pane: pane)

    let error = await failure {
      try await self.command(fixture, controller, pane, "read", tab: tab, as: stranger)
    }

    XCTAssertEqual(error?.kind, .refused)
    XCTAssertTrue(error?.text.contains("did not open that tab") ?? false, error?.text ?? "")
  }

  /// Catches a grant that ends and leaves its tabs owned. A controller that acts from the browser
  /// pane itself owns no group, so the pane's control does not move when its run ends. Only the
  /// window's word to the applet clears what the run opened.
  func testEndingAGrantReleasesItsTabsEvenWhenThePanesControlStaysPut() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()
    let (pane, applet) = try await openBrowser(fixture, controller, first)
    let own = ScriptCaller(connection: 2, window: fixture.caller.window, pane: pane)

    let reply = try await command(
      fixture, controller, pane, "open", url("/a"), as: own)

    guard case .record(let fields) = reply, case .integer(let tab)? = fields["tab"] else {
      return XCTFail("open answered \(reply)")
    }

    let ownGrant = AppletCaller(grant: "connection 2")

    XCTAssertEqual(applet.tabOwners.values.filter { $0 == ownGrant }.count, 1)

    let generation = controller.control(of: pane).generation

    controller.controllerEnded(2)

    XCTAssertEqual(controller.control(of: pane).generation, generation, "the control moved")
    XCTAssertEqual(
      applet.tabOwners.values.filter { $0 == ownGrant }.count, 0, "the ended grant kept its tab")

    let error = await failure {
      try await self.command(fixture, controller, pane, "read", tab: tab, as: own)
    }

    XCTAssertEqual(error?.kind, .refused)
  }

  /// Catches a command that runs without its power, with a message that does not say what to do,
  /// and a power that unlocks the other kind's commands.
  func testACommandWithoutItsPowerIsRefusedWithTheNameOfThePower() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()
    let (pane, applet) = try await openBrowser(fixture, controller, first)

    for (name, held) in [
      ("open", Set<ControllerPermission>([.paneControl])),
      ("open", Set<ControllerPermission>([.paneControl, .browserRead])),
    ] {
      let error = await failure {
        try await self.command(
          fixture, controller, pane, name, self.url("/a"), holding: held)
      }

      XCTAssertEqual(error?.kind, .refused, name)
      XCTAssertTrue(error?.text.contains("browser-navigation") ?? false, error?.text ?? "")
    }

    XCTAssertEqual(applet.tabCount, 1)
    XCTAssertEqual(server.requests.count, 0)
  }

  /// Catches an error code with no script meaning: a busy refusal must read as busy, which the
  /// script retries, and a missing power or an unowned tab as refused. Each message reaches the
  /// script with the applet's reason.
  func testTheNewCodesReachAScriptAsRefusedOrBusyWithTheirReason() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()
    let panes = try await layOut(
      fixture, controller, anchor: first.paneID,
      node: #"{"open":"fixture-powered","control":"remote-controlled"}"#, holding: both)
    let id = try XCTUnwrap(panes.last).rawValue

    let reference = ScriptPaneReference(window: controller.scriptWindowID, pane: id)

    for (code, kind) in [
      ("permission-missing", ScriptFailureKind.refused), ("not-owned", .refused),
      ("busy", .busy),
    ] {
      let error = await failure {
        try await fixture.scripting.sendCommand(
          to: .pane(reference), appletType: "fixture-powered",
          schemaVersion: ScriptSchemaVersion(major: 0), command: "fail",
          arguments: #"{"code":"\#(code)"}"#, caller: fixture.caller, powers: { [] },
          stillAllowed: {})
      }

      XCTAssertEqual(error?.kind, kind, code)
      XCTAssertEqual(error?.text, "the fixture refused with \(code)")
    }
  }

  /// Catches a generic tab open from a script that reaches a browser. The refusal names the
  /// browser's own command. A terminal's tab open is not touched by it.
  func testAScriptsGenericTabOpenIsRefusedForABrowserAndNamesItsOpenCommand() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()
    let (pane, applet) = try await openBrowser(fixture, controller, first)

    let reference = ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)
    let error = await failure {
      try await fixture.openTab(pane: reference, directory: nil)
    }

    XCTAssertEqual(error?.kind, .refused)
    XCTAssertTrue(error?.text.contains("open command") ?? false, error?.text ?? "")
    XCTAssertEqual(applet.tabCount, 1)
  }

  // MARK: Powers asked about

  /// Catches the window naming the wrong power for a call, which would make the host ask about the
  /// wrong thing or nothing.
  func testTheWindowNamesTheExtraPowerEachCallNeeds() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()
    let (pane, _) = try await openBrowser(fixture, controller, first)
    let target = ScriptTarget.pane(
      ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue))
    let caller = fixture.caller

    func power(_ name: String) -> ControllerPermission? {
      fixture.scripting.extraPower(
        for: .sendCommand(
          pane: target, appletType: "browser", schemaVersion: ScriptSchemaVersion(major: 0),
          command: name, arguments: "{}"), caller: caller)
    }

    XCTAssertEqual(power("open"), .browserNavigation)
    XCTAssertEqual(power("select"), .browserNavigation)
    XCTAssertEqual(power("read"), .browserRead)
    XCTAssertNil(power("scroll"), "an unknown command needs no power to be refused")

    let anchor = target
    let withURL = #"{"open":"browser","control":"remote-controlled","url":"https://example.com"}"#
    let plain = #"{"open":"browser","control":"remote-controlled"}"#

    func layoutPower(_ node: String) -> ControllerPermission? {
      let layout =
        #"{"split":"row","children":[{"pane":\#(pane.rawValue)},\#(node)]}"#

      return fixture.scripting.extraPower(
        for: .requestLayout(pane: anchor, layout: layout), caller: caller)
    }

    XCTAssertEqual(layoutPower(withURL), .browserNavigation)
    XCTAssertNil(layoutPower(plain))
  }

  // MARK: Layouts

  private func layOut(
    _ fixture: ScriptingFixture, _ controller: MainWindowController, anchor: NodeID, node: String,
    holding powers: Set<ControllerPermission>
  ) async throws -> [NodeID] {
    let layout = #"{"split":"row","children":[{"pane":\#(anchor.rawValue)},\#(node)]}"#
    let reply = try await fixture.scripting.requestLayout(
      anchor: .pane(
        ScriptPaneReference(window: controller.scriptWindowID, pane: anchor.rawValue)),
      layout: layout, caller: fixture.caller, powers: { powers }, stillAllowed: {})

    guard case .record(let fields) = reply, case .array(let panes)? = fields["panes"] else {
      throw ScriptCallError.failed("no panes in \(reply)")
    }

    return panes.compactMap {
      guard case .record(let pane) = $0, case .integer(let id)? = pane["pane"] else { return nil }

      return NodeID(rawValue: id)
    }
  }

  /// Catches a seeded browser pane that loads nothing, one made without browser navigation, and a
  /// first tab that is not the layout caller's. The seed is a loopback address and goes over HTTP.
  func testALayoutSeedsABrowserPaneAndTheFirstTabBelongsToTheCaller() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()
    let seed = server.url("/seeded").absoluteString
    let node = #"{"open":"browser","control":"remote-controlled","url":"\#(seed)"}"#

    let refused = await failure {
      _ = try await self.layOut(
        fixture, controller, anchor: first.paneID, node: node, holding: [.paneControl])
      return .null
    }

    XCTAssertEqual(refused?.kind, .refused)
    XCTAssertTrue(refused?.text.contains("browser-navigation") ?? false, refused?.text ?? "")
    XCTAssertEqual(controller.paneIDs.count, 1, "a refused layout left a pane")
    XCTAssertEqual(server.requests.count, 0)

    let panes = try await layOut(
      fixture, controller, anchor: first.paneID, node: node, holding: both)
    let created = try XCTUnwrap(panes.last)
    let applet = try XCTUnwrap(controller.paneArea.applet(for: created) as? BrowserApplet)

    await eventually("the seed loads") { applet.title == "SEEDED" }

    XCTAssertEqual(server.requests.filter { $0.path == "/seeded" }.count, 1)
    XCTAssertEqual(applet.tabOwners.count, 1)
    XCTAssertEqual(
      applet.tabOwners.values.first, AppletCaller(grant: "connection \(fixture.caller.connection)"))
  }

  /// Catches a browser pane opened with open-pane whose first tab the opener cannot drive. The
  /// layout path owns it for the caller, and so must this one. A disconnected pane has no
  /// controller, so its first tab stays unowned.
  func testAnOpenedBrowserPaneStartsWithItsFirstTabOwnedByTheOpener() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()

    let (_, remote) = try await openBrowser(fixture, controller, first)

    XCTAssertEqual(remote.tabOwners.count, 1)
    XCTAssertEqual(
      remote.tabOwners.values.first, AppletCaller(grant: "connection \(fixture.caller.connection)"))

    let (_, plain) = try await openBrowser(fixture, controller, first, access: .disconnected)

    XCTAssertEqual(plain.tabOwners.count, 0, "a disconnected pane's first tab was owned")
  }

  /// Catches a seed that bypasses the scheme rule, a url on a pane that is not a browser, and a
  /// layout browser with no url that starts anywhere but blank. A disconnected browser pane gets
  /// no owner for its first tab.
  func testALayoutSeedMeetsTheSchemeRuleAndOnlyABrowserTakesOne() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()

    for bad in [
      "javascript:alert(1)", " JaVaScRiPt:alert(1) ", "data:text/html,x", "FILE:///etc/hosts",
    ] {
      let node = #"{"open":"browser","url":"\#(bad)"}"#
      let error = await failure {
        _ = try await self.layOut(
          fixture, controller, anchor: first.paneID, node: node, holding: self.both)
        return .null
      }

      XCTAssertEqual(error?.kind, .badArgument, bad)
    }

    let elsewhere = await failure {
      _ = try await self.layOut(
        fixture, controller, anchor: first.paneID,
        node: #"{"open":"fixture-slides","url":"https://example.com"}"#, holding: self.both)
      return .null
    }

    XCTAssertEqual(elsewhere?.kind, .badArgument)
    XCTAssertEqual(controller.paneIDs.count, 1)

    let panes = try await layOut(
      fixture, controller, anchor: first.paneID, node: #"{"open":"browser"}"#, holding: both)
    let applet = try XCTUnwrap(controller.paneArea.applet(for: panes.last!) as? BrowserApplet)

    XCTAssertNil(applet.tab.record.url)
    XCTAssertEqual(applet.tabOwners.count, 0, "a disconnected pane's first tab was owned")
    XCTAssertEqual(server.requests.count, 0)
  }

  /// Catches a layout that gives a browser pane an exec driver, which the browser does not take.
  func testALayoutCannotGiveABrowserAnExecDriver() async throws {
    let fixture = makeFixture()
    let (controller, first) = try fixture.openWindow()
    let node = #"{"open":"browser","exec":{"argv":["/usr/bin/true"]}}"#

    let error = await failure {
      _ = try await self.layOut(
        fixture, controller, anchor: first.paneID, node: node, holding: self.both)
      return .null
    }

    XCTAssertEqual(error?.kind, .refused)
    XCTAssertEqual(controller.paneIDs.count, 1)
  }
}

@MainActor
private final class NoReveal: FileRevealing {
  func reveal(_ url: URL) {}
}

@MainActor
private final class NoOpener: URLOpening {
  func applicationName(toOpen url: URL) -> String? { nil }
  func open(_ url: URL) -> Bool { false }
}

extension ScriptPaneReference {
  fileprivate var paneID: NodeID { NodeID(rawValue: pane) }
}
