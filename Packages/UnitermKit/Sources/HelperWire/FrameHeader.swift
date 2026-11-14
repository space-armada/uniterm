import Foundation

/// A frame is a one-byte type, a four-byte body length, and the body.
public enum FrameHeader {
  public static let size = 5

  public static func frame(type: UInt8, body: Data) -> Data {
    var data = Data()
    data.append(type)

    let count = UInt32(truncatingIfNeeded: body.count)

    for shift in stride(from: 24, through: 0, by: -8) {
      data.append(UInt8((count >> UInt32(shift)) & 0xFF))
    }

    data.append(body)

    return data
  }

  /// Reads a header. The length is checked against `limit` by the caller before it allocates.
  public static func parse(_ bytes: Data) throws -> (type: UInt8, length: Int) {
    guard bytes.count == size else { throw WireError.truncated }

    var reader = ByteReader(bytes)
    let type = try reader.u8()
    let length = try reader.u32()

    return (type, Int(length))
  }
}

/// Where a helper finds its end of the socketpair, for every helper.
public enum HelperChannel {
  public static let socketDescriptor: Int32 = 3
}
