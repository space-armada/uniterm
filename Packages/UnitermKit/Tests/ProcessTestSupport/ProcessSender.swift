import Darwin
import ProcessInspection
import XCTest

/// A process a test learned the pid of, with the start time that makes the pid name one process.
public struct ProcessRecord: Sendable, Equatable {
  public let pid: pid_t
  public let startedMicroseconds: Int

  public init(pid: pid_t, startedMicroseconds: Int) {
    self.pid = pid
    self.startedMicroseconds = startedMicroseconds
  }

  /// Records the process `pid` names now, or returns nil when it names none that is alive.
  public init?(pid: pid_t) {
    guard let started = ProcessInspection.startTimeMicroseconds(of: pid) else { return nil }

    self.init(pid: pid, startedMicroseconds: started)
  }
}

/// How the guarded call is expected to reach a process.
public enum ExpectedSignalPath: Sendable {
  /// The system gives the process an audit token, so the signal goes by the token.
  case token

  /// The system refuses the process a token, so the signal goes by pid after the start time
  /// matches. That keeps a window between the check and the signal.
  case pid
}

/// The one way a package test signals a process that something other than the test reaps.
///
/// A raw `kill` on a pid can reach an unrelated process once the pid is freed and reused. The
/// sender signals only the process whose pid and start time the test recorded.
public enum ProcessSender {
  /// Sends `number` to the recorded process through `ProcessInspection`'s guarded call.
  ///
  /// A process that is gone is fine, so the test can end a process that has already ended. The test
  /// fails when the call reports the process unreached or refused, or when it took the other path
  /// than the site expects. A change in what the system allows then shows up at once.
  ///
  /// Returns whether the signal was sent.
  @discardableResult
  public static func signal(
    _ number: Int32, _ record: ProcessRecord, expecting expected: ExpectedSignalPath,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    switch send(number, record, expecting: expected, file: file, line: line) {
    case .byToken, .byPid: true
    case .gone, .unreached, .refused: false
    }
  }

  /// The same as `signal`, for a caller that needs what the guarded call reported. A test that
  /// stands in for a product's signal seam returns it.
  public static func send(
    _ number: Int32, _ record: ProcessRecord, expecting expected: ExpectedSignalPath,
    file: StaticString = #filePath, line: UInt = #line
  ) -> ProcessInspection.SignalResult {
    let result = ProcessInspection.signal(
      number, pid: record.pid, startedMicroseconds: record.startedMicroseconds)

    switch (result, expected) {
    case (.byToken, .token), (.byPid, .pid), (.gone, _):
      break

    case (.byToken, .pid):
      XCTFail(
        "signal \(number) to \(record.pid) went by token, and the site expects the pid path",
        file: file, line: line)

    case (.byPid, .token):
      XCTFail(
        "signal \(number) to \(record.pid) went by pid, and the site expects the token path",
        file: file, line: line)

    case (.unreached, _):
      XCTFail(
        "signal \(number) did not reach \(record.pid), which is still the recorded process",
        file: file, line: line)

    case (.refused, _):
      XCTFail("signal \(number) to \(record.pid) was refused", file: file, line: line)
    }

    return result
  }

  /// Whether the process is stopped, as SIGSTOP leaves it. A process that cannot be read is not
  /// stopped.
  public static func isStopped(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)

    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }

    return info.pbi_status == UInt32(SSTOP)
  }
}
