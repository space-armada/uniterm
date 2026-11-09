import Darwin
import Foundation
import ScriptWire
import XCTest

@testable import ScriptHost

/// A REPL helper process with pipes for its standard streams, so no pty is involved. Janet's line
/// editor reads a plain line when its input is not a terminal, which is what these tests drive.
///
/// Every wait is bounded, and a helper that outlives its test is killed.
final class ReplProcess: @unchecked Sendable {
  let process = Process()

  private let input = Pipe()
  private let output = Pipe()
  private let error = Pipe()
  private let lock = NSLock()
  private var text = ""
  private var errorText = ""

  /// Starts `ScriptHelper repl --socket address` with only `environment`, never the test's own.
  /// `shell` starts it through `/bin/sh -c` with each word single-quoted, as the terminal does.
  ///
  /// `login` starts it as libghostty does on macOS: under `login`, then `bash`, then `exec -l`. With
  /// `direct` the helper is the `exec -l` target itself. Without it, `/bin/sh -c` stands between.
  ///
  /// `session` starts it under `script`, which gives it a pty of its own as a session leader in
  /// the foreground, as a terminal does. A Ctrl-C written to the input then reaches the helper
  /// through the pty's line discipline, and not through a signal the test sends.
  init(
    address: String, environment: [String: String], arguments: [String] = [], shell: Bool = false,
    session: Bool = false, login: Bool = false, direct: Bool = false, prelude: String = ""
  ) throws {
    let words = ["repl", "--socket", address] + arguments
    let helper = ScriptFixtures.helper().path

    if login {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/script")

      let inner = ([helper] + words).map { Self.quote($0) }.joined(separator: " ")
      // libghostty hands bash `exec -l` and the quoted words, with no `/bin/sh -c` between them. The
      // helper's argv[0] is then its path with a dash in front.
      let outer =
        direct
        ? "stty cols 80 rows 24; \(prelude) exec -l " + inner
        : "stty cols 80 rows 24; \(prelude) exec -l /bin/sh -c " + Self.quote(inner)

      process.arguments = [
        "-q", "/dev/null", "/usr/bin/login", "-flp", NSUserName(), "/bin/bash", "--noprofile",
        "--norc", "-c", outer,
      ]
    } else if session {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
      // The pty script makes has no size, and the line editor would wait for the terminal to say
      // where its cursor is. The shell gives it a size and then becomes the helper.
      let command =
        "stty cols 80 rows 24; exec " + ([helper] + words).map { "'\($0)'" }.joined(separator: " ")

      process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
    } else if shell {
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", ([helper] + words).map { "'\($0)'" }.joined(separator: " ")]
    } else {
      process.executableURL = URL(fileURLWithPath: helper)
      process.arguments = words
    }

    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    // A write to a helper that has gone must fail, and never end the test run.
    signal(SIGPIPE, SIG_IGN)

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.take(handle, into: \.text)
    }

    error.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.take(handle, into: \.errorText)
    }

    try process.run()

    let watchdog = process

    DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
      if watchdog.isRunning { kill(watchdog.processIdentifier, SIGKILL) }
    }
  }

  private static func quote(_ word: String) -> String {
    "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Starts the helper with `terminal` as its standard streams, so Janet's line editor runs in its
  /// full mode.
  init(address: String, environment: [String: String], terminal: PseudoTerminal) throws {
    process.executableURL = ScriptFixtures.helper()
    process.arguments = ["repl", "--socket", address]
    process.environment = environment
    process.standardInput = terminal.child
    process.standardOutput = terminal.child
    process.standardError = terminal.child

    try process.run()

    let watchdog = process

    DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
      if watchdog.isRunning { kill(watchdog.processIdentifier, SIGKILL) }
    }
  }

  deinit {
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  private func take(_ handle: FileHandle, into path: ReferenceWritableKeyPath<ReplProcess, String>)
  {
    let data = handle.availableData

    guard !data.isEmpty else {
      handle.readabilityHandler = nil

      return
    }

    lock.lock()
    self[keyPath: path] += String(decoding: data, as: UTF8.self)
    lock.unlock()
  }

  var standardOutput: String {
    lock.lock()
    defer { lock.unlock() }

    return text
  }

  var standardError: String {
    lock.lock()
    defer { lock.unlock() }

    return errorText
  }

  var pid: pid_t { process.processIdentifier }

  func write(_ line: String) {
    try? input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
  }

  func closeInput() {
    try? input.fileHandleForWriting.close()
  }

  func interrupt() {
    kill(process.processIdentifier, SIGINT)
  }

  /// Waits until standard output holds `fragment`.
  func waitForOutput(_ fragment: String, timeout: Duration = .seconds(30)) async -> Bool {
    await pollUntil(timeout: timeout) { self.standardOutput.contains(fragment) }
  }

  func waitForError(_ fragment: String, timeout: Duration = .seconds(30)) async -> Bool {
    await pollUntil(timeout: timeout) { self.standardError.contains(fragment) }
  }

  /// Waits for the process to exit and returns its status, or nil when it is still running.
  func exitStatus(timeout: Duration = .seconds(30)) async -> Int32? {
    let ended = await pollUntil(timeout: timeout) { !self.process.isRunning }

    return ended ? process.terminationStatus : nil
  }
}

/// Asserts a value that a test got by waiting. XCTest's own assertions take their value as an
/// autoclosure, which cannot hold an `await`.
func expect(
  _ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertTrue(value, message, file: file, line: line)
}

/// Polls `condition` on the main actor until it holds or `timeout` passes. A test waits on host
/// events through it, so a missing event fails the test and never hangs it.
@MainActor
func waitUntil(
  timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool
) async -> Bool {
  await pollUntil(timeout: timeout) { condition() }
}

/// What a REPL channel reported, in order.
@MainActor
final class ReplEvents {
  private(set) var all: [ScriptReplEvent] = []

  init(_ channel: ScriptReplChannel) {
    channel.onEvent = { [weak self] in self?.all.append($0) }
  }

  var lines: [String] {
    all.compactMap {
      if case .line(let text) = $0 { return text }

      return nil
    }
  }

  var attachedProcess: ProcessIdentity? {
    for event in all {
      if case .attached(let identity) = event { return identity }
    }

    return nil
  }

  var ended: Bool { all.contains(.ended) }

  var lastEvaluating: Bool? {
    for event in all.reversed() {
      if case .evaluating(let running) = event { return running }
    }

    return nil
  }
}

/// A pty pair. The helper gets the child end, and the test reads and types on the master end.
final class PseudoTerminal: @unchecked Sendable {
  let child: FileHandle

  private let master: Int32
  private let source: DispatchSourceRead
  private let lock = NSLock()
  private var text = ""

  init(columns: UInt16 = 80) throws {
    let master = posix_openpt(O_RDWR | O_NOCTTY)

    guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master)
    else { throw POSIXError(.ENOTTY) }

    let slave = open(name, O_RDWR | O_NOCTTY)

    guard slave >= 0 else { throw POSIXError(.ENOTTY) }

    // The line editor asks the terminal where the cursor is when it reports no width, and waits
    // for an answer that nothing here would send.
    var size = winsize(ws_row: 24, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)

    _ = ioctl(master, TIOCSWINSZ, &size)

    self.master = master
    self.child = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    self.source = DispatchSource.makeReadSource(
      fileDescriptor: master, queue: DispatchQueue(label: "uniterm.test.pty"))

    source.setEventHandler { [weak self] in self?.drain() }
    source.resume()
  }

  deinit {
    source.cancel()
    close(master)
  }

  private func drain() {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(master, &buffer, buffer.count)

    guard count > 0 else { return }

    lock.lock()
    text += String(decoding: buffer.prefix(count), as: UTF8.self)
    lock.unlock()
  }

  var output: String {
    lock.lock()
    defer { lock.unlock() }

    return text
  }

  func write(_ string: String) {
    _ = string.withCString { Darwin.write(master, $0, strlen($0)) }
  }

  func waitForOutput(_ fragment: String, timeout: Duration = .seconds(30)) async -> Bool {
    await waitFor({ $0.contains(fragment) }, timeout: timeout)
  }

  /// Waits until `condition` holds for everything the terminal has shown so far.
  func waitFor(_ condition: @Sendable (String) -> Bool, timeout: Duration = .seconds(30)) async
    -> Bool
  {
    await pollUntil(timeout: timeout) { condition(output) }
  }
}
