import Foundation

/// Reads the time for a status center. Tests inject a fake.
public protocol StatusClock: Sendable {
  var now: TimeInterval { get }
}

public struct SystemStatusClock: StatusClock {
  public init() {}

  public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Runs an action after a delay and returns a closure that cancels it.
public typealias StatusScheduler =
  @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) ->
  @MainActor () ->
  Void

/// The window's message queue. It owns a `StatusQueue`, reads the clock, and wakes itself when the
/// model has something to do.
@MainActor
public final class StatusCenter {
  public private(set) var queue: StatusQueue

  private let clock: any StatusClock
  private let scheduler: StatusScheduler
  private var cancelWake: (@MainActor () -> Void)?
  private var observers: [UUID: @MainActor () -> Void] = [:]
  private var issued: [UInt64: StatusProducerKind] = [:]
  private var nextProducerID: UInt64 = 1

  public init(
    policy: StatusPolicy = .standard,
    clock: any StatusClock = SystemStatusClock(),
    scheduler: @escaping StatusScheduler = StatusCenter.defaultScheduler
  ) {
    self.queue = StatusQueue(policy: policy)
    self.clock = clock
    self.scheduler = scheduler
  }

  public static let defaultScheduler: StatusScheduler = { delay, action in
    let task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }

      action()
    }
    return { task.cancel() }
  }

  public var display: StatusDisplay? { queue.current }
  public var history: [StatusMessage] { queue.history }
  public var loss: RetentionLoss { queue.loss }
  public var hasUnseenError: Bool { queue.hasUnseenError }
  public var hasUnseenWarning: Bool { queue.hasUnseenWarning }

  /// Posts as the host. The host's own messages carry the `uniterm` identity.
  public func post(level: StatusLevel, text: String) {
    post(level: level, source: .uniterm, text: text)
  }

  /// Posts for a source. Pane and host sources are the host's to name, so this is package-only.
  /// An applet or script source posts only with an ID this center issued, of that kind, and has
  /// not retired.
  /// Returns false when the post was refused.
  @discardableResult
  package func post(level: StatusLevel, source: StatusSource, text: String) -> Bool {
    guard isAllowed(source) else { return false }

    queue.post(level: level, source: source, text: text, at: clock.now)
    didChange()
    return true
  }

  /// Records a message in the history without showing it. See `StatusQueue.record`.
  @discardableResult
  package func record(level: StatusLevel, source: StatusSource, text: String) -> Bool {
    guard isAllowed(source) else { return false }

    queue.record(level: level, source: source, text: text, at: clock.now)
    didChange()
    return true
  }

  /// Delivers a message the way `delivery` says, and admits a new history record for it. Returns
  /// the record's ID, or nil when the source was refused.
  @discardableResult
  package func deliver(
    _ delivery: StatusDelivery, level: StatusLevel, source: StatusSource, text: String
  ) -> StatusRecordID? {
    guard isAllowed(source) else { return nil }

    let id: StatusRecordID

    switch delivery {
    case .message:
      id = queue.post(level: level, source: source, text: text, at: clock.now).id

    case .attention:
      id =
        queue.record(
          level: level, source: source, text: text, raisesSignal: true, at: clock.now
        ).id

    case .historyOnly:
      id = queue.record(level: level, source: source, text: text, at: clock.now).id
    }

    didChange()
    return id
  }

  /// Records several messages in the history, and tells observers once. Returns false when the
  /// source was refused.
  @discardableResult
  package func record(
    entries: [(level: StatusLevel, text: String)], source: StatusSource
  ) -> Bool {
    guard isAllowed(source) else { return false }
    guard !entries.isEmpty else { return true }

    for entry in entries {
      queue.record(level: entry.level, source: source, text: entry.text, at: clock.now)
    }

    didChange()
    return true
  }

  /// Issues an identity to a producer that is not a pane. Equal names never share one. Returns
  /// nil at the policy's producer limit, until one retires.
  public func issueProducer(kind: StatusProducerKind, name: String) -> StatusProducer? {
    guard issued.count < queue.policy.producerLimit else { return nil }

    let id = nextProducerID
    nextProducerID += 1

    let source: StatusSource =
      switch kind {
      case .applet: .applet(id: id, name: name)
      case .script: .script(id: id, name: name)
      }

    issued[id] = kind
    return StatusProducer(source: source, center: self)
  }

  /// Frees the slot of a producer. Ending the identity is idempotent.
  func retire(_ source: StatusSource) {
    switch source {
    case .applet(let id, _), .script(let id, _): issued[id] = nil
    case .pane, .uniterm: break
    }
  }

  private func isAllowed(_ source: StatusSource) -> Bool {
    switch source {
    case .applet(let id, _): return issued[id] == .applet
    case .script(let id, _): return issued[id] == .script
    case .pane, .uniterm: return true
    }
  }

  public func dismissCurrent() {
    if queue.dismissCurrent(at: clock.now) {
      didChange()
    }
  }

  /// A pane closed. Its queued messages leave the bar and stay in the history.
  public func paneClosed(id: UInt64) {
    if queue.removePending(fromPane: id) {
      didChange()
    }
  }

  /// Acknowledges the records the history showed the user. See `StatusQueue.acknowledge`.
  public func acknowledge(ids: some Sequence<UInt64>) {
    if queue.acknowledge(ids: ids) {
      didChange()
    }
  }

  /// Acknowledges what retention dropped. See `StatusQueue.acknowledgeLoss`.
  public func acknowledgeLoss() {
    if queue.acknowledgeLoss() {
      didChange()
    }
  }

  @discardableResult
  public func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    observers[id] = handler
    return id
  }

  public func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  private func wake() {
    cancelWake = nil
    queue.advance(at: clock.now)
    didChange()
  }

  private func didChange() {
    cancelWake?()
    cancelWake = nil

    if let deadline = queue.nextWake() {
      let delay = max(0, deadline - clock.now)
      cancelWake = scheduler(delay) { [weak self] in self?.wake() }
    }

    for handler in observers.values {
      handler()
    }
  }
}
