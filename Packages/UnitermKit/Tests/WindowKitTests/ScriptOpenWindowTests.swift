import AppKit
import AppletKit
import FileRouting
import PaneModel
import ScriptHost
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import WindowKit

/// A program's open through the real host, listener, coordinator, router, and windows, with fixture
/// applets. They prove that no path is looked at before the user allows it, that an allowed open
/// lands beside the caller's pane and takes focus, and that one approval covers a batch.
/// They cannot prove what the real applets do with the file, or the key window of a live display.
@MainActor
final class ScriptOpenWindowTests: XCTestCase {
  private var fixture: RoutingFixture!
  private var spy: PathSpy!
  private var host: ScriptHost!
  private var directory: URL!
  private var anchor: RouteAnchor!

  override func setUp() async throws {
    spy = PathSpy()
    fixture = try RoutingFixture(pathKind: spy.reader)
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)

    let center = StatusCenter()

    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) },
      permissionRequests: fixture.windows.permissionRequests)

    let coordinator = LaunchOpenCoordinator(
      windows: fixture.windows, opener: fixture.opener, openFallbackWindow: {})

    coordinator.launchFinished()
    host.fileOpener = ScriptFileOpener(windows: fixture.windows, coordinator: coordinator)
    host.start()

    anchor = try fixture.anchoredWindow()

    TestSessionRoot.record(
      in: host, window: anchor.controller.scriptWindowID, pane: anchor.pane)
  }

  override func tearDown() async throws {
    host.stop()
    fixture.cleanUp()
    try? FileManager.default.removeItem(at: directory)
  }

  private func connect(_ paths: [String]) async throws -> FramedSocket {
    let socket = try UnixSocket.connect(path: host.instanceAddress)

    try socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await read(socket)
    try socket.send(ScriptHelperMessage.openBegin(OpenBegin(paths: paths)).frame())

    return socket
  }

  private func read(_ socket: FramedSocket) async throws -> ScriptAppMessage {
    try await Task.detached {
      let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
    }.value
  }

  private func waitForRow() async throws -> PermissionRequests.Row {
    _ = await waitUntil { !fixture.windows.permissionRequests.rows.isEmpty }

    return try XCTUnwrap(fixture.windows.permissionRequests.rows.first)
  }

  private func settle() async {
    for _ in 0..<50 { await Task.yield() }
  }

  // MARK: Nothing before the answer

  /// Catches a path that is looked at before the user answers, or at all when the answer is no. The
  /// router's look at a path is recorded, and a pending request, a denied one, and one whose command
  /// exited each leave it empty, with no pane made.
  func testNoPathIsLookedAtBeforeTheUserAllowsIt() async throws {
    let file = try fixture.textFile("a.txt")
    let panes = anchor.controller.paneIDs.count

    let pending = try await connect([file.path])
    _ = try await read(pending)
    let row = try await waitForRow()

    await settle()
    XCTAssertEqual(spy.looked, [], "a pending request looked at a path")

    fixture.windows.permissionRequests.decide(row.id, .deny)
    _ = try await read(pending)

    let second = try await connect([file.path])

    _ = try await read(second)

    // The second command is refused without a row, since the denial lasts for the session.
    await settle()
    XCTAssertEqual(spy.looked, [], "a denied request looked at a path")

    fixture.windows.permissionRequests.askAgain(
      try XCTUnwrap(fixture.windows.permissionRequests.denials.first).id)

    let third = try await connect([file.path])

    _ = try await read(third)
    _ = try await waitForRow()
    third.shutdownAndClose()

    _ = await waitUntil { fixture.windows.permissionRequests.rows.isEmpty }
    await settle()

    XCTAssertEqual(spy.looked, [], "a withdrawn request looked at a path")
    XCTAssertEqual(anchor.controller.paneIDs.count, panes)
    XCTAssertTrue(fixture.box.entries.isEmpty)
  }

  // MARK: After the answer

  /// Catches a program's open that leaves the keyboard behind or lands in the wrong place. The
  /// approved open splits the caller's own pane, starts in the file's folder, and takes the focus,
  /// as the user's own open does. The router looks at the path only now.
  ///
  /// This is the placement contract through the `uniterm open` authority: a command's own terminal
  /// session names the anchor. The Launch Services test of the same contract isolates the sender
  /// authority, where the focused pane of the key window is the anchor.
  func testAnAllowedOpenSplitsBesideTheCallersPaneAndTakesFocus() async throws {
    let file = try fixture.textFile("a.txt")
    let focused = anchor.controller.focusedPane

    let peer = try await connect([file.path])

    _ = try await read(peer)

    let row = try await waitForRow()

    fixture.windows.permissionRequests.decide(row.id, .allowOnce)

    let reply = try await read(peer)

    XCTAssertEqual(reply, .openDone)

    _ = await waitUntil { anchor.controller.paneIDs.count == 2 }

    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    let created = try XCTUnwrap(anchor.controller.paneIDs.first { $0 != focused })
    XCTAssertEqual(anchor.controller.focusedPane, created, "the new pane did not take the focus")
    XCTAssertEqual(spy.looked, [file.path])
    XCTAssertEqual(fixture.box.entries.map(\.start), [fixture.directory.path])
  }

  /// Catches a batch that is asked about twice. The approval named all eleven paths, which is above
  /// the confirmation threshold, and the router's own question is skipped. A missing file among
  /// them posts one summary message and does not stop the rest.
  func testOneApprovalCoversTheBatchQuestionAndFailuresMakeOneMessage() async throws {
    var paths = try (0..<RoutedOpener.confirmationThreshold).map {
      try fixture.textFile("f\($0).txt").path
    }

    paths.append(fixture.directory.appendingPathComponent("missing.txt").path)

    let peer = try await connect(paths)

    _ = try await read(peer)

    let row = try await waitForRow()

    XCTAssertEqual(row.title, "Open 11 files or folders")

    for path in paths { XCTAssertTrue(row.detail.contains(path)) }

    fixture.windows.permissionRequests.decide(row.id, .allowOnce)

    let reply = try await read(peer)

    XCTAssertEqual(reply, .openDone)

    _ = await waitUntil { fixture.box.entries.count == RoutedOpener.confirmationThreshold }

    XCTAssertTrue(fixture.box.asked.isEmpty, "the batch was asked about a second time")
    XCTAssertEqual(fixture.box.entries.count, RoutedOpener.confirmationThreshold)

    let texts = fixture.windows.controllers.flatMap { $0.statusCenter.history.map(\.text) }

    XCTAssertEqual(texts.filter { $0.contains("missing.txt") }.count, 1, "\(texts)")
  }

  /// Catches an open from a command in no session that finds no pane to sit beside. It anchors to
  /// the focused pane of the most recently key window, without bringing it forward.
  func testACallerInNoSessionAnchorsToTheMostRecentWindow() async throws {
    TestSessionRoot.remove(
      from: host, window: anchor.controller.scriptWindowID, pane: anchor.pane)

    let file = try fixture.textFile("b.txt")
    let peer = try await connect([file.path])

    _ = try await read(peer)

    let row = try await waitForRow()

    XCTAssertTrue(row.onceOnly)

    fixture.windows.permissionRequests.decide(row.id, .allowOnce)

    let reply = try await read(peer)

    XCTAssertEqual(reply, .openDone)

    _ = await waitUntil { anchor.controller.paneIDs.count == 2 }

    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
  }
}
