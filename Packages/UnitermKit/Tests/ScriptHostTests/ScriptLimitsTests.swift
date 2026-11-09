import Darwin
import Foundation
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// The helper's limits as `uniterm run` shows them: what the sandbox denies, how Ctrl-C ends a
/// script, what a runaway allocation does, and that the app keeps serving through all of it.
///
/// Each helper is a real process against a real listener. They prove the helper's own behavior and
/// that the app is never stalled by it. They cannot prove how Ctrl-C reaches a REPL through the
/// app's terminal, which `ScriptReplLimitsTests` and the UI tests cover. Every wait is bounded,
/// and a helper that outlives its test is killed.
@MainActor
final class ScriptLimitsTests: XCTestCase {
  private var directory: URL!
  private var center: StatusCenter!
  private var host: ScriptHost!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    center = StatusCenter()

    let center = center!

    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) })
    host.start()
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  private func posted(_ text: String) async -> Bool {
    await waitUntil { self.center.history.map(\.text).contains(text) }
  }

  // MARK: Sandbox

  /// Catches a denied category with no fixture, or a fixture that fails for another reason. Each
  /// script tries one operation the default sandbox denies. It must fail with the sandbox's own
  /// error, and the run must end with the script-failed status.
  func testEveryDeniedCategoryFailsWithTheSandboxError() async throws {
    let target = directory.appendingPathComponent("out.txt").path
    let cases: [(name: String, arguments: [String])] = [
      ("denied-read", []),
      ("denied-write", [target]),
      ("denied-net", []),
      ("denied-subprocess", []),
      ("denied-ffi", []),
      ("denied-env", []),
    ]

    for (name, arguments) in cases {
      let run = try await ScriptFixtures.run(
        socket: host.instanceAddress, script: ScriptFixtures.script(name), arguments: arguments)

      XCTAssertEqual(run.status, 1, "\(name): \(run.standardError)")
      XCTAssertTrue(
        run.standardError.contains("sandbox"),
        "\(name) did not fail in the sandbox: \(run.standardError)")
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: target), "a denied write wrote a file")
  }

  // MARK: Ctrl-C

  /// Catches a script in a loop that Ctrl-C leaves running, an interrupt that is reported as a
  /// script bug, and an app that stops answering other scripts while one spins. The helper ends
  /// with the interrupted status, and a second script runs to the end while the first spins.
  func testCtrlCStopsASpinningScriptAndTheAppKeepsServing() async throws {
    let spinner = try ScriptFixtures.start(
      socket: host.instanceAddress, script: ScriptFixtures.script("spin"))

    defer { if spinner.isRunning { kill(spinner.processIdentifier, SIGKILL) } }

    expect(await posted("spinning"), "the script never reached its loop")

    let other = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("post-status"))

    XCTAssertEqual(
      other.status, 0, "the app stopped serving while a script spun: \(other.standardError)")
    XCTAssertTrue(spinner.isRunning, "the loop ended on its own")

    kill(spinner.processIdentifier, SIGINT)

    let run = await ScriptFixtures.finish(spinner)

    XCTAssertEqual(run.status, 130, run.standardError)
    XCTAssertTrue(run.standardError.contains("interrupted"), run.standardError)
    XCTAssertFalse(run.standardError.contains("error"), "an interrupt read as a failure")
  }

  /// Catches a second Ctrl-C that cannot end a script stuck in a C call. The script reads standard
  /// input, which never ends, so it waits in a C call that Janet's interrupt flag never reaches.
  /// The first Ctrl-C leaves it running, and the second ends the process at once.
  func testASecondCtrlCEndsAScriptStuckInACallTheInterruptNeverReaches() async throws {
    let input = Pipe()
    let marker = directory.appendingPathComponent("stuck").path
    let stuck = try ScriptFixtures.start(
      socket: host.instanceAddress, script: ScriptFixtures.script("stuck-in-c"),
      allow: ["fs-write"], arguments: [marker], input: input)

    defer {
      if stuck.isRunning { kill(stuck.processIdentifier, SIGKILL) }

      withExtendedLifetime(input) {}
    }

    let deadline = ContinuousClock.now + .seconds(20)

    while !FileManager.default.fileExists(atPath: marker), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "the script never began")

    // The marker comes just before the read. An interrupt that lands before the read begins would
    // stop the script at the call, so the first interrupt waits until the main thread is blocked.
    expect(await waitUntilBlocked(stuck.processIdentifier), "the script never blocked in the read")

    kill(stuck.processIdentifier, SIGINT)

    try await Task.sleep(for: .seconds(1))

    XCTAssertTrue(stuck.isRunning, "the first Ctrl-C ended a call the interrupt cannot reach")

    kill(stuck.processIdentifier, SIGINT)

    let run = await ScriptFixtures.finish(stuck)

    XCTAssertEqual(run.status, 130, run.standardError)
    XCTAssertTrue(run.standardError.contains("interrupted again"), run.standardError)
  }

  /// Catches a helper whose watchdog answers only while the VM is idle. The script spins, and the
  /// app pings it. The pong must come from the watchdog thread, and the loop must still be
  /// running afterwards, so a long legitimate script is never mistaken for a hung one.
  func testTheWatchdogAnswersAPingWhileTheScriptSpins() async throws {
    let listener = try ScriptListener.start(
      directory: directory.appendingPathComponent("ping", isDirectory: true))
    let box = PingBox()
    let process = try ScriptFixtures.start(
      socket: listener.path, script: ScriptFixtures.script("spin"))

    defer {
      listener.stop()

      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    let answered = await listener.drive(timeout: .seconds(30)) { event in
      switch event {
      case .request(let connection, let id, _):
        connection.reply(id: id, result: .ok(Data()))
        connection.send(.ping(41))

      case .pong(_, let nonce):
        box.nonce = nonce

        return true

      default:
        break
      }

      return false
    }

    XCTAssertTrue(answered, "a spinning helper never answered a ping")
    XCTAssertEqual(box.nonce, 41)
    XCTAssertTrue(process.isRunning, "the helper ended")
  }

  // MARK: Memory

  /// Catches an allocation past the cap that Janet survives, or kills the app. `buffer/new` with
  /// the largest size a 32-bit integer holds is far past the 1 GiB cap. The helper must end with
  /// the memory status and message, and the app must go on serving.
  func testAHugeAllocationEndsTheHelperWithAMemoryErrorAndTheAppKeepsRunning() async throws {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("memory-huge"))

    XCTAssertEqual(run.status, 79, run.standardError)
    XCTAssertTrue(run.standardError.contains("out of memory"), run.standardError)
    XCTAssertTrue(run.standardError.contains("1024 MiB"), run.standardError)

    let after = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("post-status"))

    XCTAssertEqual(after.status, 0, after.standardError)
  }

  /// Catches a growing loop that is never stopped. The cap is 64 MiB here, so the loop reaches it
  /// in a moment. The count must include what the buffer grows by, and not only first
  /// allocations.
  func testAGrowingLoopEndsAtTheCap() async throws {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("memory-grow"),
      memoryCap: 64 << 20)

    XCTAssertEqual(run.status, 79, run.standardError)
    XCTAssertTrue(run.standardError.contains("64 MiB"), run.standardError)
  }

  /// Catches the fixture the proposal names. `(buffer/new 1e12)` never reaches the allocator,
  /// since Janet's own integer check refuses it. It is an error the script sees, and it is not
  /// the memory limit.
  func testAnAllocationJanetItselfRefusesIsAnOrdinaryError() async throws {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("memory-too-big-for-janet"))

    XCTAssertEqual(run.status, 1, run.standardError)
    XCTAssertFalse(run.standardError.contains("out of memory"), run.standardError)
  }
}

private final class PingBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: UInt32?

  var nonce: UInt32? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
