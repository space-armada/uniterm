import FileWatching

/// A clock a test advances by hand. Timers run in order of their due time as the clock passes them.
@MainActor
final class ManualScheduler: WatchScheduler {
  private final class Timer: ScheduledWork {
    let due: Double
    var work: (@MainActor () -> Void)?

    init(due: Double, work: @escaping @MainActor () -> Void) {
      self.due = due
      self.work = work
    }

    func cancel() { work = nil }
  }

  private var time = 0.0
  private var timers: [Timer] = []

  /// How many times work was scheduled, which is how many times a coalescer was noted.
  private(set) var scheduled = 0

  /// Called after each `schedule`, so a test awaits a note without a timeout for its absence.
  var onSchedule: (@MainActor () -> Void)?

  func now() -> Double { time }

  func schedule(after delay: Double, _ work: @escaping @MainActor () -> Void) -> any ScheduledWork {
    let timer = Timer(due: time + delay, work: work)
    timers.append(timer)
    scheduled += 1
    onSchedule?()

    return timer
  }

  func advance(by seconds: Double) {
    let target = time + seconds

    while let next = timers.filter({ $0.work != nil && $0.due <= target }).min(by: {
      $0.due < $1.due
    }) {
      time = max(time, next.due)
      timers.removeAll { $0 === next }

      let work = next.work
      next.work = nil
      work?()
    }

    time = target
  }
}
