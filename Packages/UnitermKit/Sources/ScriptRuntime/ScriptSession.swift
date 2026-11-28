import CJanet
import Darwin
import Foundation
import ScriptWire

/// Why a call to the app did not complete.
enum ScriptSessionError: Error, Equatable {
  /// The app answered the call with a failure.
  case failed(ScriptFailureKind, String)

  /// The socket belongs to another user, so the helper did not talk to it. This is a reachability
  /// failure. The app never answered.
  case foreignSocket(path: String)

  /// An interrupt cut a wait for a form short. The session discarded the form's handle and read
  /// both replies first, so nothing is left in flight.
  case interrupted
}

/// The helper's end of one connection to the app.
///
/// The helper runs one script at a time on one thread, so a call sends its request and waits for
/// its reply on that thread. Once the watchdog thread starts, it is the only reader of the socket.
/// It hands each reply to the VM thread through a mailbox keyed by request ID, answers the app's
/// ping itself, and carries out the app's stop request. A ping is therefore answered while the VM
/// thread is busy in a loop, in a long call into C, or waiting for a reply. Any thread may send,
/// since the socket's sends take a lock.
///
/// A wait for a form is the one call that can have a second call in flight. An interrupt during it
/// sends `discard-form` for the form, and both replies are then read by their IDs in whichever
/// order the app sends them.
///
/// A connection that is lost ends the helper. A script cannot go on without the app, and a script
/// that catches the error must not be able to keep running either.
final class ScriptSession: @unchecked Sendable {
  private let socket: FramedSocket
  private let lost: @Sendable (String) -> Never
  private var nextRequest: UInt32 = 1

  private let mailbox = NSCondition()
  private var replies: [UInt32: ScriptAppMessage] = [:]
  private var outstanding: Set<UInt32> = []
  private var dispatching = false
  private var dispatcherEnded = false

  /// How often a wait for a form looks for an interrupt. A signal does not wake a thread that
  /// waits on a condition, so the wait looks by itself. The look is a flag read, and the interval
  /// is the longest an interrupt waits to be seen.
  static let interruptLook: TimeInterval = 0.05

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

  /// Connects and asks the app to admit a script file that declares nothing. The command has read
  /// the file and runs it itself, so nothing of it is sent but its name and the capabilities
  /// granted. Nothing runs until the app admits it. A refusal throws
  /// `ScriptSessionError.failed`, and a run that waits for the user's review is told so once.
  static func openUndeclared(
    path: String, begin: UndeclaredBegin,
    onReview: (String) -> Void = { FileHandle.standardError.write(Data("uniterm: \($0)\n".utf8)) }
  ) throws -> ScriptSession {
    let session = try connect(path: path)

    do {
      try session.socket.send(ScriptHelperMessage.undeclaredBegin(begin).frame())

      var told = false

      while true {
        switch try session.readMessage() {
        case .undeclaredAdmitted:
          return session

        case .controllerRefused(let text):
          throw ScriptSessionError.failed(.refused, text)

        // The user may take as long as they like, so the wait has no timeout.
        case .controllerReviewing(let text) where !told:
          told = true
          onReview(text)

        default:
          throw WireError.badValue("the app answered an undeclared script with something else")
        }
      }
    } catch {
      session.close()

      throw error
    }
  }

  /// Connects and asks the app to admit a question-only session, which the bundled command opens
  /// for `uniterm ask`. The command runs no script code, so the session may make only the form
  /// calls. A refusal throws `ScriptSessionError.failed`.
  static func openQuestionOnly(path: String, quitText: String) throws -> ScriptSession {
    let session = try connect(path: path)

    session.quitText = quitText

    do {
      try session.socket.send(ScriptHelperMessage.questionBegin.frame())

      switch try session.readMessage() {
      case .questionOnlyAdmitted:
        return session

      case .controllerRefused(let text):
        throw ScriptSessionError.failed(.refused, text)

      default:
        throw WireError.badValue("the app answered a question session with something else")
      }
    } catch {
      session.close()

      throw error
    }
  }

  /// Connects and asks the app to route the files of a `uniterm open`. It returns when the app has
  /// taken the request, which says nothing about any file. A request the user did not allow throws
  /// `ScriptSessionError.failed`. A request that waits for the user is told once, and the wait has
  /// no timeout, since the user may take as long as they like.
  static func open(
    path: String, begin: OpenBegin,
    onReview: (String) -> Void = { FileHandle.standardError.write(Data("uniterm: \($0)\n".utf8)) }
  ) throws {
    let session = try connect(path: path)

    defer { session.close() }

    try session.socket.send(ScriptHelperMessage.openBegin(begin).frame())

    var told = false

    while true {
      switch try session.readMessage() {
      case .openDone:
        return

      case .controllerRefused(let text):
        throw ScriptSessionError.failed(.refused, text)

      case .controllerReviewing(let text) where !told:
        told = true
        onReview(text)

      default:
        throw WireError.badValue("the app answered an open with something else")
      }
    }
  }

  /// Connects and asks the app to admit a controller run. The app authenticates this process,
  /// verifies the package itself, and answers with the run's snapshot and the version it verified,
  /// or with a refusal, which throws `ScriptSessionError.failed`. Nothing of the package is read
  /// before that answer.
  ///
  /// A run whose powers wait for the user's review is told so once, and `onReview` shows it.
  static func openController(
    path: String, begin: ControllerBegin,
    onReview: (String) -> Void = { FileHandle.standardError.write(Data("uniterm: \($0)\n".utf8)) }
  ) throws -> (
    session: ScriptSession, snapshot: String, version: Data
  ) {
    let session = try connect(path: path)

    do {
      try session.socket.send(ScriptHelperMessage.controllerBegin(begin).frame())

      var told = false

      while true {
        switch try session.readMessage() {
        case .controllerAdmitted(let snapshot, let version):
          return (session, snapshot, version)

        case .controllerRefused(let text):
          throw ScriptSessionError.failed(.refused, text)

        // The user may take as long as they like, so the wait has no timeout. Ctrl-C ends the
        // command, and its run with it.
        case .controllerReviewing(let text) where !told:
          told = true
          onReview(text)

        default:
          throw WireError.badValue("the app answered a controller run with something else")
        }
      }
    } catch {
      session.close()

      throw error
    }
  }

  /// Connects and asks the app to admit a declared script file. The app authenticates this process,
  /// reads and copies the file itself, and answers with the copy's path and the SHA-256 of the whole
  /// file, or with a refusal, which throws `ScriptSessionError.failed`. The run is not admitted
  /// yet. The caller reads the copy, then reports what it declares with `declare`.
  static func openFile(path: String, begin: FileBegin) throws -> (
    session: ScriptSession, snapshot: String, version: Data
  ) {
    let session = try connect(path: path)

    do {
      try session.socket.send(ScriptHelperMessage.fileBegin(begin).frame())

      switch try session.readMessage() {
      case .fileAdmitted(let snapshot, let version):
        return (session, snapshot, version)

      case .controllerRefused(let text):
        throw ScriptSessionError.failed(.refused, text)

      default:
        throw WireError.badValue("the app answered a file run with something else")
      }
    } catch {
      session.close()

      throw error
    }
  }

  /// Reports what the file declares, and waits for the app's decision. A run whose powers wait for
  /// the user's review is told so once, and `onReview` shows it. The app admits the run or refuses
  /// it, and a refusal throws `ScriptSessionError.failed`.
  func declare(
    _ json: String,
    onReview: (String) -> Void = { FileHandle.standardError.write(Data("uniterm: \($0)\n".utf8)) }
  ) throws {
    try socket.send(ScriptHelperMessage.fileDeclaration(json).frame())

    var told = false

    while true {
      switch try readMessage() {
      case .controllerAdmitted:
        return

      case .controllerRefused(let text):
        throw ScriptSessionError.failed(.refused, text)

      // The user may take as long as they like, so the wait has no timeout.
      case .controllerReviewing(let text) where !told:
        told = true
        onReview(text)

      default:
        throw WireError.badValue("the app answered a declaration with something else")
      }
    }
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

      throw ScriptSessionError.foreignSocket(path: path)
    }

    let session = ScriptSession(socket: socket)

    try session.socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())

    let hello = try session.readMessage()

    try ScriptAppMessage.validateHello(hello)

    // The bundled command proves it comes from the same build as the app. It goes right after the
    // hello, before any declaration. A command that cannot read its own signature sends none, and
    // the app refuses it as one that did not present its identity.
    if let hash = CommandCodeIdentity.codeDirectoryHash() {
      try session.socket.send(ScriptHelperMessage.identity(codeDirectoryHash: hash).frame())
    }

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
      lost("the connection to uniterm failed: \(scriptWireText(error))")
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

  /// Hands a reply to the VM thread. A reply that answers no call in flight, or that repeats the
  /// ID of one already waiting, is a protocol fault the caller reports.
  func deliver(_ message: ScriptAppMessage) -> Bool {
    mailbox.lock()
    defer { mailbox.unlock() }

    guard case .reply(let id, _) = message, outstanding.contains(id), replies[id] == nil else {
      return false
    }

    replies[id] = message
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

  /// Takes the reply to `id`, which the caller sent. Without a watchdog it reads the socket itself.
  /// `interruptible` is a form wait: when an interrupt is waiting and no reply has come, it returns
  /// nil, and the reply stays owed.
  private func awaitReply(id: UInt32, interruptible: Bool = false) throws -> ScriptAppMessage? {
    mailbox.lock()
    let useMailbox = dispatching
    mailbox.unlock()

    guard useMailbox else {
      let message = try readMessage()

      mailbox.lock()
      outstanding.remove(id)
      mailbox.unlock()

      return message
    }

    mailbox.lock()
    defer { mailbox.unlock() }

    while replies[id] == nil {
      if dispatcherEnded { throw WireError.closed }

      if interruptible, uniterm_janet_interrupt_pending() != 0 { return nil }

      if interruptible {
        _ = mailbox.wait(until: Date(timeIntervalSinceNow: Self.interruptLook))
      } else {
        mailbox.wait()
      }
    }

    outstanding.remove(id)

    return replies.removeValue(forKey: id)
  }

  /// Posts a status message and waits for the app to answer.
  func postStatus(level: ScriptStatusLevel, text: String) throws {
    _ = try call(.postStatus(level: level, text: text))
  }

  func call(_ call: ScriptCall) throws -> Data {
    let id = nextRequest
    nextRequest &+= 1

    do {
      mailbox.lock()
      outstanding.insert(id)
      mailbox.unlock()

      try socket.send(ScriptHelperMessage.request(id: id, call: call).frame())

      var waited: UInt64?

      if case .waitForm(let form) = call { waited = form }

      let message = try awaitReply(id: id, interruptible: waited != nil)

      if message == nil, let form = waited {
        try discardAfterInterrupt(form: form, waitID: id)

        throw ScriptSessionError.interrupted
      }

      guard case .reply(let replyID, let result)? = message else {
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
      lost(
        "the connection to uniterm failed while the script was running: \(scriptWireText(error))")
    }
  }

  /// Discards a form's handle as a command's last act. The command already holds the answer or the
  /// reason it has none, so a connection that fails here changes nothing it reports, and nothing
  /// ends the process.
  func discardQuietly(_ form: UInt64) {
    let id = nextRequest
    nextRequest &+= 1

    mailbox.lock()
    outstanding.insert(id)
    mailbox.unlock()

    do {
      try socket.send(ScriptHelperMessage.request(id: id, call: .discardForm(form: form)).frame())

      _ = try awaitReply(id: id)
    } catch {
      return
    }
  }

  /// An interrupt reached a wait for `form`. It sends `discard-form` for the form, which fails the
  /// wait as ended, and reads both replies by their IDs, in either order. A user's answer that came
  /// at the same moment is dropped with the wait's reply, since the script is stopping.
  private func discardAfterInterrupt(form: UInt64, waitID: UInt32) throws {
    let discardID = nextRequest
    nextRequest &+= 1

    mailbox.lock()
    outstanding.insert(discardID)
    mailbox.unlock()

    try socket.send(
      ScriptHelperMessage.request(id: discardID, call: .discardForm(form: form)).frame())

    mailbox.lock()
    defer { mailbox.unlock() }

    while replies[discardID] == nil || replies[waitID] == nil {
      if dispatcherEnded { throw WireError.closed }

      mailbox.wait()
    }

    for id in [discardID, waitID] {
      outstanding.remove(id)
      replies.removeValue(forKey: id)
    }
  }

  private func readMessage() throws -> ScriptAppMessage {
    let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
  }
}
