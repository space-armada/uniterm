import Darwin
import Foundation
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

@MainActor
private final class CapturingOpener: ScriptFileOpening {
  private(set) var paths: [[String]] = []

  func open(_ paths: [String], from caller: ScriptCaller?) { self.paths.append(paths) }
  func label(of caller: ScriptCaller) -> String? { "zsh" }
}

/// `uniterm open` as a user runs it: the real command process against a real listener in this
/// process. They prove the exit status and text, the paths the app receives, and the handshake with
/// an app of another version. They cannot prove the shipped command's sandbox, which
/// `CommandHelperSandboxTests` runs, or how the window layer places a pane.
@MainActor
final class ScriptOpenRunTests: XCTestCase {
  private var directory: URL!
  private var host: ScriptHost!
  private var opener: CapturingOpener!
  private var answering: ChangeObservers.Token?

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()

    let center = StatusCenter()

    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) })
    opener = CapturingOpener()
    host.fileOpener = opener
    host.start()

    TestSessionRoot.record(in: host)
  }

  override func tearDown() async throws {
    answering = nil
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  /// Answers each question the command raises, as the user would in the panel.
  private func answer(_ answer: PermissionRequests.Answer) {
    let requests = host.permissionRequests

    answering = requests.changes.add {
      for row in requests.rows { requests.decide(row.id, answer) }
    }
  }

  /// Runs the command with `arguments` in `directory`, and waits for it.
  private func run(
    _ arguments: [String], in directory: URL? = nil, socket: String? = nil
  ) async throws -> HelperRun {
    try await ScriptFixtures.finish(
      try HelperHandle.spawn(
        executable: ScriptFixtures.helper(),
        arguments: ["open", "--socket", socket ?? host.instanceAddress] + arguments,
        environment: ProcessInfo.processInfo.environment, directory: directory,
        deadlines: [HelperDeadline(after: .seconds(60), signal: SIGTERM)]))
  }

  /// A folder under the temporary folder, named as `realpath` names it, which is how the command
  /// names its working directory. Foundation's own link resolution drops `/private`.
  private func makeWorkingFolder() throws -> URL {
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-open-\(UUID().uuidString.prefix(8))", isDirectory: true)

    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: made) }

    let resolved = try XCTUnwrap(realpath(made.path, nil))

    defer { free(resolved) }

    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }

  /// Catches a relative path that crosses the socket as written, a target that is looked at, and
  /// one approval that does not cover a whole command. Three arguments are one question and one
  /// handoff, every path is absolute, and the files do not need to exist, since the command never
  /// looks at them.
  func testRelativePathsAreResolvedInTheCommandAndSentAsOneBatch() async throws {
    let folder = try makeWorkingFolder()

    answer(.allowOnce)

    let run = try await run(["notes.md", "sub/x.txt", "/abs/y"], in: folder)

    XCTAssertEqual(run.status, 0, run.standardError)
    XCTAssertEqual(run.standardOutput, "")
    XCTAssertEqual(
      opener.paths, [[folder.path + "/notes.md", folder.path + "/sub/x.txt", "/abs/y"]])
  }

  /// Catches a deleted working directory that does not fail in the command. The shell removes its
  /// own directory and then runs the command in it, which has no race. The command fails with its
  /// own status and a message, and nothing reaches the app.
  func testADeletedWorkingDirectoryFailsInTheCommand() async throws {
    let folder = try makeWorkingFolder()
    let doomed = folder.appendingPathComponent("doomed", isDirectory: true)

    try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: false)

    let result = try await ScriptFixtures.finish(
      try HelperHandle.spawn(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c", "cd \"$1\" && rmdir \"$1\" && exec \"$2\" open --socket \"$3\" relative.txt",
          "sh", doomed.path, ScriptFixtures.helper().path, host.instanceAddress,
        ],
        environment: ProcessInfo.processInfo.environment,
        deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)]))

    XCTAssertEqual(result.status, 66, result.standardError)
    XCTAssertTrue(result.standardError.contains("working directory"), result.standardError)
    XCTAssertTrue(host.permissionRequests.rows.isEmpty)
    XCTAssertTrue(opener.paths.isEmpty)
  }

  /// Catches a denial that exits as a success, and one that leaks anything about a file. The user's
  /// denial is the refused status with the app's own text.
  func testADeniedOpenExitsRefused() async throws {
    answer(.deny)

    let run = try await run(["/abs/y"])

    XCTAssertEqual(run.status, 77, run.standardError)
    XCTAssertTrue(run.standardError.contains("You denied this request."), run.standardError)
    XCTAssertTrue(opener.paths.isEmpty)
  }

  /// Catches a reply that tells files apart. A path that exists and one that does not get the same
  /// status and the same empty output, since the app answers before it looks at either.
  func testTheReplyIsTheSameForAnExistingAndAMissingPath() async throws {
    let folder = try makeWorkingFolder()
    let present = folder.appendingPathComponent("present.txt")

    try Data("x".utf8).write(to: present)
    answer(.allowOnce)

    let existing = try await run([present.path])
    let missing = try await run([folder.path + "/absent.txt"])

    XCTAssertEqual(existing.status, 0, existing.standardError)
    XCTAssertEqual(missing.status, existing.status)
    XCTAssertEqual(missing.standardOutput, existing.standardOutput)
    XCTAssertEqual(missing.standardError, existing.standardError)
  }

  /// Catches a command that cannot say what to do with no path, or with a path it cannot send.
  func testAUsageErrorExitsWithTheUsageStatusAndConnectsToNothing() async throws {
    let none = try await run([])

    XCTAssertEqual(none.status, 64, none.standardError)
    XCTAssertTrue(none.standardError.contains("usage: uniterm open"), none.standardError)

    let tooMany = try await run((0..<(OpenBegin.maxPaths + 1)).map { "/p/\($0)" })

    XCTAssertEqual(tooMany.status, 64, tooMany.standardError)
    XCTAssertTrue(host.permissionRequests.rows.isEmpty)
  }

  /// Catches a new command that talks to an old app. The old app greets with version 12, and the
  /// command ends at the hello with the mismatch status, before it sends a path. The other
  /// direction, an old command with the new app, is `ScriptHelperIntegrationTests`'s refusal of
  /// a hello of another version.
  func testTheCommandRefusesAnAppOfAnotherVersionAtTheHello() async throws {
    let path = directory.appendingPathComponent("old.sock").path
    let server = try FakeApp.listen(path: path)

    let seen = Task.detached { () -> Bool in
      let accepted = accept(server, nil, nil)
      let socket = FramedSocket(descriptor: accepted)

      defer { socket.shutdownAndClose() }

      guard let frame = try? socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:)),
        (try? ScriptHelperMessage.decode(type: frame.type, body: frame.body))
          == .hello(version: ScriptProtocol.version)
      else { return false }

      try? socket.send(ScriptAppMessage.hello(version: ScriptProtocol.version + 1).frame())

      return (try? socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))) == nil
    }

    defer { Darwin.close(server) }

    let run = try await run(["/abs/y"], socket: path)

    XCTAssertEqual(run.status, 70, run.standardError)
    XCTAssertTrue(
      run.standardError.contains(
        ScriptProtocol.versionMismatchText(
          program: ScriptProtocol.version, uniterm: ScriptProtocol.version + 1)),
      run.standardError)

    let sentNothingAfterTheHello = await seen.value

    XCTAssertTrue(sentNothingAfterTheHello)
  }
}
