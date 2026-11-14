import Foundation
import XCTest

@testable import DocumentWire

final class DocumentCodecTests: XCTestCase {
  private func decode<T>(_ frame: Data, _ using: (UInt8, Data) throws -> T) throws -> T {
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    return try using(type, frame.dropFirst(FrameHeader.size).prefix(length))
  }

  /// Catches a message that does not survive its own codec.
  func testEveryMessageRoundTrips() throws {
    let app: [DocumentAppMessage] = [
      .hello(version: 1), .decode(request: 7, kind: .wordXML), .ping(nonce: 3),
    ]

    for message in app {
      XCTAssertEqual(try decode(message.frame(), DocumentAppMessage.decode), message)
    }

    let helper: [DocumentHelperMessage] = [
      .hello(version: 1), .archive(request: 7, imageCount: 2, bytes: Data([1, 2, 3])),
      .image(request: 7, index: 1, width: 2, height: 1, pixels: Data(repeating: 9, count: 8)),
      .done(request: 7), .failure(request: 7, kind: .limit, text: "Too much."), .pong(nonce: 3),
    ]

    for message in helper {
      XCTAssertEqual(try decode(message.frame(), DocumentHelperMessage.decode), message)
    }
  }

  /// Catches a split send whose frame length does not cover both parts.
  func testASplitSendMakesTheSameFrameAsAJoinedOne() throws {
    let message = DocumentHelperMessage.image(
      request: 1, index: 0, width: 1, height: 1, pixels: Data([1, 2, 3, 4]))
    let parts = try XCTUnwrap(message.parts())

    XCTAssertEqual(parts.prefix + parts.trailer, message.frame())
  }

  /// Catches a body limit that lets a small message declare an archive-sized body.
  func testOnlyTheArchiveAndImagesMayBeBig() {
    XCTAssertEqual(DocumentHelperMessage.bodyLimit(type: 1), DocumentProtocol.maxControlBody)
    XCTAssertEqual(DocumentHelperMessage.bodyLimit(type: 6), DocumentProtocol.maxControlBody)
    XCTAssertGreaterThan(DocumentHelperMessage.bodyLimit(type: 2), DocumentProtocol.maxArchiveBytes)
    XCTAssertGreaterThan(
      DocumentHelperMessage.bodyLimit(type: 3),
      DocumentProtocol.maxImagePixels * DocumentProtocol.bytesPerPixel)
  }

  func testAnUnknownTypeAndATrailingByteAreRefused() {
    XCTAssertThrowsError(try DocumentHelperMessage.decode(type: 99, body: Data()))
    XCTAssertThrowsError(try DocumentHelperMessage.decode(type: 4, body: Data([0, 0, 0, 1, 9])))
    XCTAssertThrowsError(try DocumentAppMessage.decode(type: 2, body: Data([0, 0, 0, 1, 77])))
  }

  func testAHelloOfAnotherVersionIsRefused() {
    XCTAssertThrowsError(
      try DocumentHelperMessage.validateHello(.hello(version: DocumentProtocol.version + 1)))
    XCTAssertThrowsError(try DocumentHelperMessage.validateHello(.done(request: 1)))
    XCTAssertNoThrow(
      try DocumentHelperMessage.validateHello(.hello(version: DocumentProtocol.version)))
  }
}
