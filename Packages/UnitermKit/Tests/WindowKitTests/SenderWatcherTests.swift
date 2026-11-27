import Foundation
import ScriptTestSupport
import XCTest

@testable import WindowKit

/// The system's process watcher against real processes. The coordinator tests use a fake, so they
/// cannot show that the real one reports a sender that is already gone.
@MainActor
final class SenderWatcherTests: XCTestCase {
  /// Catches a watcher that never reports a process that exited before the watch began. A sender
  /// that quits before its question is asked would then keep a question that can still be
  /// allowed. The process is started, waited on, and reaped before the watch starts.
  func testAProcessThatAlreadyExitedIsReportedAtOnce() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()

    let ended = expectation(description: "the watcher reported the exited process")
    let stop = watchProcessEnd(pid: process.processIdentifier) { ended.fulfill() }

    await fulfillment(of: [ended], timeout: 5)
    stop()
  }

  /// Catches a watcher that reports a process that still runs, or one that misses its exit. The
  /// process sleeps until the test ends it.
  func testALiveProcessIsReportedOnlyWhenItExits() async throws {
    let process = try HelperHandle.spawn(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
      standardOutput: .null, standardError: .null,
      deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)])

    var reported = false
    let ended = expectation(description: "the watcher reported the exit")

    let stop = watchProcessEnd(pid: process.pid) {
      reported = true
      ended.fulfill()
    }

    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(reported, "a live process was reported as ended")

    process.signal(SIGTERM)
    await fulfillment(of: [ended], timeout: 5)
    stop()
  }
}
