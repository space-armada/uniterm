import Foundation

/// Why bytes from the other side of a helper socket were refused. The app treats the helper as
/// untrusted, so every case is an ordinary failure and never a trap.
public enum WireError: Error, Equatable, Sendable {
  case truncated
  case trailingBytes
  case unknownType(UInt8)
  case tooLong(declared: Int, limit: Int)
  case badValue(String)
  case versionMismatch(found: UInt16, expected: UInt16)
  case closed
  case io(Int32)
}

/// Appends big-endian fields to a buffer.
public struct ByteWriter {
  public private(set) var bytes = Data()

  public init() {}

  public mutating func put(_ value: UInt8) {
    bytes.append(value)
  }

  public mutating func put(_ value: UInt16) {
    bytes.append(UInt8(value >> 8))
    bytes.append(UInt8(value & 0xFF))
  }

  public mutating func put(_ value: UInt32) {
    for shift in stride(from: 24, through: 0, by: -8) {
      bytes.append(UInt8((value >> UInt32(shift)) & 0xFF))
    }
  }

  /// A string as a 16-bit length and its UTF-8 bytes. A string past `limit` bytes is cut at a
  /// character boundary, so the writer never produces a field the reader refuses.
  public mutating func put(string: String, limit: Int) {
    var utf8: [UInt8] = []

    for scalar in string.unicodeScalars {
      let encoded = Array(String(scalar).utf8)

      if utf8.count + encoded.count > limit { break }

      utf8.append(contentsOf: encoded)
    }

    put(UInt16(utf8.count))
    bytes.append(contentsOf: utf8)
  }

  public mutating func put(raw: Data) {
    bytes.append(raw)
  }
}

/// Reads big-endian fields from a buffer, refusing anything that runs past its end.
public struct ByteReader {
  private let bytes: Data
  public private(set) var offset = 0

  public init(_ bytes: Data) {
    self.bytes = bytes
  }

  public var remaining: Int { bytes.count - offset }

  public mutating func u8() throws -> UInt8 {
    guard remaining >= 1 else { throw WireError.truncated }

    defer { offset += 1 }

    return bytes[bytes.startIndex + offset]
  }

  public mutating func u16() throws -> UInt16 {
    let high = UInt16(try u8())
    let low = UInt16(try u8())

    return high << 8 | low
  }

  public mutating func u32() throws -> UInt32 {
    var value: UInt32 = 0

    for _ in 0..<4 {
      value = value << 8 | UInt32(try u8())
    }

    return value
  }

  public mutating func string(limit: Int) throws -> String {
    let count = Int(try u16())

    guard count <= limit else { throw WireError.tooLong(declared: count, limit: limit) }

    guard remaining >= count else { throw WireError.truncated }

    let start = bytes.startIndex + offset
    offset += count

    guard let text = String(data: bytes[start..<start + count], encoding: .utf8) else {
      throw WireError.badValue("a string is not UTF-8")
    }

    return text
  }

  public mutating func rest() -> Data {
    defer { offset = bytes.count }

    return bytes.suffix(from: bytes.startIndex + offset)
  }

  public func finished() throws {
    guard remaining == 0 else { throw WireError.trailingBytes }
  }
}
