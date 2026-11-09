import Darwin
import Foundation
import ScriptWire
import XCTest

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

  /// Starts the helper on `script` against the socket at `socket`.
  static func start(
    socket: String, script: URL, onExit: (@Sendable () -> Void)? = nil
  ) throws -> Process {
    let process = Process()

    if let onExit {
      process.terminationHandler = { _ in onExit() }
    }

    process.executableURL = helper()
    process.arguments = ["run", "--socket", socket, script.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()

    let watchdog = process

    DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
      if watchdog.isRunning { watchdog.terminate() }
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

  static func run(socket: String, script: URL) async throws -> HelperRun {
    await finish(try start(socket: socket, script: script))
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
