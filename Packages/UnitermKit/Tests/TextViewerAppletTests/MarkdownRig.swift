import AppKit
import BrowserTestSupport
import Darwin
import SourceAccess
import Theme
import WebKit
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// A Markdown page in a window, with the callbacks recorded. Every test that drives WebKit builds
/// one, so each reads the same signals the pane reads.
@MainActor
final class MarkdownRig {
  let view: MarkdownView
  let window: NSWindow
  private(set) var links: [URL] = []
  private(set) var anchors: [MarkdownAnchor] = []
  private(set) var failures: [String] = []
  private(set) var terminations = 0
  private(set) var renders = 0

  static func make(
    palette: ThemePalette = .latte, width: CGFloat = 800, bypass: Bool = false,
    limits: TextViewerLimits = .standard
  ) async throws -> MarkdownRig {
    guard case .success(let assets) = MarkdownAssets.shared else {
      throw XCTSkip("the bundled web assets are missing")
    }

    guard
      let view = await MarkdownView.make(assets: assets, limits: limits, sanitizerBypass: bypass)
    else {
      throw XCTSkip("the rule list did not compile")
    }

    return MarkdownRig(view: view, palette: palette, width: width)
  }

  private init(view: MarkdownView, palette: ThemePalette, width: CGFloat) {
    self.view = view

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = view

    view.apply(palette)

    view.onLink = { [unowned self] url in links.append(url) }
    view.onAnchor = { [unowned self] anchor in anchors.append(anchor) }
    view.onFailed = { [unowned self] reason in failures.append(reason) }
    view.onTerminated = { [unowned self] in terminations += 1 }
    view.onRendered = { [unowned self] in renders += 1 }
  }

  func close() {
    view.close()
  }

  func resize(to width: CGFloat) {
    window.setContentSize(NSSize(width: width, height: 500))
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// Shows `text` and waits for the page to say it rendered.
  @discardableResult
  func show(
    _ text: String, folder: URL? = nil, anchor: MarkdownAnchor? = nil, timeout: Double = 30
  ) async -> Bool {
    let before = renders
    let located = folder.flatMap { try? ConfinedFile.Folder.at(path: $0.path).get() }

    view.show(
      document: MarkdownDocument(text: Data(text.utf8), folder: located), anchor: anchor)

    return await eventually(timeout) { self.renders > before }
  }

  func eventually(_ seconds: Double = 20, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while ContinuousClock.now < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }

  /// Evaluates a function body in the parser's world.
  func eval(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
    await view.run(body, arguments)
  }

  func number(_ body: String, _ arguments: [String: Any] = [:]) async -> Double? {
    (await eval(body, arguments) as? NSNumber)?.doubleValue
  }

  func string(_ body: String, _ arguments: [String: Any] = [:]) async -> String? {
    await eval(body, arguments) as? String
  }

  func count(_ selector: String) async -> Int {
    Int(
      await number("return document.querySelectorAll(selector).length", ["selector": selector])
        ?? -1)
  }

  /// Waits until the first image matching `selector` has loaded some pixels, or `seconds` pass.
  func imageLoaded(_ selector: String, seconds: Double = 10) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while ContinuousClock.now < deadline {
      let width = await number(
        "const i = document.querySelector(selector); return i && i.complete ? i.naturalWidth : 0",
        ["selector": selector])

      if (width ?? 0) > 0 { return true }

      try? await Task.sleep(for: .milliseconds(50))
    }

    return false
  }

  /// Waits until the first image matching `selector` has finished loading, or failed to, or
  /// `seconds` pass. A refused image completes with no pixels.
  func imageSettled(_ selector: String, seconds: Double = 10) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while ContinuousClock.now < deadline {
      let done = await number(
        "const i = document.querySelector(selector); return i && i.complete ? 1 : 0",
        ["selector": selector])

      if done == 1 { return true }

      try? await Task.sleep(for: .milliseconds(20))
    }

    return false
  }

  /// Gives the page time to start a request it should not make. Nothing signals the absence of a
  /// request, so the wait is a fixed bound, and a request that arrives later is missed.
  func settle() async {
    try? await Task.sleep(for: .milliseconds(1500))
  }

  /// SIGKILLs the web view's content process, as a crash would.
  func killContentProcess() -> Bool {
    Self.killContentProcess(of: view)
  }

  static func killContentProcess(of view: MarkdownView) -> Bool {
    let name = "_webProcessIdentifier"

    guard view.webView.responds(to: NSSelectorFromString(name)),
      let pid = (view.webView.value(forKey: name) as? NSNumber)?.int32Value, pid > 1
    else { return false }

    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
      String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        .contains("com.apple.WebKit.WebContent")
    else { return false }

    return Darwin.kill(pid, SIGKILL) == 0
  }
}

enum Pixels {
  /// A PNG that is `width` pixels wide and one tall, so a test can tell two images apart by size.
  static func png(width: Int) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    return rep.representation(using: .png, properties: [:])!
  }
}
