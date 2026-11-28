import AppletKit
import Darwin
import Foundation
import ProcessInspection
import StatusKit

/// Why a driver's transport failed. The channel closes on the first one.
public enum ExecTransportFailure: Error, Sendable, Equatable, CustomStringConvertible {
  case wire(ExecWireError)

  /// The driver wrote more than the pane had handled, past the retained bound.
  case inboundOverflow

  /// The driver stopped reading its stdin, and what waits for it passed the retained bound.
  case outboundOverflow

  public var description: String {
    switch self {
    case .wire(let error):
      return error.description

    case .inboundOverflow:
      return "the driver wrote more than \(ExecProtocol.maxRetainedBytes / (1 << 20)) MiB that "
        + "the pane had not handled yet"

    case .outboundOverflow:
      return "the driver stopped reading its input, and more than "
        + "\(ExecProtocol.maxRetainedBytes / (1 << 20)) MiB waited for it"
    }
  }
}

/// What the transport's threads report. The channel hops to the main thread for each one.
enum ExecTransportEvent: Sendable {
  /// Messages wait. Sent when the inbound queue goes from empty to holding one.
  case messagesReady

  /// Stderr text waits in the ingress. Sent when the ingress goes from empty to holding some.
  case stderrReady

  case failed(ExecTransportFailure)

  /// The child exited and its stdout reached its end. The status is the raw `waitpid` status.
  case exited(Int32)
}

/// A driver's child process and its three pipes. Every read, write, and wait runs on a thread of
/// its own, so the main thread only moves bounded values in and out under a lock.
///
/// The child is spawned directly from its argv, with no shell. It gets the three pipes on its
/// standard descriptors and nothing else of the app's. It runs in a process group of its own, so
/// closing the transport also reaches a program the driver started.
final class ExecTransport: @unchecked Sendable {
  let pid: pid_t
  let stderr = StderrIngress()

  private let stdinFD: Int32
  private let stdoutFD: Int32
  private let stderrFD: Int32
  private let notify: @Sendable (ExecTransportEvent) -> Void
  private let killGrace: DispatchTimeInterval

  private let state = NSCondition()
  private var inbound: [(message: ExecDriverMessage, bytes: Int)] = []
  private var inboundHead = 0
  private var inboundBytes = 0
  private var outbound: [Data] = []
  private var outboundBytes = 0
  private var closed = false
  private var leaderExited = false
  private var reaped = false
  private var failed = false

  private init(
    pid: pid_t, stdin: Int32, stdout: Int32, stderr: Int32, killGrace: DispatchTimeInterval,
    notify: @escaping @Sendable (ExecTransportEvent) -> Void
  ) {
    self.pid = pid
    stdinFD = stdin
    stdoutFD = stdout
    stderrFD = stderr
    self.killGrace = killGrace
    self.notify = notify
  }

  /// Spawns the child in `directory` with exactly `environment`. Nothing runs on the transport's
  /// threads until `start`.
  static func spawn(
    arguments: [String], directory: String, environment: [String: String],
    killGrace: DispatchTimeInterval = .seconds(2),
    notify: @escaping @Sendable (ExecTransportEvent) -> Void
  ) throws -> ExecTransport {
    var input: [Int32] = [-1, -1]
    var output: [Int32] = [-1, -1]
    var errors: [Int32] = [-1, -1]

    // Darwin has no pipe2, so each end takes FD_CLOEXEC right after its pipe is made. A process
    // that another thread of the app forks or spawns between the two calls, without closing what
    // it does not need, can still inherit an end. The driver itself gets only the three ends the
    // spawn's file actions name, since POSIX_SPAWN_CLOEXEC_DEFAULT closes every other descriptor.
    func makePipe(_ ends: inout [Int32]) -> Bool {
      guard pipe(&ends) == 0 else { return false }

      for descriptor in ends { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

      return true
    }

    guard makePipe(&input) else { throw ExecSpawnError.pipe(errno) }
    guard makePipe(&output) else {
      closeAll(input)
      throw ExecSpawnError.pipe(errno)
    }
    guard makePipe(&errors) else {
      closeAll(input + output)
      throw ExecSpawnError.pipe(errno)
    }

    // A write after the driver exits fails with EPIPE in place of ending the app.
    _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?

    posix_spawnattr_init(&attributes)
    posix_spawn_file_actions_init(&actions)

    defer {
      posix_spawnattr_destroy(&attributes)
      posix_spawn_file_actions_destroy(&actions)
    }

    var allSignals = sigset_t()
    var noSignals = sigset_t()
    sigfillset(&allSignals)
    sigemptyset(&noSignals)

    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_SETPGROUP))

    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
    posix_spawn_file_actions_addchdir(&actions, directory)

    let argv = arguments.map { strdup($0) } + [nil]
    let envp =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]

    defer {
      for pointer in argv + envp { free(pointer) }
    }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)

    closeAll([input[0], output[1], errors[1]])

    guard status == 0 else {
      closeAll([input[1], output[0], errors[0]])
      throw ExecSpawnError.spawn(arguments[0], status)
    }

    return ExecTransport(
      pid: pid, stdin: input[1], stdout: output[0], stderr: errors[0], killGrace: killGrace,
      notify: notify)
  }

  private static func closeAll(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
  }

  /// Starts the threads that read stdout and stderr, write stdin, and wait for the exit.
  func start() {
    let ended = DispatchGroup()
    let status = ExitStatusBox()

    ended.enter()
    thread("uniterm.exec.stdout") { [self] in
      readMessages()
      ended.leave()
    }

    thread("uniterm.exec.stderr") { [self] in readErrors() }
    thread("uniterm.exec.stdin") { [self] in writeInput() }

    ended.enter()
    thread("uniterm.exec.wait") { [self] in
      status.set(waitForExit())
      ended.leave()
    }

    ended.notify(queue: .global()) { [self] in
      notify(.exited(status.get()))
    }
  }

  private func thread(_ name: String, _ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.name = name
    thread.stackSize = 1 << 20
    thread.start()
  }

  // MARK: Inbound

  private func readMessages() {
    var reader = ExecFrameReader()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    defer { Darwin.close(stdoutFD) }

    while true {
      let count = buffer.withUnsafeMutableBytes { read(stdoutFD, $0.baseAddress, $0.count) }

      if count < 0 && errno == EINTR { continue }

      guard count > 0 else {
        do {
          try reader.finish()
        } catch {
          fail(.wire(error))
        }

        return
      }

      do {
        for line in try reader.feed(buffer[0..<count]) {
          guard admit(try ExecWire.decode(line), bytes: line.count) else { return }
        }
      } catch {
        fail(.wire(error))
        return
      }
    }
  }

  /// Queues a message for the main thread. False when the transport is closed or failed, or the
  /// message would pass the retained bound, which fails it.
  private func admit(_ message: ExecDriverMessage, bytes: Int) -> Bool {
    state.lock()

    guard !closed, !failed else {
      state.unlock()
      return false
    }

    guard inboundBytes + bytes <= ExecProtocol.maxRetainedBytes else {
      state.unlock()
      fail(.inboundOverflow)
      return false
    }

    let wasEmpty = inbound.count == inboundHead
    inbound.append((message, bytes))
    inboundBytes += bytes
    state.unlock()

    if wasEmpty { notify(.messagesReady) }

    return true
  }

  /// Takes up to `limit` waiting messages, oldest first. `remaining` says whether more wait.
  func takeMessages(limit: Int) -> (messages: [ExecDriverMessage], remaining: Bool) {
    state.lock()
    defer { state.unlock() }

    let end = min(inbound.count, inboundHead + limit)
    let taken = inbound[inboundHead..<end]

    inboundHead = end
    inboundBytes -= taken.reduce(0) { $0 + $1.bytes }

    if inboundHead == inbound.count {
      inbound.removeAll(keepingCapacity: true)
      inboundHead = 0
    }

    return (taken.map(\.message), inboundHead < inbound.count)
  }

  /// The bytes of messages read and not yet taken.
  var retainedInbound: Int {
    state.lock()
    defer { state.unlock() }

    return inboundBytes
  }

  private func readErrors() {
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    defer { Darwin.close(stderrFD) }

    while true {
      let count = buffer.withUnsafeMutableBytes { read(stderrFD, $0.baseAddress, $0.count) }

      if count < 0 && errno == EINTR { continue }

      guard count > 0 else {
        if stderr.finish() { notify(.stderrReady) }

        return
      }

      if stderr.offer(String(decoding: buffer[0..<count], as: UTF8.self)) {
        notify(.stderrReady)
      }
    }
  }

  // MARK: Outbound

  /// Queues bytes for the driver's stdin. False when the transport is closed, or the bytes would
  /// pass the retained bound, which fails it.
  @discardableResult
  func send(_ data: Data) -> Bool {
    state.lock()

    guard !closed, !failed else {
      state.unlock()
      return false
    }

    guard outboundBytes + data.count <= ExecProtocol.maxRetainedBytes else {
      state.unlock()
      fail(.outboundOverflow)
      return false
    }

    outbound.append(data)
    outboundBytes += data.count
    state.signal()
    state.unlock()

    return true
  }

  /// The bytes queued for stdin and not yet written.
  var retainedOutbound: Int {
    state.lock()
    defer { state.unlock() }

    return outboundBytes
  }

  private func writeInput() {
    defer { Darwin.close(stdinFD) }

    while true {
      state.lock()

      while outbound.isEmpty && !closed && !failed { state.wait() }

      guard !closed, !failed, !outbound.isEmpty else {
        state.unlock()
        return
      }

      let data = outbound.removeFirst()
      state.unlock()

      guard writeAll(data) else { return }

      state.lock()
      outboundBytes -= data.count
      state.unlock()
    }
  }

  private func writeAll(_ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
      var offset = 0

      while offset < raw.count {
        let written = write(stdinFD, raw.baseAddress! + offset, raw.count - offset)

        if written < 0 && errno == EINTR { continue }

        guard written > 0 else { return false }

        offset += written
      }

      return true
    }
  }

  // MARK: Lifetime

  private func fail(_ failure: ExecTransportFailure) {
    state.lock()

    guard !failed, !closed else {
      state.unlock()
      return
    }

    failed = true
    state.broadcast()
    state.unlock()

    notify(.failed(failure))
  }

  /// Ends the transport. Stdin closes first, so a driver that watches it can end by itself. The
  /// process group then gets SIGTERM, and SIGKILL after the grace period if it is still there.
  /// Nothing here waits, so the caller's thread never blocks.
  func close() {
    state.lock()
    let already = closed
    closed = true
    state.broadcast()
    state.unlock()

    guard !already else { return }

    signalGroup(SIGTERM)

    // A stopped driver ignores SIGTERM until it is continued. The continue follows at once, so the
    // driver can shut down cleanly, and nothing it started stays frozen.
    signalGroup(SIGCONT)

    DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [self] in
      signalGroup(SIGKILL)
    }
  }

  /// Ends the transport at quit. The asynchronous SIGKILL of `close` never runs once the app has
  /// exited, so this waits until `deadline` for the driver to end on SIGTERM, and then sends the
  /// group SIGKILL itself. The caller sends every driver's SIGTERM first, so all of them share
  /// one bounded wait.
  func finishForQuit(by deadline: Date) {
    close()

    state.lock()

    while !leaderExited, state.wait(until: deadline) {}

    state.unlock()

    signalGroup(SIGKILL)
  }

  /// Stops the driver's whole group, as Ctrl-Z stops a program in a shell. Returns whether the
  /// signal went out.
  @discardableResult
  func suspendGroup() -> Bool {
    signalGroup(SIGSTOP, requiringLeader: true)
  }

  /// Continues the driver's whole group.
  @discardableResult
  func resumeGroup() -> Bool {
    signalGroup(SIGCONT, requiringLeader: true)
  }

  /// Signals the child's group only while the child is not reaped. The wait thread sets the flag
  /// under the same lock, so a signal never reaches a group ID the system has handed on.
  ///
  /// The group is never the caller's own. A stop or a kill sent to it would end the app. A stop
  /// also needs the child to lead its group, which the spawn guarantees until the child moves
  /// itself out of it.
  @discardableResult
  private func signalGroup(_ number: Int32, requiringLeader: Bool = false) -> Bool {
    state.lock()
    defer { state.unlock() }

    guard !reaped, pid > 1, pid != getpgrp() else { return false }

    if requiringLeader {
      guard ProcessInspection.leadsItsOwnGroup(pid) else { return false }
    }

    return killpg(pid, number) == 0
  }

  /// The leader stays an unreaped zombie until the rest of its group has had SIGKILL. A zombie
  /// keeps its process and group IDs from being reused, so the signal cannot reach another
  /// process. A program the driver started in its group, such as one that ignores SIGTERM and
  /// holds stdout open, ends with the driver.
  private func waitForExit() -> Int32 {
    var info = siginfo_t()

    while true {
      guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 else {
        if errno == EINTR { continue }

        break
      }

      // Darwin reports a stopped child to a wait that asks only for exits. WNOWAIT leaves that
      // report in place, so the same wait would return at once forever.
      //
      // A wait for stops alone takes the report. It never reaps an exited child. The next wait then
      // blocks until the driver changes again. A paused driver is therefore not taken for an exit.
      //
      // Darwin has not been seen to report a continue here. The check for one is defensive.
      guard info.si_code == CLD_STOPPED || info.si_code == CLD_CONTINUED else { break }

      var stop = siginfo_t()

      _ = waitid(P_PID, id_t(pid), &stop, WSTOPPED | WCONTINUED | WNOHANG)
    }

    state.lock()
    leaderExited = true
    killpg(pid, SIGKILL)
    reaped = true
    state.broadcast()
    state.unlock()

    var status: Int32 = 0
    var result: pid_t

    repeat {
      result = waitpid(pid, &status, 0)
    } while result < 0 && errno == EINTR

    return status
  }
}

/// Why a driver did not start.
public enum ExecSpawnError: Error, Sendable, Equatable, CustomStringConvertible {
  case pipe(Int32)
  case spawn(String, Int32)

  public var description: String {
    switch self {
    case .pipe(let code):
      return "uniterm could not make the driver's pipes: \(String(cString: strerror(code)))"

    case .spawn(let program, let code):
      return "\(program) did not start: \(String(cString: strerror(code)))"
    }
  }
}

/// The exit status, handed from the wait thread to the end report.
private final class ExitStatusBox: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32 = 0

  func set(_ value: Int32) {
    lock.lock()
    status = value
    lock.unlock()
  }

  func get() -> Int32 {
    lock.lock()
    defer { lock.unlock() }

    return status
  }
}
