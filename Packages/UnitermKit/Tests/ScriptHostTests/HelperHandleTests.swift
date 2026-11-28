import Darwin
import Foundation
import ProcessTestSupport
import ScriptTestSupport
import XCTest

/// The fixture's own spawn, reap, and signal contract, through `HelperHandle.spawn` the way the
/// script tests call it. Each helper is a real system command, so the proof covers the kernel's
/// waits and signals and not a stand-in.
///
/// They cannot force a process id's reuse, so they prove that no signal leaves after the reap, not
/// the race that rule prevents.
final class HelperHandleTests: XCTestCase {
  private let shell = URL(fileURLWithPath: "/bin/sh")
  private let cat = URL(fileURLWithPath: "/bin/cat")

  /// Ends a helper that a failed test leaves running. A passing test never reaches it.
  private let backstop = [HelperDeadline(after: .seconds(30), signal: SIGKILL)]

  /// Catches a `finish` that waits on an exit it already missed, which hung the script tests three
  /// times in Foundation's `waitUntilExit`. One helper is reaped before `finish` is called. Another
  /// is still running when `finish` is called, and exits once its input ends. Both return their
  /// status and their output.
  ///
  /// It pins the fix, not the bug. No test reproduced Foundation missing an exit, so this cannot
  /// show that the old wait would have hung.
  func testFinishReturnsForAHelperReapedBeforeItAndForOneThatEndsWhileItWaits() async throws {
    let reaped = expectation(description: "the first helper is reaped")
    let early = try HelperHandle.spawn(
      executable: shell, arguments: ["-c", "echo early; echo warned >&2; exit 3"],
      environment: [:], deadlines: backstop, onExit: { reaped.fulfill() })

    await fulfillment(of: [reaped], timeout: 30)

    XCTAssertFalse(early.isRunning)

    let first = try await early.finish()

    XCTAssertEqual(first.exit, .exited(3))
    XCTAssertEqual(first.standardOutput, "early\n")
    XCTAssertEqual(first.standardError, "warned\n")

    let input = Pipe()
    let late = try HelperHandle.spawn(
      executable: cat, arguments: [], environment: [:],
      standardInput: .file(input.fileHandleForReading), deadlines: backstop)

    try input.fileHandleForWriting.write(contentsOf: Data("late\n".utf8))

    XCTAssertTrue(late.isRunning, "cat ended before its input did")

    async let second = late.finish()

    try input.fileHandleForWriting.close()

    let run = try await second

    XCTAssertEqual(run.exit, .exited(0))
    XCTAssertEqual(run.standardOutput, "late\n")
  }

  /// Catches an exit callback that is lost, sent twice, or sent before the status is known. The
  /// callback runs once, on the reaper's thread, and the status is already readable inside it.
  func testOnExitRunsOnceOnTheReaperThreadAfterTheStatusIsKnown() async throws {
    let input = Pipe()
    let seen = ExitCalls()
    let helper = try HelperHandle.spawn(
      executable: cat, arguments: [], environment: [:],
      standardInput: .file(input.fileHandleForReading), deadlines: backstop,
      onExit: { seen.record() })

    seen.helper = helper

    try input.fileHandleForWriting.close()

    _ = try await helper.finish()

    XCTAssertEqual(seen.calls.count, 1)
    XCTAssertEqual(seen.calls.first?.thread, HelperHandle.reaperThreadName)
    XCTAssertEqual(seen.calls.first?.status, .exited(0))
  }

  /// Catches a spawn that loses the caller's input, environment, or folder, or that passes on
  /// another descriptor of the test process. A pipe with no close-on-exec flag is open while the
  /// helper starts. The helper's own list of descriptors holds its three streams and the ones `ls`
  /// opens itself, and neither end of that pipe.
  func testTheHelperGetsItsInputEnvironmentAndFolderAndNoOtherDescriptor() async throws {
    var ends: [Int32] = [-1, -1]

    XCTAssertEqual(pipe(&ends), 0)

    // High numbers, so a leaked end can never pass for a descriptor `ls` opens itself.
    let leaked = ends.map { fcntl($0, F_DUPFD, 200) }

    for descriptor in ends { close(descriptor) }

    defer { for descriptor in leaked { close(descriptor) } }

    XCTAssertTrue(leaked.allSatisfy { $0 >= 200 })

    let folder = try realFolder()
    let input = Pipe()
    let helper = try HelperHandle.spawn(
      executable: shell,
      arguments: ["-c", "pwd -P; echo \"$FIXTURE_VALUE\"; /bin/cat; exec /bin/ls /dev/fd"],
      environment: ["FIXTURE_VALUE": "seen"], directory: folder,
      standardInput: .file(input.fileHandleForReading), deadlines: backstop)

    try input.fileHandleForWriting.write(contentsOf: Data("from the input\n".utf8))
    try input.fileHandleForWriting.close()

    let run = try await helper.finish()
    let lines = run.standardOutput.split(separator: "\n").map(String.init)
    let descriptors = Array(lines.dropFirst(3))

    XCTAssertEqual(run.exit, .exited(0), run.standardError)
    XCTAssertEqual(Array(lines.prefix(3)), [folder.path, "seen", "from the input"])
    XCTAssertEqual(Array(descriptors.prefix(3)), ["0", "1", "2"])
    XCTAssertFalse(
      descriptors.contains(String(leaked[0])) || descriptors.contains(String(leaked[1])),
      "the helper inherited \(leaked) from the test process: \(descriptors)")
  }

  /// Catches a spawn that takes only a pipe. A helper reads a pty end as its terminal, and a helper
  /// given the null device reads nothing and ends.
  func testAStreamCanBeAPtyEndOrTheNullDevice() async throws {
    let terminal = try PseudoTerminal()
    let onTerminal = try HelperHandle.spawn(
      executable: shell, arguments: ["-c", "test -t 0 && test -t 2 && echo terminal"],
      environment: [:], standardInput: .file(terminal.child),
      standardError: .file(terminal.child), deadlines: backstop)

    let ranOnTerminal = try await onTerminal.finish()

    XCTAssertEqual(ranOnTerminal.exit, .exited(0))
    XCTAssertEqual(ranOnTerminal.standardOutput, "terminal\n")

    let onNull = try HelperHandle.spawn(
      executable: cat, arguments: [], environment: [:], standardInput: .null,
      standardError: .null, deadlines: backstop)

    let ranOnNull = try await onNull.finish()

    XCTAssertEqual(ranOnNull.exit, .exited(0))
    XCTAssertEqual(ranOnNull.standardOutput, "")
  }

  /// Catches a handle that cannot tell an exit from a death by signal, and one that signals after
  /// the reap. Both helpers end with status 9, one by `exit 9` and one by SIGKILL. Once each is
  /// reaped, a signal sends nothing and says why.
  func testAnExitAndADeathBySignalReadApartAndNoSignalFollowsTheReap() async throws {
    let exited = try HelperHandle.spawn(
      executable: shell, arguments: ["-c", "exit 9"], environment: [:], deadlines: backstop)

    let input = Pipe()
    let killed = try HelperHandle.spawn(
      executable: cat, arguments: [], environment: [:],
      standardInput: .file(input.fileHandleForReading), deadlines: backstop)

    XCTAssertEqual(killed.signal(SIGKILL), .sent)

    let exitedRun = try await exited.finish()
    let killedRun = try await killed.finish()

    XCTAssertEqual(exitedRun.exit, .exited(9))
    XCTAssertEqual(killedRun.exit, .signalled(SIGKILL))
    XCTAssertEqual(exitedRun.status, killedRun.status)

    for helper in [exited, killed] {
      XCTAssertEqual(helper.signal(SIGKILL), .reaped)
      XCTAssertEqual(helper.signal(0), .reaped)
    }
  }

  /// Catches a deadline that is not the caller's own, or that never fires. A helper that would
  /// wait forever on its input is ended by the signal its deadline names.
  func testADeadlineSendsTheCallersOwnSignal() async throws {
    let input = Pipe()
    let helper = try HelperHandle.spawn(
      executable: cat, arguments: [], environment: [:],
      standardInput: .file(input.fileHandleForReading),
      deadlines: [HelperDeadline(after: .zero, signal: SIGUSR1)] + backstop)

    let status = try await helper.waitForExit()

    XCTAssertEqual(status, .signalled(SIGUSR1))
    XCTAssertEqual(try helper.exitStatus(), .signalled(SIGUSR1))
  }

  /// Catches a reaper that takes a stop for an exit. Darwin's `waitid` reports a stopped child even
  /// to a wait that asks only for exits. A reaper that believed that report would refuse every
  /// later signal. Here a stopped helper still runs, and SIGCONT and SIGKILL still reach it.
  ///
  /// A refused signal leaves nothing that can end the helper, so the test stops at the first one.
  func testAStoppedHelperStillRunsAndContinueAndKillStillReachIt() async throws {
    let input = Pipe()
    let helper = try HelperHandle.spawn(
      executable: cat, arguments: [], environment: [:],
      standardInput: .file(input.fileHandleForReading), deadlines: backstop)

    XCTAssertEqual(helper.signal(SIGSTOP), .sent)
    expect(
      await pollUntil(timeout: .seconds(10)) { ProcessSender.isStopped(helper.pid) },
      "it never stopped")

    XCTAssertTrue(helper.isRunning)
    XCTAssertNil(try helper.exitStatus())

    let continued = helper.signal(SIGCONT)

    XCTAssertEqual(continued, .sent)

    guard continued == .sent else { return }

    expect(
      await pollUntil(timeout: .seconds(10)) { !ProcessSender.isStopped(helper.pid) },
      "it never went on")

    let killed = helper.signal(SIGKILL)

    XCTAssertEqual(killed, .sent)

    guard killed == .sent else { return }

    let status = try await helper.waitForExit()

    XCTAssertEqual(status, .signalled(SIGKILL))
  }

  /// Catches a handle that signals the helper's process group, as the exec driver's transport
  /// does. A group signal also reaches what the helper started, so a test of a command that should
  /// relay a signal would pass for one that never does. The helper's child here outlives the
  /// signal that ends the helper, and still echoes its input.
  func testASignalReachesTheHelperAndNotWhatItStarted() async throws {
    let input = Pipe()
    let output = Pipe()
    let helper = try HelperHandle.spawn(
      executable: shell, arguments: ["-c", "/bin/cat <&0 & echo started; wait"],
      environment: [:], standardInput: .file(input.fileHandleForReading),
      standardOutput: .file(output.fileHandleForWriting), standardError: .null,
      deadlines: backstop)

    try output.fileHandleForWriting.close()

    let started = await readLine(output.fileHandleForReading)

    XCTAssertEqual(started, "started")
    XCTAssertEqual(helper.signal(SIGTERM), .sent)

    let status = try await helper.waitForExit()

    XCTAssertEqual(status, .signalled(SIGTERM))

    try input.fileHandleForWriting.write(contentsOf: Data("alive\n".utf8))

    let echoed = await readLine(output.fileHandleForReading)

    try input.fileHandleForWriting.close()

    XCTAssertEqual(echoed, "alive", "the signal reached the helper's child")
  }

  /// Catches a helper that inherits the test process's ignored signals or its thread's mask, as a
  /// plain `posix_spawn` passes them on. A test that ignores SIGPIPE for the whole test process
  /// would then change how every later helper behaves. With SIGPIPE ignored and SIGINT blocked
  /// where the spawn runs, each helper still dies of the signal.
  func testAHelperStartsWithDefaultSignalsAndAnEmptyMask() async throws {
    let ignoringInput = Pipe()
    let maskedInput = Pipe()
    var blocked = sigset_t()
    var previousMask = sigset_t()

    sigemptyset(&blocked)
    sigaddset(&blocked, SIGINT)

    let previousPipe = Darwin.signal(SIGPIPE, SIG_IGN)

    pthread_sigmask(SIG_BLOCK, &blocked, &previousMask)

    let ignoring = Result {
      try HelperHandle.spawn(
        executable: cat, arguments: [], environment: [:],
        standardInput: .file(ignoringInput.fileHandleForReading), deadlines: backstop)
    }
    let masked = Result {
      try HelperHandle.spawn(
        executable: cat, arguments: [], environment: [:],
        standardInput: .file(maskedInput.fileHandleForReading), deadlines: backstop)
    }

    pthread_sigmask(SIG_SETMASK, &previousMask, nil)
    Darwin.signal(SIGPIPE, previousPipe)

    let ignoringHelper = try ignoring.get()
    let maskedHelper = try masked.get()

    XCTAssertEqual(ignoringHelper.signal(SIGPIPE), .sent)
    XCTAssertEqual(maskedHelper.signal(SIGINT), .sent)

    let ignoringStatus = try await ignoringHelper.waitForExit()
    let maskedStatus = try await maskedHelper.waitForExit()

    XCTAssertEqual(ignoringStatus, .signalled(SIGPIPE), "the helper kept SIGPIPE ignored")
    XCTAssertEqual(maskedStatus, .signalled(SIGINT), "the helper kept SIGINT blocked")
  }

  /// Catches a captured pipe end that another spawner in the test process inherits. The test finds
  /// the fixture's read ends in its own descriptor table, as the other ends of the pipes on the
  /// helper's output and error. A plain spawn that closes nothing still lists neither end, because
  /// the fixture marks its ends close-on-exec.
  func testAPlainSpawnInheritsNoneOfTheFixturesPipeEnds() async throws {
    let input = Pipe()
    let helper = try HelperHandle.spawn(
      executable: cat, arguments: [], environment: [:],
      standardInput: .file(input.fileHandleForReading), deadlines: backstop)

    let fixtureEnds = [STDOUT_FILENO, STDERR_FILENO].compactMap { target in
      pipeInfo(of: helper.pid, at: target).flatMap { ownDescriptor(forPipe: $0.pipe_peerhandle) }
    }
    let inherited = try descriptorsAPlainSpawnInherits()

    try input.fileHandleForWriting.close()
    _ = try await helper.finish()

    XCTAssertEqual(fixtureEnds.count, 2, "the fixture's read ends were not found")

    for descriptor in fixtureEnds {
      XCTAssertFalse(
        inherited.contains(String(descriptor)),
        "a plain spawn inherited the fixture's read end \(descriptor): \(inherited)")
    }
  }

  /// Catches a `finish` that waits for a captured pipe's end after its helper is reaped. The
  /// helper starts a process that holds its output open, then exits. `finish` returns what the
  /// helper wrote, and the process it started ends once its input closes.
  func testFinishReturnsWhenAProcessTheHelperStartedHoldsItsOutput() async throws {
    let input = Pipe()
    let helper = try HelperHandle.spawn(
      executable: shell, arguments: ["-c", "echo before; /bin/cat <&0 & exit 0"],
      environment: [:], standardInput: .file(input.fileHandleForReading), deadlines: backstop)

    let done = FinishFlag()
    let finished = Task {
      defer { done.set() }

      return try await helper.finish()
    }

    let finishedWhileHeld = await pollUntil(timeout: .seconds(10)) { done.isSet }

    try input.fileHandleForWriting.close()

    XCTAssertTrue(finishedWhileHeld, "finish waited for a pipe that the helper's child held")

    let run = try await finished.value

    XCTAssertEqual(run.exit, .exited(0))
    XCTAssertEqual(run.standardOutput, "before\n")
  }

  /// Catches captured output that is read only once `finish` is called. A helper that writes more
  /// than a pipe holds would then block in its write and never exit. This one writes 256 KiB, and
  /// exits before `finish` is called.
  func testAHelperThatWritesMoreThanAPipeHoldsNeverStalls() async throws {
    let helper = try HelperHandle.spawn(
      executable: URL(fileURLWithPath: "/usr/bin/head"),
      arguments: ["-c", "262144", "/dev/zero"], environment: [:], deadlines: backstop)

    let exited = await pollUntil(timeout: .seconds(10)) { !helper.isRunning }

    XCTAssertTrue(exited, "the helper stalled on a full pipe")

    let run = try await helper.finish()

    XCTAssertEqual(run.exit, .exited(0))
    XCTAssertEqual(run.standardOutput.utf8.count, 262_144)
  }

  /// Catches a reaper that gives up when its wait is interrupted. A SIGUSR2 handler installed
  /// without SA_RESTART interrupts the reaper's `waitid` while it blocks. The reaper waits again,
  /// and the helper's real exit is reported. A reaper that gave up would throw an EINTR error.
  ///
  /// It reaches the `waitid` only. The `waitpid` follows at once, and no test can catch the reaper
  /// inside it.
  func testAnInterruptedReaperWaitsAgain() async throws {
    var ends: [Int32] = [-1, -1]

    XCTAssertEqual(Darwin.pipe(&ends), 0)

    defer { for descriptor in ends { close(descriptor) } }

    interruptWriteEnd = ends[1]

    var handler = sigaction()
    var previous = sigaction()

    handler.__sigaction_u.__sa_handler = noteInterrupt
    handler.sa_flags = 0

    guard sigaction(SIGUSR2, &handler, &previous) == 0 else {
      return XCTFail("the SIGUSR2 handler could not be installed: errno \(errno)")
    }

    defer { sigaction(SIGUSR2, &previous, nil) }

    // A new thread starts with its creator's mask, and the test may run on a dispatch worker that
    // blocks signals. SIGUSR2 is open while the spawn starts the reaper, so the reaper takes it.
    var usr2 = sigset_t()
    var previousMask = sigset_t()

    sigemptyset(&usr2)
    sigaddset(&usr2, SIGUSR2)
    pthread_sigmask(SIG_UNBLOCK, &usr2, &previousMask)

    let input = Pipe()
    let spawned = Result {
      try HelperHandle.spawn(
        executable: cat, arguments: [], environment: [:],
        standardInput: .file(input.fileHandleForReading), deadlines: backstop)
    }

    pthread_sigmask(SIG_SETMASK, &previousMask, nil)

    let helper = try spawned.get()

    expect(
      await pollUntil(timeout: .seconds(10)) { blockedReaperThread() != nil },
      "the reaper never blocked in its wait")

    let reaper = try XCTUnwrap(blockedReaperThread())

    let sent = pthread_kill(reaper, SIGUSR2)

    guard sent == 0 else {
      try input.fileHandleForWriting.close()

      return XCTFail("pthread_kill failed with \(sent)")
    }

    let readEnd = ends[0]
    let interrupted = await Task.detached {
      var ready = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
      var byte: UInt8 = 0

      return poll(&ready, 1, 10_000) == 1 && read(readEnd, &byte, 1) == 1
    }.value

    XCTAssertTrue(interrupted, "the handler never ran")

    try input.fileHandleForWriting.close()

    let run = try await helper.finish()

    XCTAssertEqual(run.exit, .exited(0))
  }

  /// Catches a wait that reports a made-up status once another reaper took the helper. With
  /// SIGCHLD set to discard exits, the kernel reaps the helper itself, so the fixture's wait finds
  /// no child. `finish` throws an error that names another reaper, and no signal follows.
  func testAWaitThatFindsNoChildThrowsAndNamesAnotherReaper() async throws {
    var discard = sigaction()
    var previous = sigaction()

    discard.__sigaction_u.__sa_handler = SIG_IGN
    discard.sa_flags = SA_NOCLDWAIT

    // While SIGCHLD discards exits, the kernel reaps every child of the test process, and the wait
    // of whatever started it would then fail. The test runs only with no other child alive.
    let others = childrenOfTheTestProcess()

    guard others.isEmpty else {
      return XCTFail(
        "the test process has other children, which discarding exits would reap: \(others)")
    }

    guard sigaction(SIGCHLD, &discard, &previous) == 0 else {
      return XCTFail("SIGCHLD could not be set to discard exits: errno \(errno)")
    }

    var restored = false

    // The kernel reaps every child of a process that discards SIGCHLD, so the setting is undone as
    // soon as the helper ends. The defer undoes it on every other way out, a spawn that throws
    // included.
    func restore() {
      guard !restored else { return }

      restored = true
      sigaction(SIGCHLD, &previous, nil)
    }

    defer { restore() }

    // No deadline. The kernel frees the helper's pid at its exit, before the fixture can set its
    // reaped flag. A wait that never returned would leave the flag clear, and a deadline would
    // then signal a freed pid.
    let helper = try HelperHandle.spawn(
      executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:],
      deadlines: [])
    let ended = await pollUntil(timeout: .seconds(10)) { !helper.isRunning }

    restore()

    guard ended else { return XCTFail("the fixture's wait never returned") }

    do {
      let run = try await helper.finish()

      XCTFail("finish reported \(run.exit) for a helper it never reaped")
    } catch let error as HelperWaitError {
      XCTAssertEqual(error.code, ECHILD)
      XCTAssertTrue(error.description.contains("Another reaper"), error.description)
    }

    XCTAssertFalse(helper.isRunning)
    XCTAssertEqual(helper.signal(SIGKILL), .reaped)
  }

  // MARK: Helpers

  /// A new folder under the temporary folder, named as `pwd -P` names it.
  private func realFolder() throws -> URL {
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-handle-\(UUID().uuidString.prefix(8))", isDirectory: true)

    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: made) }

    let resolved = try XCTUnwrap(realpath(made.path, nil))

    defer { free(resolved) }

    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }

  /// The descriptors that `ls /dev/fd` lists when it is spawned with no close-on-exec default.
  /// That is every descriptor of the test process not marked close-on-exec. The test reaps the
  /// child itself and never signals it.
  private func descriptorsAPlainSpawnInherits() throws -> [String] {
    var ends: [Int32] = [-1, -1]

    guard pipe(&ends) == 0 else { throw POSIXError(.EMFILE) }

    for descriptor in ends { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

    var actions: posix_spawn_file_actions_t?

    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, ends[1], STDOUT_FILENO)

    defer { posix_spawn_file_actions_destroy(&actions) }

    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/ls"), strdup("/dev/fd"), nil]

    defer { for pointer in argv { free(pointer) } }

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, "/bin/ls", &actions, nil, argv, nil)

    close(ends[1])

    let reader = FileHandle(fileDescriptor: ends[0], closeOnDealloc: true)

    guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }

    let listing = String(decoding: reader.readDataToEndOfFile(), as: UTF8.self)
    var status: Int32 = 0

    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}

    return listing.split(separator: "\n").map(String.init)
  }

  /// The reaper thread that is blocked in the kernel, or nil while none is. Each test here ends
  /// its helpers, so the one helper it starts owns the only reaper left.
  private func blockedReaperThread() -> pthread_t? {
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0

    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else {
      return nil
    }

    defer {
      for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }

      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
    }

    for index in 0..<Int(count) {
      guard let thread = pthread_from_mach_thread_np(threads[index]) else { continue }

      var name = [CChar](repeating: 0, count: 64)

      pthread_getname_np(thread, &name, name.count)

      guard
        name.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) })
          == HelperHandle.reaperThreadName
      else { continue }

      var info = thread_basic_info()
      var infoCount = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
          thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
        }
      }

      if result == KERN_SUCCESS && info.run_state == TH_STATE_WAITING { return thread }
    }

    return nil
  }

  /// The ids of the test process's children, zombies included. The buffer starts zeroed and only
  /// its nonzero entries count, so the answer holds whether the call reports ids or bytes.
  private func childrenOfTheTestProcess() -> [pid_t] {
    var ids = [pid_t](repeating: 0, count: 1024)
    let reported = ids.withUnsafeMutableBytes {
      proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count))
    }

    guard reported > 0 else { return [] }

    return ids.prefix(min(Int(reported), ids.count)).filter { $0 > 0 }
  }

  /// The pipe behind descriptor `descriptor` of process `pid`, or nil when it is not a pipe.
  private func pipeInfo(of pid: pid_t, at descriptor: Int32) -> pipe_info? {
    var info = pipe_fdinfo()
    let size = Int32(MemoryLayout<pipe_fdinfo>.size)

    guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDPIPEINFO, &info, size) == size else {
      return nil
    }

    return info.pipeinfo
  }

  /// The test process's descriptor for the pipe end `handle`, or nil when it holds none.
  private func ownDescriptor(forPipe handle: UInt64) -> Int32? {
    var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: 4096)
    let bytes = entries.withUnsafeMutableBytes {
      proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }

    guard bytes > 0 else { return nil }

    return entries.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.size)
      .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_PIPE) }
      .first { pipeInfo(of: getpid(), at: $0.proc_fd)?.pipe_handle == handle }?
      .proc_fd
  }

  /// Reads one line from `handle` off the test's thread, or nil at the stream's end.
  private func readLine(_ handle: FileHandle) async -> String? {
    await Task.detached {
      var line = Data()

      while true {
        let chunk = handle.readData(ofLength: 1)

        guard let byte = chunk.first else { return nil }

        if byte == UInt8(ascii: "\n") { return String(decoding: line, as: UTF8.self) }

        line.append(byte)
      }
    }.value
  }
}

/// What each call of an exit callback saw.
private final class ExitCalls: @unchecked Sendable {
  struct Call {
    let thread: String?
    let status: HelperExit?
  }

  private let lock = NSLock()
  private var stored: [Call] = []
  private var storedHelper: HelperHandle?

  var helper: HelperHandle? {
    get { lock.withLock { storedHelper } }
    set { lock.withLock { storedHelper = newValue } }
  }

  var calls: [Call] { lock.withLock { stored } }

  func record() {
    let status = try? helper?.exitStatus()
    let call = Call(thread: Thread.current.name, status: status)

    lock.withLock { stored.append(call) }
  }
}

private final class FinishFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = false

  var isSet: Bool { lock.withLock { stored } }

  func set() { lock.withLock { stored = true } }
}

/// The pipe end that `noteInterrupt` writes to. Only the EINTR test sets it, before it installs
/// the handler, and the handler only reads it.
nonisolated(unsafe) private var interruptWriteEnd: Int32 = -1

/// A SIGUSR2 handler that only says it ran. `write` is safe in a handler, and errno is kept.
private func noteInterrupt(_ signal: Int32) {
  let saved = errno
  var byte: UInt8 = 1

  _ = write(interruptWriteEnd, &byte, 1)
  errno = saved
}
