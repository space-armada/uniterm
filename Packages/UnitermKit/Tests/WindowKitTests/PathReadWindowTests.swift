import AppKit
import AppletFixtures
import AppletKit
import PaneModel
import ScriptHost
import ScriptWire
import SourceAccess
import XCTest

@testable import WindowKit

/// A path-reading command and the pane list, through the window side of the host API as a script
/// reaches them. The fixture applet reads what the host opened. The package tests of the scoped
/// open and of shared dispatch prove each rule alone. These prove that the window wires the scope
/// into both, off the main thread, and that the pane list hides what a user's file would tell.
@MainActor
final class PathReadWindowTests: XCTestCase {
  private var base: URL!
  private var scope: ReadScope!

  override func setUpWithError() throws {
    base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-pathread-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()

    for name in ["scope", "outside"] {
      try FileManager.default.createDirectory(
        at: base.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    try Data("inside".utf8).write(to: base.appendingPathComponent("scope/a.txt"))
    try Data("secret".utf8).write(to: base.appendingPathComponent("outside/s.txt"))

    scope = try ReadScope(directories: [base.appendingPathComponent("scope").path])

    let folder = base!

    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
  }

  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func pathsPane(
    _ controller: MainWindowController
  ) throws -> (pane: NodeID, applet: PathsFixture) {
    let pane = try XCTUnwrap(
      controller.openPane(
        .hosted(typeID: PathsFixture.typeID), axis: .row, from: controller.focusedPane))

    controller.enableRemoteControl(controller.focusedPane)
    controller.enableRemoteControl(pane)

    return (pane, try XCTUnwrap(controller.paneArea.applet(for: pane) as? PathsFixture))
  }

  private func read(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController, _ pane: NodeID, _ path: String,
    access: @escaping @MainActor () -> ReadAccess
  ) async throws -> ScriptValue {
    let caller = ScriptCaller(
      connection: 1, window: controller.scriptWindowID, pane: controller.focusedPane)

    return try await fixture.scripting.sendCommand(
      to: .pane(ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)),
      appletType: PathsFixture.typeID, schemaVersion: ScriptSchemaVersion(major: 0),
      command: "read-file", arguments: #"{"path":\#(try Self.json(path))}"#, caller: caller,
      access: access, stillAllowed: {})
  }

  private static func json(_ text: String) throws -> String {
    String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
  }

  /// Catches a read that does not reach the applet, and a refusal that tells what the path is. A
  /// file in the scope reads. A file outside, a missing one, and a caller with no power all fail
  /// with one refusal.
  func testACommandReadsInsideTheScopeAndRefusesEverythingElseAlike() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, _) = try pathsPane(controller)
    let granted = ReadAccess(scope: scope)

    let value = try await read(fixture, controller, pane, base.path + "/scope/a.txt") { granted }

    XCTAssertEqual(value, .record(["text": .string("inside")]))

    var texts: Set<String> = []

    for (path, access) in [
      (base.path + "/outside/s.txt", granted), (base.path + "/outside/none.txt", granted),
      (base.path + "/scope/a.txt", ReadAccess.none),
    ] {
      do {
        _ = try await read(fixture, controller, pane, path) { access }
        XCTFail("\(path) was read")
      } catch let error as ScriptCallError {
        XCTAssertEqual(error.kind, .refused)
        texts.insert(error.text)
      }
    }

    XCTAssertEqual(texts.count, 1, "\(texts)")
  }

  /// Catches a grant that ends while the command waits for its turn and still reads. The access is
  /// asked once to open and again at delivery, and the second answer holds nothing.
  func testAGrantRevokedBeforeDeliveryReadsNothing() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, applet) = try pathsPane(controller)
    var asked = 0
    let scope = self.scope!

    do {
      _ = try await read(fixture, controller, pane, base.path + "/scope/a.txt") {
        asked += 1

        return asked == 1 ? ReadAccess(scope: scope) : .none
      }
      XCTFail("the read ran")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    XCTAssertGreaterThanOrEqual(asked, 2)
    XCTAssertEqual(applet.lastArguments, [:])
  }

  /// Catches a pane list that tells a controller the name or folder of a user's file outside its
  /// scope. The pane is still listed, with empty titles and no directory. Terminals, panes with no
  /// file, and files inside the scope keep theirs.
  func testListPanesHidesTheTitlesOfFilesOutsideTheScope() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, applet) = try pathsPane(controller)
    let window = controller.scriptWindowID
    let caller = ScriptCaller(connection: 1, window: window, pane: controller.focusedPane)

    func fields(_ access: ReadAccess) throws -> [String: ScriptValue] {
      let listed = try fixture.scripting.listPanes(window: window, caller: caller, access: access)

      guard case .array(let panes) = listed else { throw XCTSkip("no list") }

      for case .record(let record) in panes where record["pane"] == .integer(pane.rawValue) {
        return record
      }

      throw XCTSkip("the pane is not listed")
    }

    applet.userFileSource = base.path + "/outside/s.txt"

    let hidden = try fields(ReadAccess(scope: scope))

    XCTAssertEqual(hidden["title"], .string(""))
    XCTAssertNil(hidden["directory"])

    guard case .array(let tabs)? = hidden["tabs"], case .record(let tab)? = tabs.first else {
      return XCTFail("no tabs")
    }

    XCTAssertEqual(tab["title"], .string(""))
    XCTAssertEqual(hidden["applet"], .string(PathsFixture.typeID), "the applet type stays")

    applet.userFileSource = base.path + "/scope/a.txt"

    XCTAssertEqual(try fields(ReadAccess(scope: scope))["title"], .string("Paths fixture"))

    applet.userFileSource = nil

    XCTAssertEqual(try fields(.none)["title"], .string("Paths fixture"))

    applet.userFileSource = base.path + "/sent/42/x.md"

    XCTAssertEqual(
      try fields(ReadAccess(scope: nil, controllerSentRoot: base.path + "/sent"))["title"],
      .string("Paths fixture"), "content the caller sent is its own")
    XCTAssertEqual(try fields(.none)["title"], .string(""))
  }

  /// Catches a run that declared the power and was allowed once being told nothing useful. Its
  /// refusal names its own grant, and differs from the uniform one, which stays the same for a
  /// caller outside its scope. The caller knows its own grant, so this is no probe.
  func testARunAllowedOnceIsToldItsGrantIsMissing() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, _) = try pathsPane(controller)
    let path = base.path + "/scope/a.txt"
    let notGranted = ReadAccess(scope: nil, isDeclaredButNotGranted: true)

    var kinds: [String] = []

    for access in [notGranted, ReadAccess.none, ReadAccess(scope: scope)] {
      do {
        let value = try await read(fixture, controller, pane, path) { access }

        kinds.append("read \(value)")
      } catch let error as ScriptCallError {
        kinds.append(error.text)
      }
    }

    XCTAssertTrue(kinds[0].contains("allowed the run once"), kinds[0])
    XCTAssertTrue(kinds[1].contains("cannot read that path"), kinds[1])
    XCTAssertNotEqual(kinds[0], kinds[1])
    XCTAssertTrue(kinds[2].hasPrefix("read"), kinds[2])
  }

  /// Catches a folder source whose members skip the check. The command lists and opens the members
  /// off the main thread, through the window, and answers on a later turn. The member that links
  /// out of the scope is refused and the others read.
  func testAFolderSourceOpensEachMemberThroughTheSameCheck() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, _) = try pathsPane(controller)

    try Data("second".utf8).write(to: base.appendingPathComponent("scope/b.txt"))
    try FileManager.default.createSymbolicLink(
      atPath: base.appendingPathComponent("scope/escape.txt").path,
      withDestinationPath: base.appendingPathComponent("outside/s.txt").path)

    let caller = ScriptCaller(
      connection: 1, window: controller.scriptWindowID, pane: controller.focusedPane)
    let access = ReadAccess(scope: scope)

    let value = try await fixture.scripting.sendCommand(
      to: .pane(ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)),
      appletType: PathsFixture.typeID, schemaVersion: ScriptSchemaVersion(major: 0),
      command: "read-folder", arguments: #"{"path":\#(try Self.json(base.path + "/scope"))}"#,
      caller: caller, access: { access }, stillAllowed: {})

    XCTAssertEqual(
      value,
      .record([
        "read": .array([.string("a.txt"), .string("b.txt")]),
        "refused": .array([.string("escape.txt")]),
      ]))
  }

  /// Catches a walk on a dead mount that parks another thread with every command. The opener
  /// blocks, as an open on a hung network volume does. A second command from the same connection
  /// is refused at once with the answer any outside path gets, a walk of another connection still
  /// starts while the first is blocked, and the slot comes back when the walk returns. It cannot prove how many threads the system
  /// would park, only that the walk count per connection stays under the bound.
  func testAConnectionCannotKeepMoreWalksRunningThanTheBound() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, _) = try pathsPane(controller)
    let gate = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)

    let scripting = WindowScripting(
      windows: fixture.windows,
      scopedOpener: { path, scope in
        entered.signal()
        _ = gate.wait(timeout: .now() + 5)

        return ScopedOpen.open(path: path, in: scope)
      }, maxWalksPerCaller: 1)

    let access = ReadAccess(scope: scope)
    let path = base.path + "/scope/a.txt"
    let window = controller.scriptWindowID

    func waitFor(_ signal: DispatchSemaphore) async {
      await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          signal.wait()
          continuation.resume()
        }
      }
    }

    func read(connection: UInt64) async throws -> ScriptValue {
      try await scripting.sendCommand(
        to: .pane(ScriptPaneReference(window: window, pane: pane.rawValue)),
        appletType: PathsFixture.typeID, schemaVersion: ScriptSchemaVersion(major: 0),
        command: "read-file", arguments: #"{"path":\#(try Self.json(path))}"#,
        caller: ScriptCaller(connection: connection, window: window, pane: controller.focusedPane),
        access: { access }, stillAllowed: {})
    }

    let first = Task { try await read(connection: 1) }

    await waitFor(entered)

    do {
      _ = try await read(connection: 1)
      XCTFail("a second walk ran beside the first")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    let other = Task { try await read(connection: 2) }

    await waitFor(entered)

    gate.signal()
    gate.signal()

    let firstValue = try await first.value
    let otherValue = try await other.value

    XCTAssertEqual(firstValue, .record(["text": .string("inside")]))
    XCTAssertEqual(
      otherValue, .record(["text": .string("inside")]), "another connection was held up")

    let again = Task { try await read(connection: 1) }

    await waitFor(entered)
    gate.signal()

    let againValue = try await again.value

    XCTAssertEqual(againValue, .record(["text": .string("inside")]), "the slot returns")
  }
}
