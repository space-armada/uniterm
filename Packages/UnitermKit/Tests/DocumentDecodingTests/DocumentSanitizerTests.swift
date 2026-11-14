import AppKit
import DocumentTestSupport
import XCTest

@testable import DocumentDecoding
@testable import DocumentWire

final class DocumentSanitizerTests: XCTestCase {
  /// Catches an attribute that survives the helper without being on the allowlist. A tool tip and
  /// a cursor are not drawn by the viewer, and the app should never decode them.
  func testAttributesOffTheAllowlistAreDropped() {
    let source = NSAttributedString(
      string: "text",
      attributes: [
        .toolTip: "hover", .cursor: NSCursor.pointingHand, .font: NSFont.systemFont(ofSize: 12),
      ])

    let result = DocumentSanitizer.sanitize(source)
    let attributes = result.string.attributes(at: 0, effectiveRange: nil)

    XCTAssertNil(attributes[.toolTip])
    XCTAssertNil(attributes[.cursor])
    XCTAssertNotNil(attributes[.font])
    XCTAssertEqual(result.string.string, "text")
  }

  /// Catches a heading level lost in the helper, which the contents sidebar of a later milestone
  /// reads.
  func testTheHeaderLevelSurvivesTheArchive() throws {
    let source = DocumentFixtures.attributed(heading: "Title", body: "Body", headerLevel: 2)
    let result = DocumentSanitizer.sanitize(source)
    let archive = try NSKeyedArchiver.archivedData(
      withRootObject: result.string, requiringSecureCoding: true)

    let back = try XCTUnwrap(
      try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [
          NSAttributedString.self, NSParagraphStyle.self, NSFont.self, NSColor.self,
          NSDictionary.self, NSString.self, NSTextTab.self,
        ], from: archive) as? NSAttributedString)

    let style = back.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

    XCTAssertEqual(style?.headerLevel, 2)
  }

  /// Catches an attachment that crosses as an image or a file wrapper. The archive must hold a bare
  /// placeholder, and the pixels must cross apart in the one fixed format.
  func testAnAttachmentBecomesAPlaceholderAndRawPixels() throws {
    let attachment = NSTextAttachment()
    attachment.image = DocumentFixtures.redImage(width: 8, height: 4)

    let source = NSMutableAttributedString(string: "a")
    source.append(NSAttributedString(attachment: attachment))

    let result = DocumentSanitizer.sanitize(source)

    XCTAssertEqual(result.images.count, 1)
    XCTAssertEqual(result.images[0].width, 8)
    XCTAssertEqual(result.images[0].height, 4)
    XCTAssertEqual(result.images[0].pixels.count, 8 * 4 * DocumentProtocol.bytesPerPixel)
    XCTAssertEqual(Array(result.images[0].pixels.prefix(4)), [255, 0, 0, 255])

    let placeholder =
      result.string.attribute(.attachment, at: 1, effectiveRange: nil) as? NSTextAttachment

    XCTAssertNil(placeholder?.image)
    XCTAssertNil(placeholder?.fileWrapper)
    XCTAssertNil(placeholder?.contents)
  }

  /// Catches an image past the per-image pixel cap that crosses at full size.
  func testAHugeImageIsScaledToThePixelCap() throws {
    let attachment = NSTextAttachment()
    attachment.image = NSImage(size: NSSize(width: 6000, height: 6000))

    let source = NSAttributedString(attachment: attachment)
    let result = DocumentSanitizer.sanitize(source)

    if let raster = result.images.first {
      XCTAssertLessThanOrEqual(raster.width * raster.height, DocumentProtocol.maxImagePixels)
    }
  }
}
