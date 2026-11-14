import Foundation
import XCTest

@testable import DocumentWire

final class DocumentReplyTests: XCTestCase {
  private let limits = DocumentReplyLimits(
    maxArchiveBytes: 100, maxImages: 2, maxImagePixels: 16, maxTotalPixels: 24)

  private func pixels(_ count: Int) -> Data {
    Data(repeating: 1, count: count * DocumentProtocol.bytesPerPixel)
  }

  private func assembler() -> DocumentReplyAssembler {
    DocumentReplyAssembler(request: 5, limits: limits)
  }

  /// Catches a reply the app drops, or one it assembles out of order.
  func testAWholeReplyAssembles() throws {
    var assembler = assembler()

    XCTAssertEqual(
      try assembler.accept(.archive(request: 5, imageCount: 1, bytes: Data([1]))), .pending)
    XCTAssertEqual(
      try assembler.accept(.image(request: 5, index: 0, width: 2, height: 2, pixels: pixels(4))),
      .pending)

    let step = try assembler.accept(.done(request: 5))

    XCTAssertEqual(
      step,
      .complete(
        DocumentReply(
          archive: Data([1]), images: [RawImage(width: 2, height: 2, pixels: pixels(4))])))
  }

  /// Catches each way a helper can lie about the reply. The app relies on no check in the helper.
  func testEveryViolationIsRefused() throws {
    func refused(_ messages: [DocumentHelperMessage], _ note: String) {
      var assembler = assembler()

      do {
        for message in messages { _ = try assembler.accept(message) }
        XCTFail("accepted: \(note)")
      } catch {}
    }

    let archive = DocumentHelperMessage.archive(request: 5, imageCount: 1, bytes: Data([1]))

    refused([.archive(request: 6, imageCount: 0, bytes: Data())], "another request")
    refused([.archive(request: 5, imageCount: 3, bytes: Data())], "too many images")
    refused([.archive(request: 5, imageCount: 0, bytes: Data(count: 101))], "a big archive")
    refused([archive, archive], "two archives")
    refused([.image(request: 5, index: 0, width: 1, height: 1, pixels: pixels(1))], "no archive")
    refused(
      [archive, .image(request: 5, index: 1, width: 1, height: 1, pixels: pixels(1))], "order")
    refused(
      [archive, .image(request: 5, index: 0, width: 1, height: 1, pixels: pixels(2))], "size")
    refused([archive, .image(request: 5, index: 0, width: 0, height: 1, pixels: Data())], "empty")
    refused(
      [archive, .image(request: 5, index: 0, width: 5, height: 5, pixels: pixels(25))],
      "past the per-image cap")
    refused(
      [
        .archive(request: 5, imageCount: 2, bytes: Data()),
        .image(request: 5, index: 0, width: 4, height: 4, pixels: pixels(16)),
        .image(request: 5, index: 1, width: 3, height: 3, pixels: pixels(9)),
      ], "past the total")
    refused([archive, .done(request: 5)], "done before its images")
    refused([.done(request: 5)], "done with no archive")
    refused([.pong(nonce: 1)], "a pong nobody asked for")
    refused([.hello(version: 1)], "a second hello")
  }

  func testAFailureEndsTheReplyWithTheHelpersWords() throws {
    var assembler = assembler()

    XCTAssertEqual(
      try assembler.accept(.failure(request: 5, kind: .unreadable, text: "No.")),
      .failed(.unreadable, "No."))
  }
}
