import Foundation

/// The data a host function hands back to a script.
///
/// A reply carries one value as bytes. The helper's C shim decodes them into Janet values after the
/// callback returns, since Swift cannot build a Janet value without risking a `longjmp` through its
/// own frames. The shim and this type therefore share one format.
///
/// Every integer is an exact integer in a Janet number, so below `ScriptProtocol.maxID`. A record's
/// keys become keywords. A record is unordered, as a Janet struct is.
public indirect enum ScriptValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(UInt64)
  case string(String)
  case array([ScriptValue])
  case record([String: ScriptValue])

  /// Why a value cannot be sent.
  public enum EncodingError: Error, Equatable {
    case integerTooLarge(UInt64)
    case tooManyElements(Int)
    case keyNotAllowed(String)
    case tooDeep
  }

  /// How deeply values nest. The shim checks the same number.
  public static let maxDepth = 8

  /// The longest string a value may hold, in UTF-8 bytes.
  public static let maxStringBytes = 4096

  /// The longest record key, in bytes. Keys are short ASCII names.
  public static let maxKeyBytes = 32

  /// The most fields a record holds. The shim checks for repeated keys by comparing each pair, so
  /// the number bounds that work.
  public static let maxRecordFields = 64

  private enum Tag: UInt8 {
    case null = 0
    case falseValue = 1
    case trueValue = 2
    case integer = 3
    case string = 4
    case array = 5
    case record = 6
  }

  /// Bytes for the reply. A string past the limit is cut at a character boundary, since a title
  /// comes from outside and the reply is better short than refused.
  public func encoded() throws -> Data {
    var writer = ByteWriter()

    try encode(into: &writer, depth: 0)

    return writer.bytes
  }

  private func encode(into writer: inout ByteWriter, depth: Int) throws {
    guard depth <= Self.maxDepth else { throw EncodingError.tooDeep }

    switch self {
    case .null:
      writer.put(Tag.null.rawValue)

    case .bool(let value):
      writer.put((value ? Tag.trueValue : Tag.falseValue).rawValue)

    case .integer(let value):
      guard value <= ScriptProtocol.maxID else { throw EncodingError.integerTooLarge(value) }

      writer.put(Tag.integer.rawValue)
      writer.put(id: value)

    case .string(let text):
      let bytes = Self.bounded(text, limit: Self.maxStringBytes)

      writer.put(Tag.string.rawValue)
      writer.put(UInt32(bytes.count))
      writer.put(raw: Data(bytes))

    case .array(let elements):
      guard elements.count <= Int(UInt16.max) else {
        throw EncodingError.tooManyElements(elements.count)
      }

      writer.put(Tag.array.rawValue)
      writer.put(UInt16(elements.count))

      for element in elements {
        try element.encode(into: &writer, depth: depth + 1)
      }

    case .record(let fields):
      guard fields.count <= Self.maxRecordFields else {
        throw EncodingError.tooManyElements(fields.count)
      }

      writer.put(Tag.record.rawValue)
      writer.put(UInt16(fields.count))

      for key in fields.keys.sorted() {
        let bytes = Array(key.utf8)

        guard !bytes.isEmpty, bytes.count <= Self.maxKeyBytes,
          bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F })
        else { throw EncodingError.keyNotAllowed(key) }

        writer.put(UInt8(bytes.count))
        writer.put(raw: Data(bytes))

        try fields[key]?.encode(into: &writer, depth: depth + 1)
      }
    }
  }

  /// The UTF-8 bytes of `text`, cut at a character boundary at or under `limit`.
  static func bounded(_ text: String, limit: Int) -> [UInt8] {
    var bytes: [UInt8] = []

    for scalar in text.unicodeScalars {
      let encoded = Array(String(scalar).utf8)

      if bytes.count + encoded.count > limit { break }

      bytes.append(contentsOf: encoded)
    }

    return bytes
  }

  /// Reads a value from a reply's bytes. Only tests call it. It follows the format the shim reads,
  /// and the shim's own reader is proven separately against crafted replies.
  static func decode(_ data: Data) throws -> ScriptValue {
    var reader = ByteReader(data)
    let value = try decode(from: &reader, depth: 0)

    try reader.finished()

    return value
  }

  private static func decode(from reader: inout ByteReader, depth: Int) throws -> ScriptValue {
    guard depth <= maxDepth else { throw WireError.badValue("a value nests too deeply") }

    guard let tag = Tag(rawValue: try reader.u8()) else {
      throw WireError.badValue("a value has an unknown tag")
    }

    switch tag {
    case .null: return .null
    case .falseValue: return .bool(false)
    case .trueValue: return .bool(true)
    case .integer: return .integer(try reader.id())

    case .string:
      let count = Int(try reader.u32())

      guard count <= maxStringBytes else {
        throw WireError.tooLong(declared: count, limit: maxStringBytes)
      }

      guard reader.remaining >= count else { throw WireError.truncated }

      var bytes = Data()

      for _ in 0..<count {
        bytes.append(try reader.u8())
      }

      guard let text = String(data: bytes, encoding: .utf8) else {
        throw WireError.badValue("a string is not UTF-8")
      }

      return .string(text)

    case .array:
      let count = Int(try reader.u16())

      guard reader.remaining >= count else { throw WireError.truncated }

      var elements: [ScriptValue] = []

      for _ in 0..<count {
        elements.append(try decode(from: &reader, depth: depth + 1))
      }

      return .array(elements)

    case .record:
      let count = Int(try reader.u16())

      guard count <= maxRecordFields else {
        throw WireError.tooLong(declared: count, limit: maxRecordFields)
      }

      guard reader.remaining >= count * 2 else { throw WireError.truncated }

      var fields: [String: ScriptValue] = [:]

      for _ in 0..<count {
        let length = Int(try reader.u8())

        guard length > 0, length <= maxKeyBytes, reader.remaining >= length else {
          throw WireError.badValue("a record key has a bad length")
        }

        var key = ""

        for _ in 0..<length {
          let byte = try reader.u8()

          guard byte > 0x20 && byte < 0x7F else {
            throw WireError.badValue("a record key holds a byte that is not a name character")
          }

          key.unicodeScalars.append(Unicode.Scalar(byte))
        }

        guard fields[key] == nil else { throw WireError.badValue("a record repeats a key") }

        fields[key] = try decode(from: &reader, depth: depth + 1)
      }

      return .record(fields)
    }
  }
}
