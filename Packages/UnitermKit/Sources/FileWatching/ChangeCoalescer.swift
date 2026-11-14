import Foundation

/// Merges a burst of change notes into one delivery.
///
/// A delivery waits until the notes have been quiet for `settle` seconds, so the last note of a
/// burst is always delivered. A burst that never goes quiet, such as a file a program rewrites all
/// the time, is delivered once every `ceiling` seconds at the most. With no `settle`, every note is
/// delivered at once.
@MainActor
public final class ChangeCoalescer {
  private let settle: Double
  private let ceiling: Double
  private let scheduler: any WatchScheduler
  private let deliver: @MainActor () -> Void
  private var firstPending: Double?
  private var timer: (any ScheduledWork)?

  /// The ceiling is raised to the settle time when it is lower, since a delivery cannot come
  /// before the quiet it waits for.
  public init(
    settle: Double, ceiling: Double, scheduler: any WatchScheduler,
    deliver: @escaping @MainActor () -> Void
  ) {
    self.settle = settle
    self.ceiling = max(ceiling, settle)
    self.scheduler = scheduler
    self.deliver = deliver
  }

  public var hasPending: Bool { firstPending != nil }

  public func note() {
    guard settle > 0 else {
      deliver()
      return
    }

    let now = scheduler.now()
    let first = firstPending ?? now
    let delay = max(0, min(settle, first + ceiling - now))

    firstPending = first
    timer?.cancel()
    timer = scheduler.schedule(after: delay) { [weak self] in self?.flush() }
  }

  public func cancel() {
    timer?.cancel()
    timer = nil
    firstPending = nil
  }

  private func flush() {
    timer = nil
    firstPending = nil
    deliver()
  }
}
