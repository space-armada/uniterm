import Darwin
import Foundation
import HelperWire

/// Where a helper executable is. The app finds it inside its own bundle.
public struct HelperLocation: Sendable, Equatable {
  public var url: URL?

  public init(url: URL?) {
    self.url = url
  }

  /// The helper named `name` in the app bundle, at `Contents/Helpers/<name>`. A debug build also
  /// honors the environment variable `debugOverride`, so a test can name another build of the
  /// helper. A release build never reads it, so the environment cannot swap a decoder.
  public static func bundled(named name: String, debugOverride: String) -> HelperLocation {
    #if DEBUG
      if let path = ProcessInfo.processInfo.environment[debugOverride], !path.isEmpty {
        return HelperLocation(url: URL(fileURLWithPath: path))
      }
    #endif

    return HelperLocation(
      url: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"))
  }
}

/// What a helper's reader thread reports, in order.
public enum HelperRead<Message: Sendable>: Sendable {
  case message(Message)
  case violation(String)

  /// The helper is gone. The status is the raw `waitpid` status.
  case exited(Int32)
}

/// A running helper: its process, its end of the socket, and the thread that reads it. Every helper
/// shares this spawn, reap, and footprint code.
///
/// The helper gets only the socketpair, on a fixed descriptor, and a minimal environment. Every
/// other descriptor of the app, ptys and sockets included, is closed in the child. The helper
/// exits when the socket closes, so none outlives a crashed app.
public final class HelperProcess: @unchecked Sendable {
  public let pid: pid_t
  public let socket: FramedSocket

  private let lock = NSLock()
  private var reaped = false

  private init(pid: pid_t, socket: FramedSocket) {
    self.pid = pid
    self.socket = socket
  }

  public static func spawn(executable: URL) throws -> HelperProcess {
    let (parent, child) = try FramedSocket.pair()

    // The child end moves above the fixed descriptor first, so the dup2 below never names the
    // descriptor it already has.
    let spare = fcntl(child.rawDescriptor, F_DUPFD_CLOEXEC, 10)

    guard spare >= 0 else { throw WireError.io(errno) }

    defer { Darwin.close(spare) }

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
    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    for standard in Int32(0)...2 {
      posix_spawn_file_actions_addopen(&actions, standard, "/dev/null", O_RDWR, 0)
    }

    posix_spawn_file_actions_adddup2(&actions, spare, HelperChannel.socketDescriptor)

    let path = executable.path
    let arguments = [strdup(path), nil]
    let environment = [strdup("PATH=/usr/bin:/bin"), nil]

    defer {
      for pointer in arguments + environment { free(pointer) }
    }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, path, &actions, &attributes, arguments, environment)

    guard status == 0 else { throw WireError.io(status) }

    return HelperProcess(pid: pid, socket: parent)
  }

  /// Starts the reader thread. `bodyLimit` gives the most bytes a frame of a type may declare right
  /// now. `decode` turns a frame into a message and throws for one the app refuses. `deliver` is
  /// called from the reader thread, in order, and last with `exited`.
  public func startReading<Message: Sendable>(
    threadName: String,
    bodyLimit: @escaping @Sendable (UInt8) -> Int,
    decode: @escaping @Sendable (UInt8, Data) throws -> Message,
    deliver: @escaping @Sendable (HelperRead<Message>) -> Void
  ) {
    let thread = Thread { [self] in
      readLoop(bodyLimit: bodyLimit, decode: decode, deliver: deliver)
    }

    thread.name = threadName
    thread.stackSize = 1 << 20
    thread.start()
  }

  private func readLoop<Message: Sendable>(
    bodyLimit: @Sendable (UInt8) -> Int,
    decode: @Sendable (UInt8, Data) throws -> Message,
    deliver: @Sendable (HelperRead<Message>) -> Void
  ) {
    while true {
      do {
        let frame = try socket.readFrame(limit: bodyLimit)

        deliver(.message(try decode(frame.type, frame.body)))
      } catch WireError.closed {
        break
      } catch {
        deliver(.violation("\(error)"))
        break
      }
    }

    kill()

    // Waiting without reaping keeps the pid from being reused. The flag is set under the lock
    // before the real reap, and `kill` signals only under the same lock, so a signal can never
    // reach a pid that the system has handed to another process.
    var info = siginfo_t()
    var waited: Int32

    repeat {
      waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
    } while waited < 0 && errno == EINTR

    lock.lock()
    reaped = true
    lock.unlock()

    var status: Int32 = 0
    var result: pid_t

    repeat {
      result = waitpid(pid, &status, 0)
    } while result < 0 && errno == EINTR

    deliver(.exited(status))
  }

  /// Ends the process and wakes the reader. Safe to call more than once and after exit. Returns
  /// whether it sent a signal.
  @discardableResult
  public func kill() -> Bool {
    lock.lock()

    let signalled = !reaped && Darwin.kill(pid, SIGKILL) == 0

    lock.unlock()
    socket.shutdownAndClose()

    return signalled
  }

  /// The helper's physical footprint in bytes, or nil when it cannot be read.
  public func footprint() -> Int? {
    usage()?.ri_phys_footprint.asInt
  }

  /// The most the helper's footprint has been since it started.
  public func peakFootprint() -> Int? {
    usage()?.ri_lifetime_max_phys_footprint.asInt
  }

  private func usage() -> rusage_info_current? {
    lock.lock()
    let gone = reaped
    lock.unlock()

    guard !gone else { return nil }

    var info = rusage_info_current()

    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
      }
    }

    return result == 0 ? info : nil
  }
}

extension HelperProcess {
  /// Says how a `waitpid` status ended, for the pane's message.
  public static func describe(status: Int32) -> String {
    let signal = status & 0x7F

    if signal == 0 {
      return "exited with status \((status >> 8) & 0xFF)"
    }

    return "was ended by signal \(signal)"
  }
}

extension UInt64 {
  fileprivate var asInt: Int { Int(clamping: self) }
}
