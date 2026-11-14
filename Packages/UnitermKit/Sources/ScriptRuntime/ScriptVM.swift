import CJanet
import Foundation
import ScriptWire

/// What a finished script reports. A script that fails carries where and why.
public struct ScriptFailure: Error, Equatable, Sendable {
  public enum Kind: String, Sendable {
    case parse
    case compile
    case runtime
    case start

    /// Ctrl-C or the app's stop request ended the script.
    case interrupted
  }

  public let name: String
  public let line: Int
  public let column: Int
  public let kind: Kind
  public let message: String

  /// One line for stderr: the script name, the position when Janet gave one, and the message.
  public var description: String {
    if kind == .interrupted { return "\(name): interrupted" }

    let position = line > 0 ? ":\(line):\(column)" : ""

    return "\(name)\(position): \(kind.rawValue) error: \(message)"
  }
}

/// Runs one script in the helper's Janet VM, on the calling thread. The caller must be the thread
/// that owns the VM, and no other script may run on it at the same time.
enum ScriptVM {
  /// The host functions call back into `session`. A callback never throws or traps across the C
  /// boundary. It turns a failure into the message that the shim raises to the script.
  ///
  /// `sandbox` holds the bits of every capability still denied. `arguments` reach the script
  /// through `(dyn :args)`, the script's own path first, as under Janet's command.
  static func run(
    name: String, source: Data, session: ScriptSession,
    sandbox: UInt32 = uniterm_janet_default_sandbox, arguments: [String] = []
  ) -> ScriptFailure? {
    var failure = uniterm_script_failure()

    let status = withExtendedLifetime(session) {
      let userdata = Unmanaged.passUnretained(session).toOpaque()
      var host = uniterm_host(
        userdata: userdata, post_status: postStatusCallback, call: callCallback)

      return withCStrings(arguments) { pointers in
        source.withUnsafeBytes { raw in
          uniterm_janet_run(
            &host, name, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, sandbox,
            pointers, pointers.count, &failure)
        }
      }
    }

    let kind: ScriptFailure.Kind

    switch status {
    case UNITERM_SCRIPT_OK: return nil
    case UNITERM_SCRIPT_PARSE_ERROR: kind = .parse
    case UNITERM_SCRIPT_COMPILE_ERROR: kind = .compile
    case UNITERM_SCRIPT_RUNTIME_ERROR: kind = .runtime
    case UNITERM_SCRIPT_INTERRUPTED: kind = .interrupted
    default: kind = .start
    }

    let text = failure.message
    let message = withUnsafeBytes(of: text) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }

    return ScriptFailure(
      name: name, line: Int(failure.line), column: Int(failure.column), kind: kind,
      message: message)
  }
}

extension ScriptVM {
  /// Runs the REPL in this process's Janet VM, on the calling thread, until its input ends. Each
  /// line the user enters and each change in whether a form is running reaches the app through
  /// `session`. Returns nil when the REPL ends cleanly.
  static func runRepl(session: ScriptSession, sandbox: UInt32) -> ScriptFailure? {
    var failure = uniterm_script_failure()

    let status = withExtendedLifetime(session) {
      let userdata = Unmanaged.passUnretained(session).toOpaque()
      var host = uniterm_host(
        userdata: userdata, post_status: postStatusCallback, call: callCallback)
      var repl = uniterm_repl_host(
        userdata: userdata, line: replLineCallback, running: replRunningCallback)

      return uniterm_janet_repl(&host, &repl, sandbox, &failure)
    }

    guard status != UNITERM_SCRIPT_OK else { return nil }

    let text = failure.message
    let message = withUnsafeBytes(of: text) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }

    return ScriptFailure(
      name: "repl", line: Int(failure.line), column: Int(failure.column), kind: .runtime,
      message: message)
  }
}

/// Janet's line editor returns a line, and the loop reports it before it evaluates it. A line that
/// is not UTF-8 is reported as the characters it decodes to, since the report is only for recall.
private let replLineCallback:
  @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = {
    userdata, text, length in
    guard let userdata, let text else { return }

    let session = Unmanaged<ScriptSession>.fromOpaque(userdata).takeUnretainedValue()
    let bytes = UnsafeBufferPointer(start: text, count: length)

    session.reportReplLine(String(decoding: bytes, as: UTF8.self))
  }

private let replRunningCallback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = {
  userdata, running in
  guard let userdata else { return }

  let session = Unmanaged<ScriptSession>.fromOpaque(userdata).takeUnretainedValue()

  session.reportEvaluating(running != 0)
}

/// Calls `body` with each string as a C string. The pointers last for the call.
private func withCStrings<Result>(
  _ strings: [String], _ body: ([UnsafePointer<CChar>?]) -> Result
) -> Result {
  var copies: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }

  defer {
    for copy in copies {
      free(copy)
    }
  }

  return copies.withUnsafeMutableBufferPointer { buffer in
    body(buffer.map { UnsafePointer($0) })
  }
}

/// Janet calls this from inside a host function. The text is already checked by the shim.
private let postStatusCallback:
  @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<CChar>?, Int
  ) -> Int32 = { userdata, level, text, length, errorBuffer, capacity in
    guard let userdata, let level = ScriptStatusLevel(rawValue: UInt8(truncatingIfNeeded: level))
    else {
      writeError("the status level is not known", to: errorBuffer, capacity: capacity)

      return 1
    }

    let session = Unmanaged<ScriptSession>.fromOpaque(userdata).takeUnretainedValue()
    let bytes = UnsafeBufferPointer(start: text, count: text == nil ? 0 : length)

    guard let string = String(validating: bytes, as: UTF8.self) else {
      writeError("the text is not UTF-8", to: errorBuffer, capacity: capacity)

      return 1
    }

    do {
      try session.postStatus(level: level, text: string)

      return 0
    } catch ScriptSessionError.failed(_, let message) {
      writeError(message, to: errorBuffer, capacity: capacity)
    } catch {
      writeError("the call failed: \(error)", to: errorBuffer, capacity: capacity)
    }

    return 1
  }

/// Janet calls this for every function but post-status. The shim already checked the arguments and
/// wrote the call in the wire's encoding. The reply's bytes go back in memory from malloc, which
/// the shim frees.
private let callCallback:
  @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?,
    UnsafeMutablePointer<CChar>?, Int
  ) -> Int32 = { userdata, request, length, reply, replyLength, errorBuffer, capacity in
    guard let userdata, let request, let reply, let replyLength else {
      writeError("the call was not complete", to: errorBuffer, capacity: capacity)

      return 1
    }

    let session = Unmanaged<ScriptSession>.fromOpaque(userdata).takeUnretainedValue()
    var reader = ByteReader(Data(UnsafeBufferPointer(start: request, count: length)))

    let call: ScriptCall

    do {
      call = try ScriptCall.decode(from: &reader)
      try reader.finished()
    } catch {
      writeError("the call could not be encoded: \(error)", to: errorBuffer, capacity: capacity)

      return 1
    }

    do {
      let payload = try session.call(call)

      reply.pointee = nil
      replyLength.pointee = 0

      guard !payload.isEmpty, let memory = malloc(payload.count) else { return 0 }

      payload.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: payload.count)
      reply.pointee = memory.assumingMemoryBound(to: UInt8.self)
      replyLength.pointee = payload.count

      return 0
    } catch ScriptSessionError.failed(_, let message) {
      writeError(message, to: errorBuffer, capacity: capacity)
    } catch {
      writeError("the call failed: \(error)", to: errorBuffer, capacity: capacity)
    }

    return 1
  }

private func writeError(
  _ message: String, to buffer: UnsafeMutablePointer<CChar>?, capacity: Int
) {
  guard let buffer, capacity > 0 else { return }

  var bytes: [UInt8] = []

  for scalar in message.unicodeScalars {
    let encoded = Array(String(scalar).utf8)

    if bytes.count + encoded.count > capacity - 1 { break }

    bytes.append(contentsOf: encoded)
  }

  for (index, byte) in bytes.enumerated() {
    buffer[index] = CChar(bitPattern: byte)
  }

  buffer[bytes.count] = 0
}
