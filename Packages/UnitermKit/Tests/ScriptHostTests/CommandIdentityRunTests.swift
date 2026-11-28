import ControllerTestSupport
import Foundation
import ScriptTestSupport
import ScriptWire
import XCTest

@testable import ScriptHost

/// The real command against a listener that holds the app's command identity. A command that is
/// not the one the app kept never reaches a script. These tests run the signed copy of the command
/// the controller tests use, so its identity is real. `ControllerRunTests` runs the same command
/// when it matches. They cannot prove a bundle swapped under an app, only the same two files.
final class CommandIdentityRunTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// Catches an app that lets a command run after the file at its own command path was replaced.
  /// The app kept the first file's hash. The replacement is another signed build at the same path.
  /// The run ends before any script code, with the relaunch text.
  func testACommandReplacedAtTheAppsOwnPathIsToldToRelaunch() async throws {
    let folder = try ControllerFixtures.temporaryFolder()
    let command = folder.appendingPathComponent("uniterm")

    try FileManager.default.copyItem(at: try HardenedHelper.url(), to: command)

    let identity = BundleHelperIdentity(helperURL: command)

    XCTAssertNotNil(identity.keptCodeDirectoryHash(), "the app could not read its own command")

    try FileManager.default.removeItem(at: command)
    try FileManager.default.copyItem(at: try HardenedHelper.url(debuggable: true), to: command)

    let listener = try ScriptListener.start(directory: directory, commandIdentity: identity)

    defer { listener.stop() }

    let run = try await ScriptFixtures.run(
      socket: listener.path, script: ScriptFixtures.script("post-status"), executable: command)

    XCTAssertNotEqual(run.status, 0, run.standardError)
    XCTAssertTrue(run.standardError.contains("Relaunch uniterm"), run.standardError)
    XCTAssertEqual(run.standardOutput, "")
  }

  /// Catches a command from another install that is told to relaunch, or that is not told where
  /// this app's own command is.
  func testACommandFromAnotherInstallIsToldWhichCommandThisAppRuns() async throws {
    let own = try ControllerFixtures.temporaryFolder().appendingPathComponent("uniterm")

    try FileManager.default.copyItem(at: try HardenedHelper.url(debuggable: true), to: own)

    let identity = BundleHelperIdentity(helperURL: own)

    XCTAssertNotNil(identity.keptCodeDirectoryHash(), "the app could not read its own command")

    let listener = try ScriptListener.start(directory: directory, commandIdentity: identity)

    defer { listener.stop() }

    let run = try await ScriptFixtures.run(
      socket: listener.path, script: ScriptFixtures.script("post-status"),
      executable: try HardenedHelper.url())

    XCTAssertNotEqual(run.status, 0, run.standardError)
    XCTAssertTrue(run.standardError.contains(own.path), run.standardError)
    XCTAssertTrue(run.standardError.contains("another build"), run.standardError)
    XCTAssertFalse(run.standardError.contains("Relaunch"), run.standardError)
  }
}
