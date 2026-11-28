import Darwin
import Foundation
import ScriptTestSupport
import ScriptWire
import XCTest

/// Runs the helper as `uniterm lint` would, with a listener on the address it could connect to.
///
/// These prove what a user sees on the command line: the findings and the exit status, that the
/// command never contacts the app, and that it runs none of the file's code. They cannot prove the
/// lint's reading of a file, which the runtime's lint tests hold, or the shipped command's
/// location check, which `ScriptRunUITests` runs against the built app.
final class ScriptLintCommandTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = try ScriptFixtures.makeSocketDirectory()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func write(_ source: String, named name: String = "tidy.janet") throws -> URL {
    let file = directory.appendingPathComponent(name)

    try Data(source.utf8).write(to: file)

    return file
  }

  private func lint(_ arguments: [String], socket: String? = nil) async throws -> HelperRun {
    var environment = ProcessInfo.processInfo.environment

    environment["UNITERM_SOCKET"] = socket

    return try await ScriptFixtures.finish(
      try HelperHandle.spawn(
        executable: ScriptFixtures.helper(), arguments: ["lint"] + arguments,
        environment: environment,
        deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)]))
  }

  /// Catches a lint that contacts the app, or one that runs the file. A listener waits at the
  /// address the environment names, the file would write a marker if any form ran, and the
  /// listener must see no connection.
  func testTheLintNeverContactsTheAppAndRunsNoCode() async throws {
    let marker = directory.appendingPathComponent("ran")
    let address = directory.appendingPathComponent("app.sock").path
    let listener = try FakeApp.listen(path: address)

    defer { Darwin.close(listener) }

    let file = try write(
      """
      (declare-permissions {:kind :pane-control})
      (import uniterm)
      (spit "\(marker.path)" "ran")
      (uniterm/read-clipboard)
      (os/exit 3)
      """)
    let run = try await lint([file.path], socket: address)

    XCTAssertEqual(run.status, 1, run.standardError)
    XCTAssertTrue(
      run.standardOutput.contains("\(file.path):4:1: uniterm/read-clipboard needs clipboard-read"),
      run.standardOutput)
    XCTAssertTrue(run.standardOutput.contains("declares pane-control but never uses it"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a form of the file ran")

    var poll = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)

    XCTAssertEqual(Darwin.poll(&poll, 1, 0), 0, "the lint connected to the app")
  }

  /// Catches the three outcomes sharing a status. Clean is 0, findings are 1, and a file that does
  /// not read is 65, with the file that is missing at 66.
  func testTheExitStatusTellsCleanFromFindingsFromUnreadable() async throws {
    let clean = try write(
      "(declare-permissions {:kind :pane-control})\n(import uniterm)\n"
        + "(uniterm/list-windows)\n", named: "clean.janet")
    let dirty = try write("(import uniterm)\n(uniterm/read-clipboard)\n", named: "dirty.janet")
    let broken = try write("(print 1", named: "broken.janet")
    let badDeclaration = try write(
      "(declare-permissions {:kind :nope})\n", named: "bad.janet")

    let cleanRun = try await lint([clean.path])

    XCTAssertEqual(cleanRun.status, 0, cleanRun.standardError)
    XCTAssertEqual(cleanRun.standardOutput, "")

    let dirtyRun = try await lint([dirty.path])

    XCTAssertEqual(dirtyRun.status, 1)
    XCTAssertTrue(dirtyRun.standardOutput.contains("declares nothing"), dirtyRun.standardOutput)
    XCTAssertTrue(
      dirtyRun.standardOutput.contains(
        "add (declare-permissions {:kind :clipboard-read}) as the file's first form"),
      dirtyRun.standardOutput)

    let brokenRun = try await lint([broken.path])

    XCTAssertEqual(brokenRun.status, 65)
    XCTAssertEqual(brokenRun.standardOutput, "")
    XCTAssertTrue(brokenRun.standardError.contains("broken.janet"), brokenRun.standardError)

    let badRun = try await lint([badDeclaration.path])

    XCTAssertEqual(badRun.status, 65)
    XCTAssertTrue(badRun.standardError.contains("not a permission kind"), badRun.standardError)

    let missing = try await lint([directory.appendingPathComponent("none.janet").path])

    XCTAssertEqual(missing.status, 66, missing.standardError)
  }

  /// Catches usage mistakes running the lint on something else. A folder is a package, which the
  /// lint does not cover, and a second file or an unknown flag is a usage error.
  func testUsageMistakesAreRefusedWithTheUsageStatus() async throws {
    let file = try write("(print 1)\n")

    for arguments in [[], [file.path, file.path], ["--socket", file.path], [directory.path]] {
      let run = try await lint(arguments)

      XCTAssertEqual(run.status, 64, "\(arguments): \(run.standardError)")
    }

    let help = try await lint(["--help"])

    XCTAssertEqual(help.status, 0)
    XCTAssertTrue(help.standardOutput.contains("usage: uniterm lint file.janet"))
  }
}
