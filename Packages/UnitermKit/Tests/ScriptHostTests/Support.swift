import ControllerPackage
import Darwin
import DefaultsTestSupport
import FileRouting
import Foundation
import Preferences
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// A settings store in a defaults domain of its own, so a test never reads or writes the
/// developer's settings. A new store holds no stored mode, which reads as strict.
@MainActor
final class TestScriptSettings {
  let store: SettingsStore
  let defaults: UserDefaults
  private let testDefaults = TestDefaults(prefix: "dev.uniterm.tests")

  init(mode: ScriptFileMode? = nil) {
    defaults = testDefaults.defaults
    store = SettingsStore(defaults: defaults)

    if let mode { set(mode) }
  }

  func set(_ mode: ScriptFileMode) {
    store.set(mode, for: .scriptFileMode)
  }

  func remove() {
    testDefaults.discard()
  }
}

extension ScriptHost {
  /// Answers every undeclared review that waits now and any that comes later. The caller holds the
  /// token for as long as the answers should continue.
  func answerUndeclaredReviews(with choice: UndeclaredReviewChoice) -> ChangeObservers.Token {
    changes.add { [weak self] in
      guard let self else { return }

      for review in undeclaredReviews { decideUndeclaredReview(review.id, choice) }
    }
  }
}

/// A helper that takes every peer for the bundle's command, so a raw peer in a test can play it.
struct AcceptingHelper: ControllerHelperIdentity {
  func refusal(forPeer token: AuditToken) -> String? { nil }
}

/// A helper that takes no peer for the bundle's command, so a peer is a generic one.
struct RejectingHelper: ControllerHelperIdentity {
  func refusal(forPeer token: AuditToken) -> String? { "not the command" }
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

    _ = setsockopt(
      socket.rawDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
      socklen_t(MemoryLayout<timeval>.size))

    return socket
  }

  /// A raw peer that has said hello to `host` and read its answer.
  @MainActor
  static func openPeer(host: ScriptHost) async throws -> FramedSocket {
    let peer = try connectPeer(path: host.instanceAddress)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await readMessage(peer)

    return peer
  }

  /// Reads the app's next message off the main actor, since the read blocks.
  static func readMessage(_ peer: FramedSocket) async throws -> ScriptAppMessage {
    try await Task.detached {
      let frame = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
    }.value
  }

  /// A started host for the script file tests. The run folders and the trust store sit under
  /// `work`. With no `helper`, the host identifies the bundled command by its hardened copy.
  @MainActor
  static func makeFileHost(
    directory: URL, work: URL, helper: (any ControllerHelperIdentity)?,
    onRefusal: @escaping @MainActor (ScriptRefusal) -> Void = { _ in },
    clipboard: (any ScriptClipboard)? = nil, settings: SettingsStore? = nil,
    windows: any ScriptWindowAPI = FakeWindowAPI()
  ) throws -> ScriptHost {
    let center = StatusCenter()

    let host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows,
      onRefusal: onRefusal,
      controllers: ControllerSettings(
        runsRoot: work.appendingPathComponent("runs"),
        helper: try helper ?? BundleHelperIdentity(helperURL: try HardenedHelper.url()),
        trustDirectory: work.appendingPathComponent("trust")),
      clipboard: clipboard, settings: settings)

    host.start()
    recordTestProcessAsSessionRoot(host)

    return host
  }

  /// Starts the helper on `script`. `socket` is the `--socket` flag, and nil leaves it out. The
  /// environment is the test's own without `UNITERM_SOCKET`, plus `environment`, so a variable the
  /// developer has set never decides where a test connects.
  ///
  /// `input` is the helper's standard input. The caller keeps the pipe alive, since its write end
  /// closing is the end of the input. With none, the input is empty and a read ends at once.
  ///
  /// `memoryCap` is the allocator's cap in bytes, which only a debug helper accepts. A test that
  /// leaves a helper running has it ended by SIGTERM after 60 seconds and by SIGKILL after 70,
  /// since a helper that handles SIGINT is not always ended by the first.
  ///
  /// `executable` is the command to start, and nil means `helper()`. `onExit` runs once the
  /// helper's status is known.
  static func start(
    socket: String?, script: URL, allow: [String] = [], arguments: [String] = [],
    environment: [String: String] = [:], memoryCap: UInt64? = nil, input: Pipe? = nil,
    executable: URL? = nil, onExit: (@Sendable () -> Void)? = nil
  ) throws -> HelperHandle {
    var inherited = ProcessInfo.processInfo.environment

    inherited["UNITERM_SOCKET"] = nil

    return try HelperHandle.spawn(
      executable: executable ?? helper(),
      arguments: ["run"] + (memoryCap.map { ["--memory-cap", String($0)] } ?? [])
        + allow.flatMap { ["--allow", $0] } + (socket.map { ["--socket", $0] } ?? [])
        + [script.path] + arguments,
      environment: inherited.merging(environment) { _, new in new },
      standardInput: input.map { .file($0.fileHandleForReading) } ?? .null,
      deadlines: [
        HelperDeadline(after: .seconds(60), signal: SIGTERM),
        HelperDeadline(after: .seconds(70), signal: SIGKILL),
      ],
      onExit: onExit)
  }

  /// Waits for the helper to end and returns what it wrote. See `HelperHandle.finish()` for a
  /// pipe that outlives the helper, and for a helper that another reaper took.
  static func finish(_ helper: HelperHandle) async throws -> HelperRun {
    try await helper.finish()
  }

  static func run(
    socket: String?, script: URL, allow: [String] = [], arguments: [String] = [],
    environment: [String: String] = [:], memoryCap: UInt64? = nil, executable: URL? = nil
  ) async throws -> HelperRun {
    try await finish(
      try start(
        socket: socket, script: script, allow: allow, arguments: arguments,
        environment: environment, memoryCap: memoryCap, executable: executable))
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

/// Records the test process as a session root, so the helpers a test starts are bound to window
/// 1's pane 1.
@MainActor
func recordTestProcessAsSessionRoot(_ host: ScriptHost) {
  TestSessionRoot.record(in: host)
}

/// Skips the rest of a test that proves dyld drops a loader variable from a hardened process. The
/// kernel strips those variables only while System Integrity Protection is on. GitHub's macOS
/// runners turn it off, so the probe loads there whatever the signature says.
///
/// Only a plain "disabled" skips. Any other status, or one that cannot be read, still runs the
/// probe, so a wrong guess about the cause fails loudly.
func skipUnlessSystemIntegrityIsOn() throws {
  let process = Process()
  let output = Pipe()

  process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
  process.arguments = ["status"]
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()

  let status = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)

  if status.contains("status: disabled") {
    throw XCTSkip("The injection probe needs System Integrity Protection on. \(status)")
  }
}
