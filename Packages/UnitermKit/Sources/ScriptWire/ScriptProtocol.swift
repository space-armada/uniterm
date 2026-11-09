import Foundation
@_exported import HelperWire

/// What the protocol version and its sizes mean for both sides. A mismatch is refused before any
/// call runs.
///
/// The hello is one message with one field, in every version. A peer built against another
/// version can therefore always read the other's hello, and the refusal names the version.
public enum ScriptProtocol {
  public static let version: UInt16 = 2

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

  /// The largest ID a script may hold. A Janet number is a double, so every ID below this value is
  /// an exact integer in it.
  public static let maxID: UInt64 = (1 << 53) - 1

  /// The longest applet kind a script may name, in UTF-8 bytes.
  public static let maxKindBytes = 32

  /// The longest directory a script may name, in UTF-8 bytes. It matches the system's path limit.
  public static let maxDirectoryBytes = 1024

  /// The longest file name a script may give to content it sends, in UTF-8 bytes. It matches the
  /// system's file name limit.
  public static let maxFileNameBytes = 255

  /// The most content one send may carry, in bytes. A send is the only message with a larger
  /// frame, so the reader allocates this much only for a message of its own type.
  public static let maxSendBytes = 1024 * 1024

  /// The largest payload a reply may carry. It leaves room in the frame for the reply's header.
  public static let maxReplyPayload = maxControlBody - 1024
}

/// Which way a new pane splits the pane beside it.
public enum ScriptAxis: UInt8, Sendable, Equatable, CaseIterable {
  /// The panes sit side by side.
  case row = 1

  /// The panes are stacked.
  case column = 2
}

/// How a script names a pane, or one tab of it. Every number is an exact integer that fits in a
/// Janet number. The app finds the window, pane, and tab only while they are open in this launch.
public struct ScriptPaneReference: Sendable, Equatable {
  public var window: UInt64
  public var pane: UInt64
  public var tab: UInt64?

  public init(window: UInt64, pane: UInt64, tab: UInt64? = nil) {
    self.window = window
    self.pane = pane
    self.tab = tab
  }
}

extension ByteWriter {
  mutating func put(id: UInt64) {
    put(UInt32(truncatingIfNeeded: id >> 32))
    put(UInt32(truncatingIfNeeded: id))
  }

  mutating func put(reference: ScriptPaneReference) {
    put(id: reference.window)
    put(id: reference.pane)

    if let tab = reference.tab {
      put(UInt8(1))
      put(id: tab)
    } else {
      put(UInt8(0))
    }
  }

  /// A string that may be absent. A flag says which.
  mutating func put(optional text: String?, limit: Int) {
    guard let text else {
      put(UInt8(0))
      return
    }

    put(UInt8(1))
    put(string: text, limit: limit)
  }
}

extension ByteReader {
  /// An ID. One above `ScriptProtocol.maxID` cannot be a Janet integer, so the app never sees it
  /// from a helper that checks its arguments.
  mutating func id() throws -> UInt64 {
    let high = UInt64(try u32())
    let low = UInt64(try u32())
    let value = high << 32 | low

    guard value <= ScriptProtocol.maxID else {
      throw WireError.badValue("an ID is too large for a script number")
    }

    return value
  }

  mutating func reference() throws -> ScriptPaneReference {
    let window = try id()
    let pane = try id()

    switch try u8() {
    case 0: return ScriptPaneReference(window: window, pane: pane)
    case 1: return ScriptPaneReference(window: window, pane: pane, tab: try id())
    default: throw WireError.badValue("a reference has an unknown tab flag")
    }
  }

  mutating func optionalString(limit: Int) throws -> String? {
    switch try u8() {
    case 0: return nil
    case 1: return try string(limit: limit)
    default: throw WireError.badValue("an optional string has an unknown flag")
    }
  }
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
  case listWindows
  case listPanes(window: UInt64)
  case openPane(
    kind: String, beside: ScriptPaneReference, axis: ScriptAxis?, directory: String?)
  case openTab(pane: ScriptPaneReference, directory: String?)
  case send(pane: ScriptPaneReference, name: String, content: Data)

  var code: UInt16 {
    switch self {
    case .postStatus: return 1
    case .listWindows: return 2
    case .listPanes: return 3
    case .openPane: return 4
    case .openTab: return 5
    case .send: return 6
    }
  }

  /// The code of the one call that carries content, and so has a frame of its own type.
  static let sendCode: UInt16 = 6

  func encode(into body: inout ByteWriter) {
    body.put(code)

    switch self {
    case .postStatus(let level, let text):
      body.put(level.rawValue)
      body.put(string: text, limit: ScriptProtocol.maxStatusBytes)

    case .listWindows:
      break

    case .listPanes(let window):
      body.put(id: window)

    case .openPane(let kind, let beside, let axis, let directory):
      body.put(string: kind, limit: ScriptProtocol.maxKindBytes)
      body.put(reference: beside)
      body.put(axis?.rawValue ?? 0)
      body.put(optional: directory, limit: ScriptProtocol.maxDirectoryBytes)

    case .openTab(let pane, let directory):
      body.put(reference: pane)
      body.put(optional: directory, limit: ScriptProtocol.maxDirectoryBytes)

    case .send(let pane, let name, let content):
      body.put(reference: pane)
      body.put(string: name, limit: ScriptProtocol.maxFileNameBytes)
      body.put(raw: content)
    }
  }

  /// Public because the helper reads back the call its shim wrote, before it sends the call.
  public static func decode(from reader: inout ByteReader) throws -> ScriptCall {
    switch try reader.u16() {
    case 1:
      guard let level = ScriptStatusLevel(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown status level")
      }

      return .postStatus(
        level: level, text: try reader.string(limit: ScriptProtocol.maxStatusBytes))

    case 2:
      return .listWindows

    case 3:
      return .listPanes(window: try reader.id())

    case 4:
      let kind = try reader.string(limit: ScriptProtocol.maxKindBytes)
      let beside = try reader.reference()
      let axisByte = try reader.u8()

      guard axisByte == 0 || ScriptAxis(rawValue: axisByte) != nil else {
        throw WireError.badValue("an unknown split axis")
      }

      return .openPane(
        kind: kind, beside: beside, axis: ScriptAxis(rawValue: axisByte),
        directory: try reader.optionalString(limit: ScriptProtocol.maxDirectoryBytes))

    case 5:
      return .openTab(
        pane: try reader.reference(),
        directory: try reader.optionalString(limit: ScriptProtocol.maxDirectoryBytes))

    case 6:
      let pane = try reader.reference()
      let name = try reader.string(limit: ScriptProtocol.maxFileNameBytes)
      let content = reader.rest()

      guard content.count <= ScriptProtocol.maxSendBytes else {
        throw WireError.tooLong(declared: content.count, limit: ScriptProtocol.maxSendBytes)
      }

      return .send(pane: pane, name: name, content: content)

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

  /// The window, pane, or tab the call names is not open in this launch. It may have closed, or
  /// the reference may come from an earlier launch. The text never names another pane.
  case notFound = 4
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

  /// The frame type of the one call that carries content.
  static let sendType: UInt8 = 4

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .begin: return 2
    case .request(_, let call):
      if case .send = call { return Self.sendType }

      return 3
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
    type == sendType
      ? ScriptProtocol.maxSendBytes + ScriptProtocol.maxControlBody : ScriptProtocol.maxControlBody
  }

  public static func decode(type: UInt8, body: Data) throws -> ScriptHelperMessage {
    var reader = ByteReader(body)
    let message: ScriptHelperMessage

    switch type {
    case 1: message = .hello(version: try reader.u16())

    case 2: message = .begin(name: try reader.string(limit: ScriptProtocol.maxNameBytes))

    case 3, sendType:
      let id = try reader.u32()
      let call = try ScriptCall.decode(from: &reader)

      var isSend = false

      if case .send = call { isSend = true }

      guard isSend == (type == sendType) else {
        throw WireError.badValue("a call is in a frame of the wrong type")
      }

      message = .request(id: id, call: call)

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
