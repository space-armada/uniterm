import Foundation
@_exported import HelperWire

/// What the protocol version and its sizes mean for both sides. A mismatch is refused before any
/// document moves.
public enum DocumentProtocol {
  public static let version: UInt16 = 1

  /// The descriptor the helper finds its end of the socketpair on.
  public static let socketDescriptor: Int32 = HelperChannel.socketDescriptor

  /// What the pane tells the user when the two sides disagree.
  public static let mismatchText =
    "The document reader and uniterm come from different versions. Relaunch uniterm."

  /// The largest body a message other than the archive and an image may carry.
  public static let maxControlBody = 64 * 1024

  /// The most bytes the archived attributed string may declare. The app checks this before it
  /// allocates the body.
  public static let maxArchiveBytes = 32 << 20

  /// The most pixels one image may carry. Every image crosses as raw pixels in one fixed format:
  /// four bytes each, red, green, blue, and alpha, with alpha premultiplied, in sRGB.
  public static let maxImagePixels = 16_000_000
  public static let bytesPerPixel = 4

  /// The most pixels all of one reply's images may carry together.
  public static let maxTotalPixels = 64_000_000

  /// The most images one reply may carry.
  public static let maxImages = 64

  public static let maxMessageBytes = 512
}

/// The reader to use. The app picks it from the file type, and the helper never guesses it from
/// the bytes, so a file is never read as HTML.
public enum DocumentKind: UInt8, Sendable, Equatable, CaseIterable {
  case rtf = 1
  case word97 = 2
  case wordXML = 3
}

/// Why a decode did not produce a document.
public enum DocumentFailureKind: UInt8, Sendable, Equatable {
  /// The file is damaged or the reader could not make a document of it.
  case unreadable = 1

  /// The document is past a limit the helper keeps.
  case limit = 2

  /// The helper has no descriptor for the request.
  case noSource = 3
}

/// A request from the app. Each case is one framed message.
public enum DocumentAppMessage: Equatable, Sendable {
  case hello(version: UInt16)

  /// Reads the file whose descriptor travels beside this message in the same send.
  case decode(request: UInt32, kind: DocumentKind)

  case ping(nonce: UInt32)

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .decode: return 2
    case .ping: return 3
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)

    case .decode(let request, let kind):
      body.put(request)
      body.put(kind.rawValue)

    case .ping(let nonce): body.put(nonce)
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  public static func decode(type: UInt8, body: Data) throws -> DocumentAppMessage {
    var reader = ByteReader(body)
    let message: DocumentAppMessage

    switch type {
    case 1: message = .hello(version: try reader.u16())

    case 2:
      let request = try reader.u32()

      guard let kind = DocumentKind(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown document kind")
      }

      message = .decode(request: request, kind: kind)

    case 3: message = .ping(nonce: try reader.u32())
    default: throw WireError.unknownType(type)
    }

    try reader.finished()

    return message
  }
}

/// A message from the helper. The app validates each one and trusts none of them.
public enum DocumentHelperMessage: Equatable, Sendable {
  case hello(version: UInt16)

  /// The archived attributed string, and how many images follow it. Each image replaces one
  /// attachment, in the order the attachments appear in the text.
  case archive(request: UInt32, imageCount: UInt16, bytes: Data)

  /// Raw pixels in the fixed format. The count must be `width * height * 4`.
  case image(request: UInt32, index: UInt16, width: UInt32, height: UInt32, pixels: Data)

  /// The last message of a successful reply.
  case done(request: UInt32)

  case failure(request: UInt32, kind: DocumentFailureKind, text: String)
  case pong(nonce: UInt32)

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .archive: return 2
    case .image: return 3
    case .done: return 4
    case .failure: return 5
    case .pong: return 6
    }
  }

  public func frame() -> Data {
    FrameHeader.frame(type: wireType, body: body())
  }

  private func body() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)

    case .archive(let request, let count, let bytes):
      body.put(request)
      body.put(count)
      body.put(raw: bytes)

    case .image(let request, let index, let width, let height, let pixels):
      body.put(request)
      body.put(index)
      body.put(width)
      body.put(height)
      body.put(raw: pixels)

    case .done(let request): body.put(request)

    case .failure(let request, let kind, let text):
      body.put(request)
      body.put(kind.rawValue)
      body.put(string: text, limit: DocumentProtocol.maxMessageBytes)

    case .pong(let nonce): body.put(nonce)
    }

    return body.bytes
  }

  /// A reply with a big payload as a prefix and the payload, for a sender that writes them without
  /// joining them. The frame's length covers both parts.
  public func parts() -> (prefix: Data, trailer: Data)? {
    switch self {
    case .archive(let request, let count, let bytes):
      return Self.split(
        type: wireType,
        fields: {
          $0.put(request)
          $0.put(count)
        }, trailer: bytes)

    case .image(let request, let index, let width, let height, let pixels):
      return Self.split(
        type: wireType,
        fields: {
          $0.put(request)
          $0.put(index)
          $0.put(width)
          $0.put(height)
        }, trailer: pixels)

    default:
      return nil
    }
  }

  private static func split(
    type: UInt8, fields: (inout ByteWriter) -> Void, trailer: Data
  ) -> (Data, Data) {
    var head = ByteWriter()
    fields(&head)

    var length = ByteWriter()
    length.put(UInt32(truncatingIfNeeded: head.bytes.count + trailer.count))

    var prefix = Data([type])
    prefix.append(length.bytes)
    prefix.append(head.bytes)

    return (prefix, trailer)
  }

  /// The most body bytes a message of `type` may declare. The reader checks this before it
  /// allocates the body.
  public static func bodyLimit(type: UInt8) -> Int {
    switch type {
    case 2: return DocumentProtocol.maxArchiveBytes + 64
    case 3: return DocumentProtocol.maxImagePixels * DocumentProtocol.bytesPerPixel + 64
    default: return DocumentProtocol.maxControlBody
    }
  }

  public static func decode(type: UInt8, body: Data) throws -> DocumentHelperMessage {
    var reader = ByteReader(body)

    switch type {
    case 1:
      let version = try reader.u16()
      try reader.finished()

      return .hello(version: version)

    case 2:
      let request = try reader.u32()
      let count = try reader.u16()

      return .archive(request: request, imageCount: count, bytes: reader.rest())

    case 3:
      let request = try reader.u32()
      let index = try reader.u16()
      let width = try reader.u32()
      let height = try reader.u32()

      return .image(
        request: request, index: index, width: width, height: height, pixels: reader.rest())

    case 4:
      let request = try reader.u32()
      try reader.finished()

      return .done(request: request)

    case 5:
      let request = try reader.u32()

      guard let kind = DocumentFailureKind(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown failure kind")
      }

      let text = try reader.string(limit: DocumentProtocol.maxMessageBytes)
      try reader.finished()

      return .failure(request: request, kind: kind, text: text)

    case 6:
      let nonce = try reader.u32()
      try reader.finished()

      return .pong(nonce: nonce)

    default:
      throw WireError.unknownType(type)
    }
  }

  /// What the app checks of the helper's hello.
  public static func validateHello(_ message: DocumentHelperMessage) throws {
    guard case .hello(let version) = message else {
      throw WireError.badValue("the helper did not start with a hello")
    }

    guard version == DocumentProtocol.version else {
      throw WireError.versionMismatch(found: version, expected: DocumentProtocol.version)
    }
  }
}
