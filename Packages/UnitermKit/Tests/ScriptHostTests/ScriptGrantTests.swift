import Darwin
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// A user's grant of one pane to a connection that runs in no uniterm pane, from the request to
/// each way the grant ends. Raw peers from the test process play the outside program. No session
/// root covers the test process, so each one starts unbound. A `sleep` process stands in for the
/// session of the pane that is granted, window 7's pane 1.
///
/// The host's replies arrive on the main actor, so every read runs off it.
///
/// These prove the host's bookkeeping and what the next call gets. They cannot prove the panel or
/// the menu, which `PendingRequestsUITests` drives in the real app.
@MainActor
final class ScriptGrantTests: XCTestCase {
  private var directory: URL!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!
  private var source: HelperHandle!
  private var sourceRoot: ProcessIdentity!
  private var peers: [FramedSocket] = []

  private let window: UInt64 = 7
  private let pane = NodeID(rawValue: 1)

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()

    let center = StatusCenter()

    windows = FakeWindowAPI()
    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows)
    host.start()

    source = try HelperHandle.spawn(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["120"], environment: [:],
      standardOutput: .null, standardError: .null,
      deadlines: [HelperDeadline(after: .seconds(150), signal: SIGKILL)])

    let started = try XCTUnwrap(ProcessInspection.startTime(of: source.pid))

    sourceRoot = ProcessIdentity(pid: source.pid, started: started)
    host.recordSessionRoot(sourceRoot, sessionGeneration: 1, window: window, pane: pane)
  }

  override func tearDown() async throws {
    for peer in peers { peer.shutdownAndClose() }

    peers = []
    host.stop()

    source.signal(SIGTERM)

    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: Helpers

  /// Connects a raw peer that has said hello and named itself.
  private func connect(name: String = "outside") async throws -> FramedSocket {
    let peer = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    peers.append(peer)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await Self.read(peer)
    try peer.send(ScriptHelperMessage.begin(name: name).frame())

    return peer
  }

  private static func read(_ peer: FramedSocket) async throws -> ScriptAppMessage {
    try await Task.detached {
      let frame = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
    }.value
  }

  private func call(_ peer: FramedSocket, id: UInt32, _ call: ScriptCall = .listWindows)
    async throws -> ScriptResult
  {
    try peer.send(ScriptHelperMessage.request(id: id, call: call).frame())

    let message = try await Self.read(peer)

    guard case .reply(id, let result) = message else {
      XCTFail("expected the reply to call \(id), got \(message)")

      return .failure(.failed, "no reply")
    }

    return result
  }

  private func assertRefused(
    _ result: ScriptResult, saying fragment: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .failure(.refused, let text) = result else {
      return XCTFail("expected a refusal, got \(result)", file: file, line: line)
    }

    XCTAssertTrue(text.contains(fragment), text, file: file, line: line)
  }

  private func assertAnswered(
    _ result: ScriptResult, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .ok = result else {
      return XCTFail("expected an answer, got \(result)", file: file, line: line)
    }
  }

  /// A peer whose first call was refused and whose request the user granted.
  private func grantedPeer() async throws -> (peer: FramedSocket, connection: UInt64) {
    let peer = try await connect()

    assertRefused(try await call(peer, id: 1), saying: "not running in a uniterm pane")

    let request = try XCTUnwrap(host.allPendingRequests().first)

    XCTAssertEqual(host.grantAccess(connection: request.id, window: window, pane: pane), .granted)
    assertAnswered(try await call(peer, id: 2))

    return (peer, request.id)
  }

  // MARK: Requests and grants

  /// Catches an unbound call that runs, one that is refused without asking the user, and a grant
  /// that does not let the next call through. The request names the calling process, and the
  /// grant names the chosen pane and that pane's own session.
  func testAnUnboundCallAsksTheUserAndTheNextCallAfterAGrantIsAnswered() async throws {
    let peer = try await connect(name: "lister")

    assertRefused(try await call(peer, id: 1), saying: "Pending Requests")

    let requests = host.allPendingRequests()

    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.pid, getpid())
    XCTAssertEqual(requests.first?.name, "lister")
    XCTAssertNotNil(requests.first?.executablePath)

    let request = try XCTUnwrap(requests.first)

    XCTAssertEqual(host.grantAccess(connection: request.id, window: window, pane: pane), .granted)
    XCTAssertEqual(host.allPendingRequests(), [])

    let grants = host.allGrants()

    XCTAssertEqual(grants.count, 1)
    XCTAssertEqual(grants.first?.connection, request.id)
    XCTAssertEqual(grants.first?.window, window)
    XCTAssertEqual(grants.first?.pane, pane)
    XCTAssertEqual(grants.first?.root, sourceRoot)

    assertAnswered(try await call(peer, id: 2))
  }

  /// Catches a grant to a pane whose session already ended, which would bind the program to a
  /// session that no longer exists, or to whatever reused its process ID. The request stays, so
  /// the user can pick another pane.
  func testAGrantFailsWhenThePanesSessionWasRemovedFirst() async throws {
    let peer = try await connect()

    assertRefused(try await call(peer, id: 1), saying: "not running in a uniterm pane")

    let request = try XCTUnwrap(host.allPendingRequests().first)

    host.removeSessionRoot(sourceRoot, window: window, pane: pane)

    guard case .failed = host.grantAccess(connection: request.id, window: window, pane: pane) else {
      return XCTFail("a grant to a pane with no session succeeded")
    }

    XCTAssertEqual(host.allGrants(), [])
    XCTAssertEqual(host.allPendingRequests().map(\.id), [request.id])
    assertRefused(try await call(peer, id: 2), saying: "not running in a uniterm pane")
  }

  /// Catches a grant that moves a granted program to another pane. A grant answers a request the
  /// user saw, so a connection with no request waiting cannot get one, and the first grant stays.
  func testAGrantNeedsARequestThatIsWaiting() async throws {
    let (peer, connection) = try await grantedPeer()
    let other = NodeID(rawValue: 2)

    TestSessionRoot.record(in: host, window: window, pane: other)

    guard case .failed = host.grantAccess(connection: connection, window: window, pane: other)
    else { return XCTFail("a connection with no request was granted") }

    XCTAssertEqual(host.allGrants().map(\.pane), [pane])
    assertAnswered(try await call(peer, id: 3))
  }

  // MARK: How a grant ends

  /// Catches a revoked grant that still answers, and a revoked connection that the panel asks
  /// about again at its next call.
  func testRevokingAGrantRefusesTheNextCallAndDoesNotAskAgain() async throws {
    let (peer, connection) = try await grantedPeer()

    host.revokeGrant(connection: connection)

    XCTAssertEqual(host.allGrants(), [])
    assertRefused(try await call(peer, id: 3), saying: "denied")
    XCTAssertEqual(host.allPendingRequests(), [])
  }

  /// Catches a call that reaches the window layer without the pane its connection acts for, or with
  /// another pane. The window layer checks every target against that pane.
  func testEachCallNamesThePaneItsConnectionActsFor() async throws {
    let (_, connection) = try await grantedPeer()

    XCTAssertEqual(
      windows.callers.last, ScriptCaller(connection: connection, window: window, pane: pane))
    XCTAssertEqual(host.controllers(actingFrom: window, pane: pane), [connection])
    XCTAssertEqual(host.controllers(actingFrom: window, pane: NodeID(rawValue: 2)), [])
    XCTAssertEqual(host.controllerName(connection), "outside (PID \(getpid()))")
  }

  /// Catches a revoked controller whose calls still run, one the panel asks about again, and a
  /// window layer that never hears the controller's authority ended, which would leave its groups
  /// owned.
  func testRevokingAControllerRefusesItsCallsAndEndsItsAuthority() async throws {
    let (peer, connection) = try await grantedPeer()
    var ended: [UInt64] = []

    host.onControllerEnded = { ended.append($0) }
    host.revokeControllers([connection])

    XCTAssertTrue(ended.contains(connection))
    XCTAssertEqual(host.allGrants(), [])
    assertRefused(try await call(peer, id: 3), saying: "revoked")
    XCTAssertEqual(host.allPendingRequests(), [])
    XCTAssertEqual(host.controllers(actingFrom: window, pane: pane), [])
  }

  /// Catches a connection that goes away while the window layer still counts it as the owner of
  /// its groups.
  func testAClosedConnectionEndsItsAuthority() async throws {
    let (peer, connection) = try await grantedPeer()
    var ended: [UInt64] = []

    host.onControllerEnded = { ended.append($0) }
    peer.shutdownAndClose()

    expect(await waitUntil { ended.contains(connection) }, "the close never ended the controller")
  }

  /// Catches a grant that outlives the session of the pane it names. The program may ask again,
  /// since its session is what ended and not the user's answer.
  func testTheSourceSessionClosingEndsTheGrant() async throws {
    let (peer, connection) = try await grantedPeer()

    host.removeSessionRoot(sourceRoot, window: window, pane: pane)

    XCTAssertEqual(host.allGrants(), [])
    assertRefused(try await call(peer, id: 3), saying: "not running in a uniterm pane")
    XCTAssertEqual(host.allPendingRequests().map(\.id), [connection])
  }

  /// Catches a grant that survives its source session's process exiting before any terminal
  /// reported the end. The binding is checked on each call, so the next one is refused.
  func testTheSourceSessionProcessExitingEndsTheGrant() async throws {
    let (peer, _) = try await grantedPeer()

    source.signal(SIGTERM)

    expect(await processIsGone(source.pid), "the source session never exited")
    assertRefused(try await call(peer, id: 3), saying: "has closed")
    XCTAssertEqual(host.allGrants(), [])
  }

  /// Catches a grant that survives its window closing. The window's panes no longer exist, so
  /// neither do their sessions.
  func testClosingTheSourceWindowEndsTheGrant() async throws {
    let (peer, _) = try await grantedPeer()

    host.windowClosed(window)

    XCTAssertEqual(host.allGrants(), [])
    XCTAssertNil(host.sessionRoot(window: window, pane: pane))
    assertRefused(try await call(peer, id: 3), saying: "not running in a uniterm pane")
  }

  /// Catches a grant that follows a program to its next connection. A disconnect ends the grant,
  /// and the reconnect is a new connection that starts unbound and asks again.
  func testADisconnectEndsTheGrantAndAReconnectStartsUngranted() async throws {
    let (peer, connection) = try await grantedPeer()

    peer.shutdownAndClose()

    expect(await waitUntil(timeout: .seconds(10)) { self.host.allGrants().isEmpty })

    let again = try await connect()

    assertRefused(try await call(again, id: 1), saying: "not running in a uniterm pane")

    let request = try XCTUnwrap(host.allPendingRequests().first)

    XCTAssertNotEqual(request.id, connection)
    XCTAssertEqual(host.allGrants(), [])
  }

  /// Catches a socket that keeps a grant after the process it was granted to has exited. The
  /// relay connects and is granted, then forks and exits. Its child holds the same socket and
  /// calls again, which is refused, and the dead process cannot ask the user either.
  func testAGrantedProgramThatExitsTakesTheGrantWithItThoughItsSocketLivesOn() async throws {
    let relay = try SocketRelay(path: host.instanceAddress)

    defer { relay.stop() }

    let parent = try await relay.connected()

    try await relay.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await relay.read()
    try await relay.send(ScriptHelperMessage.begin(name: "relay").frame())
    try await relay.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    guard case .reply(1, let refused) = try await relay.read() else {
      return XCTFail("the relay's first call had no reply")
    }

    assertRefused(refused, saying: "not running in a uniterm pane")

    let request = try XCTUnwrap(host.allPendingRequests().first)

    XCTAssertEqual(request.pid, parent)
    XCTAssertEqual(host.grantAccess(connection: request.id, window: window, pane: pane), .granted)

    try await relay.send(ScriptHelperMessage.request(id: 2, call: .listWindows).frame())

    guard case .reply(2, let answered) = try await relay.read() else {
      return XCTFail("the granted call had no reply")
    }

    assertAnswered(answered)

    let child = try await relay.orphan()

    XCTAssertNotEqual(child, parent)
    expect(await processIsGone(parent), "the relay's connecting process never exited")

    try await relay.send(ScriptHelperMessage.request(id: 3, call: .listWindows).frame())

    guard case .reply(3, let inherited) = try await relay.read() else {
      return XCTFail("the inherited socket's call had no reply")
    }

    assertRefused(inherited, saying: "has closed")
    XCTAssertEqual(host.allGrants(), [])

    try await relay.send(ScriptHelperMessage.request(id: 4, call: .listWindows).frame())
    _ = try await relay.read()

    XCTAssertEqual(host.allPendingRequests(), [], "a process that exited asked the user")
  }

  /// Catches a grant that ends while a call waits on its directory check, and a call that then
  /// acts anyway. Opening a pane or a tab waits off the main actor before it changes the layout.
  /// The grant is revoked, or its session ends, during that wait, so nothing opens.
  func testAGrantThatEndsDuringADirectoryCheckOpensNothing() async throws {
    let calls: [(String, ScriptCall)] = [
      (
        "open-pane",
        .openPane(
          kind: "terminal", beside: .pane(ScriptPaneReference(window: window, pane: pane.rawValue)),
          axis: nil, directory: "/synthetic", access: .disconnected)
      ),
      (
        "open-tab",
        .openTab(
          pane: .pane(ScriptPaneReference(window: window, pane: pane.rawValue)), directory: nil)
      ),
    ]

    for (label, held) in calls {
      for ends in ["revoke", "session", "controller"] {
        let (peer, connection) = try await grantedPeer()

        windows.holdsDirectoryCheck = true
        try peer.send(ScriptHelperMessage.request(id: 3, call: held).frame())

        expect(await waitUntil { self.windows.isWaitingInDirectoryCheck }, "\(label) never waited")

        switch ends {
        case "revoke": host.revokeGrant(connection: connection)
        case "controller": host.revokeControllers([connection])
        default: host.removeSessionRoot(sourceRoot, window: window, pane: pane)
        }

        windows.holdsDirectoryCheck = false
        windows.releaseWait()

        guard case .reply(3, let result) = try await Self.read(peer) else {
          return XCTFail("\(label) had no reply after \(ends)")
        }

        guard case .failure(.refused, _) = result else {
          return XCTFail("\(label) ran after \(ends): \(result)")
        }

        XCTAssertEqual(windows.opened, 0, "\(label) opened after \(ends)")

        peer.shutdownAndClose()
        expect(await waitUntil { self.host.allGrants().isEmpty })
        host.recordSessionRoot(sourceRoot, sessionGeneration: 1, window: window, pane: pane)
      }
    }
  }

  /// Catches a connection that keeps its pane after its process leaves the pane's session. The
  /// relay connects from under a stand-in session root and is bound by ancestry. Its parent then
  /// exits, so the process is moved to launchd and no longer descends from the root, which still
  /// runs. Its next call is refused and asks the user, as a daemon that lost its ancestry must.
  func testAProcessThatLosesItsAncestryLosesItsPane() async throws {
    let relay = try SocketRelay(path: host.instanceAddress, nested: true)

    defer { relay.stop() }

    let rootPID = try await relay.root()
    let peer = try await relay.connected()
    let root = ProcessIdentity(
      pid: rootPID, started: try XCTUnwrap(ProcessInspection.startTime(of: rootPID)))

    host.recordSessionRoot(root, sessionGeneration: 1, window: window, pane: NodeID(rawValue: 3))

    try await relay.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await relay.read()
    try await relay.send(ScriptHelperMessage.begin(name: "nested").frame())
    try await relay.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    guard case .reply(1, let bound) = try await relay.read() else {
      return XCTFail("the bound call had no reply")
    }

    assertAnswered(bound)

    try await relay.unparent()

    XCTAssertTrue(ProcessInspection.isRunning(pid: rootPID, started: root.started))

    try await relay.send(ScriptHelperMessage.request(id: 2, call: .listWindows).frame())

    guard case .reply(2, let unbound) = try await relay.read() else {
      return XCTFail("the call after the ancestry loss had no reply")
    }

    assertRefused(unbound, saying: "not running in a uniterm pane")
    XCTAssertEqual(host.allPendingRequests().map(\.pid), [peer])
  }

  // MARK: Bounds and answers

  /// Catches a flood of calls that grows the request list, or that lists one program more than
  /// once. Every connection the listener holds floods calls. Each gets one request, so the list
  /// stops at the listener's limit, and a connection past the limit is turned away.
  func testAFloodOfUnboundCallsKeepsOneRequestPerConnectionUpToTheListenersLimit() async throws {
    let limit = ScriptListener.maxConnections
    var flooding: [FramedSocket] = []

    for _ in 0..<limit {
      flooding.append(try await connect(name: "flood"))
    }

    for peer in flooding {
      for id in UInt32(1)...4 {
        try peer.send(ScriptHelperMessage.request(id: id, call: .listWindows).frame())
      }
    }

    for peer in flooding {
      for _ in 1...4 {
        _ = try await Self.read(peer)
      }
    }

    let requests = host.allPendingRequests()

    XCTAssertEqual(requests.count, limit)
    XCTAssertEqual(Set(requests.map(\.id)).count, limit)
    XCTAssertLessThanOrEqual(requests.count, ScriptHost.maxPendingRequests)

    let extra = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    peers.append(extra)

    do {
      try extra.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())

      let reply = try await Self.read(extra)

      XCTFail("a connection past the limit was admitted: \(reply)")
    } catch {}

    XCTAssertEqual(host.allPendingRequests().count, limit)
  }

  /// Catches a denial that the next call undoes by asking again. The denied connection stays
  /// refused and cannot be granted, and a new connection may still ask.
  func testADenialIsNotAskedAgainOnThatConnection() async throws {
    let peer = try await connect()

    assertRefused(try await call(peer, id: 1), saying: "not running in a uniterm pane")

    let request = try XCTUnwrap(host.allPendingRequests().first)

    host.denyRequest(connection: request.id)

    XCTAssertEqual(host.allPendingRequests(), [])
    assertRefused(try await call(peer, id: 2), saying: "denied")
    XCTAssertEqual(host.allPendingRequests(), [], "the denied connection asked again")

    guard case .failed = host.grantAccess(connection: request.id, window: window, pane: pane)
    else { return XCTFail("a denied connection was granted") }

    let other = try await connect()

    assertRefused(try await call(other, id: 1), saying: "not running in a uniterm pane")
    XCTAssertEqual(host.allPendingRequests().count, 1)
  }

  /// Catches the window's indicator missing a request, or staying on after the last one is
  /// answered.
  func testThePendingIndicatorFollowsTheRequests() async throws {
    var states: [Bool] = []

    host.onPendingRequestsActiveChanged = { states.append($0) }

    let peer = try await connect()

    assertRefused(try await call(peer, id: 1), saying: "not running in a uniterm pane")
    XCTAssertEqual(states.last, true)

    let request = try XCTUnwrap(host.allPendingRequests().first)

    host.denyRequest(connection: request.id)

    XCTAssertEqual(states.last, false)
  }
}

/// A perl process that holds a raw connection to the app and relays frames for the test. It can
/// fork and exit, leaving its child with the socket, which no Swift test can do without forking
/// the test process itself.
final class SocketRelay: @unchecked Sendable {
  private let process: HelperHandle
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var buffered = ""
  private var lines: [String] = []
  private var taken = 0

  /// With `nested`, the relay connects from a grandchild of the process it starts, and that first
  /// process can stand for a session root.
  init(path: String, nested: Bool = false) throws {
    process = try HelperHandle.spawn(
      executable: URL(fileURLWithPath: "/usr/bin/perl"),
      arguments: [
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/socket-relay.pl").path, path,
      ] + (nested ? ["nested"] : []),
      environment: ProcessInfo.processInfo.environment,
      standardInput: .file(input.fileHandleForReading),
      standardOutput: .file(output.fileHandleForWriting), standardError: .null,
      deadlines: [HelperDeadline(after: .seconds(150), signal: SIGKILL)])

    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData

      guard !data.isEmpty else {
        handle.readabilityHandler = nil

        return
      }

      self?.take(data)
    }
  }

  /// Ends the relay and any child it left. Closing its input ends the read loop of either one.
  func stop() {
    try? input.fileHandleForWriting.close()

    process.signal(SIGTERM)
  }

  private func take(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }

    buffered += String(decoding: data, as: UTF8.self)

    while let newline = buffered.firstIndex(of: "\n") {
      lines.append(String(buffered[..<newline]))
      buffered = String(buffered[buffered.index(after: newline)...])
    }
  }

  private func nextLine() async throws -> String {
    var line: String?
    let arrived = await pollUntil(timeout: .seconds(10)) {
      line = takeLine()

      return line != nil
    }

    guard arrived, let line else { throw WireError.closed }

    return line
  }

  private func takeLine() -> String? {
    lock.lock()
    defer { lock.unlock() }

    guard lines.count > taken else { return nil }

    taken += 1

    return lines[taken - 1]
  }

  private func command(_ line: String) throws {
    try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
  }

  private func pid(after prefix: String) async throws -> pid_t {
    let line = try await nextLine()

    guard line.hasPrefix(prefix), let pid = pid_t(line.dropFirst(prefix.count)) else {
      throw WireError.badValue(line)
    }

    return pid
  }

  /// The PID of the process that connected.
  func connected() async throws -> pid_t {
    try await pid(after: "connected ")
  }

  /// The PID of a nested relay's first process.
  func root() async throws -> pid_t {
    try await pid(after: "root ")
  }

  /// Ends the connecting process's parent, so the process is moved to launchd.
  func unparent() async throws {
    try command("unparent")
    _ = try await pid(after: "unparented ")
  }

  func send(_ frame: Data) async throws {
    try command("send " + frame.map { String(format: "%02x", $0) }.joined())

    guard try await nextLine() == "sent" else { throw WireError.closed }
  }

  func read() async throws -> ScriptAppMessage {
    try command("read")

    let line = try await nextLine()

    guard line.hasPrefix("frame ") else { throw WireError.closed }

    let hex = Array(line.dropFirst(6).utf8)
    let bytes = stride(from: 0, to: hex.count, by: 2).compactMap {
      UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)
    }

    return try ScriptAppMessage.decode(type: bytes[0], body: Data(bytes[5...]))
  }

  /// Starts perl again in the connecting process, with the socket kept open across the exec.
  /// Returns the PID the new program reports, which is the same process's.
  func exec() async throws -> pid_t {
    try command("exec")

    return try await pid(after: "execed ")
  }

  /// Forks the relay. The child writes `frame` on the inherited socket while the connecting
  /// process stays. Returns the child's PID.
  func forkSend(_ frame: Data) async throws -> pid_t {
    try command("forksend " + frame.map { String(format: "%02x", $0) }.joined())

    return try await pid(after: "childsent ")
  }

  /// Forks the relay. The connecting process exits, and the PID of the child that keeps the
  /// socket comes back.
  func orphan() async throws -> pid_t {
    try command("orphan")

    return try await pid(after: "orphaned ")
  }
}
