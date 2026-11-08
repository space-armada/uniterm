import AppKit
import DocumentTestSupport
import DocumentWire
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

final class DocumentReplyDecoderTests: XCTestCase {
  private func failure(
    _ reply: DocumentReply, limits: TextViewerLimits = .standard
  ) -> DocumentReplyError? {
    if case .failure(let error) = DocumentReplyDecoder.decodeBlocking(reply, limits: limits) {
      return error
    }

    return nil
  }

  private func archive(_ text: NSAttributedString) throws -> Data {
    try NSKeyedArchiver.archivedData(withRootObject: text, requiringSecureCoding: true)
  }

  private func pixels(_ width: Int, _ height: Int) -> RawImage {
    RawImage(
      width: width, height: height,
      pixels: Data(repeating: 255, count: width * height * DocumentProtocol.bytesPerPixel))
  }

  /// Catches an archive that makes the app build an image through a codec. An attachment that
  /// carries an `NSImage` or a file wrapper is refused, since neither class is allowed.
  func testAnArchiveCarryingAnImageOrAFileWrapperIsRefused() throws {
    let withImage = NSTextAttachment()
    withImage.image = DocumentFixtures.redImage(width: 4, height: 4)

    let wrapped = NSTextAttachment(
      fileWrapper: FileWrapper(regularFileWithContents: Data([1, 2, 3])))

    for attachment in [withImage, wrapped] {
      let reply = DocumentReply(
        archive: try archive(NSAttributedString(attachment: attachment)), images: [])
      let result = DocumentReplyDecoder.decodeBlocking(reply, limits: .standard)

      if case .success = result { XCTFail("an archive with an image object was accepted") }
    }
  }

  func testGarbageInsteadOfAnArchiveIsRefused() {
    let reply = DocumentReply(archive: Data("not an archive".utf8), images: [])

    XCTAssertEqual(failure(reply), .misbehaved("the archive is not a document"))
  }

  /// Catches an archive of a class the app does not expect, such as a plain string.
  func testAnArchiveOfAnotherClassIsRefused() throws {
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: "text" as NSString, requiringSecureCoding: true)

    if case .success = DocumentReplyDecoder.decodeBlocking(
      DocumentReply(archive: data, images: []), limits: .standard)
    {
      XCTFail("a string was taken for a document")
    }
  }

  /// Catches a placeholder that gets no image, and an image with no placeholder.
  func testImagesMustMatchPlaceholdersOneToOne() throws {
    let placeholder = NSTextAttachment()
    placeholder.bounds = CGRect(x: 0, y: 0, width: 4, height: 2)

    let text = NSMutableAttributedString(string: "a")
    text.append(NSAttributedString(attachment: placeholder))
    let data = try archive(text)

    XCTAssertNotNil(
      try? DocumentReplyDecoder.decodeBlocking(
        DocumentReply(archive: data, images: [pixels(4, 2)]), limits: .standard
      ).get())

    for images in [[], [pixels(4, 2), pixels(4, 2)]] {
      if case .success = DocumentReplyDecoder.decodeBlocking(
        DocumentReply(archive: data, images: images), limits: .standard)
      {
        XCTFail("\(images.count) images matched one placeholder")
      }
    }
  }

  /// Catches an image that is not built from the helper's pixels, with the right size.
  func testAnImageIsBuiltFromRawPixelsWithNoCodec() throws {
    let placeholder = NSTextAttachment()
    let text = NSMutableAttributedString(string: "a")
    text.append(NSAttributedString(attachment: placeholder))

    let decoded = try DocumentReplyDecoder.decodeBlocking(
      DocumentReply(archive: try archive(text), images: [pixels(6, 3)]), limits: .standard
    ).get()

    let attachment =
      decoded.text.attribute(.attachment, at: 1, effectiveRange: nil)
      as? NSTextAttachment

    XCTAssertEqual(attachment?.image?.size, NSSize(width: 6, height: 3))
    XCTAssertEqual(attachment?.bounds.size, CGSize(width: 6, height: 3))
  }

  /// Catches a cap the app leaves to the helper. The decoded length, table cell, and image count
  /// caps are applied here, off the main thread.
  func testTheAppAppliesEveryDecodedCapItself() throws {
    var limits = TextViewerLimits.standard
    limits.maxDecodedLength = 10
    limits.maxImages = 1

    let long = DocumentReply(
      archive: try archive(NSAttributedString(string: "0123456789ABC")), images: [])

    XCTAssertEqual(failure(long, limits: limits), .overCap(.length(limit: 10)))

    let text = NSMutableAttributedString()

    for _ in 0..<2 {
      text.append(NSAttributedString(attachment: NSTextAttachment()))
    }

    XCTAssertEqual(
      failure(
        DocumentReply(archive: try archive(text), images: [pixels(1, 1), pixels(1, 1)]),
        limits: limits),
      .overCap(.images(limit: 1)))
  }

  func testTableCellsAreCountedOncePerCell() throws {
    let table = NSTextTable()
    table.numberOfColumns = 2

    let text = NSMutableAttributedString()

    for (row, column) in [(0, 0), (0, 1), (1, 0)] {
      let block = NSTextTableBlock(
        table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
      let style = NSMutableParagraphStyle()
      style.textBlocks = [block]

      text.append(NSAttributedString(string: "cell\n", attributes: [.paragraphStyle: style]))
    }

    let measured = DocumentReplyDecoder.measure(text)

    XCTAssertEqual(measured.tableCells, 3)
    XCTAssertEqual(measured.attachments, 0)

    var limits = TextViewerLimits.standard
    limits.maxTableCells = 2

    XCTAssertEqual(
      failure(DocumentReply(archive: try archive(text), images: []), limits: limits),
      .overCap(.tableCells(limit: 2)))
  }
}

extension DocumentReplyError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .misbehaved(let text): return "misbehaved(\(text))"
    case .overCap(let cap): return "overCap(\(cap))"
    }
  }
}
