import Darwin
import Foundation
import ScriptWire

/// The app's listening socket for script helpers.
///
/// An accept thread takes each connection. A thread for each connection then reads and decodes its
/// frames, so no read or decode ever runs on the main thread. Every call reaches the main actor
/// through `events`.
public final class ScriptListener: @unchecked Sendable {
  /// The most peers served at once. The next one is refused.
  public static let maxConnections = 32

  /// How long a peer may take to send its hello before it is turned away.
  static let helloTimeout: TimeInterval = 5

  /// This instance's own address, `<pid>.sock`.
  public let path: String

  /// The well-known address, when this instance owns it. Only the first instance to start does.
  public let wellKnownPath: String?

  public let events: AsyncStream<ScriptEvent>

  private let continuation: AsyncStream<ScriptEvent>.Continuation
  private let listenDescriptors: [Int32]
  private let wellKnown: ScriptSocketFiles.WellKnown?
  private let wakeRead: Int32
  private let wakeWrite: Int32
  private let readPeer: @Sendable (Int32) throws -> ScriptPeer
  private let lock = NSLock()
  private var connections: [UInt64: ScriptConnection] = [:]
  private var serving = 0
  private var nextConnectionID: UInt64 = 1
  private var stopped = false

  private init(
    path: String, listenDescriptor: Int32, wellKnown: ScriptSocketFiles.WellKnown?,
    wake: (Int32, Int32), readPeer: @escaping @Sendable (Int32) throws -> ScriptPeer
  ) {
    let (events, continuation) = AsyncStream<ScriptEvent>.makeStream()

    self.path = path
    self.wellKnownPath = wellKnown?.path
    self.events = events
    self.continuation = continuation
    self.listenDescriptors = [listenDescriptor] + (wellKnown.map { [$0.descriptor] } ?? [])
    self.wellKnown = wellKnown
    self.wakeRead = wake.0
    self.wakeWrite = wake.1
    self.readPeer = readPeer
  }

  /// Listens at `<directory>/<pid>.sock`. Each running instance has its own address, named by its
  /// process ID. The folder is created private to this user.
  ///
  /// The first instance to start also listens at the well-known address, and holds the lock that
  /// owns it until it stops. A later instance leaves the address alone. A socket file that a
  /// crashed instance left is removed first.
  ///
  /// `readPeer` reads who is on the other end of a connection. Only a test replaces it, so it can
  /// play a peer of another user.
  public static func start(
    directory: URL, readPeer: (@Sendable (Int32) throws -> ScriptPeer)? = nil
  ) throws -> ScriptListener {
    try start(directory: directory, instanceName: String(getpid()), readPeer: readPeer)
  }

  /// Starts with a name other than the process ID. Only a test uses it, to stand two instances in
  /// one process.
  static func start(
    directory: URL, instanceName: String, readPeer: (@Sendable (Int32) throws -> ScriptPeer)? = nil
  ) throws -> ScriptListener {
    try ScriptSocketDirectory.prepare(directory)

    ScriptSocketFiles.removeStaleSockets(in: directory)

    let path = directory.appendingPathComponent("\(instanceName).sock").path
    let descriptor = try ScriptSocketFiles.bindListening(path: path)
    let wellKnown: ScriptSocketFiles.WellKnown?

    do {
      wellKnown = try ScriptSocketFiles.WellKnown.claim(directory: directory)
    } catch {
      Darwin.close(descriptor)
      unlink(path)

      throw error
    }

    var wake: [Int32] = [0, 0]

    guard pipe(&wake) == 0 else {
      let code = errno

      Darwin.close(descriptor)
      unlink(path)
      wellKnown?.release()

      throw ScriptListenerError.socket(path, code)
    }

    for fd in wake {
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    let listener = ScriptListener(
      path: path, listenDescriptor: descriptor, wellKnown: wellKnown, wake: (wake[0], wake[1]),
      readPeer: readPeer ?? { try ScriptPeer.read(descriptor: $0) })
    let thread = Thread { listener.acceptLoop() }

    thread.name = "uniterm.script.accept"
    thread.stackSize = 1 << 20
    thread.start()

    return listener
  }

  /// Stops listening and ends every connection. Safe to call twice.
  ///
  /// The socket files are gone when this returns, since the app may exit right after.
  ///
  /// This is the one owner of the wake pipe's write end, so a stop after the accept loop's own
  /// exit never touches a closed descriptor.
  public func stop() {
    lock.lock()

    guard !stopped else {
      lock.unlock()

      return
    }

    stopped = true
    unlink(path)
    wellKnown?.release()

    var byte: UInt8 = 1
    _ = write(wakeWrite, &byte, 1)
    Darwin.close(wakeWrite)

    let open = Array(connections.values)

    lock.unlock()

    for connection in open {
      connection.close()
    }

    continuation.finish()
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }

    return stopped
  }

  private func acceptLoop() {
    defer {
      stop()

      for descriptor in listenDescriptors {
        Darwin.close(descriptor)
      }

      Darwin.close(wakeRead)
    }

    while !isStopped {
      var polls = listenDescriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }

      polls.append(pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0))

      guard poll(&polls, nfds_t(polls.count), -1) >= 0 || errno == EINTR else { return }

      if polls[polls.count - 1].revents != 0 { return }

      for ready in polls.dropLast() where ready.revents & Int16(POLLIN) != 0 {
        let accepted = accept(ready.fd, nil, nil)

        guard accepted >= 0 else { continue }

        _ = fcntl(accepted, F_SETFD, FD_CLOEXEC)

        admit(accepted)
      }
    }
  }

  private func admit(_ descriptor: Int32) {
    lock.lock()

    guard !stopped, serving < Self.maxConnections else {
      let full = !stopped

      lock.unlock()
      Darwin.close(descriptor)

      if full { continuation.yield(.refused(nil, .tooManyConnections)) }

      return
    }

    serving += 1

    let id = nextConnectionID

    nextConnectionID += 1
    lock.unlock()

    let thread = Thread { [self] in
      serve(descriptor: descriptor, id: id)

      lock.lock()
      serving -= 1
      lock.unlock()
    }

    thread.name = "uniterm.script.reader.\(id)"
    thread.stackSize = 1 << 20
    thread.start()
  }

  private func serve(descriptor: Int32, id: UInt64) {
    let socket = FramedSocket(descriptor: descriptor)

    guard let peer = try? readPeer(descriptor) else {
      continuation.yield(
        .refused(nil, .protocolViolation("the peer's credentials were unreadable")))
      socket.shutdownAndClose()

      return
    }

    guard peer.uid == geteuid() else {
      continuation.yield(.refused(peer, .otherUser(uid: peer.uid)))
      socket.shutdownAndClose()

      return
    }

    setReadTimeout(Self.helloTimeout, on: descriptor)

    do {
      try handshake(socket)
    } catch WireError.versionMismatch(let found, _) {
      continuation.yield(.refused(peer, .versionMismatch(found: found)))
      socket.shutdownAndClose()

      return
    } catch {
      continuation.yield(.refused(peer, .protocolViolation("\(error)")))
      socket.shutdownAndClose()

      return
    }

    setReadTimeout(0, on: descriptor)

    let connection = ScriptConnection(
      id: id, peer: peer, socket: socket,
      onOverflow: { [continuation] connection in
        continuation.yield(.refused(connection.peer, .peerNotReading))
      })

    lock.lock()
    connections[id] = connection
    lock.unlock()

    readCalls(from: connection)

    connection.close()

    lock.lock()
    connections[id] = nil
    lock.unlock()

    continuation.yield(.closed(connection))
  }

  /// Reads the helper's hello and answers with the app's own, whether the versions agree or not,
  /// so the helper can tell the user what happened. A mismatch then throws.
  private func handshake(_ socket: FramedSocket) throws {
    let frame = try socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))
    let hello = try ScriptHelperMessage.decode(type: frame.type, body: frame.body)

    try socket.send(ScriptAppMessage.hello(version: ScriptProtocol.version).frame())
    try ScriptHelperMessage.validateHello(hello)
  }

  private func readCalls(from connection: ScriptConnection) {
    var begun = false

    while !connection.isClosed {
      do {
        let frame = try connection.socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))

        switch try ScriptHelperMessage.decode(type: frame.type, body: frame.body) {
        case .hello:
          throw WireError.badValue("a second hello")

        case .begin(let name):
          guard !begun else { throw WireError.badValue("a second begin") }

          begun = true
          continuation.yield(.begun(connection, name: name))

        case .request(let id, let call):
          connection.slots.wait()

          guard !connection.isClosed else { return }

          continuation.yield(.request(connection, id: id, call: call))
        }
      } catch WireError.closed {
        return
      } catch {
        if !connection.isClosed {
          continuation.yield(.refused(connection.peer, .protocolViolation("\(error)")))
        }

        return
      }
    }
  }

  private func setReadTimeout(_ seconds: TimeInterval, on descriptor: Int32) {
    var timeout = timeval(tv_sec: Int(seconds), tv_usec: 0)

    _ = setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }
}
