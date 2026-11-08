import AppKit
import Darwin
import DocumentTestSupport
import XCTest

@testable import DocumentDecoding
@testable import DocumentWire

/// Runs the helper's server on a socketpair in this process, so the protocol is proved without a
/// process. A helper that crashes or hangs is proved against a real process in the applet's tests.
final class DocumentHelperServerTests: XCTestCase {
  private var folder: URL!
  private var app: FramedSocket!
  private var finished: DispatchSemaphore!
  private var status = Int32(-1)

  override func setUpWithError() throws {
    folder = try DocumentFixtures.makeFolder()

    let (appEnd, helperEnd) = try FramedSocket.pair()
    let server = DocumentHelperServer(socket: helperEnd)

    app = appEnd
    finished = DispatchSemaphore(value: 0)

    Thread.detachNewThread { [self] in
      status = server.run()
      finished.signal()
    }
  }

  override func tearDownWithError() throws {
    app.shutdownAndClose()
    _ = finished.wait(timeout: .now() + 5)
    try? FileManager.default.removeItem(at: folder)
  }

  private func read() throws -> DocumentHelperMessage {
    let frame = try app.readFrame { DocumentHelperMessage.bodyLimit(type: $0) }

    return try DocumentHelperMessage.decode(type: frame.type, body: frame.body)
  }

  private func decode(_ data: Data, named name: String, kind: DocumentKind) throws -> DocumentReply
  {
    let url = try DocumentFixtures.write(data, named: name, in: folder)
    let descriptor = open(url.path, O_RDONLY)

    defer { close(descriptor) }

    try app.send(
      DocumentAppMessage.decode(request: 1, kind: kind).frame(), descriptor: descriptor)

    var assembler = DocumentReplyAssembler(
      request: 1,
      limits: DocumentReplyLimits(
        maxArchiveBytes: 1 << 24, maxImages: 8, maxImagePixels: 1 << 20, maxTotalPixels: 1 << 22))

    while true {
      switch try assembler.accept(try read()) {
      case .pending: continue
      case .complete(let reply): return reply
      case .failed(_, let text): throw WireError.badValue(text)
      }
    }
  }

  private func text(of reply: DocumentReply) throws -> NSAttributedString {
    try XCTUnwrap(
      try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [
          NSAttributedString.self, NSParagraphStyle.self, NSFont.self, NSColor.self,
          NSDictionary.self, NSString.self, NSTextTab.self, NSTextAttachment.self,
          NSTextTable.self, NSTextTableBlock.self, NSTextBlock.self, NSURL.self, NSNumber.self,
          NSArray.self, NSData.self, NSFontDescriptor.self, NSColorSpace.self, NSValue.self,
          NSCharacterSet.self, NSTextList.self,
        ], from: reply.archive) as? NSAttributedString)
  }

  /// Catches a helper that does not start with a hello of this protocol's version.
  func testTheHelperSaysHelloFirst() throws {
    XCTAssertEqual(try read(), .hello(version: DocumentProtocol.version))
  }

  /// Catches a ping that waits behind a decode, which would make a slow decode look like a hang.
  func testAPingIsAnsweredAtOnce() throws {
    _ = try read()

    try app.send(DocumentAppMessage.ping(nonce: 42).frame())

    XCTAssertEqual(try read(), .pong(nonce: 42))
  }

  /// Catches a reader that is wired to the wrong document type, for each of the three.
  func testRTFWordAndDocxAllDecodeToTheirText() throws {
    _ = try read()

    let cases: [(String, Data, DocumentKind)] = [
      ("a.rtf", try DocumentFixtures.rtf(body: "alpha text"), .rtf),
      ("a.doc", try DocumentFixtures.doc(body: "alpha text"), .word97),
      ("a.docx", try DocumentFixtures.docx(body: "alpha text"), .wordXML),
    ]

    for (name, data, kind) in cases {
      let reply = try decode(data, named: name, kind: kind)

      XCTAssertTrue(try text(of: reply).string.contains("alpha text"), name)
    }
  }

  /// Catches HTML read as a document. The same bytes under the RTF reader are refused, not parsed.
  func testHTMLBytesAreNotReadAsHTML() throws {
    _ = try read()

    let html = Data("<html><body><b>bold</b> text</body></html>".utf8)

    do {
      let reply = try decode(html, named: "a.rtf", kind: .rtf)
      let result = try text(of: reply).string

      XCTAssertFalse(result.contains("<b>"), "the reader treated markup as text it understands")
      XCTAssertNotEqual(result, "bold text")
    } catch {}
  }

  /// Catches a heading level lost on the way through a real reader.
  func testAWordHeadingKeepsItsLevelWhereTheReaderSetsOne() throws {
    _ = try read()

    let data = try DocumentFixtures.rtf(body: "Body", heading: "Title")
    let string = try text(of: try decode(data, named: "h.rtf", kind: .rtf))
    let style = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

    XCTAssertNotNil(style)
  }

  /// Catches a picture that leaves the archive and its pixels out of step, whatever the system
  /// reader makes of it. On the macOS this was written on, the RTF, Word 97, and Word XML readers
  /// return no attachment for a picture, so the count is zero. The sanitizer's own tests prove the
  /// pixel path with an attachment the reader would have made.
  func testAPictureNeverLeavesTheArchiveAndItsPixelsOutOfStep() throws {
    _ = try read()

    let reply = try decode(
      DocumentFixtures.docxWithImage(width: 12, height: 6), named: "i.docx", kind: .wordXML)
    let string = try text(of: reply)

    var placeholders = 0

    string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) {
      value, range, _ in
      if let attachment = value as? NSTextAttachment {
        placeholders += range.length

        XCTAssertNil(attachment.image)
        XCTAssertNil(attachment.fileWrapper)
      }
    }

    XCTAssertEqual(placeholders, reply.images.count)

    for image in reply.images {
      XCTAssertEqual(image.pixels.count, image.width * image.height * 4)
    }
  }

  /// Catches a request with no descriptor that is answered with a crash or silence.
  func testARequestWithoutAFileFails() throws {
    _ = try read()

    try app.send(DocumentAppMessage.decode(request: 1, kind: .rtf).frame())

    XCTAssertEqual(
      try read(),
      .failure(request: 1, kind: .noSource, text: "No file came with the request."))
  }

  /// Catches a descriptor the helper trusts without looking, such as a folder.
  func testAFolderIsNotARegularFile() throws {
    _ = try read()

    let descriptor = open(folder.path, O_RDONLY)

    defer { close(descriptor) }

    try app.send(
      DocumentAppMessage.decode(request: 1, kind: .rtf).frame(), descriptor: descriptor)

    guard case .failure(_, let kind, _) = try read() else { return XCTFail("expected a failure") }

    XCTAssertEqual(kind, .unreadable)
  }

  /// Catches a damaged file that crashes the reader's thread instead of failing.
  func testGarbageFailsWithoutEndingTheHelper() throws {
    _ = try read()

    XCTAssertThrowsError(
      try decode(Data("not a document at all".utf8), named: "bad.docx", kind: .wordXML))

    try app.send(DocumentAppMessage.ping(nonce: 1).frame())

    XCTAssertEqual(try read(), .pong(nonce: 1))
  }

  /// Catches a helper that accepts a hello of another version.
  func testAHelloOfAnotherVersionEndsTheHelper() throws {
    _ = try read()

    try app.send(DocumentAppMessage.hello(version: DocumentProtocol.version + 1).frame())

    XCTAssertTrue(finished.wait(timeout: .now() + 5) == .success)
    XCTAssertEqual(status, 4)

    finished.signal()
  }
}
