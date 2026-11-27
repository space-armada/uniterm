import Darwin
import Foundation
import OSLog
import ProcessInspection
import ScriptTestSupport
import XCTest

@testable import ScriptHost

/// What a reaper's guarded call reported, in order.
final class SignalResults: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [ProcessInspection.SignalResult] = []

  var all: [ProcessInspection.SignalResult] { lock.withLock { results } }

  /// The live guarded call, recording what it reports.
  func live(_ number: Int32, _ pid: pid_t, _ started: Int) -> ProcessInspection.SignalResult {
    let result = ProcessInspection.signal(number, pid: pid, startedMicroseconds: started)

    lock.withLock { results.append(result) }

    return result
  }
}

/// The reaper's kill against real processes, and what it logs. These pin the fix and not the bug,
/// since no test can force the system to hand a freed process ID to another process.
final class ProcessReaperTests: XCTestCase {
  /// A child that is recorded, then execs `/bin/sleep`. It returns once the exec shows, with the
  /// record from before it.
  private func recordedChildThatExecs() async throws -> (HelperHandle, ProcessReaper.Target) {
    let gate = Pipe()
    let child = try HelperHandle.spawn(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "read line; exec /bin/sleep 30"], environment: [:],
      standardInput: .file(gate.fileHandleForReading), standardOutput: .null,
      standardError: .null, deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)])

    try gate.fileHandleForReading.close()

    let recorded = ProcessReaper.Target.reading(child.pid)

    XCTAssertEqual(recorded.identity.started, ProcessInspection.startTime(of: child.pid))

    try gate.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
    try gate.fileHandleForWriting.close()

    let deadline = Date().addingTimeInterval(10)

    while ProcessInspection.executablePath(of: child.pid) != "/bin/sleep" && Date() < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }

    XCTAssertEqual(ProcessInspection.executablePath(of: child.pid), "/bin/sleep")

    return (child, recorded)
  }

  /// Catches a reaper that loses a helper which exec'd. The record from before the exec still
  /// names the process, and the live reaper ends it.
  func testTheLiveReaperEndsAChildThatExecd() async throws {
    let (child, recorded) = try await recordedChildThatExecs()

    defer { child.signal(SIGKILL) }

    ProcessReaper.live.killNow(recorded)

    let exit = try await child.waitForExit()

    XCTAssertEqual(exit, .signalled(SIGKILL))
  }

  /// Catches a live reaper that kills by a start time checked to the second, or by the process ID
  /// alone. A record one microsecond off, in the same second, must send nothing.
  ///
  /// The reaper gets the off record first. The test then ends the child with SIGTERM through its
  /// handle. An exit by SIGTERM shows the reaper sent nothing. An exit by SIGKILL shows its signal
  /// landed.
  ///
  /// SIGKILL is fatal from the moment it is sent, so a SIGKILL the reaper sent wins over the later
  /// SIGTERM.
  func testTheLiveReaperLeavesAChildWhoseStartTimeIsOneMicrosecondOff() async throws {
    let (child, recorded) = try await recordedChildThatExecs()

    defer { child.signal(SIGKILL) }

    let started = recorded.startedMicroseconds
    let off = ProcessReaper.Target(
      identity: recorded.identity,
      startedMicroseconds: started % 1_000_000 < 999_999 ? started + 1 : started - 1)

    ProcessReaper.live.killNow(off)

    XCTAssertEqual(child.signal(SIGTERM), .sent)

    let exit = try await child.waitForExit()

    XCTAssertEqual(exit, .signalled(SIGTERM), "a start one microsecond off was signalled")
  }

  /// Catches a reaper that hides a kill which fell back to the process ID, or one that failed,
  /// and one that logs a helper that was already gone. Each result goes to a made-up process ID,
  /// and nothing is signalled. It cannot show that a real helper ever takes the process ID path.
  ///
  /// The log line is the contract, and only the unified log holds it, so no cheaper layer can
  /// prove it. The test needs a readable log store for the current process. Its reads cost 1 to
  /// 3 s. It reads until the last expected entry shows, since the entries before it were written
  /// first.
  func testTheReaperLogsThePidPathAndFailuresButNotAGoneHelper() throws {
    let since = Date()
    let cases: [(pid: pid_t, result: ProcessInspection.SignalResult)] = [
      (4401, .byToken), (4402, .byPid), (4403, .gone), (4404, .unreached), (4405, .refused),
    ]

    for (pid, result) in cases {
      let reaper = ProcessReaper.guarded(delay: .seconds(2), signal: { _, _, _ in result })

      reaper.kill(
        ProcessReaper.Target(
          identity: ProcessIdentity(pid: pid, started: 1), startedMicroseconds: 1_000_000))
    }

    let logged = try OwnLog.entries(category: "repl", since: since) { read in
      read.contains { $0.composedMessage.contains("helper 4405") }
    }

    func levels(_ pid: pid_t) -> [OSLogEntryLog.Level] {
      logged.filter { $0.composedMessage.contains("helper \(pid)") }.map(\.level)
    }

    XCTAssertEqual(levels(4401), [], "a kill by token was logged")
    XCTAssertEqual(levels(4402), [.notice], "a kill by process ID was not logged")
    XCTAssertEqual(levels(4403), [], "a helper that was gone was logged")
    XCTAssertEqual(levels(4404), [.error], "an unreached helper was not logged as an error")
    XCTAssertEqual(levels(4405), [.error], "a refused helper was not logged as an error")
  }
}

/// This process's own log entries from uniterm's subsystem.
enum OwnLog {
  /// Reads the entries in `category` logged since `since`, again and again, until `complete`
  /// holds for them or ten seconds pass. It returns the last read either way.
  ///
  /// No documented guarantee says a store read sees an entry written just before it. So the test
  /// waits for the entries it expects, and then asserts on what it read. Each read takes about a
  /// second, so the loop needs no sleep.
  static func entries(
    category: String, since: Date, until complete: ([OSLogEntryLog]) -> Bool
  ) throws -> [OSLogEntryLog] {
    let deadline = Date().addingTimeInterval(10)
    let matching = NSPredicate(
      format: "subsystem == %@ AND category == %@", "dev.uniterm.app", category)

    while true {
      let store = try OSLogStore(scope: .currentProcessIdentifier)
      let read = try store.getEntries(at: store.position(date: since), matching: matching)
        .compactMap { $0 as? OSLogEntryLog }

      if complete(read) || Date() >= deadline { return read }
    }
  }
}
