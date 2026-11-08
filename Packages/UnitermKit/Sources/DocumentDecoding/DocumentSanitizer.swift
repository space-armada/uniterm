import AppKit
import DocumentWire
import Foundation

/// What survives the trip from the reader to the app: the text, a fixed set of attributes, and
/// each embedded image as raw pixels.
///
/// The helper drops every attribute off the allowlist, since the app decodes only what it expects
/// and displays only what it understands. An attachment becomes a bare placeholder at the same
/// place. Its image goes beside the archive as pixels, so no `NSImage`, bitmap rep, or file
/// wrapper is ever archived.
struct SanitizedDocument {
  var string: NSAttributedString
  var images: [RawImage]
}

enum DocumentSanitizer {
  /// The attributes a document keeps. `.paragraphStyle` carries tables and heading levels.
  static let allowed: Set<NSAttributedString.Key> = [
    .font, .foregroundColor, .backgroundColor, .underlineStyle, .underlineColor,
    .strikethroughStyle, .strikethroughColor, .paragraphStyle, .link, .attachment, .superscript,
    .baselineOffset, .kern, .ligature,
  ]

  static func sanitize(_ source: NSAttributedString) -> SanitizedDocument {
    let output = NSMutableAttributedString()
    var images: [RawImage] = []
    var totalPixels = 0

    let whole = NSRange(location: 0, length: source.length)

    source.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
      var kept: [NSAttributedString.Key: Any] = [:]

      for (key, value) in attributes where allowed.contains(key) && key != .attachment {
        kept[key] = value
      }

      let text = (source.string as NSString).substring(with: range)

      guard let attachment = attributes[.attachment] as? NSTextAttachment else {
        output.append(NSAttributedString(string: text, attributes: kept))
        return
      }

      // The run holds one placeholder character for each use of the attachment.
      for character in text {
        guard character == "\u{FFFC}" else {
          output.append(NSAttributedString(string: String(character), attributes: kept))
          continue
        }

        guard images.count < DocumentProtocol.maxImages,
          let raster = ImageRasterizer.raster(of: attachment),
          totalPixels + raster.width * raster.height <= DocumentProtocol.maxTotalPixels
        else { continue }

        totalPixels += raster.width * raster.height

        let placeholder = NSTextAttachment()
        placeholder.bounds = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)

        var withImage = kept
        withImage[.attachment] = placeholder

        output.append(NSAttributedString(string: "\u{FFFC}", attributes: withImage))
        images.append(raster)
      }
    }

    return SanitizedDocument(string: output, images: images)
  }
}

enum ImageRasterizer {
  /// The attachment's image as raw pixels, scaled down to the per-image cap. Nil when the
  /// attachment holds no image the system can draw.
  static func raster(of attachment: NSTextAttachment) -> RawImage? {
    guard let cgImage = cgImage(of: attachment) else { return nil }

    var width = cgImage.width
    var height = cgImage.height

    guard width > 0, height > 0 else { return nil }

    if width * height > DocumentProtocol.maxImagePixels {
      let scale = (Double(DocumentProtocol.maxImagePixels) / Double(width * height)).squareRoot()

      width = max(1, Int(Double(width) * scale))
      height = max(1, Int(Double(height) * scale))

      while width * height > DocumentProtocol.maxImagePixels { height -= 1 }
    }

    let count = width * height * DocumentProtocol.bytesPerPixel
    var pixels = PageBuffer.data(count: count)

    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * DocumentProtocol.bytesPerPixel,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }

      context.interpolationQuality = .high
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

      return true
    }

    return drawn ? RawImage(width: width, height: height, pixels: pixels) : nil
  }

  private static func cgImage(of attachment: NSTextAttachment) -> CGImage? {
    var image = attachment.image

    if image == nil, let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents {
      image = NSImage(data: data)
    }

    return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }
}
