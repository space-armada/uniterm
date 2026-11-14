import Foundation

/// An image the helper rasterized: raw pixels in the protocol's one fixed format.
public struct RawImage: Equatable, Sendable {
  public var width: Int
  public var height: Int
  public var pixels: Data

  public init(width: Int, height: Int, pixels: Data) {
    self.width = width
    self.height = height
    self.pixels = pixels
  }
}

/// What the app agrees to hold of one reply. The app applies these itself and relies on no check in
/// the helper.
public struct DocumentReplyLimits: Equatable, Sendable {
  public var maxArchiveBytes: Int
  public var maxImages: Int
  public var maxImagePixels: Int
  public var maxTotalPixels: Int

  public init(maxArchiveBytes: Int, maxImages: Int, maxImagePixels: Int, maxTotalPixels: Int) {
    self.maxArchiveBytes = maxArchiveBytes
    self.maxImages = maxImages
    self.maxImagePixels = maxImagePixels
    self.maxTotalPixels = maxTotalPixels
  }
}

/// A whole reply: the archive and the images that go with it.
public struct DocumentReply: Equatable, Sendable {
  public var archive: Data
  public var images: [RawImage]

  public init(archive: Data, images: [RawImage]) {
    self.archive = archive
    self.images = images
  }
}

/// Checks the helper's messages against the one request in flight and assembles the reply.
///
/// The archive comes first, naming how many images follow. Each image arrives in order, with pixels
/// that match its own dimensions. The last message is `done`. Anything else is a violation, and the
/// caller ends the helper.
public struct DocumentReplyAssembler: Sendable {
  public enum Step: Equatable, Sendable {
    case pending
    case complete(DocumentReply)
    case failed(DocumentFailureKind, String)
  }

  private let request: UInt32
  private let limits: DocumentReplyLimits
  private var archive: Data?
  private var expectedImages = 0
  private var images: [RawImage] = []
  private var totalPixels = 0

  public init(request: UInt32, limits: DocumentReplyLimits) {
    self.request = request
    self.limits = limits
  }

  public mutating func accept(_ message: DocumentHelperMessage) throws -> Step {
    switch message {
    case .archive(let id, let count, let bytes):
      try expect(id)

      guard archive == nil else { throw WireError.badValue("a second archive") }

      guard bytes.count <= limits.maxArchiveBytes else {
        throw WireError.tooLong(declared: bytes.count, limit: limits.maxArchiveBytes)
      }

      guard Int(count) <= limits.maxImages else {
        throw WireError.tooLong(declared: Int(count), limit: limits.maxImages)
      }

      archive = bytes
      expectedImages = Int(count)

      return .pending

    case .image(let id, let index, let width, let height, let pixels):
      try expect(id)

      guard archive != nil else { throw WireError.badValue("an image before the archive") }

      guard Int(index) == images.count, images.count < expectedImages else {
        throw WireError.badValue("an image out of order")
      }

      let (area, overflow) = Int(width).multipliedReportingOverflow(by: Int(height))

      guard !overflow, width > 0, height > 0, area <= limits.maxImagePixels else {
        throw WireError.badValue("an image has impossible dimensions")
      }

      guard totalPixels + area <= limits.maxTotalPixels else {
        throw WireError.badValue("the images are past the size the app agreed to hold")
      }

      guard pixels.count == area * DocumentProtocol.bytesPerPixel else {
        throw WireError.badValue("an image's pixels do not match its dimensions")
      }

      totalPixels += area
      images.append(RawImage(width: Int(width), height: Int(height), pixels: pixels))

      return .pending

    case .done(let id):
      try expect(id)

      guard let archive, images.count == expectedImages else {
        throw WireError.badValue("a reply ended before its images")
      }

      return .complete(DocumentReply(archive: archive, images: images))

    case .failure(let id, let kind, let text):
      try expect(id)

      return .failed(kind, text)

    case .hello, .pong:
      throw WireError.badValue("a message nobody asked for")
    }
  }

  private func expect(_ id: UInt32) throws {
    guard id == request else { throw WireError.badValue("a reply answers a different request") }
  }
}
