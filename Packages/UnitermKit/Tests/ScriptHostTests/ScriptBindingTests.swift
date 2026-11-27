import Darwin
import FileRouting
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// Tests for connection binding and ancestry validation. Covers bound descendant calls, unbound
/// refusal, dead peer detection, PID reuse, and session root lifecycle.
@MainActor
final class ScriptBindingTests: XCTestCase {
  private var directory: URL!
  private var center: StatusCenter!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    center = StatusCenter()
    windows = FakeWindowAPI()

    let center = center!

    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows)
    host.start()

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  /// A script descendant of a recorded session root has its calls answered.
  func testABoundDescendantCallSucceeds() async throws {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("list-windows"))

    XCTAssertEqual(run.status, 0, run.standardError)
    XCTAssertFalse(
      run.standardError.contains("not running in a uniterm pane"),
      "bound descendant was refused")
  }

  /// A script not descendant of any recorded session root is refused for all calls except
  /// api-version.
  func testAnUnboundNonDescendantIsRefused() async throws {
    TestSessionRoot.remove(from: host)

    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("list-windows"))

    XCTAssertEqual(run.status, 1)
    XCTAssertTrue(
      run.standardError.contains("not running in a uniterm pane"), run.standardError)
  }

  /// Catches a binding that outlives its peer. The root is the live test process, so only the
  /// peer's own exit can fail the check. The peer is a child that has exited and been collected.
  func testABindingFailsOnceItsPeerHasExited() throws {
    let child = Process()

    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()

    let started = try XCTUnwrap(ProcessInspection.startTime(of: child.processIdentifier))

    child.waitUntilExit()

    let (app, peerEnd) = try FramedSocket.pair()
    let peer = ScriptPeer(
      uid: getuid(), pid: child.processIdentifier,
      token: ScriptPeer.liveToken(descriptor: app.rawDescriptor))
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: started, socket: app, onOverflow: { _ in })

    defer { withExtendedLifetime(peerEnd) {} }

    connection.bind(to: TestSessionRoot.identity, generation: 1)

    XCTAssertFalse(connection.validateBinding(registry: host.sessionRoots), "dead peer passed")
  }

  /// A PID that is reused for a different process is detected by start time mismatch.
  func testPIDReuseIsDetected() throws {
    let oldStartTime = 1000
    let currentPid = getpid()
    let testRoot = ProcessIdentity(pid: currentPid, started: oldStartTime)

    host.recordSessionRoot(testRoot, sessionGeneration: 1, window: 1, pane: NodeID(rawValue: 1))

    let currentStartTime = ProcessInspection.startTime(of: currentPid) ?? 0
    let (app, peerEnd) = try FramedSocket.pair()
    let peer = ScriptPeer(
      uid: getuid(), pid: currentPid, token: ScriptPeer.liveToken(descriptor: app.rawDescriptor))
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: currentStartTime, socket: app,
      onOverflow: { _ in })

    defer { withExtendedLifetime(peerEnd) {} }

    connection.bind(to: testRoot, generation: 1)

    let valid = connection.validateBinding(registry: host.sessionRoots)

    XCTAssertFalse(
      valid,
      "PID reuse not detected (start times: recorded=\(oldStartTime), current=\(currentStartTime))")
  }

  /// A session root that is removed from the registry causes bound connections to fail validation.
  func testClosedSourceTabRemovesSessionRoot() throws {
    let testRoot = TestSessionRoot.identity

    let (app, peerEnd) = try FramedSocket.pair()
    let peer = ScriptPeer(
      uid: getuid(), pid: getpid(), token: ScriptPeer.liveToken(descriptor: app.rawDescriptor))
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: testRoot.started, socket: app,
      onOverflow: { _ in })

    defer { withExtendedLifetime(peerEnd) {} }

    connection.bind(to: testRoot, generation: 1)

    XCTAssertTrue(
      connection.validateBinding(registry: host.sessionRoots), "binding invalid before removal")

    TestSessionRoot.remove(from: host)

    XCTAssertFalse(
      connection.validateBinding(registry: host.sessionRoots), "binding still valid after removal")
  }

  /// A session that is replaced (same PID but different generation) invalidates old connections.
  func testHelperReplacementInvalidatesOldGeneration() throws {
    let testRoot = TestSessionRoot.identity

    let (app, peerEnd) = try FramedSocket.pair()
    let peer = ScriptPeer(
      uid: getuid(), pid: getpid(), token: ScriptPeer.liveToken(descriptor: app.rawDescriptor))
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: testRoot.started, socket: app,
      onOverflow: { _ in })

    defer { withExtendedLifetime(peerEnd) {} }

    connection.bind(to: testRoot, generation: 1)

    XCTAssertTrue(
      connection.validateBinding(registry: host.sessionRoots), "binding invalid before replacement")

    TestSessionRoot.remove(from: host)
    TestSessionRoot.record(in: host, generation: 2)

    XCTAssertFalse(
      connection.validateBinding(registry: host.sessionRoots),
      "old generation still valid after replacement")
  }

  /// Catches a binding that survives a new process instance with the same PID and start second,
  /// which a start time cannot tell apart. The admitted token carries another process ID version,
  /// as a reused PID or a later exec gives.
  func testAnotherProcessIDVersionFailsTheBinding() throws {
    let (app, peerEnd) = try FramedSocket.pair()

    defer { withExtendedLifetime(peerEnd) {} }

    let live = try XCTUnwrap(ScriptPeer.liveToken(descriptor: app.rawDescriptor))
    var bytes = live.bytes

    bytes.withUnsafeMutableBytes {
      $0.storeBytes(of: UInt32(bitPattern: live.pidVersion &+ 1), toByteOffset: 28, as: UInt32.self)
    }

    let peer = ScriptPeer(uid: getuid(), pid: getpid(), token: AuditToken(data: bytes))
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: TestSessionRoot.identity.started, socket: app,
      onOverflow: { _ in })

    connection.bind(to: TestSessionRoot.identity, generation: 1)

    XCTAssertFalse(connection.peerGenerationHolds)
    XCTAssertFalse(
      connection.validateBinding(registry: host.sessionRoots), "another instance passed")
  }

  /// Catches a binding that survives a successful exec, and a call read before the exec that runs
  /// after it. The relay connects from the test's own session, so its first call is answered. It
  /// then starts perl again in the same process with the socket open. The kernel gives it a new
  /// process ID version. The host ends the connection's authority without waiting for a call, and
  /// a call dispatched after the exec is refused and reaches the window layer not at all.
  func testASuccessfulExecEndsTheBindingAndItsQueuedCalls() async throws {
    let relay = try SocketRelay(path: host.instanceAddress)

    defer { relay.stop() }

    let pid = try await relay.connected()

    try await relay.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await relay.read()
    try await relay.send(ScriptHelperMessage.begin(name: "relay").frame())
    try await relay.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    guard case .reply(1, .ok) = try await relay.read() else {
      return XCTFail("the bound relay's first call was not answered")
    }

    let pane = NodeID(rawValue: 1)
    let id = try XCTUnwrap(host.controllers(actingFrom: 1, pane: pane).first)
    let connection = try XCTUnwrap(host.listener.findConnection(id))
    var ended: [UInt64] = []

    host.onControllerEnded = { ended.append($0) }

    XCTAssertTrue(connection.peerGenerationHolds)
    let execed = try await relay.exec()

    XCTAssertEqual(execed, pid)
    XCTAssertFalse(connection.peerGenerationHolds, "the exec kept the process ID version")

    let answered = windows.calls.count

    expect(
      await waitUntil { ended.contains(id) }, "the exec did not end the connection's authority")
    XCTAssertTrue(host.controllers(actingFrom: 1, pane: pane).isEmpty)

    host.handle(.request(connection, id: 2, call: .listWindows))

    guard case .reply(2, .failure(.refused, let text)) = try await relay.read() else {
      return XCTFail("a call read before the exec was not refused")
    }

    XCTAssertTrue(text.contains("started another executable"), text)
    XCTAssertEqual(windows.calls.count, answered, "a call ran after the exec")
  }

  /// Catches a revoked connection, bound by ancestry and still open, that the pane's badge keeps
  /// listing. A grant ends with the revoke, but an ancestry binding lasts until the connection
  /// closes, so only the revoked set can leave it out. What this cannot prove is the badge's own
  /// redraw, which reads this same list.
  func testARevokedAncestryBoundConnectionIsNotListedForItsPane() async throws {
    let relay = try SocketRelay(path: host.instanceAddress)

    defer { relay.stop() }

    _ = try await relay.connected()

    try await relay.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await relay.read()
    try await relay.send(ScriptHelperMessage.begin(name: "relay").frame())
    try await relay.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    guard case .reply(1, .ok) = try await relay.read() else {
      return XCTFail("the bound relay's first call was not answered")
    }

    let pane = NodeID(rawValue: 1)
    let id = try XCTUnwrap(host.controllers(actingFrom: 1, pane: pane).first)

    host.revokeControllers([id])

    XCTAssertTrue(host.controllers(actingFrom: 1, pane: pane).isEmpty)
  }

  /// Catches a socket handed to a forked child while the process that connected still runs. The
  /// child's call, written on the inherited socket, is refused, and the connection's authority
  /// ends.
  func testAForkedChildWritingOnTheInheritedSocketIsRefused() async throws {
    let relay = try SocketRelay(path: host.instanceAddress)

    defer { relay.stop() }

    let parent = try await relay.connected()

    try await relay.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await relay.read()
    try await relay.send(ScriptHelperMessage.begin(name: "relay").frame())

    let answered = windows.calls.count
    let child = try await relay.forkSend(
      ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    // The relay's forked child. Its parent exited and nothing reaps it, so no handle holds its pid.
    defer { kill(child, SIGKILL) }

    XCTAssertNotEqual(child, parent)

    guard case .reply(1, .failure(.refused, let text)) = try await relay.read() else {
      return XCTFail("the child's call was not refused")
    }

    XCTAssertTrue(text.contains("handed the connection on"), text)
    XCTAssertEqual(windows.calls.count, answered, "the child's call ran")
  }
}
