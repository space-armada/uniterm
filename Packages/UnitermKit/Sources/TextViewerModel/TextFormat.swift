import DocumentWire
import Foundation
import UniformTypeIdentifiers

/// The format a file is read as.
public enum TextFormat: Equatable, Sendable {
  case pdf
  case rtf
  case word97
  case wordXML
  case markdown

  /// A file the viewer does not read. The text names what it is, for the pane's message.
  case unsupported(String)

  /// The helper's reader for a format that parses in the helper.
  public var documentKind: DocumentKind? {
    switch self {
    case .rtf: return .rtf
    case .word97: return .word97
    case .wordXML: return .wordXML
    case .pdf, .markdown, .unsupported: return nil
    }
  }
}

/// The one rule that picks a format from a file's name.
///
/// 1. A file named `README`, in any case and with no extension, is Markdown.
/// 2. The extension, in any case, is mapped to a type: `markdown`, `mdown`, `mkd`, and `md` are
///    Markdown, and every other extension is looked up with the system's type database.
/// 3. A type that conforms to PDF, RTF, Word 97, or Word XML picks that reader. A type that
///    conforms to Markdown picks Markdown.
/// 4. Anything else is unsupported, and the message names the type's description, or the extension.
///
/// The rule reads only the name. A file's bytes never choose a reader, so an `.rtf` file that holds
/// HTML is read as RTF.
public enum TextFormatRule {
  static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

  public static let word97Identifier = "com.microsoft.word.doc"
  public static let wordXMLIdentifier = "org.openxmlformats.wordprocessingml.document"
  public static let markdownIdentifier = "net.daringfireball.markdown"

  public static func format(forFileNamed name: String) -> TextFormat {
    let nsName = name as NSString
    let ext = nsName.pathExtension.lowercased()

    if ext.isEmpty, nsName.deletingPathExtension.lowercased() == "readme" { return .markdown }

    if markdownExtensions.contains(ext) { return .markdown }

    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
      return .unsupported(
        ext.isEmpty ? "a file with no extension" : "a \u{201C}.\(ext)\u{201D} file")
    }

    if type.conforms(to: .pdf) { return .pdf }

    if type.conforms(to: .rtf) { return .rtf }

    if type.identifier == word97Identifier { return .word97 }

    if type.identifier == wordXMLIdentifier { return .wordXML }

    if let markdown = UTType(markdownIdentifier), type.conforms(to: markdown) {
      return .markdown
    }

    return .unsupported(type.localizedDescription ?? "a \u{201C}.\(ext)\u{201D} file")
  }

  public static func format(of file: URL) -> TextFormat {
    format(forFileNamed: file.lastPathComponent)
  }

  /// The types the open panel accepts, so the panel greys out what the viewer would refuse.
  public static var openPanelTypes: [UTType] {
    [.pdf, .rtf, UTType(word97Identifier), UTType(wordXMLIdentifier), UTType(markdownIdentifier)]
      .compactMap { $0 }
  }

  /// What the pane says about a file it does not read.
  public static func unsupportedMessage(fileName: String, description: String) -> String {
    "\u{201C}\(fileName)\u{201D} is \(description), which the text viewer does not open yet."
  }
}
