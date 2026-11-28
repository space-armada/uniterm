import AppKit
import AppletFixtures
import AppletKit
import BrowserApplet
import DefaultsTestSupport
import ExecDriver
import ExecTestSupport
import LayoutKit
import MapViewerApplet
import PaneModel
import Preferences
import ProcessTestSupport
import ScriptHost
import ScriptWire
import TextViewerApplet
import XCTest

@testable import WindowKit

/// Real windows whose panes hold hosted fixtures, a real driver process, and the window side of
/// the host API. Every pane is a slides fixture, except one the test opens as a fake applet that
/// takes no commands.
///
/// These prove the pane's exec driver from Run to end: execution authority, launch inputs, shared
/// dispatch with remote callers, the disconnected rule, restore, and close. They cannot prove the
/// chrome on screen or the panel's buttons. The UI tests drive those.
@MainActor
final class ExecPaneFixture {
  let testDefaults = TestDefaults(prefix: "uniterm-exec-test")
  let defaults: UserDefaults
  let windows: WindowSet
  let scripting: WindowScripting
  let scratch: URL

  /// The kind of applet the next pane gets.
  var nextIsFake = false
  var nextIsNotes = false
  var nextIsMap = false

  /// What the values sheet answers, and the keys it was asked for.
  var values: [String: String]? = [:]
  private(set) var askedKeys: [[String]] = []

  static let declarations =
    AppletFixtures.declarations + [
      AppletTypeDeclaration(
        typeID: "fake", displayName: "Fake", symbolName: "questionmark", opens: [],
        controlSupport: [.remoteControlled]),
      TextViewerApplet.typeDeclaration, MapViewerApplet.typeDeclaration,
      BrowserApplet.typeDeclaration,
    ]

  init() throws {
    let defaults = testDefaults.defaults
    let store = SettingsStore(defaults: defaults)
    let appearance = AppearanceController(store: store)

    self.defaults = defaults
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "exec-pane-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    var factory: AppletFactory = { _, _ in SlidesFixture() }

    windows = WindowSet(
      visibleFrame: { _ in NSRect(x: 0, y: 0, width: 4000, height: 3000) },
      makeRestoredController: { identifier, restored in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier,
          appletTypes: ExecPaneFixture.declarations, restoring: restored,
          restoreApplet: { try AppletFixtures.restore($0) },
          makeApplet: { choice, directory in try factory(choice, directory) }
        ).detachFromRealScreen()
      },
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          appletTypes: ExecPaneFixture.declarations,
          makeApplet: { choice, directory in try factory(choice, directory) }
        ).detachFromRealScreen()
      })

    scripting = WindowScripting(windows: windows)

    // A hosted choice, as a layout makes, gets its own fixture. Any other gets a slides fixture.
    factory = { [unowned self] choice, directory in
      if case .hosted(let typeID) = choice, let applet = AppletFixtures.make(typeID: typeID) {
        return applet
      }

      if case .textViewer = choice { return TextViewerApplet(startDirectory: directory) }

      if nextIsNotes { return NotesFixture() }

      if nextIsMap { return MapViewerApplet(startDirectory: directory) }

      return nextIsFake ? FakeApplet() as any Applet : SlidesFixture()
    }
  }

  func cleanUp() {
    for controller in windows.controllers { controller.window?.close() }

    testDefaults.discard()
    try? FileManager.default.removeItem(at: scratch)
  }

  /// Opens a window whose values sheet and kill grace the test controls.
  func openWindow() throws -> MainWindowController {
    let controller = try windows.open()

    prepare(controller)
    return controller
  }

  func prepare(_ controller: MainWindowController) {
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    controller.execKillGrace = .milliseconds(300)
    controller.execValuesAsker = { [unowned self] keys, _, _ in
      askedKeys.append(keys)
      return values
    }
  }

  func declaration(
    _ mode: String, _ rest: [String] = [], directory: String? = nil, keys: [String] = []
  ) throws -> ExecDeclaration {
    try ExecDeclaration(
      arguments: ExecTestDriver.arguments(mode, type: SlidesFixture.typeID, rest),
      directory: directory, environmentKeys: keys)
  }

  func slides(_ controller: MainWindowController, _ pane: NodeID) -> SlidesFixture? {
    controller.paneArea.applet(for: pane) as? SlidesFixture
  }

  func caller(_ controller: MainWindowController, _ pane: NodeID) -> ScriptCaller {
    ScriptCaller(connection: 1, window: controller.scriptWindowID, pane: pane)
  }

  func command(
    _ controller: MainWindowController, _ pane: NodeID, _ name: String, _ arguments: String = "{}",
    type: String = SlidesFixture.typeID,
    version: ScriptSchemaVersion = ScriptSchemaVersion(major: 0),
    stillAllowed: @escaping @MainActor () throws -> Void = {}
  ) async throws -> ScriptValue {
    try await scripting.sendCommand(
      to: .pane(ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)),
      appletType: type, schemaVersion: version, command: name, arguments: arguments,
      caller: caller(controller, pane), stillAllowed: stillAllowed)
  }
}

@MainActor
final class ExecPaneTests: XCTestCase {
  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
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

  private func deck(_ titles: [String]) -> String {
    #"{"name":"set-deck","arguments":{"titles":[\#(titles.map { "\"\($0)\"" }.joined(separator: ","))]}}"#
  }

  private func isRunning(_ controller: MainWindowController, _ pane: NodeID) -> Bool {
    controller.execAttachments[pane]?.channel?.isConnected == true
  }

  /// Catches a driver that starts before approval, a request that does not show the exact inputs
  /// it binds, or an approved driver whose stdout does not drive the applet.
  func testRunWaitsForApprovalThenTheDriverDrivesTheApplet() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    try controller.declareExecDriver(fixture.declaration("script", [deck(["A", "B"])]), for: pane)
    controller.runExecDriver(pane)

    let requests = fixture.windows.launchAuthority.requests

    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.launch.arguments.last, deck(["A", "B"]))
    XCTAssertEqual(requests.first?.launch.directory, controller.execEnvironment?.home)
    XCTAssertEqual(requests.first?.launch.environment, [:])
    XCTAssertEqual(requests.first?.target.pane, pane)
    XCTAssertNil(controller.execAttachments[pane]?.channel, "the driver started before approval")
    XCTAssertEqual(fixture.slides(controller, pane)?.titles, [])

    fixture.windows.launchAuthority.decide(try XCTUnwrap(requests.first?.id), .allowOnce)

    await waitUntil("the driver sets the deck") {
      fixture.slides(controller, pane)?.titles == ["A", "B"]
    }

    XCTAssertEqual(controller.control(of: pane).driver, .exec)
    XCTAssertEqual(controller.control(of: pane).access, .disconnected)
  }

  /// Catches Allow once that covers a second launch, and a pane grant that prompts again when only
  /// the arguments change, or that covers a broader program, directory, key set, or pane.
  func testAllowOnceIsOnceAndAGrantCoversOnlyItsScope() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let authority = fixture.windows.launchAuthority

    try controller.declareExecDriver(fixture.declaration("exit", ["0"]), for: pane)
    controller.runExecDriver(pane)
    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowOnce)

    await waitUntil("the first run ends") {
      if case .ended? = controller.execAttachments[pane]?.state { return true }
      return false
    }

    controller.runExecDriver(pane)

    XCTAssertEqual(authority.requests.count, 1, "Allow once covered a second launch")

    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowInPane)

    await waitUntil("the granted run ends") {
      if case .ended? = controller.execAttachments[pane]?.state { return true }
      return false
    }

    try controller.declareExecDriver(fixture.declaration("exit", ["7"]), for: pane)
    controller.runExecDriver(pane)

    XCTAssertTrue(authority.requests.isEmpty, "other arguments in the granted scope asked again")
    XCTAssertNotNil(controller.execAttachments[pane]?.channel)

    await waitUntil("the varied run ends") {
      if case .ended? = controller.execAttachments[pane]?.state { return true }
      return false
    }

    let broader = [
      try fixture.declaration("exit", ["0"], directory: fixture.scratch.path),
      try fixture.declaration("exit", ["0"], keys: ["EXTRA"]),
      try ExecDeclaration(
        arguments: ["/bin/sh", "-c", "exit 0"], directory: nil, environmentKeys: []),
    ]

    fixture.values = ["EXTRA": "x"]

    for declaration in broader {
      try controller.declareExecDriver(declaration, for: pane)
      controller.runExecDriver(pane)

      await waitUntil("\(declaration.arguments.suffix(2)) asks") { !authority.requests.isEmpty }

      XCTAssertEqual(authority.requests.count, 1, "\(declaration) ran without asking")
      XCTAssertNil(controller.execAttachments[pane]?.channel, "\(declaration) ran without asking")

      authority.decide(try XCTUnwrap(authority.requests.first?.id), .deny)
    }

    controller.openPane(.terminalShell, axis: .row)
    let other = controller.focusedPane

    try controller.declareExecDriver(fixture.declaration("exit", ["0"]), for: other)
    controller.runExecDriver(other)

    XCTAssertEqual(authority.requests.count, 1, "the grant covered another pane")
    XCTAssertEqual(authority.requests.first?.target.pane, other)
  }

  /// Catches a remote command that reaches a disconnected pane while its driver commands it, a
  /// remote command that skips the type or version check, and an applet with no commands that
  /// takes one. The driver's commands and the remote ones meet in the same dispatch.
  func testRemoteAndExecShareDispatchAndDisconnectedRefusesOnlyRemote() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    try controller.declareExecDriver(
      fixture.declaration("script", [deck(["A", "B", "C"])]), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver sets the deck") {
      fixture.slides(controller, pane)?.titles.count == 3
    }

    do {
      _ = try await fixture.command(controller, pane, "show-slide", #"{"index":2}"#)
      XCTFail("a disconnected pane took a remote command")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 0)

    controller.enableRemoteControl(pane)

    let reply = try await fixture.command(controller, pane, "show-slide", #"{"index":2}"#)

    XCTAssertEqual(reply, .record(["index": .integer(2), "title": .string("C")]))

    for (type, version, name, arguments, kind) in [
      (
        ChartFixture.typeID, ScriptSchemaVersion(major: 0), "status", "{}",
        ScriptFailureKind.unsupported
      ),
      (SlidesFixture.typeID, ScriptSchemaVersion(major: 2), "status", "{}", .unsupported),
      (SlidesFixture.typeID, ScriptSchemaVersion(major: 1), "status", "{}", .unsupported),
      (SlidesFixture.typeID, ScriptSchemaVersion(major: 0, minor: 1), "status", "{}", .unsupported),
      (SlidesFixture.typeID, ScriptSchemaVersion(major: 0), "run", "{}", .badArgument),
      (
        SlidesFixture.typeID, ScriptSchemaVersion(major: 0), "show-slide", #"{"index":"1"}"#,
        .badArgument
      ),
      (SlidesFixture.typeID, ScriptSchemaVersion(major: 0), "show-slide", "[1]", .badArgument),
      (
        SlidesFixture.typeID, ScriptSchemaVersion(major: 0), "show-slide", "not json",
        .badArgument
      ),
    ] {
      do {
        _ = try await fixture.command(
          controller, pane, name, arguments, type: type, version: version)
        XCTFail("\(type) \(version) \(name) was taken")
      } catch let error as ScriptCallError {
        XCTAssertEqual(error.kind, kind, "\(type) \(version) \(name) \(arguments)")
      }
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 2)

    fixture.nextIsFake = true
    controller.openPane(.terminalShell, axis: .row)
    let fake = controller.focusedPane
    controller.enableRemoteControl(fake)

    do {
      _ = try await fixture.command(controller, fake, "status", type: "fake")
      XCTFail("an applet with no commands took one")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
      XCTAssertTrue(error.text.contains("takes no commands"), error.text)
    }

    XCTAssertThrowsError(try controller.declareExecDriver(fixture.declaration("exit"), for: fake))
  }

  /// Catches a remote command whose grant ends after the checks and before delivery, and still
  /// takes effect.
  func testAuthorityEndingBeforeDeliveryLeavesNoEffect() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let turns = Turns()

    controller.dispatcher = ControlDispatcher { turns.pending.append($0) }
    controller.enableRemoteControl(pane)

    let deck = Task { @MainActor in
      try await fixture.command(controller, pane, "set-deck", #"{"titles":["A","B"]}"#)
    }

    await waitUntil("the deck waits in the queue") { controller.dispatcher.queuedCount == 1 }
    turns.run()
    _ = try await deck.value

    let pending = Task { @MainActor in
      try await fixture.command(controller, pane, "show-slide", #"{"index":1}"#)
    }

    await waitUntil("the command waits in the queue") { controller.dispatcher.queuedCount == 1 }

    controller.disconnect(pane)
    turns.run()

    do {
      _ = try await pending.value
      XCTFail("a command delivered after disconnect took effect")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 0)

    controller.enableRemoteControl(pane)

    let carried = Task { @MainActor in
      try await fixture.command(controller, pane, "show-slide", #"{"index":1}"#)
    }

    await waitUntil("the carried command waits") { controller.dispatcher.queuedCount == 1 }

    controller.disconnect(pane)
    controller.enableRemoteControl(pane)
    turns.run()

    do {
      _ = try await carried.value
      XCTFail("a command queued before a disconnect ran after the pane was enabled again")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 0)

    let allowed = Flag(true)
    let revoked = Task { @MainActor in
      try await fixture.command(controller, pane, "show-slide", #"{"index":1}"#) {
        guard allowed.on else { throw ScriptCallError.refused("revoked") }
      }
    }

    await waitUntil("the second command waits") { controller.dispatcher.queuedCount == 1 }

    allowed.on = false
    turns.run()

    do {
      _ = try await revoked.value
      XCTFail("a command delivered after its grant ended took effect")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.text, "revoked")
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 0)
  }

  /// Catches a driver command that waited in the queue and still runs once the driver no longer
  /// drives the pane: after the driver is replaced by a new declaration, or after the pane closes.
  func testADriverCommandQueuedBeforeItsDriverEndedLeavesNoEffect() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let turns = Turns()

    controller.dispatcher = ControlDispatcher { turns.pending.append($0) }
    controller.openPane(.terminalShell, axis: .row)

    for (pane, end) in [(controller.paneIDs[0], "replaced"), (controller.paneIDs[1], "closed")] {
      let applet = try XCTUnwrap(fixture.slides(controller, pane))

      try controller.declareExecDriver(fixture.declaration("script", [deck(["A"])]), for: pane)
      controller.runExecDriver(pane)
      fixture.windows.launchAuthority.decide(
        try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

      await waitUntil("the driver's set-deck waits in the queue") {
        controller.dispatcher.queuedCount == 1
      }

      if end == "replaced" {
        try controller.declareExecDriver(fixture.declaration("exit"), for: pane)
      } else {
        controller.closePane(pane, appletEnded: false)
      }

      turns.run()

      XCTAssertEqual(applet.titles, [], "a command ran after its driver was \(end)")
    }
  }

  /// Catches a layout that saves an environment value, a restored exec pane that runs anything,
  /// and a Run that does not wait for the values and the approval.
  func testARestoredExecPaneRunsNothingUntilValuesAndApproval() async throws {
    let fixture = try makeFixture()
    let first = try fixture.openWindow()
    let output = fixture.scratch.appendingPathComponent("env")

    try first.declareExecDriver(
      fixture.declaration("env", [output.path], keys: ["SYNTHETIC_TOKEN"]), for: first.focusedPane)
    first.execAttachments[first.focusedPane]?.values = ["SYNTHETIC_TOKEN": "secret-value"]

    let saved = try XCTUnwrap(first.savedWindow())
    let text = String(
      decoding: try LayoutCodec.encode(SavedLayout(windows: [saved])), as: UTF8.self)

    XCTAssertTrue(text.contains("SYNTHETIC_TOKEN"), text)
    XCTAssertFalse(text.contains("secret-value"), "the layout holds an environment value")

    let restored = try fixture.windows.open(
      restoring: RestoredWindow(saved: try LayoutCodec.decode(Data(text.utf8)).windows[0]))
    fixture.prepare(restored)

    let pane = restored.focusedPane
    let authority = fixture.windows.launchAuthority

    XCTAssertEqual(restored.execStatus(of: pane)?.action, "Run")
    XCTAssertTrue(authority.requests.isEmpty)
    XCTAssertNil(restored.execAttachments[pane]?.channel)

    fixture.values = nil
    restored.runExecDriver(pane)

    await waitUntil("the values sheet is answered") { fixture.askedKeys.count == 1 }
    await waitUntil("the cancelled run settles") {
      if case .idle? = restored.execAttachments[pane]?.state { return true }
      return false
    }

    XCTAssertEqual(fixture.askedKeys, [["SYNTHETIC_TOKEN"]])
    XCTAssertTrue(authority.requests.isEmpty, "a run with no values asked for approval")

    fixture.values = ["SYNTHETIC_TOKEN": "fresh"]
    restored.runExecDriver(pane)

    await waitUntil("the run asks for approval") { authority.requests.count == 1 }

    XCTAssertEqual(authority.requests.first?.launch.environment, ["SYNTHETIC_TOKEN": "fresh"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "it ran before approval")

    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowOnce)

    await waitUntil("the driver writes its environment") {
      (try? String(contentsOf: output, encoding: .utf8))?.contains("SYNTHETIC_TOKEN=fresh") == true
    }
  }

  /// Catches a pane close that leaves the driver's authority in place, or that waits for the child.
  func testClosingThePaneEndsAuthorityAtOnceAndTheChildAfter() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()

    controller.openPane(.terminalShell, axis: .row)
    let pane = controller.focusedPane

    try controller.declareExecDriver(fixture.declaration("ignore-term"), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver connects") { isRunning(controller, pane) }

    let channel = try XCTUnwrap(controller.execAttachments[pane]?.channel)
    let pid = try XCTUnwrap(channel.pid)
    let started = Date()

    controller.closePane(pane, appletEnded: false)

    XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the close waited for the child")
    XCTAssertFalse(channel.isConnected)
    XCTAssertNil(controller.execAttachments[pane])

    await waitUntil("the child is gone") { kill(pid, 0) != 0 }
  }

  // MARK: Pending replies

  /// A remote-controlled notes pane beside the first one, and the notes fixture in it.
  private func notesPane(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController
  ) -> (pane: NodeID, notes: NotesFixture) {
    fixture.nextIsNotes = true
    controller.openPane(.terminalShell, axis: .row)
    fixture.nextIsNotes = false

    let pane = controller.focusedPane

    controller.enableRemoteControl(pane)

    return (pane, controller.paneArea.applet(for: pane) as! NotesFixture)
  }

  private func startWait(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController, _ pane: NodeID,
    stillAllowed: @escaping @MainActor () throws -> Void = {}
  ) -> Task<ScriptValue, Error> {
    Task { @MainActor in
      try await fixture.command(
        controller, pane, "wait-for-notes", #"{"contains":"go"}"#, type: NotesFixture.typeID,
        stillAllowed: stillAllowed)
    }
  }

  /// What a script call settled with, or nil when it had not settled within 3 seconds. A nil has
  /// already failed the test, so a regression fails in seconds and never hangs.
  private func settled(
    _ what: String, file: StaticString = #filePath, line: UInt = #line,
    _ task: Task<ScriptValue, Error>
  ) async -> Result<ScriptValue, Error>? {
    let box = SettledBox()

    Task { @MainActor in box.result = await task.result }

    await waitUntil("\(what) settles", timeout: 3, file: file, line: line) { box.result != nil }

    return box.result
  }

  private func settled(
    _ what: String, file: StaticString = #filePath, line: UInt = #line,
    _ call: @escaping @MainActor () async throws -> ScriptValue
  ) async -> Result<ScriptValue, Error>? {
    await settled(what, file: file, line: line, Task { @MainActor in try await call() })
  }

  /// Catches a waiting command that holds the main thread or the queue, or whose answer never
  /// reaches the script. The script's wait stays pending while another command runs, then the
  /// answer arrives.
  func testAScriptCommandCanWaitWhileOthersRun() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, notes) = notesPane(fixture, controller)
    let waiting = startWait(fixture, controller, pane)

    await waitUntil("the wait is pending") { controller.dispatcher.pendingCount == 1 }

    let other = await settled("an unrelated command") {
      try await fixture.command(
        controller, pane, "set-notes", #"{"text":"almost"}"#, type: NotesFixture.typeID)
    }

    XCTAssertEqual(try other?.get(), .record(["length": .integer(6)]))
    XCTAssertEqual(controller.dispatcher.pendingCount, 1)

    let ending = await settled("the ending command") {
      try await fixture.command(
        controller, pane, "set-notes", #"{"text":"go"}"#, type: NotesFixture.typeID)
    }

    XCTAssertNotNil(ending)

    let answer = await settled("the wait", waiting)

    XCTAssertEqual(try answer?.get(), .record(["length": .integer(2)]))
    XCTAssertEqual(controller.dispatcher.pendingCount, 0)
    XCTAssertEqual(notes.waitingCount, 0)
  }

  /// Catches a waiting script that outlives what authorized it. A disconnect, the end of the
  /// script's connection, a revoked grant, and the pane's close each fail the wait at once. The
  /// applet is told to drop it, and nothing ran.
  func testEachWayAScriptLosesAuthorityFailsItsWaitAtOnce() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()

    func failure(of task: Task<ScriptValue, Error>) async -> ScriptCallError? {
      guard case .failure(let error)? = await settled("the wait", task) else { return nil }

      return error as? ScriptCallError
    }

    var (pane, notes) = notesPane(fixture, controller)
    var waiting = startWait(fixture, controller, pane)

    await waitUntil("the first wait is pending") { controller.dispatcher.pendingCount == 1 }
    controller.disconnect(pane)

    let disconnected = await failure(of: waiting)

    XCTAssertEqual(disconnected?.kind, .refused)
    XCTAssertEqual(controller.dispatcher.pendingCount, 0)
    XCTAssertEqual(notes.cancelledWaits, 1)
    XCTAssertEqual(notes.waitingCount, 0)

    controller.enableRemoteControl(pane)

    let ended = Flag(true)

    waiting = startWait(fixture, controller, pane) {
      guard ended.on else { throw ScriptCallError.refused("the script ended") }
    }

    await waitUntil("the second wait is pending") { controller.dispatcher.pendingCount == 1 }
    ended.on = false
    controller.controllerEnded(1)

    let finished = await failure(of: waiting)

    XCTAssertEqual(finished?.text, "the script ended")
    XCTAssertEqual(controller.dispatcher.pendingCount, 0)
    XCTAssertEqual(notes.cancelledWaits, 2)

    waiting = startWait(fixture, controller, pane)

    await waitUntil("the third wait is pending") { controller.dispatcher.pendingCount == 1 }
    controller.closePane(pane, appletEnded: false)

    let closed = await failure(of: waiting)

    XCTAssertEqual(closed?.kind, .notFound)
    XCTAssertEqual(controller.dispatcher.pendingCount, 0)
    XCTAssertEqual(notes.cancelledWaits, 3)

    (pane, notes) = notesPane(fixture, controller)
    waiting = startWait(fixture, controller, pane)

    await waitUntil("the fourth wait is pending") { controller.dispatcher.pendingCount == 1 }
    controller.window?.close()

    let windowClosed = await failure(of: waiting)

    XCTAssertEqual(windowClosed?.kind, .notFound)
    XCTAssertEqual(controller.dispatcher.pendingCount, 0)
  }

  /// Catches a control change that leaves a script's wait pending. Starting a driver on the pane
  /// issues a new control generation, so the script's grant over the pane is stale. The wait
  /// fails at once, with the applet told to drop it, and does not hold its slot until the applet
  /// settles it.
  func testStartingADriverFailsAScriptsWaitOnThePane() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, notes) = notesPane(fixture, controller)
    let waiting = startWait(fixture, controller, pane)

    await waitUntil("the wait is pending") { controller.dispatcher.pendingCount == 1 }

    try controller.declareExecDriver(fixture.declaration("silent"), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the wait fails", timeout: 3) { controller.dispatcher.pendingCount == 0 }

    guard controller.dispatcher.pendingCount == 0 else {
      return XCTFail("a wait survived a driver starting on its pane")
    }

    XCTAssertEqual(notes.cancelledWaits, 1)

    guard case .failure(let error)? = await settled("the wait", waiting) else {
      return XCTFail("a wait survived a driver starting on its pane")
    }

    XCTAssertEqual((error as? ScriptCallError)?.kind, .refused)
  }

  /// Catches a pending reply that reaches a script whose grant ended while the applet held it. The
  /// grant ends with no revalidation, and the applet then completes the wait. The second check
  /// refuses it, so the script sees the revocation and not the answer.
  func testACompletedWaitChecksTheScriptsGrantAgain() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, _) = notesPane(fixture, controller)
    let allowed = Flag(true)
    let waiting = startWait(fixture, controller, pane) {
      guard allowed.on else { throw ScriptCallError.refused("revoked") }
    }

    await waitUntil("the wait is pending") { controller.dispatcher.pendingCount == 1 }
    allowed.on = false

    let ending = await settled("the ending command") {
      try await fixture.command(
        controller, pane, "set-notes", #"{"text":"go"}"#, type: NotesFixture.typeID)
    }

    XCTAssertNotNil(ending)

    guard case .failure(let error)? = await settled("the wait", waiting) else {
      return XCTFail("a wait answered a script whose grant had ended")
    }

    XCTAssertEqual((error as? ScriptCallError)?.text, "revoked")
  }

  /// Catches a command that ran but whose reply a script cannot hold, reported as an ordinary
  /// failure. The script must learn that the command took effect.
  func testAReplyAScriptCannotHoldSaysTheCommandRan() {
    var deep = JSONValue.string("bottom")

    for _ in 0...ScriptValue.maxDepth { deep = .array([deep]) }

    let wide = JSONValue.object(
      Dictionary(uniqueKeysWithValues: (0...ScriptValue.maxRecordFields).map { ("k\($0)", .null) }))

    for reply in [deep, wide] {
      XCTAssertThrowsError(try WindowScripting.scriptValue(reply, depth: 0)) { error in
        XCTAssertEqual((error as? ScriptCallError)?.kind, .replyLost)
        XCTAssertTrue(
          (error as? ScriptCallError)?.text.contains("the command ran") == true, "\(error)")
      }
    }
  }

  /// Catches a quit that leaves a driver running. The driver ignores SIGTERM and its group is its
  /// own, so only a SIGKILL that goes out before the app exits ends it. The kill grace is far
  /// longer than the test, so the delayed SIGKILL of an ordinary close cannot be what ends it.
  func testQuitEndsEveryDriverBeforeTheAppExits() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    controller.execKillGrace = .seconds(60)
    try controller.declareExecDriver(fixture.declaration("ignore-term"), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver connects") { isRunning(controller, pane) }

    let pid = try XCTUnwrap(controller.execAttachments[pane]?.channel?.pid)
    let driver = try XCTUnwrap(ProcessRecord(pid: pid), "the connected driver has no start time")
    let started = Date()

    fixture.windows.endDriversForQuit()

    XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the quit waited without a bound")

    await waitUntil("the driver is gone", timeout: 3) { kill(pid, 0) != 0 }

    ProcessSender.signal(SIGKILL, driver, expecting: .token)
  }

  /// Catches a stalled driver that holds the main thread: while it neither reads nor writes, and
  /// the applet floods it with events, main-thread work still runs within a turn.
  ///
  /// The clicks themselves cost the main thread time on any machine, and a CI runner is several
  /// times slower. So the flood is measured against the same clicks with no driver running, not
  /// against a fixed time.
  func testAStalledDriverNeverHoldsTheMainThread() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let clicks = 20_000

    try controller.declareExecDriver(fixture.declaration("stall"), for: pane)

    let idle = try XCTUnwrap(fixture.slides(controller, pane))
    let idleStarted = Date()

    for _ in 0..<clicks { idle.button.performClick(nil) }

    let idleCost = Date().timeIntervalSince(idleStarted)

    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver connects") { isRunning(controller, pane) }

    let applet = try XCTUnwrap(fixture.slides(controller, pane))
    let started = Date()

    for _ in 0..<clicks { applet.button.performClick(nil) }

    let floodCost = Date().timeIntervalSince(started)

    XCTAssertLessThan(
      floodCost, 2 * idleCost, "the flood cost \(floodCost) s against \(idleCost) s with no driver")

    let turned = Flag(false)
    DispatchQueue.main.async { MainActor.assumeIsolated { turned.on = true } }

    await waitUntil("the main thread takes another turn", timeout: 2) { turned.on }
  }
}

@MainActor
private final class SettledBox {
  var result: Result<ScriptValue, Error>?
}

@MainActor
private final class Flag {
  var on: Bool

  init(_ on: Bool) { self.on = on }
}

/// The dispatcher's turns, held so a test runs them when it chooses.
@MainActor
private final class Turns {
  var pending: [@MainActor () -> Void] = []

  func run() {
    let bodies = pending
    pending = []
    for body in bodies { body() }
  }
}
