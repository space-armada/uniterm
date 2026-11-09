import CJanet
import Darwin
import Foundation
import ScriptWire

/// The REPL mode of the helper: `uniterm repl --socket PATH`.
///
/// The app starts it on a pty with a single-use token in its environment. Everything the helper
/// inherited is dropped before any user code runs, the token included. The REPL then starts in the
/// home folder, presents the token over the control channel, recalls the history the app sends,
/// and reads Janet forms from the pty.
public enum ScriptReplMain {
  /// Prints what the helper's startup left behind, then exits, so a test can see the starting
  /// state without a pty. Debug builds only. It runs the same steps as a real start, up to the
  /// connection.
  static let probeFlag = "--probe-environment"

  /// Makes the helper report each SIGINT it receives on stderr. Debug builds only. The app passes it
  /// when `UNITERM_REPL_TRACE_SIGINT` is set in its own environment.
  static let traceFlag = "--trace-sigint"

  static var usageText: String {
    """
    usage: uniterm repl --socket PATH

    Runs a Janet REPL that uniterm started. It needs the token that uniterm passes in the
    environment, and the socket of the uniterm instance that started it.
    """
  }

  static func run(arguments: [String]) -> Int32 {
    var socket: String?
    var probe = false
    var trace = false
    var memoryCap: UInt64?
    var index = 0

    while index < arguments.count {
      switch arguments[index] {
      case "--socket":
        guard index + 1 < arguments.count else { return fail("--socket needs a value", .usage) }

        socket = arguments[index + 1]
        index += 2

      case probeFlag:
        probe = true
        index += 1

      case traceFlag:
        trace = true
        index += 1

      case ScriptHelperMain.memoryCapFlag:
        guard index + 1 < arguments.count, let bytes = UInt64(arguments[index + 1]), bytes > 0
        else { return fail("--memory-cap needs a number of bytes", .usage) }

        memoryCap = bytes
        index += 2

      case "-h", "--help":
        print(usageText)

        return ScriptHelperMain.Exit.ok

      default:
        return fail("unknown option \(arguments[index])\n\(usageText)", .usage)
      }
    }

    #if !DEBUG
      if probe { return fail("unknown option \(probeFlag)\n\(usageText)", .usage) }
      if trace { return fail("unknown option \(traceFlag)\n\(usageText)", .usage) }
      if memoryCap != nil {
        return fail("unknown option \(ScriptHelperMain.memoryCapFlag)\n\(usageText)", .usage)
      }
    #endif

    if let memoryCap { uniterm_janet_set_memory_cap(memoryCap) }

    let token = ReplEnvironment.takeToken()

    guard let home = ScriptAddress.homeDirectory(), chdir(home) == 0 else {
      return fail("cannot enter your home folder, so the REPL did not start", .osError)
    }

    if probe {
      print(ReplEnvironment.probe(hadToken: token != nil))

      return ScriptHelperMain.Exit.ok
    }

    guard let socket, !socket.isEmpty else {
      return fail("a REPL needs the socket of the uniterm that started it\n\(usageText)", .usage)
    }

    guard let token else {
      return fail("a REPL needs the token that uniterm passes it\n\(usageText)", .usage)
    }

    uniterm_janet_repl_block_sigint()

    if trace { uniterm_janet_repl_trace_sigint() }

    let opened: (session: ScriptSession, history: [String])

    do {
      opened = try ScriptSession.openRepl(path: socket, token: token)
    } catch WireError.versionMismatch {
      return fail(ScriptProtocol.mismatchText, .protocolMismatch)
    } catch WireError.io(let code) where ScriptHelperMain.Address.meansNobodyListens(code) {
      return fail("no uniterm is reachable at \(socket)", .unavailable)
    } catch WireError.closed {
      return fail("uniterm closed the connection before the REPL began", .unavailable)
    } catch ScriptSessionError.failed(_, let text) {
      return fail(text, .unavailable)
    } catch {
      return fail("cannot talk to uniterm at \(socket): \(error)", .unavailable)
    }

    let session = opened.session

    for line in opened.history.suffix(ScriptProtocol.recallLines) {
      Array(line.utf8).withUnsafeBufferPointer {
        uniterm_janet_repl_seed($0.baseAddress, $0.count)
      }
    }

    let quitText = session.quitText

    // The hook runs on the VM thread inside an allocation, with the session kept alive for the rest
    // of the process. It sends through the socket's own lock, which the watchdog's pong shares.
    uniterm_janet_set_memory_limit_hook(
      { userdata in
        guard let userdata else { return }

        Unmanaged<ScriptSession>.fromOpaque(userdata).takeUnretainedValue()
          .sendMemoryLimitNotice()
      }, Unmanaged.passRetained(session).toOpaque())

    let watchdog = ScriptWatchdog.start(
      reading: session, onStop: { uniterm_janet_request_interrupt() },
      onHangup: { ScriptSession.endHelper(quitText, flushingOutput: false) })

    defer {
      watchdog.finish()
      session.close()
    }

    guard let failure = ScriptVM.runRepl(session: session, sandbox: uniterm_janet_default_sandbox)
    else { return ScriptHelperMain.Exit.ok }

    return fail(failure.description, .scriptFailed)
  }

  private enum Failure {
    case usage
    case unavailable
    case protocolMismatch
    case scriptFailed
    case osError

    var status: Int32 {
      switch self {
      case .usage: return ScriptHelperMain.Exit.usage
      case .unavailable: return ScriptHelperMain.Exit.unavailable
      case .protocolMismatch: return ScriptHelperMain.Exit.protocolMismatch
      case .scriptFailed: return ScriptHelperMain.Exit.scriptFailed
      case .osError: return 71
      }
    }
  }

  private static func fail(_ message: String, _ failure: Failure) -> Int32 {
    FileHandle.standardError.write(Data((message + "\n").utf8))

    return failure.status
  }
}

/// The helper's starting state. A REPL starts in the home folder with none of the app's
/// environment, so nothing flows into it from the app or from another pane.
enum ReplEnvironment {
  /// Reads the token and drops every inherited variable, the token included. It returns nil when
  /// the token is missing or is not 32 bytes of hex.
  static func takeToken() -> Data? {
    let value = getenv(ScriptProtocol.replTokenVariable).map { String(cString: $0) }

    dropAll()

    guard let value else { return nil }

    return decode(hex: value)
  }

  /// Replaces the process's environment with an empty one.
  static func dropAll() {
    uniterm_janet_drop_environment()
  }

  static func decode(hex: String) -> Data? {
    let bytes = Array(hex.utf8)

    guard bytes.count == ScriptProtocol.tokenBytes * 2 else { return nil }

    var data = Data()

    for pair in stride(from: 0, to: bytes.count, by: 2) {
      guard let high = nibble(bytes[pair]), let low = nibble(bytes[pair + 1]) else { return nil }

      data.append(high << 4 | low)
    }

    return data
  }

  private static func nibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
  }

  /// One line that names the working directory, how many variables are left, and whether the
  /// token was found before they went.
  static func probe(hadToken: Bool) -> String {
    var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
    let found = buffer.withUnsafeMutableBytes {
      getcwd($0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count) != nil
    }
    let directory = found ? String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) : ""
    let left = uniterm_janet_environment_count()

    return "cwd=\(directory) environment=\(left) token=\(hadToken ? "read" : "missing")"
  }
}
