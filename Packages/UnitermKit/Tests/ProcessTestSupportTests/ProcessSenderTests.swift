import Darwin
import Foundation
import ProcessInspection
import ProcessTestSupport
import XCTest

/// Pins each arm of `ProcessSender.send` against live processes. The sites that use the sender
/// prove only the arms they reach, and only when the system behaves. A sender that accepted a
/// wrong path, an unreached process, or a refused pid would pass every site.
final class ProcessSenderTests: XCTestCase {
  private var children: [Process] = []

  override func tearDown() {
    for child in children where child.isRunning {
      child.terminate()
      child.waitUntilExit()
    }

    children = []

    super.tearDown()
  }

  private func spawnSleep() throws -> ProcessRecord {
    let child = Process()

    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]

    try child.run()

    children.append(child)

    return try XCTUnwrap(ProcessRecord(pid: child.processIdentifier))
  }

  /// Runs `body` and requires that it reports exactly one failure whose text holds `fragment`. A
  /// sender that stopped failing, or failed for another reason, fails the test.
  private func expectFailure(containing fragment: String, _ body: () -> Void) {
    let options = XCTExpectedFailure.Options()

    options.issueMatcher = { $0.compactDescription.contains(fragment) }

    XCTExpectFailure(
      "the sender reports this arm as a failure", options: options, failingBlock: body)
  }

  /// A child the test spawned and owns gives a token, so a site that expects the pid path must
  /// fail. Catches an arm that accepts `.byToken` for `.pid`.
  func testTokenPathFailsAnExpectedPidPath() throws {
    let record = try spawnSleep()
    var result: ProcessInspection.SignalResult?

    expectFailure(containing: "went by token") {
      result = ProcessSender.send(SIGCONT, record, expecting: .pid)
    }

    XCTAssertEqual(result, .byToken)
  }

  /// The matching expectation passes and signals. Without this the failure tests could pass on a
  /// sender that fails every call.
  func testTokenPathPassesAnExpectedTokenPath() throws {
    let record = try spawnSleep()

    XCTAssertEqual(ProcessSender.send(SIGCONT, record, expecting: .token), .byToken)
    XCTAssertTrue(ProcessSender.signal(SIGCONT, record, expecting: .token))
  }

  /// A start time one microsecond off names another process, so the call reports gone. A gone
  /// process is accepted for either path. Catches a sender that fails or signals on a mismatch.
  func testStartTimeOffByOneMicrosecondIsGoneAndAccepted() throws {
    let live = try spawnSleep()
    let record = ProcessRecord(pid: live.pid, startedMicroseconds: live.startedMicroseconds + 1)

    XCTAssertEqual(ProcessSender.send(SIGCONT, record, expecting: .token), .gone)
    XCTAssertEqual(ProcessSender.send(SIGCONT, record, expecting: .pid), .gone)
    XCTAssertFalse(ProcessSender.signal(SIGCONT, record, expecting: .token))
  }

  /// The token signal answers EINVAL for signal 0, so a signal 0 probe of a live child through a
  /// token is unreached, and the sender fails it. Catches an arm that treats an unreached live
  /// process as done.
  func testSignalZeroProbeOfLiveChildFailsAsUnreached() throws {
    let record = try spawnSleep()
    var result: ProcessInspection.SignalResult?

    expectFailure(containing: "did not reach") {
      result = ProcessSender.send(0, record, expecting: .token)
    }

    XCTAssertEqual(result, .unreached)
  }

  /// The guarded call never signals pid 1, so the sender fails it as refused. Catches an arm that
  /// accepts a refusal.
  func testPidOneFailsAsRefused() {
    let record = ProcessRecord(pid: 1, startedMicroseconds: 0)
    var result: ProcessInspection.SignalResult?

    expectFailure(containing: "was refused") {
      result = ProcessSender.send(SIGCONT, record, expecting: .token)
    }

    XCTAssertEqual(result, .refused)
  }

  /// The guarded call never signals the test process itself, so a test that records its own pid
  /// fails as refused. Catches an arm that accepts a refusal, and a sender that signals itself.
  func testOwnPidFailsAsRefused() {
    let record = ProcessRecord(pid: getpid(), startedMicroseconds: 0)
    var result: ProcessInspection.SignalResult?

    expectFailure(containing: "was refused") {
      result = ProcessSender.send(SIGCONT, record, expecting: .pid)
    }

    XCTAssertEqual(result, .refused)
  }
}
