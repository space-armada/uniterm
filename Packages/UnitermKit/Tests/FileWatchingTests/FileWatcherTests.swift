import Foundation
import XCTest

@testable import FileWatching

/// These tests use the real file system and short windows. Each one waits only for the event it
/// expects, and the one that expects silence waits a third of a second.
@MainActor
final class FileWatcherTests: XCTestCase {
  private static let policy = WatchPolicy(
    settle: 0.05, ceiling: 0.5, watchesFolder: true, retryLimit: nil, retryInterval: 0.05)

  private final class Log {
    var signatures: [FileSignature] = []
    var waiter: XCTestExpectation?
    var target = 0

    func record(_ signature: FileSignature) {
      signatures.append(signature)

      if signatures.count >= target { waiter?.fulfill() }
    }
  }

  private func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("filewatching-\(UUID().uuidString)").resolvingSymlinksInPath()

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    return folder
  }

  private func watch(_ file: URL, policy: WatchPolicy = FileWatcherTests.policy) async -> (
    FileWatcher, Log
  ) {
    let log = Log()
    let watcher = FileWatcher(url: file, policy: policy) { log.record($0) }
    addTeardownBlock { @MainActor in watcher.stop() }
    await watcher.whenArmed()

    return (watcher, log)
  }

  private func next(_ log: Log, count: Int, _ action: () throws -> Void) async throws {
    let waiter = expectation(description: "delivery \(count)")

    log.waiter = waiter
    log.target = count

    try action()
    await fulfillment(of: [waiter], timeout: 5)
  }

  /// Catches a watch that never sees a write in place.
  func testAWriteInPlaceDelivers() async throws {
    let file = try scratch().appendingPathComponent("a.txt")
    try Data("one".utf8).write(to: file)
    let (_, log) = await watch(file)

    try await next(log, count: 1) { try Data("two, longer".utf8).write(to: file) }

    XCTAssertEqual(log.signatures.last?.exists, true)
  }

  /// Catches a watch that follows the old file after an editor renames a new one over it, and one
  /// that stops watching after the rename.
  func testWriteNewThenRenameDeliversAndTheNextWriteStillDoes() async throws {
    let folder = try scratch()
    let file = folder.appendingPathComponent("a.txt")
    try Data("one".utf8).write(to: file)
    let (_, log) = await watch(file)

    let replacement = folder.appendingPathComponent(".a.txt.tmp")
    try await next(log, count: 1) {
      try Data("two".utf8).write(to: replacement)
      XCTAssertEqual(rename(replacement.path, file.path), 0)
    }

    let before = log.signatures.count

    try await next(log, count: before + 1) { try Data("three three".utf8).write(to: file) }
  }

  /// Catches a folder watch that notes every neighbor's change. The neighbors churn first, then the
  /// file itself changes. The injected scheduler counts the notes, so the one that the file's own
  /// write makes is the only one, and nothing waits for an absence.
  func testChangesToOtherFilesInTheFolderDeliverNothing() async throws {
    let folder = try scratch()
    let file = folder.appendingPathComponent("a.txt")
    try Data("one".utf8).write(to: file)

    let scheduler = ManualScheduler()
    let noted = expectation(description: "the file's own write is noted")
    noted.assertForOverFulfill = false
    scheduler.onSchedule = { noted.fulfill() }

    let watcher = FileWatcher(url: file, policy: Self.policy, scheduler: scheduler) { _ in }
    addTeardownBlock { @MainActor in watcher.stop() }
    await watcher.whenArmed()

    let neighbor = folder.appendingPathComponent("b.txt")
    try Data("x".utf8).write(to: neighbor)
    try Data("xy".utf8).write(to: neighbor)
    try FileManager.default.moveItem(at: neighbor, to: folder.appendingPathComponent("c.txt"))
    try FileManager.default.removeItem(at: folder.appendingPathComponent("c.txt"))
    try Data("two two".utf8).write(to: file)

    await fulfillment(of: [noted], timeout: 5)

    XCTAssertEqual(scheduler.scheduled, 1)
  }

  /// Catches a delete that the watch loses, and a file that comes back unseen. The delivery after
  /// the delete says the file is gone, and the one after it says it is back.
  func testADeletedFileReportsGoneThenBack() async throws {
    let file = try scratch().appendingPathComponent("a.txt")
    try Data("one".utf8).write(to: file)
    let (_, log) = await watch(file)

    try await next(log, count: 1) { try FileManager.default.removeItem(at: file) }
    XCTAssertEqual(log.signatures.last?.exists, false)

    try await next(log, count: 2) { try Data("back".utf8).write(to: file) }
    XCTAssertEqual(log.signatures.last?.exists, true)
  }

  /// Catches a watch that dies with its folder. The folder is deleted whole and made again with
  /// the file in it, and the watch reports the file back.
  func testADeletedAndRecreatedFolderReportsTheFileBack() async throws {
    let folder = try scratch().appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let file = folder.appendingPathComponent("a.txt")
    try Data("one".utf8).write(to: file)
    let (_, log) = await watch(file)

    try await next(log, count: 1) { try FileManager.default.removeItem(at: folder) }
    XCTAssertEqual(log.signatures.last?.exists, false)

    try await next(log, count: 2) {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      try Data("again".utf8).write(to: file)
    }
    XCTAssertEqual(log.signatures.last?.exists, true)
  }

  /// Catches a stopped watch that still calls back. A second watcher on the same file is the
  /// sentinel: once it has delivered the write, the stopped one had every chance to.
  func testAStoppedWatchDeliversNothing() async throws {
    let file = try scratch().appendingPathComponent("a.txt")
    try Data("one".utf8).write(to: file)
    let (stopped, stoppedLog) = await watch(file)
    let (_, sentinelLog) = await watch(file)

    stopped.stop()

    try await next(sentinelLog, count: 1) { try Data("two two".utf8).write(to: file) }

    XCTAssertEqual(stoppedLog.signatures.count, 0)
  }

  /// Catches a map watch that changed: with the file-only policy, a neighbor's change in the
  /// folder is not watched, and the file's own write arrives at once.
  func testTheFileOnlyPolicyDeliversAWriteWithoutCoalescing() async throws {
    let file = try scratch().appendingPathComponent("a.txt")
    try Data("one".utf8).write(to: file)
    let (_, log) = await watch(file, policy: .fileOnly)

    try await next(log, count: 1) { try Data("two two".utf8).write(to: file) }
  }

  /// Catches a watch that blocks the main thread on a named pipe. Opening a pipe for reading waits
  /// for a writer unless the open is non-blocking, and a viewer can be pointed at any path.
  func testWatchingANamedPipeNeverBlocks() async throws {
    let pipe = try scratch().appendingPathComponent("pipe.md")

    XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)

    let (watcher, _) = await watch(pipe, policy: .document)

    watcher.stop()
  }
}
