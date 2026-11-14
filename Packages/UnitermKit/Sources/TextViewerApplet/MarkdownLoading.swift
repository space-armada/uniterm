import Foundation
import SourceAccess

/// Reads a Markdown file in full, off the main thread, and finds the folder its images resolve
/// against. The text is never parsed here. WebKit's content process parses it.
enum MarkdownLoading {
  @concurrent
  static func load(path: String, limit: Int) async -> Result<MarkdownDocument, FileReadError> {
    loadBlocking(path: path, limit: limit)
  }

  static func loadBlocking(path: String, limit: Int) -> Result<MarkdownDocument, FileReadError> {
    switch RegularFile.readAll(path: path, limit: limit) {
    case .failure(let error):
      return .failure(error)

    case .success(let data):
      let folder = try? ConfinedFile.Folder.at(path: (path as NSString).deletingLastPathComponent)
        .get()

      return .success(MarkdownDocument(text: data, folder: folder))
    }
  }
}
