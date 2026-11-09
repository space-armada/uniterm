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
  private let onRefusal: @MainActor (ScriptRefusal) -> Void
  private var sessions: [UInt64: Session] = [:]
  private var task: Task<Void, Never>?

  public init(
    listener: ScriptListener, issueProducer: @escaping ProducerIssuer,
    onRefusal: @escaping @MainActor (ScriptRefusal) -> Void = { _ in }
  ) {
    self.listener = listener
    self.issueProducer = issueProducer
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
      connection.reply(id: id, result: run(call, on: connection))

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
    }
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
