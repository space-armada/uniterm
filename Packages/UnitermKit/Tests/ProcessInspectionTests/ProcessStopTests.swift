import Darwin
import XCTest

@testable import ProcessInspection

/// A child these tests stop and continue. Every test ends its children in teardown, with a
/// continue first, so a stopped child never outlives its test.
private final class StopChild {
  let pid: pid_t
  let started: Int
  let ownGroup: Bool
  private var reaped = false

  init(_ arguments: [String], ownGroup: Bool) throws {
    var attributes: posix_spawnattr_t?

    posix_spawnattr_init(&attributes)

    defer { posix_spawnattr_destroy(&attributes) }

    if ownGroup {
      posix_spawnattr_setpgroup(&attributes, 0)
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    }

    let argv = arguments.map { strdup($0) } + [nil]

    defer {
      for word in argv { free(word) }
    }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, arguments[0], nil, &attributes, argv, environ)

    guard status == 0 else { throw POSIXError(.init(rawValue: status) ?? .EIO) }

    self.pid = pid
    self.ownGroup = ownGroup

    guard let started = ProcessInspection.startTimeMicroseconds(of: pid) else {
      throw POSIXError(.ESRCH)
    }

    self.started = started
  }

  /// Ends the child and everything in its group, and collects it. A stopped group is continued
  /// first, so nothing is left frozen.
  func end() {
    guard !reaped else { return }

    reaped = true

    if ownGroup {
      killpg(pid, SIGCONT)
      killpg(pid, SIGKILL)
    } else {
      kill(pid, SIGCONT)
      kill(pid, SIGKILL)
    }

    var status: Int32 = 0

    waitpid(pid, &status, 0)
  }
}

/// What the system says about a stopped process, and the group signal that stops one. These pin the
/// facts the suspend feature rests on: a helper that leads its own group can be stopped with its
/// children, a process that shares the caller's group is never signalled, and the state of a
/// stopped process reads from outside.
final class ProcessStopTests: XCTestCase {
  private var children: [StopChild] = []

  override func tearDown() {
    for child in children { child.end() }

    children = []
  }

  private func spawn(_ arguments: [String], ownGroup: Bool = true) throws -> StopChild {
    let child = try StopChild(arguments, ownGroup: ownGroup)

    children.append(child)

    return child
  }

  private func waitUntil(_ description: String, _ condition: () -> Bool) throws {
    let deadline = ContinuousClock.now + .seconds(10)

    while !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("timed out waiting for \(description)")

        throw CancellationError()
      }

      usleep(10_000)
    }
  }

  // MARK: State

  /// Catches a stop that never reads as one, and a continue that reads as stopped. A process that is
  /// gone reads as nothing, so a caller never takes it for running.
  func testAStoppedProcessReadsAsStoppedAndAContinuedOneAsRunning() throws {
    let child = try spawn(["/bin/sleep", "30"])

    XCTAssertEqual(ProcessInspection.isStopped(pid: child.pid), false)

    XCTAssertEqual(kill(child.pid, SIGSTOP), 0)
    try waitUntil("the child to read as stopped") {
      ProcessInspection.isStopped(pid: child.pid) == true
    }

    XCTAssertEqual(kill(child.pid, SIGCONT), 0)
    try waitUntil("the child to read as running") {
      ProcessInspection.isStopped(pid: child.pid) == false
    }

    child.end()

    XCTAssertNil(ProcessInspection.isStopped(pid: child.pid))
  }

  /// Catches a stop read that trusts a pid the system has handed to another process.
  func testAStartTimeThatDoesNotMatchReadsAsNothing() throws {
    let child = try spawn(["/bin/sleep", "30"])

    XCTAssertEqual(
      ProcessInspection.isStopped(pid: child.pid, startedMicroseconds: child.started), false)
    XCTAssertNil(
      ProcessInspection.isStopped(pid: child.pid, startedMicroseconds: child.started + 1))
  }

  // MARK: Own group

  /// A helper started with a group of its own leads it, so a group stop reaches it and what it
  /// started. This is the fact the REPL's pty session leader and an exec driver both rely on.
  func testAChildStartedInItsOwnGroupLeadsIt() throws {
    let child = try spawn(["/bin/sleep", "30"])

    XCTAssertEqual(ProcessInspection.processGroup(of: child.pid), child.pid)
    XCTAssertTrue(ProcessInspection.leadsItsOwnGroup(child.pid))
  }

  /// Catches a group signal that would reach the caller's own group. The child shares the test's
  /// group, as a helper spawned without one does. Nothing is sent, and the test process and the
  /// child both keep running.
  func testAProcessInTheCallersGroupIsNeverSignalled() throws {
    let child = try spawn(["/bin/sleep", "30"], ownGroup: false)

    XCTAssertEqual(ProcessInspection.processGroup(of: child.pid), getpgrp())
    XCTAssertFalse(ProcessInspection.leadsItsOwnGroup(child.pid))

    XCTAssertEqual(
      ProcessInspection.signalGroup(SIGSTOP, leader: child.pid, startedMicroseconds: child.started),
      .refused)
    XCTAssertEqual(ProcessInspection.isStopped(pid: child.pid), false)
  }

  /// Catches a guard that lets the caller's own process through.
  func testTheCallersOwnProcessAndPidOneAreRefused() {
    XCTAssertEqual(
      ProcessInspection.signalGroup(SIGSTOP, leader: getpid(), startedMicroseconds: 0), .refused)
    XCTAssertEqual(
      ProcessInspection.signalGroup(SIGSTOP, leader: 1, startedMicroseconds: 0), .refused)
    XCTAssertFalse(ProcessInspection.leadsItsOwnGroup(getpid()))
    XCTAssertFalse(ProcessInspection.leadsItsOwnGroup(1))
  }

  /// Catches a signal that reaches a process ID another process took. A start time that does not
  /// match reads as gone, and the child is left alone.
  func testAGroupSignalNeedsTheRecordedStartTime() throws {
    let child = try spawn(["/bin/sleep", "30"])

    XCTAssertEqual(
      ProcessInspection.signalGroup(
        SIGSTOP, leader: child.pid, startedMicroseconds: child.started + 1), .gone)
    XCTAssertEqual(ProcessInspection.isStopped(pid: child.pid), false)
  }

  /// Catches a stop that reaches the leader and misses a program the leader started. The shell
  /// leads its own group, and its sleep is in that group, so one stop freezes both and one
  /// continue thaws both.
  func testAGroupStopFreezesTheLeaderAndAProgramItStarted() throws {
    let leader = try spawn(["/bin/sh", "-c", "/bin/sleep 30 & wait"])

    var member: pid_t = 0

    try waitUntil("the shell to start its sleep") {
      member = ProcessInspection.children(of: leader.pid).first ?? 0

      return member > 0
    }

    XCTAssertEqual(ProcessInspection.processGroup(of: member), leader.pid)

    XCTAssertEqual(
      ProcessInspection.signalGroup(
        SIGSTOP, leader: leader.pid, startedMicroseconds: leader.started),
      .byPid)

    try waitUntil("both to read as stopped") {
      ProcessInspection.isStopped(pid: leader.pid) == true
        && ProcessInspection.isStopped(pid: member) == true
    }

    XCTAssertEqual(
      ProcessInspection.signalGroup(
        SIGCONT, leader: leader.pid, startedMicroseconds: leader.started),
      .byPid)

    try waitUntil("both to read as running") {
      ProcessInspection.isStopped(pid: leader.pid) == false
        && ProcessInspection.isStopped(pid: member) == false
    }
  }

  /// Catches a group signal that reaches a group the named member does not belong to. The member is
  /// the helper under a wrapper that leads the group. A member of another group is refused, and
  /// nothing stops.
  func testAMemberMustBelongToTheLeadersGroup() throws {
    let leader = try spawn(["/bin/sh", "-c", "/bin/sleep 30; exit 0"])
    let stranger = try spawn(["/bin/sleep", "30"])

    var member: pid_t = 0

    try waitUntil("the shell to start its sleep") {
      member = ProcessInspection.children(of: leader.pid).first ?? 0

      return member > 0
    }

    XCTAssertEqual(
      ProcessInspection.signalGroup(
        SIGSTOP, leader: leader.pid, startedMicroseconds: leader.started, member: stranger.pid),
      .refused)
    XCTAssertEqual(ProcessInspection.isStopped(pid: member), false)
    XCTAssertEqual(ProcessInspection.isStopped(pid: stranger.pid), false)

    XCTAssertEqual(
      ProcessInspection.signalGroup(
        SIGSTOP, leader: leader.pid, startedMicroseconds: leader.started, member: member),
      .byPid)

    try waitUntil("the member to read as stopped") {
      ProcessInspection.isStopped(pid: member) == true
    }
  }

  // MARK: After the parent is gone

  /// Pins an operating system rule, not product code: no driver stays frozen once uniterm is gone.
  /// No uniterm code runs here. A driver's group is orphaned when its parent exits. The kernel then sends a stopped group SIGHUP and SIGCONT, so a
  /// member that does not catch SIGHUP ends. The parent here is a perl that starts a child in a
  /// group of its own, waits until the child has stopped, and exits.
  func testAStoppedGroupWhoseParentIsGoneIsEnded() throws {
    let script = """
      use POSIX;
      pipe(my $r, my $w);
      my $pid = fork();
      if (!$pid) {
        setpgrp(0, 0);
        close($r);
        syswrite($w, "$$\\n");
        kill("STOP", $$);
        sleep 100;
        exit 0;
      }
      close($w);
      my $line = <$r>;
      print $line;
      select(undef, undef, undef, 0.5);
      exit 0;
      """

    let process = Process()
    let output = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", script]
    process.standardOutput = output

    try process.run()

    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    process.waitUntilExit()

    let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))

    defer {
      kill(child, SIGCONT)
      kill(child, SIGKILL)
    }

    try waitUntil("the orphaned stopped child to end") { kill(child, 0) != 0 }
  }

  /// Pins the macOS rule behind "nothing stays stopped once the app is gone", for the REPL's half. The
  /// helper is a session leader on a pty the app holds the master of. `script` stands in for the
  /// app: it owns the master, and a shell it starts leads the session. The shell stops itself, and
  /// the stand-in is killed, as a crashed app closes its master. The stopped session leader must be
  /// gone within a bounded time. This proves an OS rule, and no product code runs.
  func testAStoppedSessionLeaderIsGoneOnceTheMasterOfItsPtyCloses() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stopped-leader-\(UUID().uuidString)")

    defer { try? FileManager.default.removeItem(at: file) }

    let app = Process()
    let input = Pipe()

    app.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    app.arguments = [
      "-q", "/dev/null", "/bin/sh", "-c", "echo $$ > '\(file.path)'; kill -STOP $$; sleep 100",
    ]
    app.standardInput = input
    app.standardOutput = FileHandle.nullDevice
    app.standardError = FileHandle.nullDevice

    try app.run()

    defer { kill(app.processIdentifier, SIGKILL) }

    var leader: pid_t = 0

    try waitUntil("the shell to name itself") {
      guard let text = try? String(contentsOf: file, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
      else { return false }

      leader = pid

      return true
    }

    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: leader))

    defer {
      _ = ProcessInspection.signal(SIGCONT, pid: leader, startedMicroseconds: started)
      _ = ProcessInspection.signal(SIGKILL, pid: leader, startedMicroseconds: started)
    }

    try waitUntil("the shell to stop") { ProcessInspection.isStopped(pid: leader) == true }
    XCTAssertEqual(getsid(leader), leader, "the shell does not lead its own session")

    kill(app.processIdentifier, SIGKILL)
    app.waitUntilExit()

    try waitUntil("the stopped session leader to be gone") {
      ProcessInspection.startTimeMicroseconds(of: leader) != started
    }
  }

  // MARK: Record

  /// Pins the rule that the observed state is the truth: a stop uniterm sent is not shown until it
  /// is seen, an outside continue clears the record, and a stop from outside is not uniterm's.
  func testTheRecordFollowsTheObservedState() {
    var state = SuspensionState()

    XCTAssertFalse(state.isSuspended)
    XCTAssertFalse(state.canResume)

    state.stopSent()

    XCTAssertFalse(state.isSuspended, "a stop that has not landed was shown")
    XCTAssertTrue(state.canResume, "Resume had nothing to continue right after a stop was sent")

    XCTAssertFalse(state.observe(stopped: false), "a stale running read changed the state")
    XCTAssertTrue(state.madeByUniterm, "a read before the stop landed cleared the record")

    XCTAssertTrue(state.observe(stopped: true))
    XCTAssertTrue(state.isSuspendedByUniterm)

    XCTAssertTrue(state.observe(stopped: false))
    XCTAssertFalse(state.madeByUniterm, "an outside continue left uniterm's record behind")
    XCTAssertFalse(state.canResume)

    XCTAssertTrue(state.observe(stopped: true))
    XCTAssertTrue(state.isSuspended)
    XCTAssertFalse(state.isSuspendedByUniterm, "a stop from outside was counted as uniterm's")
    XCTAssertTrue(state.canResume)

    state.continueSent()

    XCTAssertTrue(state.isSuspended, "the process still reads as stopped until it is seen running")
    XCTAssertFalse(state.canResume, "a second Resume would go out for a continue already sent")

    state.stopSent()

    XCTAssertTrue(state.canResume, "a stop sent after a continue left nothing to resume")

    state.continueSent()
    state.observe(stopped: false)

    XCTAssertFalse(state.canResume)
  }

  /// Catches a pending continue that outlives the stop it answered. uniterm stops and continues a
  /// process before either is seen, since the watcher reports only changes and sees none. A later
  /// stop from outside must still offer Resume.
  func testAnOutsideStopAfterAStopAndContinueNeverSeenStillOffersResume() {
    var state = SuspensionState()

    state.stopSent()
    state.continueSent()

    XCTAssertFalse(state.canResume)

    XCTAssertTrue(state.observe(stopped: true))

    XCTAssertTrue(state.isSuspended)
    XCTAssertTrue(state.canResume, "Resume was not offered for a stop from outside")
  }
}

/// The watch that reports a stop or a continue. A process source's signal notice must fire for a
/// stop and a continue, including one sent from another process, since the whole feature follows
/// the observed state.
@MainActor
final class ProcessStopWatcherTests: XCTestCase {
  private var children: [StopChild] = []

  override func tearDown() async throws {
    for child in children { child.end() }

    children = []
  }

  private func spawn(_ arguments: [String]) throws -> StopChild {
    let child = try StopChild(arguments, ownGroup: true)

    children.append(child)

    return child
  }

  /// Waits on main-actor events by yielding. Each wait is bounded.
  private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)

    while !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("timed out waiting for \(description)")

        throw CancellationError()
      }

      try await Task.sleep(for: .milliseconds(5))
    }
  }

  /// Catches a process source that never fires for a stop, which would leave a stop made in a shell
  /// or with `kill -STOP` unseen. The stop and the continue both come from another process, as a
  /// shell's job control sends them, and the watcher reports each one.
  func testAStopAndAContinueFromAnotherProcessAreReported() async throws {
    let child = try spawn(["/bin/sleep", "30"])
    var reports: [Bool] = []

    let watcher = ProcessStopWatcher(
      pid: child.pid, startedMicroseconds: child.started, settleDelay: .milliseconds(5)
    ) { reports.append($0) }

    watcher.start()

    defer { watcher.cancel() }

    try await waitUntil("the first settle") { watcher.settles >= 1 }

    XCTAssertEqual(reports, [], "a running process was reported as a change")

    try Self.sendFromAnotherProcess("-STOP", to: child.pid)
    try await waitUntil("the stop to be reported") { reports == [true] }

    try Self.sendFromAnotherProcess("-CONT", to: child.pid)
    try await waitUntil("the continue to be reported") { reports == [true, false] }
  }

  /// Catches a report taken from a read that has not settled. The reader says stopped once, then
  /// running, so the first reading was not the process's state. Only a state that two reads in a
  /// row agree on is reported.
  func testAReadThatDisagreesWithTheNextIsNotReported() async throws {
    let readings = Readings([nil, true, false, false])
    var reports: [Bool] = []

    let watcher = ProcessStopWatcher(
      pid: getpid(), startedMicroseconds: 0, settleDelay: .milliseconds(1),
      read: { _, _ in readings.next() }, onChange: { reports.append($0) })

    watcher.start()

    defer { watcher.cancel() }

    try await waitUntil("the settle to finish") { watcher.settles >= 1 }

    XCTAssertEqual(reports, [], "an unreadable read and a lone stop reading were reported")
  }

  /// Catches a report that waits for the notice alone. The settle a caller asks for after its own
  /// signal reads the process again, and reports what it finds.
  func testASettleAfterTheCallersOwnSignalReportsTheStop() async throws {
    let child = try spawn(["/bin/sleep", "30"])
    var reports: [Bool] = []

    let watcher = ProcessStopWatcher(
      pid: child.pid, startedMicroseconds: child.started, settleDelay: .milliseconds(5)
    ) { reports.append($0) }

    watcher.start()

    defer { watcher.cancel() }

    try await waitUntil("the first settle") { watcher.settles >= 1 }

    XCTAssertEqual(
      ProcessInspection.signalGroup(SIGSTOP, leader: child.pid, startedMicroseconds: child.started),
      .byPid)

    watcher.settle()

    try await waitUntil("the stop to be reported") { reports == [true] }
  }

  private static func sendFromAnotherProcess(_ flag: String, to pid: pid_t) throws {
    let kill = Process()

    kill.executableURL = URL(fileURLWithPath: "/bin/kill")
    kill.arguments = [flag, "\(pid)"]

    try kill.run()
    kill.waitUntilExit()

    XCTAssertEqual(kill.terminationStatus, 0)
  }
}

/// A scripted reader, so a test hands the watcher exactly the readings it wants. The last reading
/// repeats once the script runs out.
private final class Readings: @unchecked Sendable {
  private let lock = NSLock()
  private var script: [Bool?]

  init(_ script: [Bool?]) {
    self.script = script
  }

  func next() -> Bool? {
    lock.lock()
    defer { lock.unlock() }

    return script.count > 1 ? script.removeFirst() : script.first ?? nil
  }
}
