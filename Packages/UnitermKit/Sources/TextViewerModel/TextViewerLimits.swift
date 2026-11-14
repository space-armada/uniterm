import DocumentWire
import Foundation

/// The caps the text viewer keeps. A cap is a policy value with no setting.
///
/// The file caps bound the bytes read for a PDF, which loads in the app, and the bytes the helper
/// is handed for RTF and Word. The decoded caps bound what the text view lays out on the main
/// thread. The helper's footprint cap bounds what a hostile `.docx` can inflate to, since the
/// helper dies there and not the app.
public struct TextViewerLimits: Equatable, Sendable {
  /// The most bytes read from a PDF. PDFKit's pages use more memory than the file.
  public var maxPDFBytes = 256 << 20

  /// The most bytes of an RTF or Word file the app hands the helper.
  public var maxDocumentBytes = 64 << 20

  /// The most bytes read from a Markdown file. The page parses it in WebKit's content process, so a
  /// large file costs that process, never the app.
  public var maxMarkdownBytes = 32 << 20

  /// The most bytes served for one image a Markdown document names.
  public var maxMarkdownImageBytes = 16 << 20

  /// The most characters, in UTF-16 units, a decoded document may hold.
  public var maxDecodedLength = 4_000_000

  /// The most table cells a decoded document may hold.
  public var maxTableCells = 20_000

  public var maxImages = 64
  public var maxImagePixels = 16_000_000
  public var maxTotalPixels = 64_000_000

  /// The most bytes the helper's archive may carry.
  public var maxArchiveBytes = 32 << 20

  /// The most the helper's physical footprint may be before the app ends it.
  public var footprintCap = 1 << 30

  /// How long a decode may run.
  public var decodeTimeBound = Duration.seconds(10)

  public init() {}

  public static let standard = TextViewerLimits()

  public func fileLimit(for format: TextFormat) -> Int {
    switch format {
    case .pdf: return maxPDFBytes
    case .markdown: return maxMarkdownBytes
    default: return maxDocumentBytes
    }
  }

  public var replyLimits: DocumentReplyLimits {
    DocumentReplyLimits(
      maxArchiveBytes: maxArchiveBytes, maxImages: maxImages, maxImagePixels: maxImagePixels,
      maxTotalPixels: maxTotalPixels)
  }

  /// The message for a file past its cap.
  public func tooLargeMessage(fileName: String, bytes: Int, format: TextFormat) -> String {
    let limit = fileLimit(for: format)

    return "\u{201C}\(fileName)\u{201D} is \(Self.size(bytes)). "
      + "The text viewer opens files up to \(Self.size(limit))."
  }

  /// What a decoded document is past, or nil when it is within every cap.
  public func violation(length: Int, tableCells: Int, attachments: Int) -> CapViolation? {
    if length > maxDecodedLength {
      return .length(limit: maxDecodedLength)
    }

    if tableCells > maxTableCells {
      return .tableCells(limit: maxTableCells)
    }

    if attachments > maxImages {
      return .images(limit: maxImages)
    }

    return nil
  }

  public enum CapViolation: Equatable, Sendable {
    case length(limit: Int)
    case tableCells(limit: Int)
    case images(limit: Int)

    /// The pane's message, which names the limit.
    public func message(fileName: String) -> String {
      switch self {
      case .length(let limit):
        return "\u{201C}\(fileName)\u{201D} has more than \(limit.formatted()) characters. "
          + "The text viewer shows documents up to that length."

      case .tableCells(let limit):
        return "\u{201C}\(fileName)\u{201D} has more than \(limit.formatted()) table cells. "
          + "The text viewer shows documents up to that many."

      case .images(let limit):
        return "\u{201C}\(fileName)\u{201D} has more than \(limit.formatted()) images. "
          + "The text viewer shows documents up to that many."
      }
    }
  }

  static func size(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}
