import Darwin
import Foundation
import ScriptWire
import XCTest

@testable import ScriptHost

/// What a helper process left behind.
struct HelperRun {
  let status: Int32
  let standardOutput: String
  let standardError: String
}

enum ScriptFixtures {
  /// The unsandboxed helper that SwiftPM builds beside the test bundle. `UNITERM_SCRIPT_HELPER`
  /// names another build, such as the one inside the built app.
  static func helper() -> URL {
    if let path = ProcessInfo.processInfo.environment["UNITERM_SCRIPT_HELPER"], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }

    let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
    let products = bundle?.bundleURL.deletingLastPathComponent()

    return (products ?? URL(fileURLWithPath: ".")).appendingPathComponent("ScriptHelper")
  }

  static func script(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name).janet")
  }

  /// A short private folder for a socket. A socket path holds 104 bytes, so the folder sits
  /// directly under the temporary folder.
  static func makeSocketDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    return directory
  }

  /// Connects a raw peer whose reads give up after 10 seconds, so a test that expects the app to
  /// answer or close fails instead of hanging.
  static func connectPeer(path: String) throws -> FramedSocket {
    let socket = try UnixSocket.connect(path: path)
    var timeout = timeval(tv_sec: 10, tv_usec: 0)

    _ = setsockopt(
      socket.rawDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
      socklen_t(MemoryLayout<timeval>.size))

    return socket
  }

  /// Starts the helper on `script`. `socket` is the `--socket` flag, and nil leaves it out. The
  /// environment is the test's own without `UNITERM_SOCKET`, plus `environment`, so a variable the
  /// developer has set never decides where a test connects.
  ///
  /// `input` is the helper's standard input. The caller keeps the pipe alive, since its write end
  /// closing is the end of the input. With none, the input is empty and a read ends at once.
  ///
  /// `memoryCap` is the allocator's cap in bytes, which only a debug helper accepts. A test that
  /// leaves a helper running is ended by SIGTERM after 60 seconds and by SIGKILL after 70, since a
  /// helper that handles SIGINT is not always ended by the first.
  static func start(
    socket: String?, script: URL, allow: [String] = [], arguments: [String] = [],
    environment: [String: String] = [:], memoryCap: UInt64? = nil, input: Pipe? = nil,
    onExit: (@Sendable () -> Void)? = nil
  ) throws -> Process {
    let process = Process()

    if let onExit {
      process.terminationHandler = { _ in onExit() }
    }

    var inherited = ProcessInfo.processInfo.environment

    inherited["UNITERM_SOCKET"] = nil

    process.environment = inherited.merging(environment) { _, new in new }
    process.executableURL = helper()
    process.arguments =
      ["run"] + (memoryCap.map { ["--memory-cap", String($0)] } ?? [])
      + allow.flatMap { ["--allow", $0] } + (socket.map { ["--socket", $0] } ?? [])
      + [script.path] + arguments
    process.standardInput = input ?? FileHandle.nullDevice
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()

    let watchdog = process

    DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
      if watchdog.isRunning { watchdog.terminate() }
    }

    DispatchQueue.global().asyncAfter(deadline: .now() + 70) {
      if watchdog.isRunning { kill(watchdog.processIdentifier, SIGKILL) }
    }

    return process
  }

  /// Waits for the helper to exit and reads what it wrote. Neither pipe is read before the
  /// process ends, which holds because a script's output is small.
  static func finish(_ process: Process) async -> HelperRun {
    let out = (process.standardOutput as! Pipe).fileHandleForReading
    let err = (process.standardError as! Pipe).fileHandleForReading

    return await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let outData = out.readDataToEndOfFile()
        let errData = err.readDataToEndOfFile()

        process.waitUntilExit()

        continuation.resume(
          returning: HelperRun(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)))
      }
    }
  }

  static func run(
    socket: String?, script: URL, allow: [String] = [], arguments: [String] = [],
    environment: [String: String] = [:], memoryCap: UInt64? = nil
  ) async throws -> HelperRun {
    await finish(
      try start(
        socket: socket, script: script, allow: allow, arguments: arguments,
        environment: environment, memoryCap: memoryCap))
  }

  /// The footprint of a process in bytes, or nil when it cannot be read.
  static func footprint(of pid: pid_t) -> Int? {
    var info = rusage_info_current()

    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
      }
    }

    return result == 0 ? Int(info.ri_phys_footprint) : nil
  }
}

extension ScriptListener {
  /// Hands each event to `handler` until it returns true, or until `timeout` passes. Returns
  /// whether the handler finished. A test that waits on the listener uses this, so a missing event
  /// fails the test and never hangs it.
  func drive(
    timeout: Duration = .seconds(30), _ handler: @escaping @Sendable (ScriptEvent) -> Bool
  ) async -> Bool {
    let events = self.events

    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await event in events where handler(event) { return true }

        return false
      }

      group.addTask {
        try? await Task.sleep(for: timeout)

        return false
      }

      let finished = await group.next() ?? false

      group.cancelAll()

      return finished
    }
  }
}

/// A clock a test moves by hand, so a bound of seconds never costs seconds.
final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = ContinuousClock.Instant.now

  var now: ContinuousClock.Instant {
    lock.lock()
    defer { lock.unlock() }

    return current
  }

  func advance(by amount: Duration) {
    lock.lock()
    current = current + amount
    lock.unlock()
  }
}

/// Footprints a test hands the app, by process ID.
final class FakeFootprints: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [pid_t: Int] = [:]

  func set(_ footprint: Int, for pid: pid_t) {
    lock.lock()
    values[pid] = footprint
    lock.unlock()
  }

  func read(_ pid: pid_t) -> Int? {
    lock.lock()
    defer { lock.unlock() }

    return values[pid]
  }
}

/// Polls `condition` on the caller's actor until it holds or `timeout` passes, and returns whether
/// it held. Every wait in these tests goes through it, so each one is bounded.
func pollUntil(
  timeout: Duration, interval: Duration = .milliseconds(20),
  isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while clock.now < deadline {
    if condition() { return true }

    try? await Task.sleep(for: interval)
  }

  return condition()
}

/// Waits until no process has the ID `pid`, for at most `timeout`.
func processIsGone(_ pid: pid_t, timeout: Duration = .seconds(10)) async -> Bool {
  await pollUntil(timeout: timeout) { kill(pid, 0) != 0 && errno == ESRCH }
}
/// True when the process's main thread, the oldest thread it has, is blocked in the kernel. A
/// helper stuck in a read is waiting, and a helper on its way to the read is running. A test uses
/// it to know the call has begun before it sends the first interrupt.
func mainThreadIsWaiting(_ pid: pid_t) -> Bool {
  var identifiers = [UInt64](repeating: 0, count: 64)
  let listed = identifiers.withUnsafeMutableBytes {
    proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, $0.baseAddress, Int32($0.count))
  }

  guard listed > 0, let main = identifiers.prefix(Int(listed) / MemoryLayout<UInt64>.size).min()
  else { return false }

  var info = proc_threadinfo()
  let size = Int32(MemoryLayout<proc_threadinfo>.size)

  guard proc_pidinfo(pid, PROC_PIDTHREADINFO, main, &info, size) == size else { return false }

  return info.pth_run_state == TH_STATE_WAITING
}

/// Waits until the process's main thread is blocked, for at most `timeout`.
func waitUntilBlocked(_ pid: pid_t, timeout: Duration = .seconds(10)) async -> Bool {
  await pollUntil(timeout: timeout, interval: .milliseconds(10)) { mainThreadIsWaiting(pid) }
}
