import Darwin
import XCTest

@testable import TerminalApplet

private final class Finds: @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  let expectation = XCTestExpectation(description: "a remote client was found")

  func record(_ name: String) {
    lock.lock()
    names.append(name)
    lock.unlock()
    expectation.fulfill()
  }

  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return names
  }
}

/// A process table the test edits by hand, standing in for the kernel's.
private final class FakeProcesses: @unchecked Sendable {
  private let lock = NSLock()
  private var kids: [pid_t: [pid_t]] = [:]
  private var called: [pid_t: [String]] = [:]

  func set(_ pid: pid_t, names: [String], children: [pid_t] = []) {
    lock.lock()
    kids[pid] = children
    called[pid] = names
    lock.unlock()
  }

  func remove(_ pid: pid_t) {
    lock.lock()
    kids[pid] = nil
    called[pid] = nil
    lock.unlock()
  }

  var table: ProcessTable {
    ProcessTable(
      children: { pid in
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.kids[pid] ?? []
      },
      names: { pid in
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.called[pid] ?? []
      })
  }
}

/// Which process trees count as holding a remote client, and how the watcher finds one.
final class RemoteClientWatcherTests: XCTestCase {
  /// Catches a change to the list of remote clients that nobody reviewed. The list is part of the
  /// contract, and a name added or dropped changes which output clicks trust.
  func testTheListOfRemoteClientsIsThePublishedOne() {
    XCTAssertEqual(
      RemoteClients.names,
      ["ssh", "mosh-client", "mosh", "telnet", "rlogin", "rsh", "et", "autossh"])
    XCTAssertFalse(RemoteClients.isRemoteClient("sshd"))
    XCTAssertFalse(RemoteClients.isRemoteClient("zsh"))
    XCTAssertFalse(RemoteClients.isRemoteClient("kubectl"))
  }

  // MARK: Fake process events

  /// Catches a scan that stops at the root's children. The client runs two levels down, under a
  /// shell and a wrapper, and is found when a process event triggers the scan.
  func testAClientBelowTheShellIsFoundOnTheNextEvent() {
    let processes = FakeProcesses()
    processes.set(getpid(), names: ["xctest"], children: [11])
    processes.set(11, names: ["zsh"], children: [])

    let finds = Finds()
    let watcher = RemoteClientWatcher(
      root: getpid(), table: processes.table, pollInterval: nil, found: finds.record)
    watcher.drain()
    XCTAssertTrue(finds.all.isEmpty)

    processes.set(11, names: ["zsh"], children: [12])
    processes.set(12, names: ["git"], children: [13])
    processes.set(13, names: ["ssh"], children: [])
    watcher.rescan()
    watcher.drain()

    XCTAssertEqual(finds.all, ["ssh"])
  }

  /// Catches a name match that reads only the kernel's short name. A process that was started
  /// through a link has the real name only in its path.
  func testTheExecutablePathNameCountsToo() {
    let processes = FakeProcesses()
    processes.set(getpid(), names: ["xctest"], children: [21])
    processes.set(21, names: ["autoss", "autossh"], children: [])

    let finds = Finds()
    let watcher = RemoteClientWatcher(
      root: getpid(), table: processes.table, pollInterval: nil, found: finds.record)
    watcher.drain()

    XCTAssertEqual(finds.all, ["autossh"])
  }

  /// Catches a watcher that reports twice, or keeps scanning after it found a client. The marker
  /// never clears, so there is nothing left to learn.
  func testAfterFindingAClientTheWatcherSaysNothingMore() {
    let processes = FakeProcesses()
    processes.set(getpid(), names: ["xctest"], children: [31])
    processes.set(31, names: ["mosh-client"], children: [])

    let finds = Finds()
    let watcher = RemoteClientWatcher(
      root: getpid(), table: processes.table, pollInterval: nil, found: finds.record)
    watcher.drain()

    processes.set(32, names: ["ssh"], children: [])
    processes.set(getpid(), names: ["xctest"], children: [31, 32])
    watcher.rescan()
    watcher.rescan()
    watcher.drain()

    XCTAssertEqual(finds.all, ["mosh-client"])
  }

  /// Names a known gap. A client that starts and ends between two scans leaves no trace, so the
  /// watcher finds nothing. The limit is stated in the proposal.
  func testAClientThatExitsBeforeTheScanIsMissed() {
    let processes = FakeProcesses()
    processes.set(getpid(), names: ["xctest"], children: [])

    let finds = Finds()
    let watcher = RemoteClientWatcher(
      root: getpid(), table: processes.table, pollInterval: nil, found: finds.record)
    watcher.drain()

    processes.set(41, names: ["ssh"], children: [])
    processes.set(getpid(), names: ["xctest"], children: [41])
    processes.remove(41)
    processes.set(getpid(), names: ["xctest"], children: [])
    watcher.rescan()
    watcher.drain()

    XCTAssertTrue(finds.all.isEmpty)
  }

  /// Catches a watcher that goes on after it was stopped.
  func testAStoppedWatcherNeverReports() {
    let processes = FakeProcesses()
    processes.set(getpid(), names: ["xctest"], children: [])

    let finds = Finds()
    let watcher = RemoteClientWatcher(
      root: getpid(), table: processes.table, pollInterval: nil, found: finds.record)
    watcher.drain()
    watcher.stop()

    processes.set(51, names: ["ssh"], children: [])
    processes.set(getpid(), names: ["xctest"], children: [51])
    watcher.rescan()
    watcher.drain()

    XCTAssertTrue(finds.all.isEmpty)
  }

  /// Catches a scan with no bound. A table that loops, as a process that lists itself as a child,
  /// must end.
  func testACyclicTableEnds() {
    let processes = FakeProcesses()
    processes.set(getpid(), names: ["xctest"], children: [61])
    processes.set(61, names: ["zsh"], children: [62])
    processes.set(62, names: ["zsh"], children: [61, getpid()])

    let finds = Finds()
    let watcher = RemoteClientWatcher(
      root: getpid(), table: processes.table, pollInterval: nil, found: finds.record)
    watcher.drain()

    XCTAssertTrue(finds.all.isEmpty)
  }

  // MARK: Real processes

  private var children: [pid_t] = []
  private var scratch: URL?

  override func tearDown() {
    for pid in children {
      // Each child leads its own process group, and the unreaped leader holds the group id. So the
      // group signal reaches the client `sh` forked, and no other process can take the id.
      killpg(pid, SIGKILL)

      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }

    children = []

    if let scratch { try? FileManager.default.removeItem(at: scratch) }

    scratch = nil
  }

  /// A copy of `sleep` under the given name, signed again, since a copied system binary carries
  /// a signature for its old place.
  private func makeProgram(named name: String) throws -> String {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appending(path: "uniterm-remote-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    scratch = folder

    let path = folder.appending(path: name).path
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)

    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    XCTAssertEqual(sign.terminationStatus, 0)

    return path
  }

  private func spawn(_ path: String, _ arguments: [String]) throws -> pid_t {
    var pid: pid_t = 0
    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]

    defer {
      for word in argv { free(word) }
    }

    var attributes: posix_spawnattr_t?

    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)

    defer { posix_spawnattr_destroy(&attributes) }

    let status = posix_spawn(&pid, path, nil, &attributes, &argv, environ)
    XCTAssertEqual(status, 0, "posix_spawn \(path) failed with \(status)")
    children.append(pid)
    return pid
  }

  /// Catches a watcher whose process events do not fire for a real fork and exec. The watcher
  /// starts first, with no timer, and the client appears after. The shell forks the client, so the
  /// client is a grandchild of the root.
  func testARealClientStartedAfterTheWatcherIsFoundByProcessEvents() async throws {
    let program = try makeProgram(named: "ssh")

    let finds = Finds()
    let watcher = RemoteClientWatcher(root: getpid(), pollInterval: nil, found: finds.record)
    watcher.drain()

    _ = try spawn("/bin/sh", ["-c", "\"$0\" 30; true", program])

    await fulfillment(of: [finds.expectation], timeout: 20)

    XCTAssertEqual(finds.all, ["ssh"])
    watcher.stop()
  }

  /// Catches a watcher that calls any process with the wrong name a remote client.
  func testARealProgramWithAnotherNameIsNotAClient() throws {
    let program = try makeProgram(named: "sshd-not")
    _ = try spawn(program, ["30"])

    let finds = Finds()
    let watcher = RemoteClientWatcher(root: getpid(), pollInterval: nil, found: finds.record)
    watcher.rescan()
    watcher.drain()

    XCTAssertTrue(finds.all.isEmpty)
    watcher.stop()
  }
}
