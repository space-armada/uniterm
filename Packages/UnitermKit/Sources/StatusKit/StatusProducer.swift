import Foundation

/// What kind of non-pane producer asks for an identity.
public enum StatusProducerKind: Sendable {
  case applet
  case script
}

/// The answer to a request for a producer identity. A refusal says which of its two causes held.
public enum ProducerRequest {
  case issued(StatusProducer)

  /// No window is open to issue an identity.
  case noWindow

  /// The center already issued as many identities as its policy allows.
  case limitReached
}

/// How a host-observed driver failure ranks. The kind carries the level, so a driver never picks
/// one by matching its own text.
public enum DriverFailureKind: Sendable {
  /// Requested content is unavailable. Nothing the user made is lost.
  case contentUnavailable

  /// User work is lost.
  case workLost

  public var level: StatusLevel {
    switch self {
    case .contentUnavailable: return .warning
    case .workLost: return .error
    }
  }
}

/// A producer that is not a pane, such as a script or an applet outside any pane.
///
/// The status center issues the identity, and the producer can post only as itself. Its ID is
/// never reused, so a retired producer's records stay distinguishable from a later one with the
/// same name.
@MainActor
public final class StatusProducer {
  public let source: StatusSource
  private weak var center: StatusCenter?

  init(source: StatusSource, center: StatusCenter) {
    self.source = source
    self.center = center
  }

  public func post(level: StatusLevel, text: String) {
    center?.post(level: level, source: source, text: text)
  }

  public func record(level: StatusLevel, text: String) {
    center?.record(level: level, source: source, text: text)
  }

  /// Posts a failure the host observed. The kind sets the level.
  public func post(failure kind: DriverFailureKind, text: String) {
    post(level: kind.level, text: text)
  }

  /// Records drained stderr text. Raw stderr is info whatever it says, and it goes to the history
  /// only, with no turn on the bar. The ingress already sanitized and coalesced it. The whole batch
  /// reaches observers as one change, so a full batch costs one refresh.
  ///
  /// A driver schedules one hop to the main thread when `StderrIngress.offer` returns true. It
  /// drains and calls this on that hop. It schedules the next hop only from a later `offer` that
  /// returns true, so a sustained flood costs one hop for each drain and never one for each line.
  public func record(stderr batch: StderrBatch) {
    var entries: [(level: StatusLevel, text: String)] = batch.lines.map { line in
      (.info, line.count > 1 ? "\(line.text) (\u{00D7}\(line.count))" : line.text)
    }

    if batch.dropped > 0 {
      let noun = batch.dropped == 1 ? "line" : "lines"
      entries.append((.info, "\(batch.dropped) \(noun) of output did not fit and were dropped."))
    }

    center?.record(entries: entries, source: source)
  }

  /// Ends the identity. Its records stay in the history, and it can post no more.
  public func retire() {
    center?.retire(source)
  }

  /// A producer that is dropped without `retire` frees its slot, so forgetting is harmless.
  isolated deinit {
    center?.retire(source)
  }
}
