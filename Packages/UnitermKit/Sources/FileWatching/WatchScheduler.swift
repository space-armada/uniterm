import Foundation

/// Work that a scheduler has not run yet.
public protocol ScheduledWork: AnyObject {
  func cancel()
}

/// The clock and the timers a watcher uses. A test supplies one that it advances by hand, so no
/// test waits in real time for a coalescing window.
@MainActor
public protocol WatchScheduler: AnyObject {
  /// Seconds on a clock that never goes back.
  func now() -> Double

  /// Runs `work` on the main actor after `delay` seconds.
  func schedule(after delay: Double, _ work: @escaping @MainActor () -> Void) -> any ScheduledWork
}

/// The real clock and the main queue.
@MainActor
public final class DispatchWatchScheduler: WatchScheduler {
  private final class Item: ScheduledWork {
    var item: DispatchWorkItem?

    func cancel() {
      item?.cancel()
      item = nil
    }
  }

  public init() {}

  public func now() -> Double {
    ProcessInfo.processInfo.systemUptime
  }

  public func schedule(after delay: Double, _ work: @escaping @MainActor () -> Void)
    -> any ScheduledWork
  {
    let handle = Item()
    let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }

    handle.item = item
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)

    return handle
  }
}
