import ControllerTestSupport
import Foundation
import XCTest

@testable import ScriptHost

/// The app's own command, as the app kept it at launch. These tests prove that the kept hash is the
/// command's, and that a command put on disk later is never taken for it. They cannot prove a swap
/// of a bundle under a running app, which `CommandIdentityTests` covers from the peer's side.
final class BundleHelperIdentityTests: XCTestCase {
  /// Catches an app that adopts a command it finds on disk after launch. The kept hash is the one
  /// read first, so a replaced file never becomes the app's own command.
  func testACommandReplacedOnDiskAfterTheFirstReadIsNeverAdopted() throws {
    let folder = try ControllerFixtures.temporaryFolder()
    let command = folder.appendingPathComponent("uniterm")

    try FileManager.default.copyItem(at: try HardenedHelper.url(), to: command)

    let identity = BundleHelperIdentity(helperURL: command)
    let first = try XCTUnwrap(identity.keptCodeDirectoryHash())

    XCTAssertEqual(first, CodeIdentity.ofFile(at: try HardenedHelper.url())?.codeDirectoryHash)

    try FileManager.default.removeItem(at: command)
    try FileManager.default.copyItem(at: ScriptFixtures.helper(), to: command)

    let swapped = try XCTUnwrap(CodeIdentity.ofFile(at: command)?.codeDirectoryHash)

    XCTAssertNotEqual(swapped, first, "the fixture must differ from the kept command")
    XCTAssertEqual(identity.keptCodeDirectoryHash(), first)
    XCTAssertEqual(identity.commandPath, command.path)
  }

  /// Catches an app that adopts a command which becomes readable after launch. A command that was
  /// unreadable at launch stays unreadable for the life of the process, so a file put there later
  /// is never taken for the app's own command, and the refusals for an unreadable command apply.
  func testACommandUnreadableAtLaunchIsNeverAdoptedWhenItAppearsLater() throws {
    let folder = try ControllerFixtures.temporaryFolder()
    let command = folder.appendingPathComponent("uniterm")
    let identity = BundleHelperIdentity(helperURL: command)

    XCTAssertNil(identity.keptCodeDirectoryHash())

    try FileManager.default.copyItem(at: try HardenedHelper.url(), to: command)

    XCTAssertNotNil(CodeIdentity.ofFile(at: command), "the replacement must be a valid command")
    XCTAssertNil(identity.keptCodeDirectoryHash(), "a command that appeared later was adopted")
  }
}
