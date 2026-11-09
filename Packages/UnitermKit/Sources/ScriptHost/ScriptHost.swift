import Foundation
import ScriptWire
import StatusKit

/// The main actor's side of scripting. It answers each call a connected script makes, and never
/// waits on a peer.
///
/// A script's status messages post through a producer that this app issued, so a script never
/// posts as uniterm. The producer's name is the script's, which the user can read in the history.
@MainActor
public final class ScriptHost {
  /// Issues a script producer, or nil when no window can show one.
  public typealias ProducerIssuer = @MainActor (_ name: String) -> StatusProducer?

  /// The longest producer name shown, in characters.
  static let maxLabelLength = 64

  private struct Session {
    var name = "script"
    var producer: StatusProducer?
  }

  private let listener: ScriptListener
  private let issueProducer: ProducerIssuer
  private let windows: (any ScriptWindowAPI)?
  private let sentContent: ScriptSentContent?
  private let onRefusal: @MainActor (ScriptRefusal) -> Void
  private var sessions: [UInt64: Session] = [:]

  /// The file each pane holds from a script's send. It is the only one the pane may still read.
  private struct Held {
    var file: URL
    var size: Int
  }

  private struct PaneKey: Hashable {
    var window: UInt64
    var pane: UInt64
  }

  private var held: [PaneKey: Held] = [:]
  private var task: Task<Void, Never>?

  /// Without `windows` or `sentContent`, the calls that need them are refused.
  public init(
    listener: ScriptListener, issueProducer: @escaping ProducerIssuer,
    windows: (any ScriptWindowAPI)? = nil, sentContent: ScriptSentContent? = nil,
    onRefusal: @escaping @MainActor (ScriptRefusal) -> Void = { _ in }
  ) {
    self.listener = listener
    self.issueProducer = issueProducer
    self.windows = windows
    self.sentContent = sentContent
    self.onRefusal = onRefusal
  }

  public var socketPath: String { listener.path }

  public func start() {
    guard task == nil else { return }

    let events = listener.events

    task = Task { [weak self] in
      for await event in events {
        self?.handle(event)
      }
    }
  }

  public func stop() {
    listener.stop()
    task?.cancel()
    task = nil

    for session in sessions.values {
      session.producer?.retire()
    }

    sessions = [:]
  }

  func handle(_ event: ScriptEvent) {
    switch event {
    case .begun(let connection, let name):
      sessions[connection.id, default: Session()].name = Self.label(for: name)

    case .request(let connection, let id, let call):
      releaseFilesOfClosedPanes()

      switch call {
      case .openPane, .openTab:
        Task { @MainActor [weak self] in
          let result = await self?.runAsync(call) ?? .failure(.refused, "uniterm is quitting")

          connection.reply(id: id, result: result)
        }

      default:
        connection.reply(id: id, result: run(call, on: connection))
      }

    case .closed(let connection):
      sessions[connection.id]?.producer?.retire()
      sessions[connection.id] = nil

    case .refused(_, let refusal):
      onRefusal(refusal)
    }
  }

  private func run(_ call: ScriptCall, on connection: ScriptConnection) -> ScriptResult {
    switch call {
    case .postStatus(let level, let text):
      guard let producer = producer(for: connection) else {
        return .failure(.refused, "uniterm has no window to show the message")
      }

      producer.post(level: Self.level(level), text: text)

      return .ok(Data())

    case .listWindows:
      return answer { try requireWindows().listWindows() }

    case .listPanes(let window):
      return answer { try requireWindows().listPanes(window: window) }

    case .openPane, .openTab:
      return .failure(.failed, "the call needs to wait, and was run as if it did not")

    case .send(let pane, let name, let content):
      return answer { try send(content, named: name, to: pane) }
    }
  }

  /// The calls that check a directory run off the main actor and answer later.
  private func runAsync(_ call: ScriptCall) async -> ScriptResult {
    do {
      switch call {
      case .openPane(let kind, let beside, let axis, let directory):
        return Self.result(
          of: try await requireWindows().openPane(
            kind: kind, beside: beside, axis: axis, directory: directory))

      case .openTab(let pane, let directory):
        return Self.result(
          of: try await requireWindows().openTab(pane: pane, directory: directory))

      default:
        return .failure(.failed, "the call does not wait")
      }
    } catch {
      return Self.failure(error)
    }
  }

  private func requireWindows() throws -> any ScriptWindowAPI {
    guard let windows else { throw ScriptCallError.refused("uniterm has no windows to script") }

    return windows
  }

  /// Checks the pane first, so a refused send writes nothing. A file the pane did not take is
  /// removed at once.
  ///
  /// The check and the send run with no suspension between them, so the pane cannot change in
  /// between. The pane's previous file is the pane's no more once it takes this one.
  private func send(_ content: Data, named name: String, to pane: ScriptPaneReference) throws
    -> ScriptValue
  {
    let windows = try requireWindows()

    guard let sentContent else { throw ScriptCallError.refused("uniterm cannot hold content") }

    try ScriptSentContent.checkName(name)
    try windows.prepareSend(to: pane)

    // At most 1 MiB, a known size, so ADR-08 lets this write run on the main actor.
    let file = try sentContent.write(content, named: name)
    let reply: ScriptValue

    do {
      reply = try windows.send(to: pane, file: file)
    } catch {
      sentContent.discard(file, size: content.count)

      throw error
    }

    let key = PaneKey(window: pane.window, pane: pane.pane)

    if let previous = held.updateValue(Held(file: file, size: content.count), forKey: key) {
      sentContent.discard(previous.file, size: previous.size)
    }

    return reply
  }

  /// Removes the file of each pane that has closed, and gives its bytes back. A pane that is open
  /// keeps its last file, since the pane may still read it.
  private func releaseFilesOfClosedPanes() {
    guard let windows, let sentContent else { return }

    for (key, file) in held
    where !windows.isOpen(ScriptPaneReference(window: key.window, pane: key.pane)) {
      sentContent.discard(file.file, size: file.size)
      held[key] = nil
    }
  }

  /// Runs a function and turns what it returns, or throws, into the call's reply.
  private func answer(_ body: () throws -> ScriptValue) -> ScriptResult {
    do {
      return Self.result(of: try body())
    } catch {
      return Self.failure(error)
    }
  }

  /// A reply the frame cannot hold becomes a failure the script sees.
  private static func result(of value: ScriptValue) -> ScriptResult {
    do {
      let payload = try value.encoded()

      guard payload.count <= ScriptProtocol.maxReplyPayload else {
        return .failure(.failed, "the answer is too large for one reply")
      }

      return .ok(payload)
    } catch {
      return .failure(.failed, "the answer could not be sent: \(error)")
    }
  }

  private static func failure(_ error: any Error) -> ScriptResult {
    guard let error = error as? ScriptCallError else {
      return .failure(.failed, "the call failed: \(error)")
    }

    return .failure(error.kind, error.text)
  }

  private func producer(for connection: ScriptConnection) -> StatusProducer? {
    var session = sessions[connection.id, default: Session()]

    if session.producer == nil {
      session.producer = issueProducer(session.name)
      sessions[connection.id] = session
    }

    return session.producer
  }

  private static func level(_ level: ScriptStatusLevel) -> StatusLevel {
    switch level {
    case .info: return .info
    case .warning: return .warning
    case .error: return .error
    }
  }

  /// The script names its own label, so the label is cleaned like any text from outside.
  static func label(for name: String) -> String {
    let printable = name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
    let cleaned = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)

    guard !cleaned.isEmpty else { return "script" }

    return String(cleaned.prefix(maxLabelLength))
  }
}
