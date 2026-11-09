import Darwin
import Foundation
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// The listener's addresses, peers, and queues, driven by raw peers. No helper process runs, so
/// every test here is fast and bounded by its own read timeout.
///
/// They prove who owns the well-known address and when it goes away, that a second instance
/// leaves it alone, that a crashed instance's files are removed, that a peer of another user is
/// turned away, and that a peer that never reads cannot grow the queue. They cannot prove two
/// separate app processes, which `ScriptRunUITests` starts for real. The well-known address of a
/// test is in its own folder, never the user's.
final class ScriptListenerTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var wellKnown: String {
    directory.appendingPathComponent(ScriptAddress.wellKnownName).path
  }

  private func hello(to path: String) throws -> FramedSocket {
    let socket = try ScriptFixtures.connectPeer(path: path)

    try socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    return socket
  }

  /// Catches the command and the app disagreeing about where the well-known address is. The
  /// command derives it from the home folder, and the app from Application Support.
  func testTheCommandAndTheAppAgreeOnTheWellKnownAddress() throws {
    let home = try XCTUnwrap(ScriptAddress.homeDirectory())

    XCTAssertEqual(
      ScriptAddress.wellKnownPath(home: home),
      try ScriptSocketDirectory.defaultDirectory()
        .appendingPathComponent(ScriptAddress.wellKnownName).path)
  }

  /// Catches an owner that does not claim the address, or one whose address reaches a different
  /// listener than its own.
  func testTheFirstInstanceOwnsTheWellKnownAddressAndItReachesThatInstance() throws {
    let first = try ScriptListener.start(directory: directory)

    defer { first.stop() }

    XCTAssertEqual(first.wellKnownPath, wellKnown)

    let viaWellKnown = try hello(to: wellKnown)

    viaWellKnown.shutdownAndClose()
  }

  /// Catches a second instance that takes the address, breaks the first one's socket, or loses its
  /// own. Two listeners in one process stand for two instances, since the lock is per open file.
  func testASecondInstanceNeitherTakesOverNorBreaksTheFirstOnesSocket() async throws {
    let first = try ScriptListener.start(directory: directory)
    let firstInode = try inode(of: wellKnown)

    let sibling = try startAnotherInstance(in: directory)

    defer {
      first.stop()
      sibling.stop()
    }

    XCTAssertNil(sibling.wellKnownPath, "the second instance claimed the address")
    XCTAssertEqual(try inode(of: wellKnown), firstInode, "the address was replaced")

    let viaWellKnown = try hello(to: wellKnown)
    let viaSibling = try hello(to: sibling.path)

    viaWellKnown.shutdownAndClose()
    viaSibling.shutdownAndClose()

    XCTAssertNotEqual(sibling.path, first.path)
  }

  /// A second process has its own ID, so its socket file has its own name. The stand-in names the
  /// file itself, and takes the lock claim as a second instance would.
  private func startAnotherInstance(in directory: URL) throws -> ScriptListener {
    try ScriptListener.start(directory: directory, instanceName: "9999999")
  }

  /// Catches an address that goes on pointing at an owner that quit, or one that a second
  /// instance quietly takes over. After the owner stops, the address is gone and stays gone, and
  /// the second instance is still reachable at its own.
  func testAfterTheOwnerQuitsTheAddressIsGoneAndTheSecondInstanceKeepsItsOwn() throws {
    let first = try ScriptListener.start(directory: directory)
    let second = try startAnotherInstance(in: directory)

    defer { second.stop() }

    first.stop()

    XCTAssertFalse(FileManager.default.fileExists(atPath: wellKnown))

    XCTAssertThrowsError(try UnixSocket.connect(path: wellKnown)) { error in
      guard case WireError.io(let code) = error else { return XCTFail("\(error)") }

      XCTAssertEqual(code, ENOENT)
    }

    XCTAssertNil(second.wellKnownPath)

    try hello(to: second.path).shutdownAndClose()
  }

  /// Catches a stale socket file that blocks a new owner, or one that a client could still reach. A
  /// file left at the address by a process that died, with its lock free, is replaced.
  func testAStaleWellKnownFileIsReplacedByTheNextOwner() throws {
    let stale = try FakeApp.listen(path: wellKnown)

    Darwin.close(stale)

    XCTAssertThrowsError(try UnixSocket.connect(path: wellKnown)) { error in
      guard case WireError.io(let code) = error else { return XCTFail("\(error)") }

      XCTAssertEqual(code, ECONNREFUSED)
    }

    let owner = try ScriptListener.start(directory: directory)

    defer { owner.stop() }

    XCTAssertEqual(owner.wellKnownPath, wellKnown)

    try hello(to: wellKnown).shutdownAndClose()
  }

  /// Catches a lock that outlives its owner, or one that a program the app starts could inherit.
  /// The lock is held while the owner runs and free after it stops. Its descriptor is
  /// close-on-exec, so no child keeps the address owned after the app quits.
  func testTheLockIsHeldWhileTheOwnerRunsAndFreeAfterItStops() throws {
    let owner = try ScriptListener.start(directory: directory)

    defer { owner.stop() }

    let lock = open(directory.appendingPathComponent(ScriptAddress.lockName).path, O_RDONLY)

    defer { Darwin.close(lock) }

    XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), -1, "the lock is not held")
    XCTAssertEqual(errno, EWOULDBLOCK)

    owner.stop()

    XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0, "stop did not release the lock")

    let other = directory.appendingPathComponent("claim", isDirectory: true)

    try ScriptSocketDirectory.prepare(other)

    let claim = try XCTUnwrap(try ScriptSocketFiles.WellKnown.claim(directory: other))

    defer { claim.release() }
    defer { Darwin.close(claim.descriptor) }

    XCTAssertNotEqual(fcntl(claim.lock, F_GETFD) & FD_CLOEXEC, 0, "a child would inherit the lock")
    XCTAssertNotEqual(fcntl(claim.descriptor, F_GETFD) & FD_CLOEXEC, 0)
  }

  /// Catches a listener that keeps the files of an instance that crashed. A file for a process
  /// that is gone is removed. A file for this process, for a process that is running and made it,
  /// and anything that is not a socket stay.
  func testStartRemovesSocketFilesOfCrashedInstancesOnly() throws {
    let dead = directory.appendingPathComponent("4000000.sock").path
    let living = directory.appendingPathComponent("\(getpid() + 1).sock").path
    let plain = directory.appendingPathComponent("4000001.sock")

    Darwin.close(try FakeApp.listen(path: dead))
    Darwin.close(try FakeApp.listen(path: living))
    try Data().write(to: plain)

    let started = ProcessIdentity.startTime(of: getpid()) ?? 0
    let removed = ScriptSocketFiles.removeStaleSockets(
      in: directory, current: getpid(),
      startTime: { $0 == getpid() + 1 ? started : nil })

    XCTAssertEqual(removed, ["4000000.sock"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: dead))
    XCTAssertTrue(FileManager.default.fileExists(atPath: living))
    XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
  }

  /// Catches a reused process ID keeping a dead instance's file. A running process that started
  /// after the file was made cannot be its owner, so the file is stale. A process that started
  /// before the file was made may be.
  func testAReusedProcessIDDoesNotKeepADeadInstancesFile() {
    XCTAssertTrue(ScriptSocketFiles.isStale(pid: 7, birth: 100, startTime: { _ in 200 }))
    XCTAssertFalse(ScriptSocketFiles.isStale(pid: 7, birth: 200, startTime: { _ in 200 }))
    XCTAssertFalse(ScriptSocketFiles.isStale(pid: 7, birth: 300, startTime: { _ in 200 }))
    XCTAssertTrue(ScriptSocketFiles.isStale(pid: 7, birth: 300, startTime: { _ in nil }))
  }

  /// Catches a listener that serves a peer of another user. The credential reader reports one, since
  /// a second user cannot be made in a test. The peer is closed, and the app reports the refusal.
  func testAPeerOfAnotherUserIsRejected() async throws {
    let listener = try ScriptListener.start(
      directory: directory,
      readPeer: { descriptor in
        let real = try ScriptPeer.read(descriptor: descriptor)

        return ScriptPeer(uid: real.uid &+ 1, pid: real.pid, token: real.token)
      })

    defer { listener.stop() }

    let socket = try ScriptFixtures.connectPeer(path: listener.path)

    try? socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())

    XCTAssertThrowsError(try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))) { error in
      XCTAssertEqual(error as? WireError, .closed, "the app answered a peer of another user")
    }

    let seen = RefusalBox()
    let reported = await listener.drive(timeout: .seconds(15)) { event in
      guard case .refused(_, let refusal) = event else { return false }

      seen.set(refusal)

      return true
    }

    XCTAssertTrue(reported, "the app never reported the refusal")

    guard case .otherUser(let uid)? = seen.value else {
      return XCTFail("the refusal was \(String(describing: seen.value))")
    }

    XCTAssertEqual(uid, geteuid() &+ 1)
  }

  /// Drives the listener until it reports a protocol violation, and returns every event up to it.
  private func eventsUntilViolation(of listener: ScriptListener) async -> (Bool, EventLog) {
    let log = EventLog()
    let found = await listener.drive(timeout: .seconds(15)) { event in
      log.record(event)

      if case .refused(_, .protocolViolation) = event { return true }

      return false
    }

    return (found, log)
  }

  /// Catches a peer that calls the host after its hello without declaring a script or a REPL.
  /// The call must never reach the host, and the peer must be closed.
  func testACallBeforeBeginOrAttachIsRefusedAndNeverReachesTheHost() async throws {
    let listener = try ScriptListener.start(directory: directory)

    defer { listener.stop() }

    let socket = try hello(to: listener.path)

    try socket.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    let (found, log) = await eventsUntilViolation(of: listener)

    XCTAssertTrue(found, "the app accepted a call from a peer that never declared a role")
    XCTAssertEqual(log.requests, 0)

    XCTAssertThrowsError(try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:)))
  }

  /// Catches a script that begins again after it has called the host, which would rename its
  /// session. A second begin is refused, so only the first name is ever reported.
  func testBeginAfterACallIsRefusedAndKeepsTheFirstName() async throws {
    let listener = try ScriptListener.start(directory: directory)

    defer { listener.stop() }

    let socket = try hello(to: listener.path)

    try socket.send(ScriptHelperMessage.begin(name: "first").frame())
    try socket.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())
    try socket.send(ScriptHelperMessage.begin(name: "second").frame())

    let (found, log) = await eventsUntilViolation(of: listener)

    XCTAssertTrue(found, "the app accepted a second begin")
    XCTAssertEqual(log.names, ["first"])
    XCTAssertEqual(log.requests, 1)
  }

  /// Catches same-user peers holding connection slots by saying hello and then never declaring.
  /// The bound is injected, so the test runs in a fraction of a second. A peer that declared is
  /// past the bound for good, and the sleep past it is the only way to show that.
  func testAPeerThatNeverDeclaresIsClosedAndADeclaredPeerIsNot() async throws {
    let listener = try ScriptListener.start(directory: directory, declarationTimeout: 0.25)

    defer { listener.stop() }

    let declared = try hello(to: listener.path)

    try declared.send(ScriptHelperMessage.begin(name: "kept").frame())

    let silent = try hello(to: listener.path)

    let (found, _) = await eventsUntilViolation(of: listener)

    XCTAssertTrue(found, "the app never turned away the peer that did not declare")
    XCTAssertThrowsError(try silent.readFrame(limit: ScriptAppMessage.bodyLimit(type:))) { error in
      XCTAssertEqual(error as? WireError, .closed)
    }

    try await Task.sleep(for: .milliseconds(400))
    try declared.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    let reached = await listener.drive(timeout: .seconds(15)) { event in
      if case .request = event { return true }

      return false
    }

    XCTAssertTrue(reached, "the declared peer was closed by the declaration bound")
  }

  /// Catches a peer that never reads growing the app's memory. A raw peer sends many calls and
  /// reads nothing. The app queues each reply for the writer, so the queue must stop at its bounds
  /// and the peer must be disconnected, whatever the peer does.
  func testAPeerThatNeverReadsIsDisconnectedWhenItsQueueFills() async throws {
    let listener = try ScriptListener.start(directory: directory)

    defer { listener.stop() }

    let socket = try hello(to: listener.path)

    try socket.send(ScriptHelperMessage.begin(name: "flood").frame())

    let sender = Task.detached {
      var sent: UInt32 = 0

      while sent < 200_000 {
        sent += 1

        do {
          try socket.send(
            ScriptHelperMessage.request(
              id: sent, call: .postStatus(level: .info, text: "x")
            ).frame())
        } catch {
          break
        }
      }

      return sent
    }

    let tracker = QueueTracker()
    let refused = await listener.drive(timeout: .seconds(30)) { event in
      switch event {
      case .request(let connection, let id, _):
        // The host answers at once, as it does for a status post. The peer reads none of it.
        connection.reply(id: id, result: .ok(Data()))
        tracker.record(connection.queued)

        return false

      case .refused(_, .peerNotReading):
        return true

      default:
        return false
      }
    }

    sender.cancel()
    socket.shutdownAndClose()

    let peak = tracker.peak

    XCTAssertTrue(refused, "the app never disconnected the peer that stopped reading")
    XCTAssertLessThanOrEqual(peak.messages, ScriptConnection.maxQueuedMessages)
    XCTAssertLessThanOrEqual(peak.bytes, ScriptConnection.maxQueuedBytes)
  }

  /// The bounds themselves, on a connection whose peer is never read from. Large replies stop at
  /// the byte bound and small ones at the message bound. Each ends the connection, and nothing
  /// stays queued after it.
  func testTheWriterQueueIsBoundedByMessagesAndByBytes() throws {
    for size in [0, ScriptProtocol.maxReplyPayload] {
      let (app, peer) = try FramedSocket.pair()
      let overflowed = OverflowFlag()
      let connection = ScriptConnection(
        id: 1, peer: ScriptPeer(uid: getuid(), pid: getpid(), token: nil), socket: app,
        onOverflow: { _ in overflowed.set() })

      defer { peer.shutdownAndClose() }

      // The pair's buffers fill first, then the writer blocks and replies queue. A count past
      // both bounds must end the connection whatever the buffers hold.
      var peak = (messages: 0, bytes: 0)

      for id in 0..<2_000_000 where !connection.isClosed {
        connection.reply(id: UInt32(id), result: .ok(Data(count: size)))

        let queued = connection.queued

        peak = (max(peak.messages, queued.messages), max(peak.bytes, queued.bytes))
      }

      XCTAssertTrue(connection.isClosed, "size \(size): the connection never ended")
      XCTAssertTrue(overflowed.value, "size \(size): the overflow was not reported")
      XCTAssertLessThanOrEqual(peak.messages, ScriptConnection.maxQueuedMessages)
      XCTAssertLessThanOrEqual(peak.bytes, ScriptConnection.maxQueuedBytes)

      if size == 0 {
        XCTAssertEqual(peak.messages, ScriptConnection.maxQueuedMessages, "the message bound")
      } else {
        XCTAssertLessThan(peak.messages, ScriptConnection.maxQueuedMessages, "the byte bound")
      }
    }
  }
}

private final class RefusalBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ScriptRefusal?

  func set(_ refusal: ScriptRefusal) {
    lock.lock()
    stored = refusal
    lock.unlock()
  }

  var value: ScriptRefusal? {
    lock.lock()
    defer { lock.unlock() }

    return stored
  }
}

private final class QueueTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var most = (messages: 0, bytes: 0)

  func record(_ queued: (messages: Int, bytes: Int)) {
    lock.lock()
    most = (max(most.messages, queued.messages), max(most.bytes, queued.bytes))
    lock.unlock()
  }

  var peak: (messages: Int, bytes: Int) {
    lock.lock()
    defer { lock.unlock() }

    return most
  }
}

private final class OverflowFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  func set() {
    lock.lock()
    flag = true
    lock.unlock()
  }

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }

    return flag
  }
}

private func inode(of path: String) throws -> UInt64 {
  var info = stat()

  guard lstat(path, &info) == 0 else { throw WireError.io(errno) }

  return UInt64(info.st_ino)
}

private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var begun: [String] = []
  private var requested = 0

  func record(_ event: ScriptEvent) {
    lock.lock()
    defer { lock.unlock() }

    switch event {
    case .begun(_, let name): begun.append(name)
    case .request: requested += 1
    default: break
    }
  }

  var names: [String] {
    lock.lock()
    defer { lock.unlock() }

    return begun
  }

  var requests: Int {
    lock.lock()
    defer { lock.unlock() }

    return requested
  }
}
