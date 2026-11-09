import Foundation
import ScriptWire

/// Why a call to the app did not complete.
enum ScriptSessionError: Error, Equatable {
  /// The app closed the connection, or it failed.
  case connectionLost(String)

  /// The app answered the call with a failure.
  case failed(ScriptFailureKind, String)
}

/// The helper's end of one connection to the app.
///
/// The helper runs one script at a time on one thread, so a call sends its request and waits for
/// the reply on that thread. Nothing else reads the socket. A later change that lets another
/// thread interrupt the script moves the read to its own thread.
final class ScriptSession {
  private let socket: FramedSocket
  private var nextRequest: UInt32 = 1

  init(socket: FramedSocket) {
    self.socket = socket
  }

  /// Connects, exchanges the protocol version, and names the script. Throws
  /// `WireError.versionMismatch` when the app is another version.
  static func open(path: String, name: String) throws -> ScriptSession {
    let session = ScriptSession(socket: try UnixSocket.connect(path: path))

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
      throw ScriptSessionError.connectionLost("uniterm closed the connection")
    } catch {
      throw ScriptSessionError.connectionLost("the connection to uniterm failed: \(error)")
    }
  }

  private func readMessage() throws -> ScriptAppMessage {
    let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
  }
}
