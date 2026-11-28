import Darwin
import Foundation

/// How a helper ended.
public enum HelperExit: Equatable, Sendable, CustomStringConvertible {
  /// The helper exited with this status.
  case exited(Int32)

  /// This signal ended the helper.
  case signalled(Int32)

  /// Reads a raw `waitpid` status. The reaper waits only for exits, so a stop never reaches here.
  public init(waitStatus status: Int32) {
    let signal = status & 0x7F

    self = signal == 0 ? .exited((status >> 8) & 0xFF) : .signalled(signal)
  }

  /// The exit status, or the number of the signal that ended the helper, the way Foundation's
  /// `terminationStatus` reads. Only the case itself tells the two apart.
  public var status: Int32 {
    switch self {
    case .exited(let code), .signalled(let code): code
    }
  }

  public var description: String {
    switch self {
    case .exited(let code): "exited with status \(code)"
    case .signalled(let signal): "ended by signal \(signal)"
    }
  }
}

/// What a helper left behind.
public struct HelperRun: Sendable {
  public let exit: HelperExit
  public let standardOutput: String
  public let standardError: String

  /// The exit status, or the number of the signal that ended the helper.
  public var status: Int32 { exit.status }
}

/// What a spawned helper reads as its standard input.
public enum HelperInput {
  /// The null device, so a read ends at once.
  case null

  /// A descriptor the caller owns, such as a pipe's read end or a pty end. The helper gets a copy,
  /// and the caller's own stays open until the caller closes it.
  case file(FileHandle)
}

/// Where a spawned helper's standard output or standard error goes.
public enum HelperOutput {
  case null

  /// A descriptor the caller owns, such as a pipe's write end or a pty end. The helper gets a copy,
  /// and the caller's own stays open until the caller closes it.
  case file(FileHandle)

  /// A pipe the handle owns and reads from the spawn on. `finish` returns what it read.
  case captured
}

/// A signal the handle sends if the helper still runs `after` its spawn. It is how a test that
/// hangs fails alone instead of holding up the whole run.
public struct HelperDeadline: Sendable {
  public let after: Duration
  public let signal: Int32

  public init(after: Duration, signal: Int32) {
    self.after = after
    self.signal = signal
  }
}

/// What `HelperHandle.signal(_:)` did.
public enum HelperSignalResult: Equatable, Sendable {
  case sent

  /// Nothing was sent. The helper has been reaped, so its id may already name another process.
  case reaped

  /// `kill` failed with this errno.
  case failed(Int32)
}

/// Why the fixture could not spawn a helper.
public struct HelperSpawnError: Error, CustomStringConvertible {
  public let executable: String
  public let call: String
  public let code: Int32

  public var description: String {
    "\(call) for \(executable) failed: \(String(cString: strerror(code)))"
  }
}

/// A wait on a helper failed, so its status is unknown.
public struct HelperWaitError: Error, CustomStringConvertible {
  public let pid: pid_t
  public let call: String
  public let code: Int32

  public var description: String {
    guard code == ECHILD else {
      return "\(call) for helper \(pid) failed: \(String(cString: strerror(code))). Its status "
        + "is unknown"
    }

    return "\(call) found no child \(pid). Another reaper in the test process took the helper's "
      + "exit, or the test process ignores SIGCHLD. Its status is unknown"
  }
}

/// A helper the fixture spawned, and the only way a test signals it. The fixture is the helper's
/// only reaper, so the handle knows when the process id stops being the helper's.
///
/// One thread per helper waits with `waitid` and `WNOWAIT`. That sees the exit and leaves the
/// helper a zombie, which keeps its id. The thread then sets the reaped flag under the lock, and
/// only then reaps with `waitpid`. `signal` sends only under the same lock while the flag is clear,
/// so a signal never reaches an id that the system has handed to another process.
///
/// The helper gets its three standard streams and no other descriptor of the test process. Every
/// signal starts at its default with an empty mask, whatever the test process has set, so a test
/// that ignores SIGPIPE cannot change how a later helper behaves. The helper stays in the test
/// process's group, and the handle signals only the helper's own process. A test that stops a
/// helper's group asks for `ownProcessGroup`, so the stop can never reach the test process.
public final class HelperHandle: @unchecked Sendable {
  /// The name of the thread that reaps each helper. `onExit` runs on it.
  public static let reaperThreadName = "uniterm.tests.helper-reaper"

  public let pid: pid_t

  private let onExit: (@Sendable () -> Void)?
  private let lock = NSLock()
  private var reaped = false

  /// The reaper's result, set before `onExit` runs. A waiter sees only `report`, which is set after
  /// `onExit` returns, so a test that waits always finds the callback done.
  private var ending: Result<HelperExit, HelperWaitError>?
  private var report: Result<HelperExit, HelperWaitError>?

  private var outputDone: Bool
  private var output = Data()
  private var errors = Data()
  private var waiters: [Waiter] = []

  private struct Waiter {
    let needsOutput: Bool
    let continuation: CheckedContinuation<Result<HelperExit, HelperWaitError>, Never>
  }

  private init(pid: pid_t, capturing: Bool, onExit: (@Sendable () -> Void)?) {
    self.pid = pid
    self.onExit = onExit
    outputDone = !capturing
  }

  /// Spawns a helper that this handle alone reaps.
  ///
  /// The helper runs `executable` with exactly `arguments` and `environment`. It starts in
  /// `directory`, or in the test process's own folder when that is nil.
  ///
  /// Each deadline sends its signal if the helper still runs by then. `onExit` runs once, on the
  /// reaper thread, after the status is known.
  public static func spawn(
    executable: URL, arguments: [String], environment: [String: String],
    directory: URL? = nil, ownProcessGroup: Bool = false, standardInput: HelperInput = .null,
    standardOutput: HelperOutput = .captured, standardError: HelperOutput = .captured,
    deadlines: [HelperDeadline], onExit: (@Sendable () -> Void)? = nil
  ) throws -> HelperHandle {
    let path = executable.path
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?

    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)

    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }

    // The copies the helper takes are closed once it has them. The handle keeps the read end of
    // each captured pipe, and both ends of the pipe that wakes its reader at the reap.
    var childCopies: [Int32] = []
    var kept: [Int32] = []
    var captured: [Int32] = []
    var wake: (read: Int32, write: Int32)?

    func closeAll(_ descriptors: [Int32]) {
      for descriptor in descriptors { Darwin.close(descriptor) }
    }

    do {
      switch standardInput {
      case .null:
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

      case .file(let handle):
        let copy = try spareCopy(of: handle, for: path)

        childCopies.append(copy)
        posix_spawn_file_actions_adddup2(&actions, copy, STDIN_FILENO)
      }

      for (stream, target) in [(standardOutput, STDOUT_FILENO), (standardError, STDERR_FILENO)] {
        switch stream {
        case .null:
          posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0)
          captured.append(-1)

        case .file(let handle):
          let copy = try spareCopy(of: handle, for: path)

          childCopies.append(copy)
          posix_spawn_file_actions_adddup2(&actions, copy, target)
          captured.append(-1)

        case .captured:
          let ends = try makePipe(for: path)

          kept.append(ends.read)
          childCopies.append(ends.write)
          posix_spawn_file_actions_adddup2(&actions, ends.write, target)
          captured.append(ends.read)
        }
      }

      if captured.contains(where: { $0 >= 0 }) {
        let ends = try makePipe(for: path)

        kept += [ends.read, ends.write]
        wake = ends
      }
    } catch {
      closeAll(childCopies + kept)
      throw error
    }

    if let directory {
      posix_spawn_file_actions_addchdir(&actions, directory.path)
    }

    var allSignals = sigset_t()
    var noSignals = sigset_t()
    sigfillset(&allSignals)
    sigemptyset(&noSignals)

    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK

    if ownProcessGroup {
      posix_spawnattr_setpgroup(&attributes, 0)
      flags |= POSIX_SPAWN_SETPGROUP
    }

    posix_spawnattr_setflags(&attributes, Int16(flags))

    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    let envp =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]

    defer {
      for pointer in argv + envp { free(pointer) }
    }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)

    closeAll(childCopies)

    guard status == 0 else {
      closeAll(kept)
      throw HelperSpawnError(executable: path, call: "posix_spawn", code: status)
    }

    let handle = HelperHandle(pid: pid, capturing: wake != nil, onExit: onExit)
    let readEnds = captured
    let wakeEnds = wake

    if let wakeEnds {
      startThread(named: "uniterm.tests.helper-output") {
        handle.collect(output: readEnds[0], errors: readEnds[1], wake: wakeEnds.read)
      }
    }

    startThread(named: reaperThreadName) { handle.reap(waking: wakeEnds?.write) }

    for deadline in deadlines {
      DispatchQueue.global().asyncAfter(deadline: .now() + deadline.after.dispatchInterval) {
        [weak handle] in
        handle?.signal(deadline.signal)
      }
    }

    return handle
  }

  /// Darwin has no pipe2, so each end takes FD_CLOEXEC right after the pipe is made. Another
  /// spawner in the test process that runs between the two calls can still inherit an end.
  private static func makePipe(for path: String) throws -> (read: Int32, write: Int32) {
    var ends: [Int32] = [-1, -1]

    guard pipe(&ends) == 0 else {
      throw HelperSpawnError(executable: path, call: "pipe", code: errno)
    }

    for descriptor in ends { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

    return (ends[0], ends[1])
  }

  /// A close-on-exec copy above the standard descriptors. The spawn moves it onto its target, so
  /// a caller's descriptor that is itself 0, 1, or 2 never collides with another stream's target.
  private static func spareCopy(of handle: FileHandle, for path: String) throws -> Int32 {
    let copy = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)

    guard copy >= 0 else {
      throw HelperSpawnError(executable: path, call: "fcntl(F_DUPFD_CLOEXEC)", code: errno)
    }

    return copy
  }

  private static func startThread(named name: String, _ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)

    thread.name = name
    thread.start()
  }

  // MARK: State

  /// Whether the helper still runs. A stopped helper still runs. A helper stops running once the
  /// reaper has its status, or once a wait on it has failed.
  public var isRunning: Bool {
    lock.withLock { ending == nil }
  }

  /// How the helper ended, or nil while it runs. It never waits. It throws when a wait on the
  /// helper failed, as it does when another reaper took the helper.
  public func exitStatus() throws -> HelperExit? {
    try lock.withLock { ending }?.get()
  }

  /// Waits for the helper to end, and returns how it ended. It throws when a wait on the helper
  /// failed, as it does when another reaper took the helper.
  public func waitForExit() async throws -> HelperExit {
    try await reported(needsOutput: false).get()
  }

  /// Waits for the helper to end, and returns how it ended with what it wrote to each captured
  /// stream. A stream the caller routed elsewhere reads as empty.
  ///
  /// The handle reads each captured stream from the spawn on, so a helper that writes more than a
  /// pipe holds never stalls. When the helper is reaped and a captured pipe stays open, a process
  /// the helper started holds the pipe. `finish` then keeps what the pipe held at the reap, and
  /// returns without waiting for the pipe's end.
  ///
  /// It throws when a wait on the helper failed, as it does when another reaper took the helper,
  /// so a test never reads a made-up status.
  public func finish() async throws -> HelperRun {
    let exit = try await reported(needsOutput: true).get()
    let (output, errors) = lock.withLock { (self.output, self.errors) }

    return HelperRun(
      exit: exit, standardOutput: String(decoding: output, as: UTF8.self),
      standardError: String(decoding: errors, as: UTF8.self))
  }

  /// Sends signal `number` to the helper's own process, never to its group. It sends nothing once
  /// the helper is reaped, since its id may then name another process. Signal 0 only probes.
  @discardableResult
  public func signal(_ number: Int32) -> HelperSignalResult {
    lock.lock()
    defer { lock.unlock() }

    guard !reaped else { return .reaped }

    return Darwin.kill(pid, number) == 0 ? .sent : .failed(errno)
  }

  // MARK: Threads

  private func reap(waking wake: Int32?) {
    var info = siginfo_t()
    var waitFailure: Int32 = 0

    while true {
      guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 else {
        if errno == EINTR { continue }

        waitFailure = errno
        break
      }

      // Darwin reports a stopped child to a wait that asks only for exits. WNOWAIT leaves that
      // report in place, so the same wait would return at once forever.
      //
      // A wait for stops alone takes the report. It never reaps an exited child. The next wait then
      // blocks until the helper changes again. A stopped helper is therefore not taken for an exit.
      //
      // Darwin has not been seen to report a continue here. The check for one is defensive.
      guard info.si_code == CLD_STOPPED || info.si_code == CLD_CONTINUED else { break }

      var stop = siginfo_t()

      _ = waitid(P_PID, id_t(pid), &stop, WSTOPPED | WCONTINUED | WNOHANG)
    }

    lock.withLock { reaped = true }

    let result: Result<HelperExit, HelperWaitError>

    if waitFailure != 0 {
      result = .failure(HelperWaitError(pid: pid, call: "waitid", code: waitFailure))
    } else {
      var status: Int32 = 0
      var reapedID: pid_t

      repeat {
        reapedID = waitpid(pid, &status, 0)
      } while reapedID < 0 && errno == EINTR

      let reapFailure = errno

      result =
        reapedID == pid
        ? .success(HelperExit(waitStatus: status))
        : .failure(HelperWaitError(pid: pid, call: "waitpid", code: reapFailure))
    }

    lock.withLock { ending = result }
    onExit?()

    if let wake { Darwin.close(wake) }

    let ready = lock.withLock {
      report = result

      return takeReadyWaiters()
    }

    for (continuation, result) in ready { continuation.resume(returning: result) }
  }

  /// Reads each captured stream until its end, or until the reaper closes `wake`.
  private func collect(output: Int32, errors: Int32, wake: Int32) {
    var open = [(descriptor: output, index: 0), (descriptor: errors, index: 1)]
      .filter { $0.descriptor >= 0 }
    var collected = [Data(), Data()]
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    func readOnce(_ descriptor: Int32, into index: Int) -> Bool {
      while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }

        if count < 0 && errno == EINTR { continue }

        guard count > 0 else { return false }

        collected[index].append(contentsOf: buffer[0..<count])

        return true
      }
    }

    while !open.isEmpty {
      var polls =
        open.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
        + [pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]

      if poll(&polls, nfds_t(polls.count), -1) < 0 {
        if errno == EINTR { continue }

        break
      }

      // The helper is reaped, so all it wrote is already in the pipe. Only a process it started
      // can still hold a pipe open, and the handle never waits for that.
      if polls[polls.count - 1].revents != 0 {
        for stream in open {
          _ = fcntl(stream.descriptor, F_SETFL, fcntl(stream.descriptor, F_GETFL) | O_NONBLOCK)

          while readOnce(stream.descriptor, into: stream.index) {}
        }

        break
      }

      open = open.enumerated()
        .filter { position, stream in
          polls[position].revents == 0 || readOnce(stream.descriptor, into: stream.index)
        }
        .map(\.element)
    }

    for descriptor in [output, errors, wake] where descriptor >= 0 { Darwin.close(descriptor) }

    let ready = lock.withLock {
      self.output = collected[0]
      self.errors = collected[1]
      outputDone = true

      return takeReadyWaiters()
    }

    for (continuation, result) in ready { continuation.resume(returning: result) }
  }

  // MARK: Waiting

  private func reported(needsOutput: Bool) async -> Result<HelperExit, HelperWaitError> {
    await withCheckedContinuation { continuation in
      lock.lock()

      if let report, outputDone || !needsOutput {
        lock.unlock()
        continuation.resume(returning: report)

        return
      }

      waiters.append(Waiter(needsOutput: needsOutput, continuation: continuation))
      lock.unlock()
    }
  }

  /// Takes every waiter whose wait is over. The caller holds the lock.
  private func takeReadyWaiters() -> [(
    CheckedContinuation<Result<HelperExit, HelperWaitError>, Never>,
    Result<HelperExit, HelperWaitError>
  )] {
    guard let report else { return [] }

    let ready = waiters.filter { outputDone || !$0.needsOutput }

    waiters.removeAll { outputDone || !$0.needsOutput }

    return ready.map { ($0.continuation, report) }
  }
}

extension Duration {
  fileprivate var dispatchInterval: DispatchTimeInterval {
    let (seconds, attoseconds) = components

    return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
  }
}
