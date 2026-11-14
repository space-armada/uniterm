import Darwin
import Foundation

/// A process and the second it started. The ID alone can be reused after the process ends, so the
/// start time tells an instance that is running from a later process with the same ID.
public struct ProcessIdentity: Equatable, Sendable {
  public let pid: pid_t
  public let started: Int

  public init(pid: pid_t, started: Int) {
    self.pid = pid
    self.started = started
  }

  /// This process. A process whose start the system will not report is taken to have started at
  /// zero, which only makes it compare equal to itself.
  public static var current: ProcessIdentity {
    let pid = getpid()

    return ProcessIdentity(pid: pid, started: startTime(of: pid) ?? 0)
  }

  var folderName: String { "\(pid).\(started)" }

  init?(folderName: String) {
    let parts = folderName.split(separator: ".", omittingEmptySubsequences: false)

    guard parts.count == 2, let pid = pid_t(parts[0]), let started = Int(parts[1]) else {
      return nil
    }

    self.init(pid: pid, started: started)
  }

  /// True when a process with this ID exists and started at this second.
  var isRunning: Bool {
    guard let actual = Self.startTime(of: pid) else { return false }

    return actual == started
  }

  static func startTime(of pid: pid_t) -> Int? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)

    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

    return Int(info.pbi_start_tvsec)
  }
}
