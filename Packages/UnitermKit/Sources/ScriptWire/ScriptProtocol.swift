import Foundation
@_exported import HelperWire

/// What the protocol version and its sizes mean for both sides. A mismatch is refused before any
/// call runs.
///
/// The hello is one message with one field, in every version. A peer built against another
/// version can therefore always read the other's hello, and the refusal names the version.
public enum ScriptProtocol {
  public static let version: UInt16 = 1

  /// What the user is told when the two sides disagree. The app and its command are two binaries
  /// in one bundle, so replacing the bundle under a running app pairs an old app with a new one.
  public static let mismatchText =
    "The uniterm command and the app come from different versions. Relaunch uniterm."

  /// The largest body any message may declare. The reader checks it before it allocates.
  public static let maxControlBody = 64 * 1024

  /// The longest script name a peer may announce, in UTF-8 bytes.
  public static let maxNameBytes = 128

  /// The longest status text a script may post, in UTF-8 bytes. It matches the host function's own
  /// check in the Janet shim.
  public static let maxStatusBytes = 2048

  /// The longest failure message a reply may carry, in UTF-8 bytes.
  public static let maxFailureBytes = 512
}

/// How serious a script's status message is.
public enum ScriptStatusLevel: UInt8, Sendable, Equatable, CaseIterable {
  case info = 0
  case warning = 1
  case error = 2
}

/// A host function call. Each case is one function, named on the wire by a 16-bit code that never
/// changes meaning. A new function takes a new code and keeps the others.
public enum ScriptCall: Equatable, Sendable {
  case postStatus(level: ScriptStatusLevel, text: String)

  var code: UInt16 {
    switch self {
    case .postStatus: return 1
    }
  }

  func encode(into body: inout ByteWriter) {
    body.put(code)

    switch self {
    case .postStatus(let level, let text):
      body.put(level.rawValue)
      body.put(string: text, limit: ScriptProtocol.maxStatusBytes)
    }
  }

  static func decode(from reader: inout ByteReader) throws -> ScriptCall {
    switch try reader.u16() {
    case 1:
      guard let level = ScriptStatusLevel(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown status level")
      }

      return .postStatus(
        level: level, text: try reader.string(limit: ScriptProtocol.maxStatusBytes))

    default:
      throw WireError.badValue("an unknown host function")
    }
  }
}

/// Why a call did not succeed. The kind lets a script tell its own mistake from a refusal.
public enum ScriptFailureKind: UInt8, Sendable, Equatable {
  /// The call's arguments are not acceptable.
  case badArgument = 1

  /// The app declined the call, such as for a missing window.
  case refused = 2

  /// The app failed while it ran the call.
  case failed = 3
}

/// The app's answer to one call.
public enum ScriptResult: Equatable, Sendable {
  /// The call ran. The payload is the function's result, which is empty for a function that
  /// returns nothing.
  case ok(Data)

  case failure(ScriptFailureKind, String)
}

/// A message from a script helper. The app validates each one and trusts none of them.
public enum ScriptHelperMessage: Equatable, Sendable {
  case hello(version: UInt16)

  /// Names the script, or the REPL, that the connection serves. The name labels the script's
  /// messages in the status bar.
  case begin(name: String)

  /// A host function call. The reply carries the same request ID.
  case request(id: UInt32, call: ScriptCall)

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .begin: return 2
    case .request: return 3
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)

    case .begin(let name): body.put(string: name, limit: ScriptProtocol.maxNameBytes)

    case .request(let id, let call):
      body.put(id)
      call.encode(into: &body)
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  /// The most body bytes a message of `type` may declare.
  public static func bodyLimit(type: UInt8) -> Int {
    ScriptProtocol.maxControlBody
  }

  public static func decode(type: UInt8, body: Data) throws -> ScriptHelperMessage {
    var reader = ByteReader(body)
    let message: ScriptHelperMessage

    switch type {
    case 1: message = .hello(version: try reader.u16())

    case 2: message = .begin(name: try reader.string(limit: ScriptProtocol.maxNameBytes))

    case 3:
      let id = try reader.u32()
      message = .request(id: id, call: try ScriptCall.decode(from: &reader))

    default: throw WireError.unknownType(type)
    }

    try reader.finished()

    return message
  }

  /// What the app checks of the helper's hello.
  public static func validateHello(_ message: ScriptHelperMessage) throws {
    guard case .hello(let version) = message else {
      throw WireError.badValue("the helper did not start with a hello")
    }

    guard version == ScriptProtocol.version else {
      throw WireError.versionMismatch(found: version, expected: ScriptProtocol.version)
    }
  }
}

/// A message from the app. The helper validates each one.
public enum ScriptAppMessage: Equatable, Sendable {
  case hello(version: UInt16)

  case reply(id: UInt32, result: ScriptResult)

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .reply: return 2
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)

    case .reply(let id, let result):
      body.put(id)

      switch result {
      case .ok(let payload):
        body.put(UInt8(0))
        body.put(raw: payload)

      case .failure(let kind, let text):
        body.put(kind.rawValue)
        body.put(string: text, limit: ScriptProtocol.maxFailureBytes)
      }
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  public static func bodyLimit(type: UInt8) -> Int {
    ScriptProtocol.maxControlBody
  }

  public static func decode(type: UInt8, body: Data) throws -> ScriptAppMessage {
    var reader = ByteReader(body)

    switch type {
    case 1:
      let version = try reader.u16()
      try reader.finished()

      return .hello(version: version)

    case 2:
      let id = try reader.u32()
      let status = try reader.u8()

      if status == 0 {
        return .reply(id: id, result: .ok(reader.rest()))
      }

      guard let kind = ScriptFailureKind(rawValue: status) else {
        throw WireError.badValue("an unknown failure kind")
      }

      let text = try reader.string(limit: ScriptProtocol.maxFailureBytes)
      try reader.finished()

      return .reply(id: id, result: .failure(kind, text))

    default:
      throw WireError.unknownType(type)
    }
  }

  /// What the helper checks of the app's hello.
  public static func validateHello(_ message: ScriptAppMessage) throws {
    guard case .hello(let version) = message else {
      throw WireError.badValue("the app did not start with a hello")
    }

    guard version == ScriptProtocol.version else {
      throw WireError.versionMismatch(found: version, expected: ScriptProtocol.version)
    }
  }
}
