import Foundation

/// A JSON value as the controller formats read it. Every kind has its own case, so a field can
/// never be read two ways, such as a number as a string.
///
/// `integer` holds exactly the whole numbers the controller formats use: unsigned, at most nine
/// digits, with no fraction or exponent. Any other number is `number`, so a reader that matches
/// `integer` never takes a negative or a fraction for a version.
public indirect enum StrictJSON: Equatable, Sendable {
  case string(String)
  case integer(Int)

  /// A number outside the `integer` domain, as the validated literal from the document.
  case number(String)
  case boolean(Bool)
  case null
  case array([StrictJSON])

  /// The members in the order the bytes hold them. No key repeats.
  case object([(key: String, value: StrictJSON)])

  public static func == (lhs: StrictJSON, rhs: StrictJSON) -> Bool {
    switch (lhs, rhs) {
    case (.string(let a), .string(let b)): return a == b
    case (.integer(let a), .integer(let b)): return a == b
    case (.number(let a), .number(let b)): return a == b
    case (.boolean(let a), .boolean(let b)): return a == b
    case (.null, .null): return true
    case (.array(let a), .array(let b)): return a == b
    case (.object(let a), .object(let b)):
      return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    default: return false
    }
  }
}

/// Why a document is not strict JSON. The offset is the byte where reading stopped.
public struct StrictJSONError: Error, Equatable, CustomStringConvertible, Sendable {
  public let offset: Int
  public let reason: String

  public var description: String { "byte \(offset): \(reason)" }
}

/// Reads RFC 8259 JSON more strictly than Foundation does. Foundation keeps the last of two equal
/// keys, which lets two readers of one file see two documents. This reader refuses a repeated key,
/// a byte order mark, bytes that are not UTF-8, an unpaired surrogate, an escaped NUL, a number
/// with a leading zero, and anything after the value. Keys repeat when they are equal after their
/// escapes are decoded.
public enum StrictJSONReader {
  /// The deepest nesting a document may have.
  public static let maxDepth = 8

  public static func parse(_ bytes: Data, maxBytes: Int) throws -> StrictJSON {
    guard bytes.count <= maxBytes else {
      throw StrictJSONError(offset: maxBytes, reason: "the document is over \(maxBytes) bytes")
    }

    guard String(validating: bytes, as: UTF8.self) != nil else {
      throw StrictJSONError(offset: 0, reason: "the document is not UTF-8")
    }

    var reader = Reader(bytes: [UInt8](bytes))

    reader.skipSpace()

    let value = try reader.value(depth: 0)

    reader.skipSpace()

    guard reader.atEnd else { throw reader.error("something follows the document") }

    return value
  }

  private struct Reader {
    let bytes: [UInt8]
    var index = 0

    var atEnd: Bool { index == bytes.count }

    func error(_ reason: String) -> StrictJSONError {
      StrictJSONError(offset: index, reason: reason)
    }

    mutating func skipSpace() {
      while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
        index += 1
      }
    }

    mutating func value(depth: Int) throws -> StrictJSON {
      guard depth < StrictJSONReader.maxDepth else { throw error("the document nests too deeply") }

      guard index < bytes.count else { throw error("a value is missing") }

      switch bytes[index] {
      case UInt8(ascii: "{"): return try object(depth: depth)
      case UInt8(ascii: "["): return try array(depth: depth)
      case UInt8(ascii: "\""): return .string(try string())
      case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"): return try number()
      case UInt8(ascii: "t"):
        try literal("true")
        return .boolean(true)
      case UInt8(ascii: "f"):
        try literal("false")
        return .boolean(false)
      case UInt8(ascii: "n"):
        try literal("null")
        return .null
      default: throw error("a value must be a string, number, boolean, null, array, or object")
      }
    }

    mutating func literal(_ word: String) throws {
      let expected = Array(word.utf8)

      guard bytes.count - index >= expected.count,
        Array(bytes[index..<index + expected.count]) == expected
      else { throw error("a value must be a string, number, boolean, null, array, or object") }

      index += expected.count
    }

    mutating func object(depth: Int) throws -> StrictJSON {
      index += 1
      skipSpace()

      var members: [(key: String, value: StrictJSON)] = []
      var keys = Set<String>()

      if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
        index += 1

        return .object(members)
      }

      while true {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
          throw error("an object key must be a string")
        }

        let keyStart = index
        let key = try string()

        guard keys.insert(key).inserted else {
          throw StrictJSONError(offset: keyStart, reason: "the key \"\(key)\" appears twice")
        }

        skipSpace()

        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
          throw error("a colon must follow a key")
        }

        index += 1
        skipSpace()
        members.append((key, try value(depth: depth + 1)))
        skipSpace()

        guard index < bytes.count else { throw error("the object does not end") }

        if bytes[index] == UInt8(ascii: "}") {
          index += 1

          return .object(members)
        }

        guard bytes[index] == UInt8(ascii: ",") else { throw error("a comma or } is missing") }

        index += 1
        skipSpace()
      }
    }

    mutating func array(depth: Int) throws -> StrictJSON {
      index += 1
      skipSpace()

      var elements: [StrictJSON] = []

      if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
        index += 1

        return .array(elements)
      }

      while true {
        elements.append(try value(depth: depth + 1))
        skipSpace()

        guard index < bytes.count else { throw error("the array does not end") }

        if bytes[index] == UInt8(ascii: "]") {
          index += 1

          return .array(elements)
        }

        guard bytes[index] == UInt8(ascii: ",") else { throw error("a comma or ] is missing") }

        index += 1
        skipSpace()
      }
    }

    mutating func digits() -> Range<Int> {
      let start = index

      while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
        index += 1
      }

      return start..<index
    }

    mutating func number() throws -> StrictJSON {
      let start = index
      let negative = bytes[index] == UInt8(ascii: "-")

      if negative { index += 1 }

      let whole = digits()

      guard !whole.isEmpty else { throw error("a number needs digits") }

      guard whole.count == 1 || bytes[whole.lowerBound] != UInt8(ascii: "0") else {
        throw error("a number has a leading zero")
      }

      var plain = !negative && whole.count <= 9

      if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        index += 1
        plain = false

        guard !digits().isEmpty else { throw error("a fraction needs digits") }
      }

      if index < bytes.count, [UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) {
        index += 1
        plain = false

        if index < bytes.count, [UInt8(ascii: "+"), UInt8(ascii: "-")].contains(bytes[index]) {
          index += 1
        }

        guard !digits().isEmpty else { throw error("an exponent needs digits") }
      }

      guard plain else { return .number(String(decoding: bytes[start..<index], as: UTF8.self)) }

      return .integer(bytes[whole].reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) })
    }

    mutating func string() throws -> String {
      index += 1

      var scalars = String.UnicodeScalarView()
      var run: [UInt8] = []

      func flush() {
        scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
        run.removeAll(keepingCapacity: true)
      }

      while true {
        guard index < bytes.count else { throw error("a string does not end") }

        let byte = bytes[index]

        if byte == UInt8(ascii: "\"") {
          index += 1
          flush()

          return String(scalars)
        }

        guard byte >= 0x20 else { throw error("a string holds a control character") }

        guard byte == UInt8(ascii: "\\") else {
          run.append(byte)
          index += 1

          continue
        }

        flush()
        index += 1

        guard index < bytes.count else { throw error("an escape does not end") }

        let escape = bytes[index]

        index += 1

        switch escape {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append("\u{08}")
        case UInt8(ascii: "f"): scalars.append("\u{0C}")
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"): scalars.append(try unicodeEscape())
        default: throw error("an escape is not one JSON allows")
        }
      }
    }

    mutating func hexQuad() throws -> UInt32 {
      guard index + 4 <= bytes.count,
        let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
      else { throw error("a \\u escape needs four hex digits") }

      index += 4

      return value
    }

    mutating func unicodeEscape() throws -> Unicode.Scalar {
      let first = try hexQuad()

      guard first != 0 else { throw error("a string holds an escaped NUL") }

      if (0xDC00...0xDFFF).contains(first) { throw error("a string holds an unpaired surrogate") }

      guard (0xD800...0xDBFF).contains(first) else { return Unicode.Scalar(first)! }

      guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"),
        bytes[index + 1] == UInt8(ascii: "u")
      else { throw error("a string holds an unpaired surrogate") }

      index += 2

      let second = try hexQuad()

      guard (0xDC00...0xDFFF).contains(second) else {
        throw error("a string holds an unpaired surrogate")
      }

      return Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))!
    }
  }
}

extension StrictJSON {
  /// The members of an object whose keys are exactly `required` plus some of `optional`. Any other
  /// key is refused, so a field this version does not know can never be ignored.
  public func members(
    of what: String, required: Set<String>, optional: Set<String> = []
  ) throws -> [String: StrictJSON] {
    guard case .object(let members) = self else {
      throw ControllerPackageError.malformed("\(what) must be an object")
    }

    var found: [String: StrictJSON] = [:]

    for member in members {
      guard required.contains(member.key) || optional.contains(member.key) else {
        throw ControllerPackageError.malformed("\(what) has the unknown field \"\(member.key)\"")
      }

      found[member.key] = member.value
    }

    for key in required.sorted() where found[key] == nil {
      throw ControllerPackageError.malformed("\(what) is missing \"\(key)\"")
    }

    return found
  }

  public func string(_ what: String) throws -> String {
    guard case .string(let text) = self else {
      throw ControllerPackageError.malformed("\(what) must be a string")
    }

    return text
  }

  public func integer(_ what: String) throws -> Int {
    guard case .integer(let number) = self else {
      throw ControllerPackageError.malformed("\(what) must be a whole number")
    }

    return number
  }

  public func array(_ what: String) throws -> [StrictJSON] {
    guard case .array(let elements) = self else {
      throw ControllerPackageError.malformed("\(what) must be an array")
    }

    return elements
  }

  public func object(_ what: String) throws -> [(key: String, value: StrictJSON)] {
    guard case .object(let members) = self else {
      throw ControllerPackageError.malformed("\(what) must be an object")
    }

    return members
  }
}
