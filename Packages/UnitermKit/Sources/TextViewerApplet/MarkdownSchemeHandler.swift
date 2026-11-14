import Foundation
import SourceAccess
import UniformTypeIdentifiers
import WebKit

/// What the Markdown page may load, and under which policy.
enum MarkdownScheme {
  static let name = "uniterm-markdown"
  static let pageURL = URL(string: "uniterm-markdown://app/index.html")!

  /// Images and the document's text come from the viewer's own scheme and nowhere else. The page
  /// runs no script of its own. The user scripts in the parser's world are exempt from this
  /// policy, which is how WebKit treats a content world, so `script-src 'none'` costs the viewer
  /// nothing and denies every script the document might carry.
  static let contentSecurityPolicy = [
    "default-src 'none'",
    "img-src \(name):",
    "style-src \(name):",
    "connect-src \(name):",
    "script-src 'none'",
    "frame-src 'none'",
    "object-src 'none'",
    "media-src 'none'",
    "font-src 'none'",
    "form-action 'none'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
  ].joined(separator: "; ")

  static func isViewerURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == name
  }

  /// Whether `url` is the page itself, possibly with a fragment.
  static func isPage(_ url: URL) -> Bool {
    guard isViewerURL(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return false }

    parts.fragment = nil

    return parts.url == pageURL
  }
}

/// The document a Markdown pane serves. The text was read in full, off the main thread, and the
/// folder is what relative images resolve against.
struct MarkdownDocument: Sendable {
  let text: Data
  let folder: ConfinedFile.Folder?
}

/// Serves the Markdown page, its stylesheet, the document's text, and the images the document
/// names by relative path. Nothing else loads. An unknown route, a refused image path, and any
/// failure answer 404 with an empty body.
///
/// A reply must never reach a task WebKit has stopped, so the handler tracks the live tasks and
/// drops a reply for any other. Image bytes are read off the main thread.
@MainActor
final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
  var document: MarkdownDocument?

  private let assets: MarkdownAssets
  private let limits: TextViewerLimits

  /// The tasks still waiting, by a serial the handler gives each request. An image read finishes
  /// later, and by then WebKit may have stopped its task and reused the object's address for a new
  /// one. A serial is never reused, so a late reply finds nothing to answer.
  private var live: [Int: any WKURLSchemeTask] = [:]
  private var serials: [ObjectIdentifier: Int] = [:]
  private var nextSerial = 0

  init(assets: MarkdownAssets, limits: TextViewerLimits) {
    self.assets = assets
    self.limits = limits
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    nextSerial += 1

    let id = nextSerial
    live[id] = urlSchemeTask
    serials[ObjectIdentifier(urlSchemeTask)] = id

    guard let url = urlSchemeTask.request.url, url.host == "app" else {
      finish(id, status: 404)
      return
    }

    switch url.path {
    case "/index.html":
      serve(id, assets.page, type: "text/html; charset=utf-8")

    case "/viewer.css":
      serve(id, assets.stylesheet, type: "text/css; charset=utf-8")

    case "/document":
      guard let document else {
        finish(id, status: 404)
        return
      }

      serve(id, document.text, type: "text/plain; charset=utf-8")

    case "/image":
      serveImage(id, url: url)

    default:
      finish(id, status: 404)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    if let id = serials.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) { live[id] = nil }
  }

  /// Ends every request still waiting, as when the pane closes.
  func cancelAll() {
    live.removeAll()
    serials.removeAll()
  }

  /// Forgets request `id` and hands back its task, or nil when WebKit already stopped it.
  private func release(_ id: Int) -> (any WKURLSchemeTask)? {
    guard let task = live.removeValue(forKey: id) else { return nil }

    serials[ObjectIdentifier(task)] = nil

    return task
  }

  private func serveImage(_ id: Int, url: URL) {
    guard let document, let folder = document.folder,
      let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "p" })?.value
    else {
      finish(id, status: 404)
      return
    }

    guard let type = Self.imageType(forName: name) else {
      finish(id, status: 404)
      return
    }

    let limit = limits.maxMarkdownImageBytes

    Task { [weak self] in
      let bytes = await Self.readImage(name: name, folder: folder, limit: limit)

      guard let self else { return }

      switch bytes {
      case .some(let data):
        serve(id, data, type: type)

      case .none:
        finish(id, status: 404)
      }
    }
  }

  /// The MIME type of an image the viewer serves, by the name's extension. A name with any other
  /// extension is not an image, and nothing loads.
  nonisolated static func imageType(forName name: String) -> String? {
    let ext = (name as NSString).pathExtension.lowercased()

    guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image),
      let mime = type.preferredMIMEType
    else { return nil }

    return mime
  }

  @concurrent
  private static func readImage(name: String, folder: ConfinedFile.Folder, limit: Int) async
    -> Data?
  {
    switch ConfinedFile.open(name: name, in: folder) {
    case .failure:
      return nil

    case .success(let opened):
      defer { Darwin.close(opened.descriptor) }

      switch RegularFile.read(
        descriptor: opened.descriptor, path: name, size: opened.info.size, limit: limit)
      {
      case .success(let data): return data
      case .failure: return nil
      }
    }
  }

  private func serve(_ id: Int, _ text: String, type: String) {
    serve(id, Data(text.utf8), type: type)
  }

  private func serve(_ id: Int, _ data: Data, type: String) {
    guard let url = live[id]?.request.url else { return }

    let headers = [
      "Content-Type": type,
      "Content-Length": String(data.count),
      "Cache-Control": "no-store",
      "Content-Security-Policy": MarkdownScheme.contentSecurityPolicy,
      "X-Content-Type-Options": "nosniff",
    ]

    guard
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
    else {
      finish(id, status: 404)
      return
    }

    guard let task = release(id) else { return }

    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  private func finish(_ id: Int, status: Int) {
    guard let task = release(id) else { return }

    guard let url = task.request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": "0", "Cache-Control": "no-store"])
    else {
      task.didFailWithError(URLError(.badURL))
      return
    }

    task.didReceive(response)
    task.didFinish()
  }
}
