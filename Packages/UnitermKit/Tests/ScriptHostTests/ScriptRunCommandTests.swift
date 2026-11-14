import Darwin
import Foundation
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// Runs the helper as `uniterm run` would, against a real listener in this process.
///
/// These prove what a user sees on the command line: the exit status and message when no app
/// listens, which address wins, the script's arguments, what `--allow` grants, and that a helper
/// ends when the app goes away even while its script never yields. They cannot prove the shipped
/// command's location check, which `ScriptRunUITests` runs against the built app. Each wait on a
/// process is bounded, so a hang fails the test.
@MainActor
final class ScriptRunCommandTests: XCTestCase {
  private var directory: URL!
  private var host: ScriptHost!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()

    let center = StatusCenter()
    let listener = try ScriptListener.start(directory: directory)

    host = ScriptHost(
      listener: listener, issueProducer: { center.issueProducer(kind: .script, name: $0) })
    host.start()
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  /// Catches a command that hangs or crashes when no app listens. The message names the address,
  /// and the status is the one no other failure uses.
  func testNoAppAtTheAddressIsReportedClearly() async throws {
    let missing = directory.appendingPathComponent("none.sock").path
    let run = try await ScriptFixtures.run(
      socket: missing, script: ScriptFixtures.script("post-status"))

    XCTAssertEqual(run.status, 69, run.standardError)
    XCTAssertTrue(run.standardError.contains("no uniterm is reachable"), run.standardError)
    XCTAssertTrue(run.standardError.contains(missing), run.standardError)
  }

  /// Catches a stale socket file, one that nobody listens on, being reported as a protocol or
  /// connection failure instead of as no app. The command never talks to it.
  func testASocketFileNobodyListensOnIsReportedAsNoApp() async throws {
    let path = directory.appendingPathComponent("stale.sock").path
    let server = try FakeApp.listen(path: path)

    Darwin.close(server)

    XCTAssertTrue(FileManager.default.fileExists(atPath: path))

    let run = try await ScriptFixtures.run(
      socket: path, script: ScriptFixtures.script("post-status"))

    XCTAssertEqual(run.status, 69, run.standardError)
    XCTAssertTrue(run.standardError.contains("no uniterm is reachable"), run.standardError)
  }

  /// Catches an address that comes from the wrong place. The flag wins over the variable, and the
  /// variable stands in for the flag. A wrong winner shows as a script that ran against the other
  /// address, or one that did not run.
  func testTheFlagWinsOverTheVariableAndTheVariableWorksAlone() async throws {
    let missing = directory.appendingPathComponent("none.sock").path
    let script = ScriptFixtures.script("post-status")

    let viaVariable = try await ScriptFixtures.run(
      socket: nil, script: script, environment: ["UNITERM_SOCKET": host.instanceAddress])

    XCTAssertEqual(viaVariable.status, 0, viaVariable.standardError)

    let flagWins = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: script, environment: ["UNITERM_SOCKET": missing])

    XCTAssertEqual(flagWins.status, 0, flagWins.standardError)

    let flagLoses = try await ScriptFixtures.run(
      socket: missing, script: script, environment: ["UNITERM_SOCKET": host.instanceAddress])

    XCTAssertEqual(flagLoses.status, 69, "the variable won over the flag")
  }

  /// Catches arguments that never reach the script, or that arrive without the script's own path
  /// first. The convention is Janet's: `(dyn :args)` starts with the script.
  func testScriptArgumentsReachTheScriptAfterItsOwnPath() async throws {
    let script = ScriptFixtures.script("args")
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: script, arguments: ["alpha", "--beta", "gamma delta"])

    XCTAssertEqual(run.status, 0, run.standardError)
    XCTAssertEqual(
      run.standardOutput.split(separator: "\n").map(String.init),
      [script.path, "alpha", "--beta", "gamma delta"])
  }

  /// Catches a grant that is missing, too wide, or applied to the wrong name. A script with no
  /// flag cannot read a file, and the same script with `--allow fs-read` can. A write stays denied
  /// under it, which shows the grant cleared only its own bits.
  func testACapabilityIsGrantedOnlyWhenTheCommandLineNamesIt() async throws {
    let file = directory.appendingPathComponent("data.txt")

    try Data("twelve bytes".utf8).write(to: file)

    let script = ScriptFixtures.script("allowed-read")

    let denied = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: script, arguments: [file.path])

    XCTAssertEqual(denied.status, 1)
    XCTAssertTrue(denied.standardError.contains("sandbox"), denied.standardError)

    let granted = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: script, allow: ["fs-read"], arguments: [file.path])

    XCTAssertEqual(granted.status, 0, granted.standardError)
    XCTAssertEqual(granted.standardOutput, "12\n")

    let write = ScriptFixtures.script("denied-write")
    let stillDenied = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: write, allow: ["fs-read"],
      arguments: [directory.appendingPathComponent("out.txt").path])

    XCTAssertEqual(stillDenied.status, 1)
    XCTAssertTrue(stillDenied.standardError.contains("sandbox"), stillDenied.standardError)
  }

  /// Catches a default sandbox that leaves a process or a network call open, which the proposal
  /// denies. Each is forbidden with no flag. With its capability, the same script gets past the
  /// sandbox: the process call is allowed, and a local port is opened.
  func testSubprocessAndNetworkAreDeniedByDefaultAndGrantedByTheirNames() async throws {
    let subprocess = ScriptFixtures.script("denied-subprocess")
    let net = ScriptFixtures.script("denied-net")

    let blockedProcess = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: subprocess)

    XCTAssertEqual(blockedProcess.status, 1)
    XCTAssertTrue(blockedProcess.standardError.contains("sandbox"), blockedProcess.standardError)

    let ranProcess = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: subprocess, allow: ["subprocess"])

    XCTAssertEqual(ranProcess.status, 0, ranProcess.standardError)
    XCTAssertEqual(ranProcess.standardError, "")

    let blockedNet = try await ScriptFixtures.run(socket: host.instanceAddress, script: net)

    XCTAssertEqual(blockedNet.status, 1)
    XCTAssertTrue(blockedNet.standardError.contains("sandbox"), blockedNet.standardError)

    let reachedNet = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: net, allow: ["net"])

    XCTAssertEqual(reachedNet.status, 0, reachedNet.standardError)
    XCTAssertEqual(reachedNet.standardOutput, "listening true\n")
  }

  /// Catches a name that is accepted by mistake, or refused only after the script began. The
  /// status is the usage status, which the unreachable address never gives, so the command refused
  /// before it connected.
  func testAnUnknownCapabilityIsRefusedBeforeAnythingRuns() async throws {
    let missing = directory.appendingPathComponent("none.sock").path

    for name in ["nonsense", "all", "FS-READ", "", "hrtime", "compile"] {
      let run = try await ScriptFixtures.run(
        socket: missing, script: ScriptFixtures.script("post-status"), allow: [name])

      XCTAssertEqual(run.status, 64, "--allow \(name): \(run.standardError)")
      XCTAssertTrue(run.standardError.contains("--allow"), run.standardError)
    }
  }

  /// Catches a command that runs on a usage error, and a help flag that fails.
  func testAUsageErrorPrintsUsageAndHelpSucceeds() async throws {
    let script = ScriptFixtures.script("post-status")

    for (arguments, status) in [(["run"], Int32(64)), (["run", "--bogus", script.path], 64)] {
      let run = try await runRaw(arguments)

      XCTAssertEqual(run.status, status, "\(arguments): \(run.standardError)")
      XCTAssertTrue(run.standardError.contains("usage: uniterm run"), run.standardError)
    }

    let help = try await runRaw(["run", "--help"])

    XCTAssertEqual(help.status, 0)
    XCTAssertTrue(help.standardOutput.contains("usage: uniterm run"), help.standardOutput)
  }

  private func runRaw(_ arguments: [String]) async throws -> HelperRun {
    let process = Process()

    process.executableURL = ScriptFixtures.helper()
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()

    let watchdog = process

    DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
      if watchdog.isRunning { watchdog.terminate() }
    }

    return await ScriptFixtures.finish(process)
  }
}

/// The helper's behavior when the app goes away, which needs a listener the test drives by hand.
@MainActor
final class ScriptRunAppQuitTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// Catches a helper that outlives the app, or one that exits zero. The script waits for a reply
  /// the app never sends, then the app quits. The run exits with the connection-lost status and a
  /// message that names the cause.
  func testARunWhoseAppQuitsExitsNonzeroAndSaysWhy() async throws {
    let listener = try ScriptListener.start(directory: directory)
    let process = try ScriptFixtures.start(
      socket: listener.path, script: ScriptFixtures.script("post-status"))

    defer { if process.isRunning { process.terminate() } }

    let asked = await listener.drive { event in
      guard case .request = event else { return false }

      listener.stop()

      return true
    }

    XCTAssertTrue(asked, "the helper never made its call")

    let run = await ScriptFixtures.finish(process)

    XCTAssertEqual(run.status, 74, run.standardError)
    XCTAssertTrue(run.standardError.contains("uniterm quit"), run.standardError)
  }

  /// Catches a watchdog that does not run, or one that reads frames the VM thread needs. The script
  /// never yields, so only the watchdog can end it. The helper must exit soon after the app closes
  /// the connection, with the same status and message.
  func testAHelperBusyInALoopStillExitsWhenTheConnectionCloses() async throws {
    let listener = try ScriptListener.start(directory: directory)
    let marker = directory.appendingPathComponent("looping")
    let exited = expectation(description: "the helper exits")
    let process = try ScriptFixtures.start(
      socket: listener.path, script: ScriptFixtures.script("busy-loop"), allow: ["fs-write"],
      arguments: [marker.path], onExit: { exited.fulfill() })

    defer {
      listener.stop()

      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    Task {
      _ = await listener.drive { event in
        if case .request(let connection, let id, _) = event {
          connection.reply(id: id, result: .ok(Data()))
        }

        return false
      }
    }

    // The marker is written after the last reply, so the script is in its loop once it exists.
    let deadline = ContinuousClock.now + .seconds(15)

    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the script never began")
    XCTAssertTrue(process.isRunning, "the loop ended on its own")

    listener.stop()

    let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 15)

    XCTAssertEqual(outcome, .completed, "a helper in a busy loop outlived its connection")

    guard outcome == .completed else { return }

    let run = await ScriptFixtures.finish(process)

    XCTAssertEqual(run.status, 74, run.standardError)
    XCTAssertTrue(run.standardError.contains("uniterm quit"), run.standardError)
  }
}
