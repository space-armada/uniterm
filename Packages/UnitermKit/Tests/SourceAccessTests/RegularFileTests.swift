import Darwin
import XCTest

@testable import SourceAccess

final class RegularFileTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-regular-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private func write(_ name: String, _ bytes: Int) throws -> String {
    let url = folder.appendingPathComponent(name)
    try Data(repeating: 7, count: bytes).write(to: url)

    return url.path
  }

  /// Catches a read that loses bytes or stops early.
  func testAFileReadsWhole() throws {
    let path = try write("a", 200_000)

    XCTAssertEqual(try RegularFile.readAll(path: path, limit: 1 << 20).get().count, 200_000)
  }

  /// Catches a file past the limit that is read anyway, and one that is exactly at it.
  func testTheLimitIsCheckedBeforeTheReadAndHoldsAtItsEdge() throws {
    let path = try write("a", 1000)

    XCTAssertEqual(try RegularFile.readAll(path: path, limit: 1000).get().count, 1000)

    guard
      case .failure(.tooLarge(_, let bytes, let limit)) = RegularFile.readAll(
        path: path, limit: 999)
    else { return XCTFail("a file past the limit was read") }

    XCTAssertEqual(bytes, 1000)
    XCTAssertEqual(limit, 999)
  }

  /// Catches a size from `fstat` that is trusted over the bytes read. A reader told the file is
  /// small reads past the limit and stops there.
  func testTheBytesActuallyReadAreCountedAgainstTheLimit() throws {
    let path = try write("a", 100_000)
    let opened = try RegularFile.open(path: path).get()

    defer { close(opened.descriptor) }

    guard
      case .failure(.tooLarge(_, let bytes, _)) = RegularFile.read(
        descriptor: opened.descriptor, path: path, size: 10, limit: 70_000)
    else { return XCTFail("the lie about the size went through") }

    XCTAssertGreaterThan(bytes, 70_000)
  }

  /// Catches a symlink to a device or a pipe that is read as a file.
  func testADeviceAndAPipeAreNotFiles() throws {
    let link = folder.appendingPathComponent("zero").path
    let pipe = folder.appendingPathComponent("pipe").path

    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/dev/zero")
    XCTAssertEqual(mkfifo(pipe, 0o644), 0)

    for path in [link, pipe] {
      guard
        case .failure(.access(.notARegularFile(_, let kind))) = RegularFile.readAll(
          path: path, limit: 1 << 20)
      else { return XCTFail("\(path) was read") }

      XCTAssertTrue(kind == "a device" || kind == "a pipe", kind)
    }
  }

  func testAFolderAndAMissingPathAreRefused() {
    if case .success = RegularFile.open(path: folder.path) { XCTFail("a folder opened as a file") }

    guard case .failure(.missing) = RegularFile.open(path: folder.path + "/none") else {
      return XCTFail("a missing path was not reported as missing")
    }
  }
}
