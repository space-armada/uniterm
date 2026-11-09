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

  /// What the helper says when the app's end of the connection closes. A REPL words it for a REPL.
  private(set) var quitText = ScriptSession.appQuitText

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

  /// What a REPL's helper says when the app's end of the connection closes.
  static let replQuitText = "uniterm quit, or closed this REPL's connection"

  /// Connects, exchanges the protocol version, and names the script. Throws
  /// `WireError.versionMismatch` when the app is another version.
  static func open(path: String, name: String) throws -> ScriptSession {
    let session = try connect(path: path)

    try session.socket.send(ScriptHelperMessage.begin(name: name).frame())

    return session
  }

  /// Connects as a REPL's helper does. After the version, it presents the token and waits for the
  /// app to accept it. The app answers with the history to recall, oldest first, or with a refusal
  /// that says why. A refusal throws `ScriptSessionError.failed`.
  static func openRepl(path: String, token: Data) throws -> (
    session: ScriptSession, history: [String]
  ) {
    let session = try connect(path: path)

    session.quitText = replQuitText

    do {
      try session.socket.send(ScriptHelperMessage.attach(token: token).frame())

      var lines: [String] = []

      while true {
        switch try session.readMessage() {
        case .history(let more, let final):
          lines += more

          guard lines.count <= maxHistoryLines else {
            throw WireError.badValue("the app sent more history than a REPL can recall")
          }

          if final { return (session, lines) }

        case .attachRefused(let text):
          throw ScriptSessionError.failed(.refused, text)

        default:
          throw WireError.badValue("the app answered a token with something else")
        }
      }
    } catch {
      session.close()

      throw error
    }
  }

  /// The most history lines a helper accepts. The app sends at most the lines the line editor
  /// recalls, so a larger history is a fault.
  private static let maxHistoryLines = 1000

  private static func connect(path: String) throws -> ScriptSession {
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

    return session
  }

  /// Tells the app a line the user entered. It needs no answer, and a lost connection ends the
  /// helper as any other call does.
  func reportReplLine(_ text: String) {
    notify(.replLine(text))
  }

  /// Tells the app whether a form is evaluating.
  func reportEvaluating(_ running: Bool) {
    notify(.replEvaluating(running))
  }

  private func notify(_ message: ScriptHelperMessage) {
    do {
      try socket.send(message.frame())
    } catch WireError.closed {
      lost(quitText)
    } catch {
      lost("the connection to uniterm failed: \(error)")
    }
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
      lost(quitText)
    } catch {
      lost("the connection to uniterm failed while the script was running: \(error)")
    }
  }

  private func readMessage() throws -> ScriptAppMessage {
    let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
  }
}
