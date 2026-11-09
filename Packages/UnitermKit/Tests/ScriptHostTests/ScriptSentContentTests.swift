import Darwin
import Foundation
import ScriptWire
import XCTest

@testable import ScriptHost

/// The folder where content a script sends waits. These prove who can read it, which names it
/// takes, what it holds at most, and that a second instance never removes the first one's files.
/// They cannot prove that a viewer reads a file, which `WindowScriptingTests` covers.
final class ScriptSentContentTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-sent-\(UUID().uuidString.prefix(8))", isDirectory: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func mode(_ url: URL) throws -> mode_t {
    var info = stat()

    guard stat(url.path, &info) == 0 else { throw WireError.io(errno) }

    return info.st_mode & 0o777
  }

  /// Catches a spool that another user can enter or read. The root, the instance folder, each
  /// send's folder, and the file all deny everyone but the user.
  func testEveryLevelIsPrivate() throws {
    let store = try ScriptSentContent(root: root)
    let file = try store.write(Data("synthetic".utf8), named: "a.txt")

    XCTAssertEqual(try mode(root), 0o700)
    XCTAssertEqual(try mode(root.appendingPathComponent(ProcessIdentity.current.folderName)), 0o700)
    XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
    XCTAssertEqual(try mode(file), 0o600)
    XCTAssertEqual(try Data(contentsOf: file), Data("synthetic".utf8))
    XCTAssertEqual(file.lastPathComponent, "a.txt")
  }

  /// Catches a name that escapes the folder, or one that routes by a trick. Only a plain file name
  /// is accepted, and the extension is what the viewer routes by.
  func testOnlyAPlainFileNameIsAccepted() throws {
    let store = try ScriptSentContent(root: root)

    for name in [
      "", "a/b.txt", "/etc/hosts", ".hidden", "..", "a\u{0}b", String(repeating: "n", count: 256),
    ] {
      XCTAssertThrowsError(try store.write(Data(), named: name), "\(name.debugDescription)") {
        XCTAssertEqual(($0 as? ScriptCallError)?.kind, .badArgument)
      }
    }

    XCTAssertNoThrow(try store.write(Data(), named: "caf\u{00E9}.txt"))
  }

  /// Catches content past the wire's limit being written.
  func testContentPastTheLimitIsRefused() throws {
    let store = try ScriptSentContent(root: root)

    XCTAssertThrowsError(
      try store.write(Data(count: ScriptProtocol.maxSendBytes + 1), named: "big.bin")
    ) {
      XCTAssertEqual(($0 as? ScriptCallError)?.kind, .badArgument)
    }
  }

  /// Catches a launch that removes the files of another running instance, one that leaves the files
  /// of an instance that ended, and one that trusts a reused process ID. A folder survives only
  /// when its process exists and started at the second the folder names.
  func testALaunchRemovesOnlyWhatEndedInstancesLeft() throws {
    let fileManager = FileManager.default
    let parent = getppid()
    let started = try XCTUnwrap(ProcessIdentity.startTime(of: parent))

    var gone: pid_t = 99_990

    while ProcessIdentity.startTime(of: gone) != nil { gone += 1 }

    let alive = ProcessIdentity(pid: parent, started: started)
    let ended = ProcessIdentity(pid: gone, started: 1_700_000_000)
    let reused = ProcessIdentity(pid: parent, started: started + 1)

    for identity in [alive, ended, reused, .current] {
      let folder = root.appendingPathComponent(identity.folderName, isDirectory: true)

      try fileManager.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      fileManager.createFile(
        atPath: folder.appendingPathComponent("old.txt").path, contents: Data())
    }

    _ = try ScriptSentContent(root: root)

    func exists(_ identity: ProcessIdentity) -> Bool {
      fileManager.fileExists(atPath: root.appendingPathComponent(identity.folderName).path)
    }

    XCTAssertTrue(exists(alive), "another running instance lost its folder")
    XCTAssertFalse(exists(ended), "an ended instance left its folder")
    XCTAssertFalse(exists(reused), "a reused process ID kept a dead instance's folder")
    XCTAssertFalse(
      fileManager.fileExists(
        atPath: root.appendingPathComponent(ProcessIdentity.current.folderName + "/old.txt").path),
      "this instance started with an old file")
  }

  /// Catches a script that fills the disk. Past the budget, a send is refused. A discarded file
  /// gives its bytes back.
  func testTheBudgetRefusesMoreAndGivesBackWhatIsDiscarded() throws {
    let chunk = 1000
    let store = try ScriptSentContent(root: root, budget: 3 * chunk)
    var files: [URL] = []

    for _ in 0..<3 {
      files.append(try store.write(Data(count: chunk), named: "c.bin"))
    }

    XCTAssertThrowsError(try store.write(Data(count: 1), named: "more.bin")) {
      XCTAssertEqual(($0 as? ScriptCallError)?.kind, .refused)
    }

    store.discard(files.removeLast(), size: chunk)

    XCTAssertNoThrow(try store.write(Data(count: 1), named: "more.bin"))
  }
}
