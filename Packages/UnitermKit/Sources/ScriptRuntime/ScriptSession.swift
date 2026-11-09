import Darwin
import Foundation
import ScriptWire

/// Why a call to the app did not complete.
enum ScriptSessionError: Error, Equatable {
  /// The app answered the call with a failure.
  case failed(ScriptFailureKind, String)
}

/// The helper's end of one connection to the app.
///
/// The helper runs one script at a time on one thread, so a call sends its request and waits for
/// the reply on that thread. Nothing else reads the socket. The watchdog thread only watches the
/// descriptor for a hangup, and a later thread that handles Ctrl-C does the same.
///
/// A connection that is lost ends the helper. A script cannot go on without the app, and a script
/// that catches the error must not be able to keep running either.
final class ScriptSession {
  private let socket: FramedSocket
  private let lost: @Sendable (String) -> Never
  private var nextRequest: UInt32 = 1

  /// `lost` runs when the app closes the connection or it fails. It must not return.
  init(
    socket: FramedSocket,
    lost: @escaping @Sendable (String) -> Never = ScriptSession.endFlushing
  ) {
    self.socket = socket
    self.lost = lost
  }

  /// The descriptor the watchdog watches.
  var descriptor: Int32 { socket.rawDescriptor }

  /// Says why on stderr and ends the process with a status of its own. It must not return.
  ///
  /// `flushingOutput` is for the VM thread, which owns standard output. A script writes through
  /// stdio, so the text it printed sits in a buffer that `_exit` drops. The watchdog thread passes
  /// false. It cannot know whether the VM thread holds the stdio lock, and a blocked flush there
  /// would leave the helper running after the app quit. A run cut off by the app quitting may
  /// therefore lose the end of its output, and when the watchdog ends it, all of what was buffered.
  static func endHelper(_ reason: String, flushingOutput: Bool) -> Never {
    if flushingOutput {
      fflush(stdout)
    }

    let text = "uniterm: \(reason)\n"

    _ = text.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    _exit(ScriptHelperMain.Exit.connectionLost)
  }

  /// What the VM thread does when the connection is lost.
  static let endFlushing: @Sendable (String) -> Never = { reason in
    endHelper(reason, flushingOutput: true)
  }

  /// What the helper says when the app's end of the connection closes.
  static let appQuitText = "uniterm quit, or closed the connection, while the script was running"

  /// Connects, exchanges the protocol version, and names the script. Throws
  /// `WireError.versionMismatch` when the app is another version.
  static func open(path: String, name: String) throws -> ScriptSession {
    let socket = try UnixSocket.connect(path: path)

    // A socket that another user made could read the script's name and what the script asks for.
    guard try UnixSocket.peerUserID(of: socket.rawDescriptor) == geteuid() else {
      socket.shutdownAndClose()

      throw ScriptSessionError.failed(.refused, "the socket at \(path) belongs to another user")
    }

    let session = ScriptSession(socket: socket)

    try session.socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())

    let hello = try session.readMessage()

    try ScriptAppMessage.validateHello(hello)
    try session.socket.send(ScriptHelperMessage.begin(name: name).frame())

    return session
  }

  func close() {
    socket.shutdownAndClose()
  }

  /// Posts a status message and waits for the app to answer.
  func postStatus(level: ScriptStatusLevel, text: String) throws {
    _ = try call(.postStatus(level: level, text: text))
  }

  func call(_ call: ScriptCall) throws -> Data {
    let id = nextRequest
    nextRequest &+= 1

    do {
      try socket.send(ScriptHelperMessage.request(id: id, call: call).frame())

      guard case .reply(let replyID, let result) = try readMessage() else {
        throw WireError.badValue("the app sent a hello instead of a reply")
      }

      guard replyID == id else {
        throw WireError.badValue("the app answered request \(replyID), not \(id)")
      }

      switch result {
      case .ok(let payload): return payload
      case .failure(let kind, let text): throw ScriptSessionError.failed(kind, text)
      }
    } catch let error as ScriptSessionError {
      throw error
    } catch WireError.closed {
      lost(Self.appQuitText)
    } catch {
      lost("the connection to uniterm failed while the script was running: \(error)")
    }
  }

  private func readMessage() throws -> ScriptAppMessage {
    let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
  }
}
