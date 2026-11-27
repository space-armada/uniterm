import AppletKit
import Foundation

/// The exec wire's version and bounds, which the app and every driver share.
///
/// The wire is UTF-8 JSON, one object per LF-terminated line, on the driver's stdin and stdout.
/// Both sides start with a hello that names the protocol version, the applet type, and its command
/// schema version. No command or event flows until both sides accept the other's hello. Each side
/// refuses any protocol version but its own at the hello.
///
/// The protocol is an external version. It is 0 and stays 0 until uniterm's maintainers declare it
/// version 1. At 0 a change lands in place, and nothing promises that an older driver still runs.
/// A driver's message is read with its old meaning or refused, never read under a new meaning.
/// Drivers written for the versions that counted breaking revisions before this reset, 1 through
/// 4, are refused at the hello.
public enum ExecProtocol {
  public static let version = 0

  /// The most clipboard text one typed clipboard request reads or writes, in UTF-8 bytes. A larger
  /// clipboard is refused, never cut. A longer write is refused as that one call while its line
  /// fits a frame. A line past the frame still ends the driver, since the reader never learns its
  /// request ID.
  ///
  /// JSON escapes a control character to six bytes. The bound is an eighth of a frame. A text at
  /// the bound therefore fits one frame with the rest of its message, however it is escaped.
  public static let maxClipboardBytes = 128 * 1024

  /// The longest frame, newline excluded. The reader refuses a longer line before it has
  /// buffered the whole of it.
  public static let maxFrameBytes = 1 << 20

  /// The most bytes held for a driver in each direction: frames read but not yet handled, and
  /// frames written but not yet taken by the driver.
  public static let maxRetainedBytes = 4 << 20

  /// How deeply a frame's values may nest.
  public static let maxDepth = 32

  /// The most values one frame may hold. With the frame's size, it bounds the decoded memory.
  public static let maxValues = 65_536

  /// The most frames the main thread handles in one turn.
  public static let framesPerTurn = 64

  /// The longest request ID a driver may choose, as a string, in UTF-8 bytes.
  public static let maxRequestIDBytes = 64

  /// The longest command or applet type name, in UTF-8 bytes.
  public static let maxNameBytes = 64

  /// The longest refusal text a driver may send, in UTF-8 bytes. Longer text is cut.
  public static let maxRefusalBytes = 512
}

/// Why the wire failed. Each one closes the channel, and the pane shows the text.
public enum ExecWireError: Error, Sendable, Equatable, CustomStringConvertible {
  case frameTooLong
  case partialFrameAtEOF
  case malformed(String)
  case tooDeep
  case tooManyValues

  public var description: String {
    switch self {
    case .frameTooLong:
      return "the driver wrote a line longer than \(ExecProtocol.maxFrameBytes) bytes"

    case .partialFrameAtEOF:
      return "the driver's output ended in the middle of a line"

    case .malformed(let why):
      return "the driver wrote a line that is not a message: \(why)"

    case .tooDeep:
      return "the driver wrote a message nested more than \(ExecProtocol.maxDepth) levels deep"

    case .tooManyValues:
      return "the driver wrote a message with more than \(ExecProtocol.maxValues) values"
    }
  }
}

/// A message from a driver. The app validates each one and trusts none of them.
public enum ExecDriverMessage: Sendable, Equatable {
  /// A hello at this protocol version, whose applet type and schema version are read in this
  /// protocol's shape.
  case hello(protocolVersion: Int, appletType: String, schemaVersion: AppletSchemaVersion)

  /// A hello at another protocol version. Its other fields may be in another shape, so none is
  /// read. The case carries no schema version, so a hello that never matched this protocol cannot
  /// reach the check of a schema version, whatever version the schemas are at.
  case helloOfAnotherVersion(protocolVersion: Int)

  /// A command for the applet. The ID is the driver's own, and the reply carries it back.
  case command(id: JSONValue, name: String, arguments: JSONValue)

  /// A command for another pane: a member of a group the driver owns. It names the applet type
  /// and schema version it was written for, as a remote command does.
  case paneCommand(
    id: JSONValue, pane: UInt64, appletType: String, schemaVersion: AppletSchemaVersion,
    name: String,
    arguments: JSONValue)

  /// A layout for the driver's own subtree, anchored at its pane. The window reads the layout.
  case layout(id: JSONValue, layout: JSONValue)

  /// A read of the clipboard's plain text. It is a power of its own, apart from writes.
  case clipboardRead(id: JSONValue)

  /// A write of plain text to the clipboard. It is a power of its own, apart from reads. The text
  /// may pass `maxClipboardBytes`, and the channel refuses that write alone.
  case clipboardWrite(id: JSONValue, text: String)

  /// The driver refuses the app, such as for an app hello it does not support. The text is shown.
  case refusal(String)
}

/// A message to a driver.
public enum ExecAppMessage: Sendable, Equatable {
  case hello(protocolVersion: Int, appletType: String, schemaVersion: AppletSchemaVersion)
  case event(name: String, data: JSONValue)
  case reply(id: JSONValue, result: JSONValue)
  case error(id: JSONValue?, code: String, message: String)
}

public enum ExecWire {
  /// One line for the driver, with its newline. A JSON encoder escapes every newline inside a
  /// string, so the line holds exactly one.
  public static func frame(_ message: ExecAppMessage) -> Data {
    let object: [String: JSONValue]

    switch message {
    case .hello(let version, let type, let schema):
      object = [
        "type": .string("hello"), "protocol": .number(Double(version)),
        "applet": .string(type),
        "schema": .array([.number(Double(schema.major)), .number(Double(schema.minor))]),
      ]

    case .event(let name, let data):
      object = ["type": .string("event"), "name": .string(name), "data": data]

    case .reply(let id, let result):
      object = ["type": .string("reply"), "id": id, "result": result]

    case .error(let id, let code, let text):
      object = [
        "type": .string("error"), "id": id ?? .null,
        "error": .object(["code": .string(code), "message": .string(text)]),
      ]
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    // Encoding a JSON value of finite numbers cannot fail. A number that is not finite comes only
    // from a bug, and an empty object is sent in its place so the line stays one message.
    let data = (try? encoder.encode(JSONValue.object(object))) ?? Data("{}".utf8)

    return data + Data([0x0A])
  }

  /// Decodes one line, without its newline. The bounds on nesting and values are checked before
  /// the JSON decoder sees the bytes.
  public static func decode(_ line: Data) throws(ExecWireError) -> ExecDriverMessage {
    try checkBounds(line)

    let value: JSONValue

    do {
      value = try JSONDecoder().decode(JSONValue.self, from: line)
    } catch {
      throw .malformed("it is not JSON")
    }

    guard case .object(let fields) = value else { throw .malformed("it is not an object") }

    guard case .string(let type)? = fields["type"] else { throw .malformed("it has no type") }

    switch type {
    case "hello":
      let protocolVersion = try integer(fields["protocol"], "protocol")

      // A driver of another protocol may write its other fields in another shape. The hello then
      // still decodes, so the refusal names the protocol versions and says to update, instead of
      // calling the line malformed.
      guard protocolVersion == ExecProtocol.version else {
        return .helloOfAnotherVersion(protocolVersion: protocolVersion)
      }

      return .hello(
        protocolVersion: protocolVersion,
        appletType: try name(fields["applet"], "applet"),
        schemaVersion: try schemaVersion(fields["schema"]))

    case "command":
      let arguments = fields["arguments"] ?? .object([:])

      guard case .object = arguments else { throw .malformed("its arguments are not an object") }

      let id = try requestID(fields["id"])
      let command = try name(fields["name"], "name")

      guard let target = fields["pane"] else {
        return .command(id: id, name: command, arguments: arguments)
      }

      return .paneCommand(
        id: id, pane: try paneID(target), appletType: try name(fields["applet"], "applet"),
        schemaVersion: try schemaVersion(fields["schema"]), name: command,
        arguments: arguments)

    case "layout":
      guard let layout = fields["layout"], case .object = layout else {
        throw .malformed("its layout is not an object")
      }

      return .layout(id: try requestID(fields["id"]), layout: layout)

    case "clipboard-read":
      return .clipboardRead(id: try requestID(fields["id"]))

    case "clipboard-write":
      // Text past the clipboard bound is still a message. The channel refuses that one write.
      guard case .string(let text)? = fields["text"] else {
        throw .malformed("its text is not a string")
      }

      return .clipboardWrite(id: try requestID(fields["id"]), text: text)

    case "error":
      var text = "the driver gave no reason"

      if case .object(let error)? = fields["error"], case .string(let message)? = error["message"] {
        text = message
      } else if case .string(let message)? = fields["message"] {
        text = message
      }

      return .refusal(
        String(decoding: text.utf8.prefix(ExecProtocol.maxRefusalBytes), as: UTF8.self))

    default:
      throw .malformed("its type \"\(type.prefix(32))\" is unknown")
    }
  }

  private static func integer(_ value: JSONValue?, _ field: String) throws(ExecWireError) -> Int {
    guard case .number(let number)? = value, number.isFinite, number == number.rounded(),
      abs(number) < 2_147_483_648.0
    else { throw .malformed("its \(field) is not a whole number") }

    return Int(number)
  }

  /// A schema version is `[major, minor]`, two whole numbers that are not negative.
  private static func schemaVersion(_ value: JSONValue?) throws(ExecWireError)
    -> AppletSchemaVersion
  {
    guard case .array(let parts)? = value, parts.count == 2 else {
      throw .malformed("its schema is not [major, minor]")
    }

    let major = try integer(parts[0], "schema major")
    let minor = try integer(parts[1], "schema minor")

    guard major >= 0, minor >= 0 else { throw .malformed("its schema is not [major, minor]") }

    return AppletSchemaVersion(major, minor)
  }

  private static func name(_ value: JSONValue?, _ field: String) throws(ExecWireError) -> String {
    guard case .string(let text)? = value, !text.isEmpty,
      text.utf8.count <= ExecProtocol.maxNameBytes
    else { throw .malformed("its \(field) is not a name") }

    return text
  }

  /// A pane ID is a whole number above 0 that a double holds exactly.
  private static func paneID(_ value: JSONValue) throws(ExecWireError) -> UInt64 {
    guard case .number(let number) = value, number.isFinite, number == number.rounded(),
      number >= 1, number <= 9_007_199_254_740_991
    else { throw .malformed("its pane is not a pane ID") }

    return UInt64(number)
  }

  /// A request ID is a whole number or a short string, as the driver chose it.
  private static func requestID(_ value: JSONValue?) throws(ExecWireError) -> JSONValue {
    switch value {
    case .number(let number)? where number.isFinite && number == number.rounded():
      return .number(number)

    case .string(let text)? where text.utf8.count <= ExecProtocol.maxRequestIDBytes:
      return .string(text)

    default:
      throw .malformed("its id is not a whole number or a short string")
    }
  }

  /// Counts nesting and values in one pass over the bytes, outside strings. It reads every byte
  /// once and keeps two counters, so a hostile line costs no more than its length.
  static func checkBounds(_ line: Data) throws(ExecWireError) {
    var depth = 0
    var values = 0
    var inString = false
    var escaped = false

    for byte in line {
      if inString {
        if escaped {
          escaped = false
        } else if byte == 0x5C {
          escaped = true
        } else if byte == 0x22 {
          inString = false
        }

        continue
      }

      switch byte {
      case 0x22:
        inString = true
        values += 1

      case 0x5B, 0x7B:
        depth += 1
        values += 1

        guard depth <= ExecProtocol.maxDepth else { throw .tooDeep }

      case 0x5D, 0x7D:
        depth -= 1

      case 0x2C:
        values += 1

      default:
        break
      }

      guard values <= ExecProtocol.maxValues else { throw .tooManyValues }
    }
  }
}
