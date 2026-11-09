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
  }

  public let name: String
  public let line: Int
  public let column: Int
  public let kind: Kind
  public let message: String

  /// One line for stderr: the script name, the position when Janet gave one, and the message.
  public var description: String {
    let position = line > 0 ? ":\(line):\(column)" : ""

    return "\(name)\(position): \(kind.rawValue) error: \(message)"
  }
}

/// Runs one script in the helper's Janet VM, on the calling thread. The caller must be the thread
/// that owns the VM, and no other script may run on it at the same time.
enum ScriptVM {
  /// The host functions call back into `session`. A callback never throws or traps across the C
  /// boundary. It turns a failure into the message that the shim raises to the script.
  static func run(
    name: String, source: Data, session: ScriptSession
  ) -> ScriptFailure? {
    var failure = uniterm_script_failure()

    let status = withExtendedLifetime(session) {
      let userdata = Unmanaged.passUnretained(session).toOpaque()
      var host = uniterm_host(userdata: userdata, post_status: postStatusCallback)

      return source.withUnsafeBytes { raw in
        uniterm_janet_run(
          &host, name, raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
          uniterm_janet_default_sandbox, &failure)
      }
    }

    let kind: ScriptFailure.Kind

    switch status {
    case UNITERM_SCRIPT_OK: return nil
    case UNITERM_SCRIPT_PARSE_ERROR: kind = .parse
    case UNITERM_SCRIPT_COMPILE_ERROR: kind = .compile
    case UNITERM_SCRIPT_RUNTIME_ERROR: kind = .runtime
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
    } catch ScriptSessionError.connectionLost(let message) {
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
