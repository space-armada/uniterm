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

  public let path: String
  public let events: AsyncStream<ScriptEvent>

  private let continuation: AsyncStream<ScriptEvent>.Continuation
  private let listenDescriptor: Int32
  private let wakeRead: Int32
  private let wakeWrite: Int32
  private let lock = NSLock()
  private var connections: [UInt64: ScriptConnection] = [:]
  private var serving = 0
  private var nextConnectionID: UInt64 = 1
  private var stopped = false

  private init(path: String, listenDescriptor: Int32, wake: (Int32, Int32)) {
    let (events, continuation) = AsyncStream<ScriptEvent>.makeStream()

    self.path = path
    self.events = events
    self.continuation = continuation
    self.listenDescriptor = listenDescriptor
    self.wakeRead = wake.0
    self.wakeWrite = wake.1
  }

  /// Listens at `<directory>/<pid>.sock`. Each running instance has its own address, named by its
  /// process ID. The folder is created private to this user.
  public static func start(directory: URL) throws -> ScriptListener {
    try ScriptSocketDirectory.prepare(directory)

    let path = directory.appendingPathComponent("\(getpid()).sock").path
    let length = path.utf8.count

    guard length <= UnixSocket.maxPathBytes else {
      throw ScriptListenerError.pathTooLong(path, length)
    }

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)

    guard descriptor >= 0 else { throw ScriptListenerError.socket(path, errno) }

    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

    // A socket file left by an earlier process with this ID is stale, since this process is the
    // only one that owns the ID now.
    unlink(path)

    do {
      try UnixSocket.withAddress(path: path) { address, size in
        guard bind(descriptor, address, size) == 0 else {
          throw ScriptListenerError.socket(path, errno)
        }
      }

      guard chmod(path, 0o600) == 0 else { throw ScriptListenerError.socket(path, errno) }
      guard listen(descriptor, 16) == 0 else { throw ScriptListenerError.socket(path, errno) }
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

      throw ScriptListenerError.socket(path, code)
    }

    for fd in wake {
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    let listener = ScriptListener(
      path: path, listenDescriptor: descriptor, wake: (wake[0], wake[1]))
    let thread = Thread { listener.acceptLoop() }

    thread.name = "uniterm.script.accept"
    thread.stackSize = 1 << 20
    thread.start()

    return listener
  }

  /// Stops listening, removes the socket file, ends every connection, and finishes `events`. The
  /// file is gone when this returns, since the app may exit right after. This is the one owner of
  /// the wake pipe's write end, so a stop that follows the accept loop's own exit never touches a
  /// closed descriptor. Safe to call twice.
  public func stop() {
    lock.lock()

    guard !stopped else {
      lock.unlock()

      return
    }

    stopped = true
    unlink(path)

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
      Darwin.close(listenDescriptor)
      Darwin.close(wakeRead)
    }

    while !isStopped {
      var polls = [
        pollfd(fd: listenDescriptor, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
      ]

      guard poll(&polls, 2, -1) >= 0 || errno == EINTR else { return }

      if polls[1].revents != 0 { return }

      guard polls[0].revents & Int16(POLLIN) != 0 else { continue }

      let accepted = accept(listenDescriptor, nil, nil)

      guard accepted >= 0 else { continue }

      _ = fcntl(accepted, F_SETFD, FD_CLOEXEC)

      admit(accepted)
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

    guard let peer = try? ScriptPeer.read(descriptor: descriptor) else {
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

    let connection = ScriptConnection(id: id, peer: peer, socket: socket)

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
