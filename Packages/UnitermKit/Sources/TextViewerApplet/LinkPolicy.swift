import Foundation
import PDFKit

/// Which links a document may open. A link in an RTF, Word, or PDF document opens in the default
/// app only for `http`, `https`, and `mailto`. Everything else is refused, `file:` and custom
/// schemes included.
enum LinkPolicy {
  static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

  static func url(from value: Any?) -> URL? {
    if let url = value as? URL { return url }

    if let text = value as? String { return URL(string: text) }

    return nil
  }

  static func isOpenable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }

    return allowedSchemes.contains(scheme)
  }

  /// Whether a PDF may run `action`. Page navigation and links to the safe schemes run. A link to
  /// another file, a form reset, a print command, and any kind of action this build does not know
  /// are refused, since each can reach past the document.
  static func allows(_ action: PDFAction) -> Bool {
    switch action {
    case let action as PDFActionURL:
      return action.url.map(isOpenable) ?? false

    case is PDFActionGoTo:
      return true

    case let action as PDFActionNamed:
      return action.name != .print

    default:
      return false
    }
  }
}
