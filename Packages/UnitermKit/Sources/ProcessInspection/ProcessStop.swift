import Darwin
import Foundation

extension ProcessInspection {
  /// True while the process is stopped, as a shell's Ctrl-Z or a `SIGSTOP` leaves it. Returns nil
  /// when the process does not exist, has exited, or the system refuses the query.
  ///
  /// A process a debugger holds at a breakpoint is not stopped in this sense. Its task is
  /// suspended and its state stays running, so it reads false.
  public static func isStopped(pid: pid_t) -> Bool? {
    guard let info = record(of: pid) else { return nil }

    return info.kp_proc.p_stat == CChar(SSTOP)
  }

  /// The same read, for the process that started at `startedMicroseconds`. A pid that another
  /// process took reads as nil.
  public static func isStopped(pid: pid_t, startedMicroseconds: Int) -> Bool? {
    guard startTimeMicroseconds(of: pid) == startedMicroseconds else { return nil }

    return isStopped(pid: pid)
  }

  /// The process group the process leads or belongs to. Returns nil when the process does not
  /// exist or the system refuses the query.
  public static func processGroup(of pid: pid_t) -> pid_t? {
    let group = getpgid(pid)

    return group > 0 ? group : nil
  }

  /// True when sending a signal to the group `pid` leads could reach only that process and what it
  /// started. The process must lead a group named by its own pid, and that group must not be the
  /// caller's.
  ///
  /// A group stop sent to the caller's own group stops the app. A group the process only belongs
  /// to is shared with other programs. Neither is ever signalled.
  public static func leadsItsOwnGroup(_ pid: pid_t) -> Bool {
    guard pid > 1, let group = processGroup(of: pid) else { return false }

    return group == pid && group != getpgrp()
  }

  /// Sends signal `number` to the process group that `pid` leads, only while `pid` is still the
  /// process that started at `startedMicroseconds`.
  ///
  /// The leader is a process uniterm started, such as the child a terminal session spawned. A
  /// helper that program starts is a member of the leader's group, and not its leader, since the
  /// terminal's login stays the parent and the group's leader. So the caller names the `member` it
  /// means to reach, and the group must be the member's own. A member of any other group is refused.
  ///
  /// A leader that leads no group of its own, or whose group is the caller's, is refused and
  /// nothing is sent. The system does not hand out a process ID that names a live group, so a signal
  /// to a group whose leader has left reaches only the old group.
  public static func signalGroup(
    _ number: Int32, leader pid: pid_t, startedMicroseconds: Int, member: pid_t? = nil
  ) -> SignalResult {
    guard pid > 1, pid != getpid() else { return .refused }

    guard startTimeMicroseconds(of: pid) == startedMicroseconds else { return .gone }

    guard leadsItsOwnGroup(pid) else { return .refused }

    if let member {
      guard member > 1, member != getpid(), processGroup(of: member) == pid else {
        return .refused
      }
    }

    guard killpg(pid, number) == 0 else { return errno == ESRCH ? .gone : .unreached }

    return .byPid
  }
}

/// What the app knows of a controller process it may suspend: whether the process is stopped, and
/// whether uniterm is the one that stopped it.
///
/// The process's observed state is the truth. The record only says which stops uniterm made, so
/// that "Resume All" continues those and nothing else, and a continue from outside clears it.
public struct SuspensionState: Equatable, Sendable {
  /// True while the process reads as stopped, whoever stopped it.
  public private(set) var isStopped = false

  /// True from the moment uniterm signals a stop until the process is seen running again.
  public private(set) var madeByUniterm = false

  /// True from the moment uniterm signals a continue until the process is seen running. The process
  /// still reads as stopped meanwhile, and a second Resume must not go out for it.
  private var continuePending = false

  public init() {}

  /// A stop shows as suspended whoever made it.
  public var isSuspended: Bool { isStopped }

  /// True when uniterm's own stop holds. The window's slot counts only these.
  public var isSuspendedByUniterm: Bool { isStopped && madeByUniterm }

  /// True when a Resume has something to continue: a stop that is seen and not yet answered with a
  /// continue, or a stop uniterm just sent. It follows uniterm's intent while a change is pending,
  /// so a key pressed twice quickly toggles twice.
  public var canResume: Bool { (isStopped && !continuePending) || madeByUniterm }

  /// Records that uniterm sent a stop. The observed state follows on its own.
  public mutating func stopSent() {
    madeByUniterm = true
    continuePending = false
  }

  /// Records that uniterm sent a continue.
  public mutating func continueSent() {
    madeByUniterm = false
    continuePending = true
  }

  /// Takes one settled reading of the process. Returns true when the state shown changed.
  ///
  /// A reading of running after a stop was seen is a continue, and uniterm's record of its own
  /// stop goes with it. A reading of running before any stop was seen changes nothing, since uniterm's
  /// stop may not have landed yet.
  @discardableResult
  public mutating func observe(stopped: Bool) -> Bool {
    let changed = stopped != isStopped

    if !stopped && isStopped { madeByUniterm = false }

    if !stopped { continuePending = false }

    isStopped = stopped

    return changed
  }
}
