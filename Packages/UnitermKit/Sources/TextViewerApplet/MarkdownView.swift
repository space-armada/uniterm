import AppKit
import Theme
import WebKit

/// A web view that gives file drops to the pane instead of taking them, and keeps the context
/// menu to entries that cannot start a navigation or a download.
final class MarkdownWebView: WKWebView {
  override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    unregisterDraggedTypes()
  }

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)

    let refused = ["Download", "NewWindow", "Reload", "GoBack", "GoForward", "Share"]

    for item in menu.items
    where refused.contains(where: { item.identifier?.rawValue.contains($0) == true }) {
      menu.removeItem(item)
    }
  }
}

/// The compiled rule list that blocks every load that is not the viewer's own scheme. WebKit may let
/// a load that an isolated world starts skip the page's policy, so the rule list is the second
/// guard. A list that fails to compile stops the pane, since a pane without it is not safe to load.
@MainActor
enum MarkdownRules {
  static let source = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^\(MarkdownScheme.name):"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

  static let shared = RuleListCompiler {
    try? await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "uniterm.markdown.rules", encodedContentRuleList: source)
  }

  static func compiled() async -> WKContentRuleList? {
    await shared.compiled()
  }
}

/// Compiles one rule list and shares the result among the panes that ask. A failed compile is
/// forgotten, so the next pane tries again and one bad moment does not break Markdown until relaunch.
@MainActor
final class RuleListCompiler {
  private let compile: @MainActor () async -> WKContentRuleList?
  private var compiling: Task<WKContentRuleList?, Never>?

  init(compile: @escaping @MainActor () async -> WKContentRuleList?) {
    self.compile = compile
  }

  func compiled() async -> WKContentRuleList? {
    if let compiling { return await compiling.value }

    let compile = compile
    let task = Task { @MainActor () -> WKContentRuleList? in await compile() }

    compiling = task

    let list = await task.value

    if list == nil, compiling == task { compiling = nil }

    return list
  }
}

/// Shows one rendered Markdown document in a web view with no network, no page script, and its own
/// non-persistent website data.
///
/// The parser and the sanitizer run as user scripts in a named content world, and the page's own
/// world runs nothing. The one message handler is registered for that world only. The page, the
/// document's text, and its relative images come from a scheme handler. A rule list blocks every
/// load outside that scheme. Links open only through the pane's link policy.
@MainActor
final class MarkdownView: NSView, WKNavigationDelegate, WKUIDelegate {
  static let world = WKContentWorld.world(name: "uniterm.markdown")
  static let handlerName = "uniterm"

  /// The page finished rendering. The anchor is where the page settled.
  var onRendered: (() -> Void)?

  /// The page reports the scroll position changed.
  var onAnchor: ((MarkdownAnchor) -> Void)?

  /// The page could not render the document.
  var onFailed: ((String) -> Void)?

  /// WebKit's content process ended.
  var onTerminated: (() -> Void)?

  /// A user-activated link, for the pane's link policy.
  var onLink: ((URL) -> Void)?

  private(set) var anchor: MarkdownAnchor?
  private(set) var headings: [MarkdownHeading] = []
  private(set) var lineCount = 0
  private(set) var isRendered = false

  /// Counts the documents this view has shown. The page echoes it in every message about a
  /// document, and a message that carries another number is dropped.
  private(set) var generation = 0

  let webView: MarkdownWebView
  let scheme: MarkdownSchemeHandler

  private let controller: WKUserContentController
  private let assets: MarkdownAssets
  private var proxy: Proxy?
  private var palette = ThemePalette.latte
  private var pageReady = false
  private var restoreAnchor: MarkdownAnchor?
  private var closed = false

  /// Builds the view, or nil when the rule list cannot be compiled. A view without it is never
  /// built.
  static func make(
    assets: MarkdownAssets, limits: TextViewerLimits, sanitizerBypass: Bool = false
  ) async -> MarkdownView? {
    guard let rules = await MarkdownRules.compiled() else { return nil }

    return MarkdownView(
      assets: assets, limits: limits, rules: rules, sanitizerBypass: sanitizerBypass)
  }

  private init(
    assets: MarkdownAssets, limits: TextViewerLimits, rules: WKContentRuleList,
    sanitizerBypass: Bool
  ) {
    self.assets = assets

    scheme = MarkdownSchemeHandler(assets: assets, limits: limits)
    controller = WKUserContentController()

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.userContentController = controller
    configuration.setURLSchemeHandler(scheme, forURLScheme: MarkdownScheme.name)

    controller.add(rules)

    webView = MarkdownWebView(frame: .zero, configuration: configuration)

    super.init(frame: .zero)

    let proxy = Proxy(owner: self)
    self.proxy = proxy
    controller.add(proxy, contentWorld: Self.world, name: Self.handlerName)

    for source in [assets.parser, assets.sanitizer, assets.viewer] {
      controller.addUserScript(
        WKUserScript(
          source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
    }

    #if DEBUG
      if sanitizerBypass {
        controller.addUserScript(
          WKUserScript(
            source: Self.bypassScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
            in: Self.world))
      }
    #endif

    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    webView.allowsLinkPreview = false
    webView.isInspectable = false
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.unregisterDraggedTypes()
    webView.setAccessibilityIdentifier("text-viewer-markdown")

    addSubview(webView)

    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.topAnchor.constraint(equalTo: topAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    apply(palette)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  #if DEBUG
    /// Replaces the sanitizer with a pass-through that builds executable markup from the parser's
    /// output. A test uses it to prove the page's policy holds alone. It exists in debug builds
    /// only.
    private static let bypassScript = """
      window.umViewer.sanitize = function (html) {
        const range = document.createRange();
        range.selectNodeContents(document.body);
        return range.createContextualFragment(html);
      };
      """
  #endif

  // MARK: Showing

  /// Loads the page for `document`. `anchor` is where the page scrolls to once it has rendered.
  func show(document: MarkdownDocument, anchor: MarkdownAnchor?) {
    scheme.document = document
    generation += 1
    restoreAnchor = anchor
    self.anchor = anchor
    pageReady = false
    isRendered = false
    headings = []
    lineCount = 0

    webView.load(URLRequest(url: MarkdownScheme.pageURL))
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
    webView.appearance = appearance
    webView.underPageBackgroundColor = palette[.base].nsColor

    guard pageReady else { return }

    Task { [weak self] in
      _ = await self?.run(
        "window.umViewer.setTheme(theme)", ["theme": MarkdownTheme.payload(for: palette)])
    }
  }

  func focusPage() {
    window?.makeFirstResponder(webView)
  }

  /// Tears the page down: the handler, the scripts, and any request still waiting.
  func close() {
    closed = true
    webView.stopLoading()
    controller.removeAllUserScripts()
    controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
    scheme.cancelAll()
    scheme.document = nil
    proxy = nil
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
  }

  /// Runs `body` in the parser's world with `arguments`. Tests use it to read the page's state.
  @discardableResult
  func run(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
    guard !closed else { return nil }

    return try? await webView.callAsyncJavaScript(
      body, arguments: arguments, in: nil, contentWorld: Self.world)
  }

  // MARK: Messages

  func receive(_ body: Any) {
    guard !closed, let message = MarkdownMessage(body: body) else { return }

    if message != .ready, MarkdownMessage.generation(of: body) != generation { return }

    switch message {
    case .ready:
      pageReady = true
      startRendering()

    case .rendered(let lines, let found, let settled):
      lineCount = lines
      headings = found
      isRendered = true

      if let settled { anchor = settled }

      onRendered?()

    case .anchor(let moved):
      guard isRendered else { return }

      anchor = moved
      onAnchor?(moved)

    case .failed(let reason):
      onFailed?(reason)
    }
  }

  private func startRendering() {
    var options: [String: Any] = [
      "theme": MarkdownTheme.payload(for: palette), "generation": generation,
    ]

    if let restoreAnchor {
      options["anchor"] = ["line": restoreAnchor.line, "fraction": restoreAnchor.fraction]
    }

    Task { [weak self] in
      _ = await self?.run("return await window.umViewer.start(options)", ["options": options])
    }
  }

  private final class Proxy: NSObject, WKScriptMessageHandler {
    private weak var owner: MarkdownView?

    init(owner: MarkdownView) {
      self.owner = owner
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      MainActor.assumeIsolated { owner?.receive(message.body) }
    }
  }

  // MARK: Navigation

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard !navigationAction.shouldPerformDownload, let url = navigationAction.request.url else {
      return .cancel
    }

    if MarkdownScheme.isPage(url) { return .allow }

    if navigationAction.navigationType == .linkActivated, !MarkdownScheme.isViewerURL(url) {
      onLink?(url)
    }

    return .cancel
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
  ) async -> WKNavigationResponsePolicy {
    guard let url = navigationResponse.response.url, MarkdownScheme.isViewerURL(url),
      navigationResponse.canShowMIMEType
    else { return .cancel }

    return .allow
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard !closed else { return }

    pageReady = false
    isRendered = false
    onTerminated?()
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
      !MarkdownScheme.isViewerURL(url)
    {
      onLink?(url)
    }

    return nil
  }
}
