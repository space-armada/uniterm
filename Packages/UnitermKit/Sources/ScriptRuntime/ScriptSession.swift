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
/// its reply on that thread. Once the watchdog thread starts, it is the only reader of the socket.
/// It hands a reply to the VM thread through a one-slot mailbox, answers the app's ping itself, and
/// carries out the app's stop request. A ping is therefore answered while the VM thread is busy in
/// a loop, in a long call into C, or waiting for a reply. Any thread may send, since the socket's
/// sends take a lock.
///
/// A connection that is lost ends the helper. A script cannot go on without the app, and a script
/// that catches the error must not be able to keep running either.
final class ScriptSession: @unchecked Sendable {
  private let socket: FramedSocket
  private let lost: @Sendable (String) -> Never
  private var nextRequest: UInt32 = 1

  private let mailbox = NSCondition()
  private var reply: ScriptAppMessage?
  private var dispatching = false
  private var dispatcherEnded = false

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

          guard lines.count <= ScriptProtocol.recallLines else {
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

  /// From now on the watchdog thread reads the socket and calls `deliver` for each reply, so the
  /// VM thread waits in the mailbox instead of reading. Call it before the thread starts.
  func beginDispatching() {
    mailbox.lock()
    dispatching = true
    mailbox.unlock()
  }

  /// Hands a reply to the VM thread. The app answers one call at a time, so a reply that arrives
  /// while another waits in the slot is a protocol fault the caller reports.
  func deliver(_ message: ScriptAppMessage) -> Bool {
    mailbox.lock()
    defer { mailbox.unlock() }

    guard reply == nil else { return false }

    reply = message
    mailbox.broadcast()

    return true
  }

  /// The watchdog thread has stopped reading. A VM thread that waits for a reply stops waiting.
  func dispatcherDidEnd() {
    mailbox.lock()
    dispatcherEnded = true
    mailbox.broadcast()
    mailbox.unlock()
  }

  /// One frame from the app, for the watchdog thread.
  func readForDispatcher() throws -> ScriptAppMessage {
    try readMessage()
  }

  /// Answers the app's ping. It runs on the watchdog thread.
  func sendPong(_ nonce: UInt32) throws {
    try socket.send(ScriptHelperMessage.pong(nonce).frame())
  }

  /// Tells the app the helper's allocator is about to end the process for the cap. It runs on the VM
  /// thread, which holds no connection lock while it allocates, so taking the send lock here
  /// waits at most for the watchdog's pong. A send that fails is ignored, since the process ends
  /// next and the app then reports a lost connection.
  func sendMemoryLimitNotice() {
    try? socket.send(ScriptHelperMessage.memoryLimit.frame())
  }

  private func awaitReply() throws -> ScriptAppMessage {
    mailbox.lock()
    let useMailbox = dispatching
    mailbox.unlock()

    guard useMailbox else { return try readMessage() }

    mailbox.lock()
    defer { mailbox.unlock() }

    while reply == nil {
      if dispatcherEnded { throw WireError.closed }

      mailbox.wait()
    }

    let message = reply!

    reply = nil

    return message
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

      guard case .reply(let replyID, let result) = try awaitReply() else {
        throw WireError.badValue("the app answered a call with something else")
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
