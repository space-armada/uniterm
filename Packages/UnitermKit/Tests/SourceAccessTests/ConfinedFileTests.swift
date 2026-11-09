import Darwin
import XCTest

@testable import SourceAccess

final class ConfinedFileTests: XCTestCase {
  private func folder(_ scratch: Scratch, _ sub: String = "") throws -> ConfinedFile.Folder {
    try ConfinedFile.Folder.at(path: scratch.url.appendingPathComponent(sub).path).get()
  }

  private func read(_ name: String, in folder: ConfinedFile.Folder) -> Result<
    String, ConfinedFileError
  > {
    ConfinedFile.open(name: name, in: folder).map { opened in
      defer { Darwin.close(opened.descriptor) }

      let data = RegularFile.read(
        descriptor: opened.descriptor, path: name, size: opened.info.size, limit: 1 << 20)

      return (try? data.get()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
  }

  /// Catches a walk that cannot reach the files a document names: a plain name, a nested one, a
  /// `..` that stays on the volume, and a relative link inside the folder.
  func testNamesInsideTheVolumeOpen() throws {
    let scratch = try Scratch(self)

    try FileManager.default.createDirectory(
      at: scratch.url.appendingPathComponent("docs/img"), withIntermediateDirectories: true)
    try scratch.write("docs/a.txt", "a")
    try scratch.write("docs/img/b.txt", "b")
    try scratch.write("shared.txt", "shared")
    try FileManager.default.createSymbolicLink(
      atPath: scratch.url.appendingPathComponent("docs/link.txt").path, withDestinationPath: "a.txt"
    )

    let docs = try folder(scratch, "docs")

    XCTAssertEqual(try read("a.txt", in: docs).get(), "a")
    XCTAssertEqual(try read("img/b.txt", in: docs).get(), "b")
    XCTAssertEqual(try read("./img/../a.txt", in: docs).get(), "a")
    XCTAssertEqual(try read("../shared.txt", in: docs).get(), "shared")
    XCTAssertEqual(try read("link.txt", in: docs).get(), "a")
  }

  /// Catches names the walk must refuse before it opens anything: root-relative, empty, and
  /// control characters.
  func testNamesThatAreNotRelativePathsAreRefused() throws {
    let scratch = try Scratch(self)
    let docs = try folder(scratch)

    for name in ["/etc/hosts", "", "a\0b", "//x", "."] {
      XCTAssertEqual(
        ConfinedFile.open(name: name, in: docs).failure, .invalidName,
        "name: \(name.debugDescription)")
    }
  }

  /// Catches a walk that follows a link to another volume. The root of `/dev` is a different
  /// filesystem, so a link to a device node stops at the mount, before any device is opened. `net`
  /// and `Volumes` are refused by name without a lookup.
  func testLinksIntoOtherVolumesAreRefused() throws {
    let scratch = try Scratch(self)

    for (name, target) in [
      ("zero.png", "/dev/zero"), ("net.png", "/net/host/a.png"),
      ("volumes.png", "/Volumes/Other/a.png"), ("home.png", "/home/a.png"),
    ] {
      try FileManager.default.createSymbolicLink(
        atPath: scratch.url.appendingPathComponent(name).path, withDestinationPath: target)
    }

    let docs = try folder(scratch)

    for name in ["zero.png", "net.png", "volumes.png", "home.png"] {
      XCTAssertEqual(ConfinedFile.open(name: name, in: docs).failure, .leavesVolume, name)
    }
  }

  /// Catches a `..` chain that escapes onto another filesystem. `/dev` is its own mount, so a chain
  /// that climbs to the root and steps into it stops at the mount, before any device opens. The
  /// system and Data volumes report one device, so the walk treats them as one volume.
  func testClimbingOntoAnotherMountIsRefused() throws {
    let scratch = try Scratch(self)
    let docs = try folder(scratch)
    let climb = String(repeating: "../", count: 24) + "dev/zero"

    XCTAssertEqual(ConfinedFile.open(name: climb, in: docs).failure, .leavesVolume)
  }

  /// Catches a file that is not data: a FIFO opens without blocking and is refused, and a folder
  /// is refused.
  func testPipesAndFoldersAreNotFiles() throws {
    let scratch = try Scratch(self)

    XCTAssertEqual(mkfifo(scratch.url.appendingPathComponent("pipe.png").path, 0o600), 0)
    try FileManager.default.createDirectory(
      at: scratch.url.appendingPathComponent("dir.png"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: scratch.url.appendingPathComponent("pipelink.png").path,
      withDestinationPath: "pipe.png")

    let docs = try folder(scratch)

    XCTAssertEqual(ConfinedFile.open(name: "pipe.png", in: docs).failure, .notAFile)
    XCTAssertEqual(ConfinedFile.open(name: "pipelink.png", in: docs).failure, .notAFile)
    XCTAssertEqual(ConfinedFile.open(name: "dir.png", in: docs).failure, .notAFile)
  }

  /// Catches a loop of links that would spin, and a missing file that reads as a refusal.
  func testLinkLoopsStopAndMissingFilesAreMissing() throws {
    let scratch = try Scratch(self)

    try FileManager.default.createSymbolicLink(
      atPath: scratch.url.appendingPathComponent("loop.png").path, withDestinationPath: "loop.png")

    let docs = try folder(scratch)

    XCTAssertEqual(ConfinedFile.open(name: "loop.png", in: docs).failure, .tooManyLinks)
    XCTAssertEqual(ConfinedFile.open(name: "gone.png", in: docs).failure, .missing)
    XCTAssertEqual(ConfinedFile.open(name: "gone/deeper.png", in: docs).failure, .missing)
  }
}

extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }

    return nil
  }
}
