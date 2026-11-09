import AppKit
import DocumentWire
import Foundation
import TextViewerModel

/// A decoded document, ready for a text view. An attributed string is not `Sendable`, but this one
/// is built once off the main thread and handed over whole.
struct DecodedDocument: @unchecked Sendable {
  let text: NSAttributedString

  /// The headings the reader marked, found off the main thread with the rest of the decode.
  let contents: Contents
}

enum DocumentReplyError: Error, Equatable, Sendable {
  /// The reply decoded to something other than what the app expects.
  case misbehaved(String)

  case overCap(TextViewerLimits.CapViolation)
}

/// Turns the helper's reply into an attributed string, and checks it against the app's own caps.
///
/// The archive decodes only through secure coding of the classes below. They leave out `NSImage`,
/// `NSBitmapImageRep`, and `NSFileWrapper`, so a reply cannot make the app build an image through
/// a codec. Images arrive as raw pixels and become `CGImage`s with no decoder. The caps run here,
/// off the main thread, before any text view lays out the string.
enum DocumentReplyDecoder {
  static let allowedClasses: [AnyClass] = [
    NSAttributedString.self, NSMutableAttributedString.self, NSString.self, NSMutableString.self,
    NSDictionary.self, NSMutableDictionary.self, NSArray.self, NSMutableArray.self,
    NSNumber.self, NSURL.self, NSData.self, NSValue.self, NSFont.self, NSFontDescriptor.self,
    NSColor.self, NSColorSpace.self, NSParagraphStyle.self, NSMutableParagraphStyle.self,
    NSTextTab.self, NSTextList.self, NSTextBlock.self, NSTextTable.self, NSTextTableBlock.self,
    NSTextAttachment.self, NSCharacterSet.self, NSMutableCharacterSet.self, NSShadow.self,
  ]

  @concurrent
  static func decode(_ reply: DocumentReply, limits: TextViewerLimits) async -> Result<
    DecodedDocument, DocumentReplyError
  > {
    decodeBlocking(reply, limits: limits)
  }

  static func decodeBlocking(_ reply: DocumentReply, limits: TextViewerLimits) -> Result<
    DecodedDocument, DocumentReplyError
  > {
    let object: Any?

    do {
      object = try NSKeyedUnarchiver.unarchivedObject(
        ofClasses: allowedClasses, from: reply.archive)
    } catch {
      return .failure(.misbehaved("the archive is not a document"))
    }

    guard let source = object as? NSAttributedString else {
      return .failure(.misbehaved("the archive is not an attributed string"))
    }

    let measured = measure(source)

    if let violation = limits.violation(
      length: source.length, tableCells: measured.tableCells, attachments: measured.attachments)
    {
      return .failure(.overCap(violation))
    }

    guard measured.attachments == reply.images.count else {
      return .failure(.misbehaved("the images do not match the placeholders"))
    }

    guard !reply.images.isEmpty else {
      return .success(DecodedDocument(text: source, contents: ContentsBuilders.text(source)))
    }

    let mutable = NSMutableAttributedString(attributedString: source)
    var next = 0
    var failed = false

    source.enumerateAttribute(
      .attachment, in: NSRange(location: 0, length: source.length), options: []
    ) { value, range, stop in
      guard value is NSTextAttachment else { return }

      for index in range.location..<NSMaxRange(range) {
        guard next < reply.images.count, let image = Self.image(from: reply.images[next]) else {
          failed = true
          stop.pointee = true
          return
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: image.size)
        mutable.addAttribute(
          .attachment, value: attachment, range: NSRange(location: index, length: 1))
        next += 1
      }
    }

    guard !failed, next == reply.images.count else {
      return .failure(.misbehaved("the images do not match the placeholders"))
    }

    return .success(DecodedDocument(text: mutable, contents: ContentsBuilders.text(mutable)))
  }

  /// The table cells and attachment placeholders of a decoded string.
  static func measure(_ text: NSAttributedString) -> (tableCells: Int, attachments: Int) {
    var cells = Set<ObjectIdentifier>()
    var attachments = 0
    let whole = NSRange(location: 0, length: text.length)

    text.enumerateAttribute(.paragraphStyle, in: whole, options: []) { value, _, _ in
      guard let style = value as? NSParagraphStyle else { return }

      for block in style.textBlocks where block is NSTextTableBlock {
        cells.insert(ObjectIdentifier(block))
      }
    }

    text.enumerateAttribute(.attachment, in: whole, options: []) { value, range, _ in
      if value is NSTextAttachment { attachments += range.length }
    }

    return (cells.count, attachments)
  }

  /// An image built straight from the helper's pixels: four bytes each, premultiplied RGBA in sRGB.
  static func image(from raw: RawImage) -> NSImage? {
    guard let provider = CGDataProvider(data: raw.pixels as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let cgImage = CGImage(
        width: raw.width, height: raw.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: raw.width * DocumentProtocol.bytesPerPixel, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }

    return NSImage(cgImage: cgImage, size: NSSize(width: raw.width, height: raw.height))
  }
}
