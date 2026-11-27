import Foundation

/// The pure model behind the status bar message area.
///
/// Every method takes the current time, so a test drives it with a fake clock. The queue never
/// reads a clock itself.
public struct StatusQueue: Sendable {
  private struct Pending: Sendable {
    var message: StatusMessage

    /// Older errors folded into this one, oldest first. They are kept whole, so a pane close can
    /// give back the ones that did not come from the closing pane.
    var folded: [StatusMessage]

    /// Folded errors that left `folded` to stay within its bounds. They are only counted.
    var foldedLost = 0

    var collapsed: Int { folded.count + foldedLost }
  }

  /// The two retention pools. An info or warning flood can never reach the error pool.
  private enum Pool: Hashable, Sendable {
    case errors
    case others

    init(_ level: StatusLevel) {
      self = level == .error ? .errors : .others
    }
  }

  public let policy: StatusPolicy

  public private(set) var current: StatusDisplay?

  /// Every retained record, oldest first.
  public private(set) var history: [StatusMessage] = []

  /// What retention has dropped, with the unseen counts the dropped records held.
  public private(set) var loss = RetentionLoss()

  private var unseenErrors: Set<UInt64> = []
  private var unseenWarnings: Set<UInt64> = []
  private var poolCounts: [Pool: Int] = [:]
  private var poolBytes: [Pool: Int] = [:]
  private var sourceIndex: [Pool: [StatusSourceKey: Int]] = [:]
  private var pending: [Pending] = []
  private var shownAt: TimeInterval = 0
  private var nextID: UInt64 = 1

  public init(policy: StatusPolicy = .standard) {
    self.policy = policy
  }

  public var pendingCount: Int { pending.count }

  /// The folded errors held whole across the waiting messages. Tests read it.
  var foldedStoredCount: Int { pending.reduce(0) { $0 + $1.folded.count } }

  /// The sources the retention index tracks, summed over both pools.
  var indexedSourceCount: Int { sourceIndex.values.reduce(0) { $0 + $1.count } }

  /// The bytes the retained history costs.
  var historyBytes: Int { poolBytes.values.reduce(0, +) }

  /// True while an error that has not been acknowledged is retained, or was lost to retention.
  public var hasUnseenError: Bool { !unseenErrors.isEmpty || loss.unseenErrors > 0 }

  /// True while a warning that has not been acknowledged is retained, or was lost to retention.
  public var hasUnseenWarning: Bool { !unseenWarnings.isEmpty || loss.unseenWarnings > 0 }

  public var unseenErrorCount: Int { unseenErrors.count + loss.unseenErrors }
  public var unseenWarningCount: Int { unseenWarnings.count + loss.unseenWarnings }

  /// The IDs of the retained records that have not been acknowledged.
  public var unseenIDs: Set<UInt64> { unseenErrors.union(unseenWarnings) }

  /// Posts a message. Its presentation coalesces into one already on the bar or waiting when the
  /// source, level, and text all match. The history gets the record either way, and a repeat never
  /// restarts the dwell of the one on the bar.
  @discardableResult
  public mutating func post(
    level: StatusLevel, source: StatusSource, text: String, at now: TimeInterval
  ) -> StatusMessage {
    advance(at: now)

    let source = source.boundingLabel(to: policy.maximumLabelBytes)
    let text = StatusText.bounded(text, maximumBytes: policy.maximumTextBytes)
    let repeated = isPresented(level: level, key: source.key, text: text)
    let message = admit(level: level, source: source, text: text, at: now, raisesSignal: true)

    guard !repeated else { return message }

    pending.append(Pending(message: message, folded: []))
    boundPending()
    advance(at: now)
    return message
  }

  /// Admits a message to the history only. It takes no turn on the bar. It raises no unseen signal
  /// unless `raisesSignal` says so. An applet records quietly when its own pane already says the
  /// same thing, or when it cannot be seen. It raises the signal for a warning that restore
  /// recorded while the pane is on screen.
  @discardableResult
  public mutating func record(
    level: StatusLevel, source: StatusSource, text: String, raisesSignal: Bool = false,
    at now: TimeInterval
  ) -> StatusMessage {
    admit(
      level: level, source: source.boundingLabel(to: policy.maximumLabelBytes),
      text: StatusText.bounded(text, maximumBytes: policy.maximumTextBytes), at: now,
      raisesSignal: raisesSignal)
  }

  /// Applies whatever the passage of time allows. Returns true when the displayed message changed.
  @discardableResult
  public mutating func advance(at now: TimeInterval) -> Bool {
    guard let shown = current else {
      guard !pending.isEmpty else { return false }

      show(at: now)
      return true
    }

    let elapsed = now - shownAt

    if !pending.isEmpty {
      guard elapsed >= policy.minimumDwell else { return false }

      show(at: now)
      return true
    }

    if shown.message.level != .error, elapsed >= policy.idleTimeout {
      current = nil
      return true
    }

    return false
  }

  /// Clears an error that is on the bar. Returns true when something was cleared.
  @discardableResult
  public mutating func dismissCurrent(at now: TimeInterval) -> Bool {
    guard let shown = current, shown.message.level == .error else { return false }

    current = nil
    advance(at: now)
    return true
  }

  /// Drops the queued messages that a closed pane posted. They stay in the history. A message of
  /// that pane that is already on the bar stays until its normal turn ends, since the user may
  /// not have read it yet. Returns true when something left the queue.
  ///
  /// Errors from other sources that were folded into a dropped error are queued again, so the
  /// close never hides an error from a pane that is still open. They fold again when
  /// they outgrow the waiting bounds.
  @discardableResult
  public mutating func removePending(fromPane id: UInt64) -> Bool {
    var changed = false
    var kept: [Pending] = []

    for entry in pending {
      let survivors = entry.folded.filter { $0.source.paneID != id }

      if entry.message.source.paneID == id {
        changed = true
        kept += survivors.map { Pending(message: $0, folded: []) }
      } else if survivors.count != entry.folded.count {
        changed = true
        var trimmed = entry
        trimmed.folded = survivors
        kept.append(trimmed)
      } else {
        kept.append(entry)
      }
    }

    pending = kept
    boundPending()
    return changed
  }

  /// Acknowledges the records the user was shown. Returns true when an unseen record cleared.
  /// Records outside `ids` stay unseen, and so does the loss summary.
  @discardableResult
  public mutating func acknowledge(ids: some Sequence<UInt64>) -> Bool {
    var changed = false

    for id in ids {
      if unseenErrors.remove(id) != nil { changed = true }
      if unseenWarnings.remove(id) != nil { changed = true }
    }

    return changed
  }

  /// Acknowledges what retention dropped. Only the loss summary's own control calls it.
  @discardableResult
  public mutating func acknowledgeLoss() -> Bool {
    guard loss.unseenErrors > 0 || loss.unseenWarnings > 0 else { return false }

    loss.unseenErrors = 0
    loss.unseenWarnings = 0
    return true
  }

  /// The retained records of one pane, oldest first.
  public func history(forPane id: UInt64) -> [StatusMessage] {
    history.filter { $0.source.paneID == id }
  }

  /// The panes that have retained rows, in pane order. A pane's name is its newest row's.
  public func historyPanes() -> [HistoryPane] {
    var names: [UInt64: String] = [:]

    for message in history {
      if let id = message.source.paneID {
        names[id] = message.source.label
      }
    }

    return names.keys.sorted().map { HistoryPane(id: $0, name: names[$0] ?? "") }
  }

  /// The time at which `advance` next has something to do, or nil when nothing is scheduled.
  public func nextWake() -> TimeInterval? {
    guard let shown = current else { return nil }

    if !pending.isEmpty {
      return shownAt + policy.minimumDwell
    }

    if shown.message.level != .error {
      return shownAt + policy.idleTimeout
    }

    return nil
  }

  private func isPresented(level: StatusLevel, key: StatusSourceKey, text: String) -> Bool {
    func matches(_ message: StatusMessage) -> Bool {
      message.level == level && message.source.key == key && message.text == text
    }

    if let shown = current, matches(shown.message) { return true }

    return pending.contains { matches($0.message) || $0.folded.contains(where: matches) }
  }

  private mutating func admit(
    level: StatusLevel, source: StatusSource, text: String, at now: TimeInterval,
    raisesSignal: Bool
  ) -> StatusMessage {
    let message = StatusMessage(
      id: nextID, level: level, source: source, text: text, postedAt: now)
    nextID += 1

    history.append(message)

    let pool = Pool(level)
    poolCounts[pool, default: 0] += 1
    poolBytes[pool, default: 0] += message.storageBytes
    sourceIndex[pool, default: [:]][source.key, default: 0] += 1

    if raisesSignal { markUnseen(id: message.id, level: level) }

    trim()
    return message
  }

  private mutating func markUnseen(id: UInt64, level: StatusLevel) {
    let retained = history.contains { $0.id == id }

    switch level {
    case .error:
      if retained { unseenErrors.insert(id) } else { loss.unseenErrors += 1 }

    case .warning:
      if retained { unseenWarnings.insert(id) } else { loss.unseenWarnings += 1 }

    case .info:
      break
    }
  }

  /// Holds each pool to its count and byte limits. A full pool drops the oldest record of its most
  /// represented source, so a chatty source gives up its own rows first. Of equal sources, the one
  /// with the oldest row goes first. What was dropped moves into the loss summary, unseen counts
  /// included.
  private mutating func trim() {
    for pool in [Pool.errors, .others] {
      let (countLimit, byteLimit) =
        pool == .errors
        ? (policy.errorHistoryLimit, policy.errorHistoryBytes)
        : (policy.otherHistoryLimit, policy.otherHistoryBytes)

      while poolCounts[pool, default: 0] > countLimit || poolBytes[pool, default: 0] > byteLimit {
        guard evictOldest(from: pool) else { break }
      }
    }
  }

  private mutating func evictOldest(from pool: Pool) -> Bool {
    let counts = sourceIndex[pool] ?? [:]

    guard let most = counts.values.max(),
      let index = history.firstIndex(where: {
        Pool($0.level) == pool && counts[$0.source.key] == most
      })
    else { return false }

    let dropped = history.remove(at: index)

    poolCounts[pool, default: 0] -= 1
    poolBytes[pool, default: 0] -= dropped.storageBytes

    let key = dropped.source.key
    let left = (sourceIndex[pool]?[key] ?? 1) - 1
    sourceIndex[pool]?[key] = left > 0 ? left : nil

    if unseenErrors.remove(dropped.id) != nil { loss.unseenErrors += 1 }
    if unseenWarnings.remove(dropped.id) != nil { loss.unseenWarnings += 1 }

    if pool == .errors { loss.errors += 1 } else { loss.others += 1 }
    return true
  }

  private mutating func show(at now: TimeInterval) {
    normalizePending()

    let next = pending.removeFirst()
    current = StatusDisplay(message: next.message, collapsedErrors: next.collapsed)
    shownAt = now
  }

  /// Folds a backlog early when the waiting messages outgrow their count or byte bound.
  private mutating func boundPending() {
    let bytes = pending.reduce(0) { $0 + $1.message.storageBytes }

    if pending.count > policy.pendingLimit || bytes > policy.pendingBytes {
      normalizePending(force: true)
    }
  }

  /// Folds a backlog of errors into the newest one, then skips older non-error messages when the
  /// backlog is long. An error is never dropped, only counted. The fold has its own bounds, and an
  /// error that leaves it stays counted.
  private mutating func normalizePending(force: Bool = false) {
    let errorIndexes = pending.indices.filter { pending[$0].message.level == .error }

    if errorIndexes.count > 1, let newest = errorIndexes.last {
      for index in errorIndexes.dropLast() {
        pending[newest].folded += pending[index].folded + [pending[index].message]
        pending[newest].foldedLost += pending[index].foldedLost
      }

      Self.trimFolded(&pending[newest], policy: policy)

      let older = Set(errorIndexes.dropLast())
      pending = pending.enumerated().filter { !older.contains($0.offset) }.map(\.element)
    }

    if force || pending.count > policy.backlogLimit {
      guard pending.count > 1 else { return }

      let lastIndex = pending.count - 1
      pending = pending.enumerated().filter {
        $0.element.message.level == .error || $0.offset == lastIndex
      }.map(\.element)
    }
  }

  private static func trimFolded(_ entry: inout Pending, policy: StatusPolicy) {
    var bytes = entry.folded.reduce(0) { $0 + $1.storageBytes }

    while entry.folded.count > policy.foldedLimit || bytes > policy.foldedBytes {
      guard !entry.folded.isEmpty else { return }

      bytes -= entry.folded.removeFirst().storageBytes
      entry.foldedLost += 1
    }
  }
}
