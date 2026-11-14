import Darwin
import Foundation
import ScriptWire
import XCTest

@testable import ScriptHost

/// The installer's file-system work, against a fake bundle and a fake home in a temporary folder.
/// The save panel that picks the place is UI and is not covered here.
///
/// They prove that the link points into the bundle and is never a copy, that an existing link is
/// replaced, that a file or a folder is refused and left alone, and that a folder off the usual
/// path is reported. They cannot prove how the panel passes a place to the installer.
final class ScriptCommandInstallerTests: XCTestCase {
  private var root: URL!
  private var home: URL!
  private var command: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true)
    command = ScriptCommandInstaller.command(in: root.appendingPathComponent("uniterm.app"))

    try FileManager.default.createDirectory(
      at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    try Data("#!/bin/sh\n".utf8).write(to: command)

    XCTAssertEqual(chmod(command.path, 0o755), 0)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func installer() -> ScriptCommandInstaller {
    ScriptCommandInstaller(command: command, home: home)
  }

  private func destination(_ link: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
  }

  /// Catches an install that copies the command, links to the wrong place, or fails when the
  /// folder is missing. The default folder is made, and the link leads to the bundle's command.
  func testInstallCreatesTheFolderAndALinkIntoTheBundle() throws {
    let tool = installer()
    let link = tool.defaultDirectory.appendingPathComponent("uniterm")

    XCTAssertFalse(FileManager.default.fileExists(atPath: tool.defaultDirectory.path))

    let installed = try tool.install(at: link)

    XCTAssertEqual(try destination(link), command.path)
    XCTAssertFalse(installed.replaced)
    XCTAssertTrue(installed.onPath)
    XCTAssertTrue(installed.message.contains("Installed"), installed.message)
    XCTAssertFalse(installed.message.contains("PATH"), installed.message)
  }

  /// Catches an install that fails over an older link, or that leaves a moment with no command. A
  /// link to a moved bundle is replaced by one to this bundle.
  func testInstallReplacesAnExistingSymlink() throws {
    let tool = installer()
    let link = tool.defaultDirectory.appendingPathComponent("uniterm")

    try FileManager.default.createDirectory(
      at: tool.defaultDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "/old/uniterm.app/Contents/Helpers/uniterm")

    let installed = try tool.install(at: link)

    XCTAssertEqual(try destination(link), command.path)
    XCTAssertTrue(installed.replaced)
    XCTAssertTrue(installed.message.contains("Updated"), installed.message)

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: tool.defaultDirectory.path)

    XCTAssertEqual(leftovers, ["uniterm"], "the install left a temporary link behind")
  }

  /// Catches an install that overwrites a user's own file or folder. Both are refused with a
  /// message that names the place, and neither is touched.
  func testInstallRefusesARegularFileOrAFolderAndLeavesItAlone() throws {
    let tool = installer()
    let bin = tool.defaultDirectory

    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

    let file = bin.appendingPathComponent("uniterm")

    try Data("mine".utf8).write(to: file)

    XCTAssertThrowsError(try tool.install(at: file)) { error in
      XCTAssertEqual(
        error as? ScriptCommandInstaller.InstallError, .occupied(file.path, kind: "a file"))
      XCTAssertTrue("\(error)".contains(file.path))
    }

    XCTAssertEqual(try Data(contentsOf: file), Data("mine".utf8))

    let folder = bin.appendingPathComponent("folder", isDirectory: true)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

    XCTAssertThrowsError(try tool.install(at: folder)) { error in
      XCTAssertEqual(
        error as? ScriptCommandInstaller.InstallError, .occupied(folder.path, kind: "a folder"))
    }

    var isDirectory: ObjCBool = false

    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
  }

  /// Catches an install that links to a command the bundle does not hold, which would leave a
  /// dangling link that the user could not tell from a working one.
  func testInstallRefusesWhenTheBundleHasNoCommand() throws {
    try FileManager.default.removeItem(at: command)

    let link = installer().defaultDirectory.appendingPathComponent("uniterm")

    XCTAssertThrowsError(try installer().install(at: link)) { error in
      XCTAssertEqual(
        error as? ScriptCommandInstaller.InstallError, .commandMissing(command.path))
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
  }

  /// Catches a folder off the usual path going unmentioned. The message says so and names the
  /// folder. The usual folders, and the user's own `.local/bin`, say nothing.
  func testInstallTellsTheUserWhenTheFolderIsNotOnTheUsualPath() throws {
    let tool = installer()
    let odd = root.appendingPathComponent("elsewhere", isDirectory: true)
    let installed = try tool.install(at: odd.appendingPathComponent("uniterm"))

    XCTAssertFalse(installed.onPath)
    XCTAssertTrue(installed.message.contains("not one of the usual folders"), installed.message)
    XCTAssertTrue(installed.message.contains(odd.path), installed.message)

    let usual = home.appendingPathComponent("bin", isDirectory: true)

    XCTAssertTrue(try tool.install(at: usual.appendingPathComponent("uniterm")).onPath)
  }

  /// Catches the installer and the app disagreeing about where the bundle's command is.
  func testTheCommandLivesInTheHelpersFolderOfTheBundle() {
    XCTAssertEqual(
      ScriptCommandInstaller.command(in: URL(fileURLWithPath: "/Applications/uniterm.app")).path,
      "/Applications/uniterm.app/Contents/Helpers/uniterm")
  }

  /// Catches a file that appears in an empty place after the installer looked. The place is claimed
  /// with an exclusive rename, so the user's file is never replaced, and its bytes survive.
  func testAFileThatAppearsInAnEmptyPlaceIsNeverReplaced() throws {
    var tool = installer()
    let link = tool.defaultDirectory.appendingPathComponent("uniterm")

    try FileManager.default.createDirectory(
      at: tool.defaultDirectory, withIntermediateDirectories: true)

    tool.beforeCommit = { try? Data("mine".utf8).write(to: link) }

    XCTAssertThrowsError(try tool.install(at: link)) { error in
      XCTAssertEqual(
        error as? ScriptCommandInstaller.InstallError, .occupied(link.path, kind: "a file"))
    }

    XCTAssertEqual(try Data(contentsOf: link), Data("mine".utf8))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: tool.defaultDirectory.path), ["uniterm"],
      "the install left its temporary link behind")
  }

  /// Catches a symlink that the user swaps for a file after the installer looked. The swap takes
  /// the file out and the installer puts it back, so the file is intact and the install is refused.
  func testAFileThatReplacesASymlinkAfterTheLookIsPutBack() throws {
    var tool = installer()
    let link = tool.defaultDirectory.appendingPathComponent("uniterm")

    try FileManager.default.createDirectory(
      at: tool.defaultDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/old")

    tool.beforeCommit = {
      try? FileManager.default.removeItem(at: link)
      try? Data("mine".utf8).write(to: link)
    }

    XCTAssertThrowsError(try tool.install(at: link)) { error in
      XCTAssertEqual(
        error as? ScriptCommandInstaller.InstallError, .occupied(link.path, kind: "a file"))
    }

    XCTAssertEqual(try Data(contentsOf: link), Data("mine".utf8))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: tool.defaultDirectory.path), ["uniterm"])
  }

  /// Catches a link to a translocated or read-only app, which would dangle once the app quits. The
  /// install is refused with a message to move uniterm, and no link is made.
  func testInstallRefusesAnAppThatRunsFromAPlaceThatWillNotLast() throws {
    let moved = root.appendingPathComponent("AppTranslocation/ABC/d/uniterm.app")
    let translocated = ScriptCommandInstaller.command(in: moved)

    try FileManager.default.createDirectory(
      at: translocated.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: command, to: translocated)

    let link = installer().defaultDirectory.appendingPathComponent("uniterm")

    for tool in [
      ScriptCommandInstaller(command: translocated, home: home),
      ScriptCommandInstaller(command: command, home: home, isReadOnly: { _ in true }),
    ] {
      XCTAssertThrowsError(try tool.install(at: link)) { error in
        guard case .unstableLocation = error as? ScriptCommandInstaller.InstallError else {
          return XCTFail("\(error)")
        }

        XCTAssertTrue("\(error)".contains("Applications"), "\(error)")
      }
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
  }
}
