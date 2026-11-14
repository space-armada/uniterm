import Foundation

/// The files the Markdown page is made of, read once from the package's resources. The parser and
/// the sanitizer are the pinned files that `web-assets.pin` names.
struct MarkdownAssets: Sendable {
  let page: String
  let stylesheet: String
  let parser: String
  let sanitizer: String
  let viewer: String

  enum LoadError: Error, Equatable {
    case missing(String)
  }

  static func load(from bundle: Bundle = .module) -> Result<MarkdownAssets, LoadError> {
    func read(_ name: String, _ ext: String) -> String? {
      guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "web"),
        let data = try? Data(contentsOf: url)
      else { return nil }

      return String(decoding: data, as: UTF8.self)
    }

    guard let page = read("index", "html") else { return .failure(.missing("index.html")) }
    guard let stylesheet = read("viewer", "css") else { return .failure(.missing("viewer.css")) }
    guard let parser = read("markdown-it.umd.min", "js") else {
      return .failure(.missing("markdown-it.umd.min.js"))
    }
    guard let sanitizer = read("purify.min", "js") else {
      return .failure(.missing("purify.min.js"))
    }
    guard let viewer = read("viewer", "js") else { return .failure(.missing("viewer.js")) }

    return .success(
      MarkdownAssets(
        page: page, stylesheet: stylesheet, parser: parser, sanitizer: sanitizer, viewer: viewer))
  }

  /// The assets of this build. A failure is a packaging error, so it shows in the pane as a
  /// message and never as a blank page.
  static let shared = load()
}
