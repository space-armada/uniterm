import Foundation
@_exported import HelperWire

/// What the protocol version means for both sides. A mismatch is refused before any image moves.
public enum ImageProtocol {
  public static let version: UInt16 = 2

  /// The descriptor the helper finds its end of the socketpair on.
  public static let socketDescriptor: Int32 = HelperChannel.socketDescriptor

  /// What the pane tells the user when the two sides disagree.
  public static let mismatchText =
    "The image decoder and uniterm come from different versions. Relaunch uniterm."

  /// How many opened sources a helper keeps. Opening one past the limit drops the one decoded from
  /// longest ago. A pane holds the image on screen, the one it left, and the next one, so a source
  /// it still needs is not dropped. A decode of a dropped source reports a stale source.
  public static let retainedSources = 4

  /// The largest body a message other than an image may carry.
  public static let maxControlBody = 256 * 1024
}

/// Why a decode did not produce an image.
public enum FailureKind: UInt8, Sendable, Equatable {
  /// ImageIO has no decoder for the file. The text names the format.
  case unsupportedFormat = 1

  /// The file is damaged or cannot be decoded.
  case unreadable = 2

  /// The image is past a limit the helper keeps, such as its memory cap.
  case limit = 3

  /// The request named a source the helper no longer holds.
  case staleSource = 4

  /// The helper has no descriptor for the request.
  case noSource = 5
}

/// A request from the app. Each case is one framed message.
public enum AppMessage: Equatable, Sendable {
  case hello(version: UInt16)

  /// A new source. The file's descriptor travels beside this message in the same send.
  case open(source: UInt32)

  /// Decode `frame` of `source` so the longer side is at most `maxPixel` pixels. A value of zero
  /// asks for the native size.
  case decode(request: UInt32, source: UInt32, maxPixel: UInt32, frame: UInt32)

  case ping(nonce: UInt32)

  /// A rectangle of the decode whose longer side is `level` pixels, in that decode's own pixels
  /// counted from the top left. The helper keeps the decode of the last level asked for, so the
  /// next rectangle of the same level costs a copy and not a decode.
  case region(
    request: UInt32, source: UInt32, level: UInt32, x: UInt32, y: UInt32, width: UInt32,
    height: UInt32)

  /// Drops the decode a region request left in memory for `source`.
  case release(source: UInt32)

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .open: return 2
    case .decode: return 3
    case .ping: return 4
    case .region: return 5
    case .release: return 6
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)
    case .open(let source): body.put(source)

    case .decode(let request, let source, let maxPixel, let frame):
      body.put(request)
      body.put(source)
      body.put(maxPixel)
      body.put(frame)

    case .ping(let nonce): body.put(nonce)

    case .region(let request, let source, let level, let x, let y, let width, let height):
      body.put(request)
      body.put(source)
      body.put(level)
      body.put(x)
      body.put(y)
      body.put(width)
      body.put(height)

    case .release(let source): body.put(source)
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  public static func decode(type: UInt8, body: Data) throws -> AppMessage {
    var reader = ByteReader(body)

    let message: AppMessage

    switch type {
    case 1: message = .hello(version: try reader.u16())
    case 2: message = .open(source: try reader.u32())

    case 3:
      message = .decode(
        request: try reader.u32(), source: try reader.u32(), maxPixel: try reader.u32(),
        frame: try reader.u32())

    case 4: message = .ping(nonce: try reader.u32())

    case 5:
      message = .region(
        request: try reader.u32(), source: try reader.u32(), level: try reader.u32(),
        x: try reader.u32(), y: try reader.u32(), width: try reader.u32(),
        height: try reader.u32())

    case 6: message = .release(source: try reader.u32())
    default: throw WireError.unknownType(type)
    }

    try reader.finished()

    return message
  }
}

/// What a decoded image's header says. The pixels follow it in the same message.
public struct ImageHeader: Equatable, Sendable {
  public var request: UInt32
  public var source: UInt32
  public var frame: UInt32
  public var width: UInt32
  public var height: UInt32
  public var space: OutputSpace
  public var format: PixelFormat

  public init(
    request: UInt32, source: UInt32, frame: UInt32, width: UInt32, height: UInt32,
    space: OutputSpace, format: PixelFormat
  ) {
    self.request = request
    self.source = source
    self.frame = frame
    self.width = width
    self.height = height
    self.space = space
    self.format = format
  }
}

/// What the helper knows about a source it opened.
public struct SourceInfo: Equatable, Sendable {
  public var source: UInt32

  /// The size in pixels after the EXIF orientation applies.
  public var width: UInt32
  public var height: UInt32

  /// Milliseconds each frame shows. One entry for a still image, which is never played.
  public var frameDelays: [UInt32]

  /// The resolution the file declares, in dots per inch after the orientation applies. Zero means
  /// the file declares none.
  public var dpiX: UInt16
  public var dpiY: UInt16

  public init(
    source: UInt32, width: UInt32, height: UInt32, frameDelays: [UInt32], dpiX: UInt16 = 0,
    dpiY: UInt16 = 0
  ) {
    self.source = source
    self.width = width
    self.height = height
    self.frameDelays = frameDelays
    self.dpiX = dpiX
    self.dpiY = dpiY
  }

  public var frameCount: Int { frameDelays.count }
}

/// A message from the helper. The app validates each one and trusts none of them.
public enum HelperMessage: Equatable, Sendable {
  case hello(version: UInt16, types: [String])
  case opened(SourceInfo)

  /// The pixels are exactly `width * height * format.bytesPerPixel` bytes. The app checks that
  /// against its own count before it keeps them.
  case image(ImageHeader, pixels: Data)
  case failure(request: UInt32, kind: FailureKind, text: String)
  case pong(nonce: UInt32)

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .opened: return 2
    case .image: return 3
    case .failure: return 4
    case .pong: return 5
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version, let types):
      body.put(version)
      body.put(UInt16(min(types.count, ImageLimits.maxTypes)))

      for type in types.prefix(ImageLimits.maxTypes) {
        body.put(string: type, limit: ImageLimits.maxTypeBytes)
      }

    case .opened(let info):
      body.put(info.source)
      body.put(info.width)
      body.put(info.height)
      body.put(info.dpiX)
      body.put(info.dpiY)
      body.put(UInt16(min(info.frameDelays.count, ImageLimits.maxFrames)))

      for delay in info.frameDelays.prefix(ImageLimits.maxFrames) {
        body.put(delay)
      }

    case .image(let header, let pixels):
      body.put(header.request)
      body.put(header.source)
      body.put(header.frame)
      body.put(header.width)
      body.put(header.height)
      body.put(header.space.rawValue)
      body.put(header.format.rawValue)
      body.put(raw: pixels)

    case .failure(let request, let kind, let text):
      body.put(request)
      body.put(kind.rawValue)
      body.put(string: text, limit: ImageLimits.maxMessageBytes)

    case .pong(let nonce):
      body.put(nonce)
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  /// An image reply as a prefix and its pixels, for a sender that writes them without joining them.
  /// The prefix holds the frame header and the image header, and the frame's length covers both
  /// parts.
  public static func imageParts(_ header: ImageHeader, pixels: Data) -> (prefix: Data, pixels: Data)
  {
    var fields = ByteWriter()
    fields.put(header.request)
    fields.put(header.source)
    fields.put(header.frame)
    fields.put(header.width)
    fields.put(header.height)
    fields.put(header.space.rawValue)
    fields.put(header.format.rawValue)

    let length = UInt32(truncatingIfNeeded: fields.bytes.count + pixels.count)
    var lengthField = ByteWriter()
    lengthField.put(length)

    var prefix = Data([3])
    prefix.append(lengthField.bytes)
    prefix.append(fields.bytes)

    return (prefix, pixels)
  }

  /// The most body bytes a message of `type` may declare. An image may carry up to
  /// `maxImageBytes`. The reader checks this before it allocates the body.
  public static func bodyLimit(type: UInt8, maxImageBytes: Int) -> Int {
    type == 3 ? maxImageBytes + 64 : ImageProtocol.maxControlBody
  }

  public static func decode(type: UInt8, body: Data) throws -> HelperMessage {
    var reader = ByteReader(body)

    switch type {
    case 1:
      let version = try reader.u16()
      let count = Int(try reader.u16())

      guard count <= ImageLimits.maxTypes else {
        throw WireError.tooLong(declared: count, limit: ImageLimits.maxTypes)
      }

      var types: [String] = []

      for _ in 0..<count {
        types.append(try reader.string(limit: ImageLimits.maxTypeBytes))
      }

      try reader.finished()

      return .hello(version: version, types: types)

    case 2:
      let source = try reader.u32()
      let width = try reader.u32()
      let height = try reader.u32()
      let dpiX = try reader.u16()
      let dpiY = try reader.u16()
      let count = Int(try reader.u16())

      guard count >= 1, count <= ImageLimits.maxFrames else {
        throw WireError.badValue("a source declares \(count) frames")
      }

      var delays: [UInt32] = []

      for _ in 0..<count {
        delays.append(try reader.u32())
      }

      try reader.finished()

      return .opened(
        SourceInfo(
          source: source, width: width, height: height, frameDelays: delays, dpiX: dpiX,
          dpiY: dpiY))

    case 3:
      let request = try reader.u32()
      let source = try reader.u32()
      let frame = try reader.u32()
      let width = try reader.u32()
      let height = try reader.u32()

      guard let space = OutputSpace(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown color space")
      }

      guard let format = PixelFormat(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown pixel format")
      }

      return .image(
        ImageHeader(
          request: request, source: source, frame: frame, width: width, height: height,
          space: space, format: format),
        pixels: reader.rest())

    case 4:
      let request = try reader.u32()

      guard let kind = FailureKind(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown failure kind")
      }

      let text = try reader.string(limit: ImageLimits.maxMessageBytes)
      try reader.finished()

      return .failure(request: request, kind: kind, text: text)

    case 5:
      let nonce = try reader.u32()
      try reader.finished()

      return .pong(nonce: nonce)

    default:
      throw WireError.unknownType(type)
    }
  }
}

/// What the app expects of an image it asked for. The helper's header and pixels must match it.
public struct ImageExpectation: Equatable, Sendable {
  public var request: UInt32
  public var source: UInt32
  public var frame: UInt32

  /// The longer side the app asked for, or zero for the native size.
  public var maxPixel: Int

  /// The source's size, which bounds a native-size decode.
  public var sourceWidth: Int
  public var sourceHeight: Int

  /// The most bytes the app agrees to hold for this image.
  public var byteCap: Int

  /// The size of the rectangle asked for, when the request was a region. The app clips the
  /// rectangle to the level before it asks, so the reply must match it exactly.
  public var region: (width: Int, height: Int)?

  public init(
    request: UInt32, source: UInt32, frame: UInt32, maxPixel: Int, sourceWidth: Int,
    sourceHeight: Int, byteCap: Int, region: (width: Int, height: Int)? = nil
  ) {
    self.request = request
    self.source = source
    self.frame = frame
    self.maxPixel = maxPixel
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    self.byteCap = byteCap
    self.region = region
  }

  public static func == (lhs: ImageExpectation, rhs: ImageExpectation) -> Bool {
    lhs.request == rhs.request && lhs.source == rhs.source && lhs.frame == rhs.frame
      && lhs.maxPixel == rhs.maxPixel && lhs.sourceWidth == rhs.sourceWidth
      && lhs.sourceHeight == rhs.sourceHeight && lhs.byteCap == rhs.byteCap
      && lhs.region?.width == rhs.region?.width && lhs.region?.height == rhs.region?.height
  }

  /// Checks a helper's image against what was asked. The byte count comes from the checked
  /// dimensions, never from the helper, and the pixels must match it exactly.
  public func validate(_ header: ImageHeader, pixels: Data) throws {
    guard header.request == request, header.source == source, header.frame == frame else {
      throw WireError.badValue("an image answers a different request")
    }

    guard header.space.format == header.format else {
      throw WireError.badValue("a pixel format does not suit its color space")
    }

    let width = Int(header.width)
    let height = Int(header.height)

    guard let expected = ImageLimits.byteCount(width: width, height: height, format: header.format)
    else {
      throw WireError.badValue("an image has impossible dimensions")
    }

    if let region {
      guard width == region.width, height == region.height else {
        throw WireError.badValue("a region is not the size that was asked for")
      }
    } else {
      let bound = maxPixel > 0 ? maxPixel : max(sourceWidth, sourceHeight)

      guard max(width, height) <= max(bound, 1), width <= sourceWidth, height <= sourceHeight
      else {
        throw WireError.badValue("an image is larger than was asked for")
      }
    }

    guard expected <= byteCap else {
      throw WireError.badValue("an image is past the size the app agreed to hold")
    }

    guard pixels.count == expected else {
      throw WireError.badValue("an image's pixels do not match its dimensions")
    }
  }
}

/// What the app checks of the helper's hello.
public enum HelperHandshake {
  public static func validate(_ message: HelperMessage) throws -> [String] {
    guard case .hello(let version, let types) = message else {
      throw WireError.badValue("the helper did not start with a hello")
    }

    guard version == ImageProtocol.version else {
      throw WireError.versionMismatch(found: version, expected: ImageProtocol.version)
    }

    return types
  }
}
