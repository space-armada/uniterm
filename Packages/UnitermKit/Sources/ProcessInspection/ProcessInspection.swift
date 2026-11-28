import Darwin
import Foundation

/// Reads process information from the system, and signals a process only while it is the one a
/// caller recorded. It has no dependencies, so any module can use it.
///
/// `proc_pidinfo` refuses a setuid-root process, such as the `/usr/bin/login` that libghostty
/// spawns, for a caller that is not root. `sysctl(KERN_PROC_PID)` reads it.
public enum ProcessInspection {
  /// The start time of the given process, in seconds since epoch. Returns nil when the process
  /// does not exist, has exited, or the system refuses the query.
  public static func startTime(of pid: pid_t) -> Int? {
    guard let info = record(of: pid) else { return nil }

    return Int(info.kp_proc.p_starttime.tv_sec)
  }

  /// The start time of the given process, in microseconds since epoch. Returns nil when the process
  /// does not exist, has exited, or the system refuses the query.
  ///
  /// A later process that takes a freed pid starts later, unless the system clock was set back in
  /// between. So a pid and this time name one process. An exec keeps both.
  public static func startTimeMicroseconds(of pid: pid_t) -> Int? {
    guard let info = record(of: pid) else { return nil }

    let started = info.kp_proc.p_starttime

    return Int(started.tv_sec) * 1_000_000 + Int(started.tv_usec)
  }

  /// The parent PID and start time of the given process. Returns nil when the process does not
  /// exist, has no parent, or the system refuses the query.
  public static func parent(of pid: pid_t) -> (pid: pid_t, started: Int)? {
    guard let info = record(of: pid) else { return nil }

    let parentPid = info.kp_eproc.e_ppid

    guard parentPid > 0 else { return nil }

    guard let started = startTime(of: parentPid) else { return nil }

    return (pid: parentPid, started: started)
  }

  /// True when a process with the given ID and start time is running.
  public static func isRunning(pid: pid_t, started: Int) -> Bool {
    guard let actual = startTime(of: pid) else { return false }

    return actual == started
  }

  /// The executable path of the given process. Returns nil when the process does not exist or the
  /// system refuses the query.
  public static func executablePath(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))

    guard length > 0 else { return nil }

    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }

  /// The name the kernel keeps for the given process, which is the last component of the path it
  /// ran, cut to the kernel's limit. Returns nil when the process does not exist.
  public static func name(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 256)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))

    guard length > 0 else { return nil }

    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }

  /// The direct children of the given process that are alive now. A child that exits or forks
  /// while this runs may be missing or new by the time the caller looks at it.
  public static func children(of pid: pid_t) -> [pid_t] {
    var capacity = 64

    while true {
      var buffer = [pid_t](repeating: 0, count: capacity)

      // The call returns a count of PIDs, not bytes.
      let count = Int(proc_listchildpids(pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size)))

      guard count > 0 else { return [] }

      if count < capacity { return buffer.prefix(count).filter { $0 > 0 } }

      capacity *= 2
    }
  }

  /// The kernel's record of a live process. For a PID that does not exist, sysctl succeeds but
  /// returns no bytes, so the size and the PID are both checked.
  ///
  /// A zombie has exited and only waits for its parent to collect it. It still has a record, but
  /// it is not running, so a socket it left behind must carry none of its authority.
  static func record(of pid: pid_t) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size

    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }

    guard size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return nil }

    guard info.kp_proc.p_stat != CChar(SZOMB) else { return nil }

    return info
  }
}
