import Darwin
import Dispatch
import Foundation

/// Watches one process for the moment it stops or continues, and reports its settled state.
///
/// A kqueue process source fires on every signal the process gets, and it never says which. So a
/// notice only starts a read. The watcher reads the state again after a short delay, until two
/// readable readings in a row agree. A single read right after the notice can find the state
/// unreadable while a signal is pending, or not yet changed, so it is never trusted alone.
///
/// The watcher reports a change only. It reports nothing for a process that is gone.
@MainActor
public final class ProcessStopWatcher {
  public typealias Reader = @Sendable (pid_t, Int) -> Bool?

  private let pid: pid_t
  private let started: Int
  private let settleDelay: Duration
  private let maximumReads: Int
  private let read: Reader
  private let onChange: @MainActor (Bool) -> Void

  private var source: (any DispatchSourceProcess)?
  private var pending: Task<Void, Never>?
  private var reported = false

  /// How many settle passes have finished, so a test waits for one and never for a delay.
  public private(set) var settles = 0

  /// `read` answers whether the process the pid and start time name is stopped, and nil when it
  /// is gone or unreadable. The default reads the system.
  public init(
    pid: pid_t, startedMicroseconds: Int, settleDelay: Duration = .milliseconds(25),
    maximumReads: Int = 12,
    read: @escaping Reader = { ProcessInspection.isStopped(pid: $0, startedMicroseconds: $1) },
    onChange: @escaping @MainActor (Bool) -> Void
  ) {
    self.pid = pid
    started = startedMicroseconds
    self.settleDelay = settleDelay
    self.maximumReads = maximumReads
    self.read = read
    self.onChange = onChange
  }

  /// Starts watching, and reads the state once, since a stop that came before the watch raised no
  /// notice.
  public func start() {
    guard source == nil else { return }

    let watch = DispatchSource.makeProcessSource(
      identifier: pid, eventMask: [.signal, .exit], queue: .main)

    watch.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.settle() }
    }

    source = watch
    watch.activate()

    settle()
  }

  /// Reads the state again until it settles. A caller that signals the process asks for this
  /// right after, so the display does not wait for the notice.
  public func settle() {
    guard source != nil else { return }

    pending?.cancel()

    let pid = pid
    let started = started
    let delay = settleDelay
    let reads = maximumReads
    let read = read

    pending = Task { @MainActor [weak self] in
      var previous: Bool?

      for attempt in 0..<reads {
        if attempt > 0 {
          try? await Task.sleep(for: delay)

          guard !Task.isCancelled else { return }
        }

        guard let now = read(pid, started) else { continue }

        if now == previous {
          self?.report(now)

          return
        }

        previous = now
      }

      self?.finishedUnsettled()
    }
  }

  /// Stops watching. Nothing is reported afterwards.
  public func cancel() {
    pending?.cancel()
    pending = nil
    source?.cancel()
    source = nil
  }

  private func report(_ stopped: Bool) {
    settles += 1

    guard stopped != reported else { return }

    reported = stopped
    onChange(stopped)
  }

  private func finishedUnsettled() {
    settles += 1
  }
}
