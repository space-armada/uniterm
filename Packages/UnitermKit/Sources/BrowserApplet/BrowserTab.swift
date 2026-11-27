import AppKit
import AppletKit
import BrowserModel
import StatusKit
import WebKit

/// What a tab tells its applet. The applet turns each into a notice, a refresh, or both.
@MainActor
protocol BrowserTabDelegate: AnyObject {
  /// The page, its title, its loading state, or the history changed.
  func tabDidChange(_ tab: BrowserTab)

  /// Something the user should hear about, such as a refused navigation or a failed load.
  func tab(_ tab: BrowserTab, notice level: StatusLevel, text: String)

  /// Asks the user a question for the tab. Nothing in the tab waits on it except the one
  /// navigation that raised it.
  func tab(_ tab: BrowserTab, confirm request: AppletConfirmation) async -> Bool

  /// The user pressed a history button on the mouse over the tab's page.
  func tab(_ tab: BrowserTab, historyButton: BrowserWebView.HistoryButton)

  /// The tab put an explanation in its pane. The history records it, and the status bar stays
  /// quiet, since the pane already says it.
  func tab(_ tab: BrowserTab, explained text: String)

  /// The user followed a link to an address that names another app.
  func tab(_ tab: BrowserTab, handOff url: URL)

  /// A page asked for a new window. The applet answers with the tab it built from `configuration`,
  /// or nil to refuse. WebKit needs the web view back before this returns. `byUser` is true when
  /// the user's own click on a link, or choice from the context menu, asked for it.
  func tab(
    _ tab: BrowserTab, openWindowWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, byUser: Bool
  ) -> BrowserTab?

  /// The page's script called `window.close()` on a window it opened.
  func tabDidRequestClose(_ tab: BrowserTab)

  /// WebKit turned a navigation into a download. The applet holds it from here.
  func tab(_ tab: BrowserTab, download: WKDownload)

  /// The tab holds a download decision for a page that passed the free limit, and wants the
  /// pane to ask.
  func tabNeedsDownloadQuestion(_ tab: BrowserTab)

  /// A page raised an alert, a confirmation, or a prompt. The applet owns the answer.
  func tab(_ tab: BrowserTab, present dialog: PageDialog)

  /// The tab's unsent-input mark changed, so what a close would lose changed.
  func tabUnsentInputDidChange(_ tab: BrowserTab)

  /// The tab's content process ended or hung, and the tab dropped its web view. The applet answers
  /// by deciding whether the user sees the stopped message, by ending what the page left waiting,
  /// and by showing the tab's new web view when the tab is the selected one. `hadFocus` is true
  /// when the keyboard was in the old web view. `recovering` is true when the tab is about to load its
  /// page again by itself, as after a hang that a user's reload or navigation ran into.
  func tab(_ tab: BrowserTab, didLoseContentWithFocus hadFocus: Bool, recovering: Bool)

  /// Whether a page dialog of the tab waits for the user. A page that waits on one is not hung.
  func tabHoldsDialog(_ tab: BrowserTab) -> Bool

  /// Whether the user is looking at the tab: it is selected in a pane that is attached.
  func tabIsViewed(_ tab: BrowserTab) -> Bool

  /// Asks whether to replace a web view that stopped answering while it holds input that was not
  /// sent. The page may only be busy. False when the user declines or cannot be asked.
  func tab(confirmReplacingUnresponsive tab: BrowserTab) async -> Bool
}

/// An address whose scheme the browser chose, kept with the text that produced it. A failure to
/// connect to it can offer plain HTTP, and Load over HTTP resolves `typed` again.
struct AssumedLoad: Equatable {
  var url: URL
  var typed: String
}

/// Why a reload, a back, or a forward did not go ahead.
enum HistoryMove: Equatable {
  case moved

  /// There was nowhere to go.
  case unavailable

  /// A tab that never loaded has a stored address the rule refuses.
  case refused(SchemeRefusal, address: String)
}

/// One page's web view and what the applet needs to know about it.
///
/// The tab owns every load decision that is about a page: which schemes load, which results of a
/// form post are never reloaded silently, and which load failures are worth reporting. The applet
/// owns what the user sees around it.
@MainActor
final class BrowserTab: NSObject {
  let id: AppletTabID

  /// The tab's web view. It is built on first use, so a restored tab nobody has looked at holds no
  /// web view and no content process. A web view whose content process ended or hung is replaced,
  /// so callers read this each time and never keep the value.
  var webView: WKWebView {
    if let current { return current }

    let view = makeWebView()

    current = view
    LiveContentViews.add(view)

    return view
  }

  private var current: WKWebView?

  /// Whether the web view exists. It goes back to false when the content process ends or hangs and
  /// the tab drops the web view.
  var isMaterialized: Bool { current != nil }

  /// How far the tab's first load has come, and what it shows or holds meanwhile.
  private var loadState: LoadState

  /// Whether the user is looking at the message that the page stopped. Only the selected tab of an
  /// attached pane shows it. A stopped tab never reloads on its own: the user's Reload builds a
  /// new web view.
  var isStopped: Bool { loadState.isStopped }

  /// Counts the times the tab lost its content. An answer to a question the user was asked before
  /// that, such as one about opening another app, belongs to a page that is gone.
  private(set) var generation = 0

  private(set) var isClosed = false

  /// What the tab knows about form posts, and the question the gate puts to the user.
  private let gate = ResendGate()

  /// The bound on a reload or navigation the content process never answers.
  private let hangRecovery: HangRecovery

  private let hangPolicy: HangPolicy

  weak var delegate: (any BrowserTabDelegate)?

  /// The tab whose page opened this one. A pop-up tab that closes itself returns the selection to
  /// it while it exists.
  weak var opener: BrowserTab?

  /// The page whose script opened this tab, directly or through the question that let it open
  /// more. The pane places such tabs in the order they were asked for, after the group's last tab.
  /// A tab the user opened by a click is not in a group.
  weak var scriptGroup: BrowserTab?

  /// Whether WebKit built this tab's web view for a new window. Only such a tab is closed by
  /// `window.close()`.
  let isPopup: Bool

  /// Whether a script asked for this tab, and not the user's own click or menu choice. Only these
  /// tabs count toward the pane's limit.
  let isScriptOpened: Bool

  /// Whether the tab holds edited form input. It clears on every load and when the fields return
  /// to their defaults.
  var hasUnsentInput: Bool { unsent.isMarked }

  let unsent = UnsentInputTracker()

  /// How many dialogs the page has raised since its last load. From the second on, a dialog offers
  /// to stop the rest.
  private var dialogsThisLoad = 0

  /// Whether the user chose to stop the page's dialogs, and whether the user heard that they are
  /// dismissed. Both end at the page's next load.
  private var dialogsStopped = false
  private var warnedAboutDialogs = false

  /// The tabs this page's script tried to open past the pane's limit. It ends at the page's next
  /// load.
  var scriptTabs = ScriptTabHold()

  /// The downloads this page started without a click, and the decisions held for the question
  /// about more. It ends at the page's next load.
  var downloadHold = DownloadHold()

  /// Whether the navigation in progress is the one a click or a load of the user's started.
  private var userNavigation = UserNavigation()

  /// The configuration WebKit gave a pop-up, used once to build its web view.
  private var adopted: WKWebViewConfiguration?

  /// What began the tab's current load. A notice from the tab takes its delivery from it, so a
  /// background tab restored at launch stays as quiet as a restore is. The restore origin ends at
  /// the user's first decision in the tab, such as a click on a link, since what follows is theirs.
  var loadOrigin = LoadOrigin.user

  /// The last committed address and title, as the description stores them.
  private(set) var record: BrowserDescription.Tab

  /// The address the user is looking at, from the web view. Nil before the first commit.
  private(set) var currentURL: URL?

  /// The address of the page that last committed. WebKit moves `url` to a new page before it
  /// commits, so a download that starts from a link needs this one to name where it came from.
  private(set) var committedURL: URL?

  private(set) var pageTitle: String?
  private(set) var isLoading = false
  private(set) var canGoBack = false
  private(set) var canGoForward = false

  /// Whether the address bar should warn about the current page. It is recomputed whenever the
  /// address or WebKit's secure-content flag changes, so it follows a page that loads insecure
  /// content after commit and a navigation to a page with none.
  private(set) var showsSecurityWarning = false

  /// Whether a question about sending a form again is waiting for the user.
  var isAskingToResend: Bool { gate.isAsking }

  /// What the tab shows in place of a page it could not load, until the next load or commit.
  var errorPage: LoadErrorPage? { loadState.errorPage }

  /// The load the tab began with an assumed HTTPS scheme, until it commits or another load begins.
  private var assumed: AssumedLoad?

  /// The address and scheme choice of the load that failed into `errorPage`, so Reload can try it
  /// again.
  private var failedLoad: (url: URL, assumed: AssumedLoad?)?

  /// Whether a question about opening another app is waiting. A tab holds at most one.
  var isAskingToOpenApp = false

  /// The note of a real mouse-up in this tab's web view, taken by the next link decision.
  private var gesture = LinkGesture()

  /// The note that the user asked for a window: a real click on a link, or a choice from the
  /// context menu. The next request for a window takes it, once, within the same bound.
  private var windowGesture = LinkGesture()
  private let clock: @Sendable () -> Date

  /// The history WebKit handed back when a closed tab reopened. It applies at the first load.
  private var restoredState: Data? { loadState.history }

  /// Whether a load began, from the stored address, a restored history, or the user.
  var hasBegunLoading: Bool { loadState.hasBegunLoading }

  private let dataStore: WKWebsiteDataStore
  private let hsts: HSTSStore
  private var observations: [NSKeyValueObservation] = []

  /// The last history record read from a view that had committed a page.
  private var lastReadInteraction: Data?

  /// The address of the last load the tab began from a typed address, for a tab that stops before
  /// any page committed.
  private var lastRequested: URL?

  /// Whether a question about replacing a hung web view is waiting for the user.
  var isAskingToReplace: Bool { hangRecovery.isAskingToReplace }

  init(
    id: AppletTabID, record: BrowserDescription.Tab, dataStore: WKWebsiteDataStore,
    hsts: HSTSStore, clock: @escaping @Sendable () -> Date = Date.init, restoredState: Data? = nil,
    hang: HangPolicy = .live
  ) {
    self.id = id
    self.record = record
    self.dataStore = dataStore
    self.hsts = hsts
    self.hangRecovery = HangRecovery(policy: hang)
    self.hangPolicy = hang
    self.clock = clock
    self.loadState = .idle(history: restoredState)
    self.isPopup = false
    self.isScriptOpened = false

    super.init()

    hangRecovery.owner = self
  }

  /// A tab built from the configuration WebKit passed for a new window. WebKit ties the new page
  /// to its opener through that configuration, so `window.opener` works and the website data
  /// store is the opener's, which is the browser's shared one. The web view is built at once,
  /// since WebKit needs it back from the same call. The page loads on its own, so the tab counts
  /// as having begun loading.
  init(
    id: AppletTabID, adopting configuration: WKWebViewConfiguration, opener: BrowserTab,
    openedByUser: Bool, dataStore: WKWebsiteDataStore, hsts: HSTSStore,
    clock: @escaping @Sendable () -> Date, hang: HangPolicy = .live
  ) {
    self.id = id
    self.record = BrowserDescription.Tab()
    self.dataStore = dataStore
    self.hsts = hsts
    self.hangRecovery = HangRecovery(policy: hang)
    self.hangPolicy = hang
    self.clock = clock
    self.loadState = .loading(error: nil, history: nil)
    self.isPopup = true
    self.isScriptOpened = !openedByUser
    self.adopted = configuration
    self.opener = opener

    super.init()

    hangRecovery.owner = self

    _ = webView
  }

  private func makeWebView() -> WKWebView {
    let fromScratch = adopted == nil
    let configuration = adopted ?? WKWebViewConfiguration()

    adopted = nil

    // A pop-up's own configuration already carries the opener's store. A pop-up rebuilt after its
    // process ended has no configuration from WebKit, so it takes the browser's store like any tab.
    if fromScratch { configuration.websiteDataStore = dataStore }

    // WKWebView on macOS lets a script open a window with no user gesture unless this is false.
    // The browser blocks it, as every other browser does, so a page cannot open tabs on its own.
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

    // Each web view gets its own controller. A controller takes one handler of a name in a world,
    // so a pop-up that shared its opener's would raise an exception, and would report into the
    // opener's tab.
    let controller = WKUserContentController()

    configuration.userContentController = controller
    unsent.install(in: controller)
    MediaCaptureScript.install(in: controller)
    unsent.onChange = { [weak self] in
      guard let self else { return }

      delegate?.tabUnsentInputDidChange(self)
    }

    let view = BrowserWebView(frame: .zero, configuration: configuration)

    view.navigationDelegate = self
    view.uiDelegate = self
    view.allowsBackForwardNavigationGestures = true
    view.setAccessibilityIdentifier("browser-web")
    view.onMouseUp = { [weak self] in self?.noteMouseUp() }
    view.onMenuChoice = { [weak self] in self?.noteUserWindowRequest() }
    view.onHistoryButton = { [weak self] button in
      guard let self else { return }

      delegate?.tab(self, historyButton: button)
    }

    observe(view)

    return view
  }

  /// The user chose a new-tab item from the context menu.
  func noteUserWindowRequest() {
    windowGesture.noteMouseUp(at: clock())
  }

  /// A real left mouse-up reached the web view. A tab's next link decision may count as followed by
  /// the user, once, within the bound.
  func noteMouseUp() {
    gesture.noteMouseUp(at: clock())
  }

  var hasLoadedNothing: Bool { !isMaterialized || (webView.url == nil && !isLoading) }

  /// Whether a stop has something to bring back: a page that committed, a history record, or an
  /// address a load began for.
  private var hasPageToRestore: Bool {
    restoredState != nil || record.url != nil || lastRequested != nil
  }

  /// WebKit's record of the tab's history and scroll positions, for a tab that is closing or a pane
  /// that is describing itself. A record the tab was given and has not applied yet comes back as it
  /// was. A web view that holds no page reports an empty record, which would replace it, so a tab
  /// with no page has none.
  ///
  /// The read is kept until something changes the history, since a read costs time in step with the
  /// history and a page chooses how often the window asks. A scroll position can be as old as the
  /// last history change. `liveInteractionData` reads past the kept value.
  var interactionData: Data? {
    if let restoredState { return restoredState }

    if let kept = keptInteraction { return kept }

    return readInteraction()
  }

  /// The record read now, for a tab that is closing, where a stale scroll position would be lost.
  var liveInteractionData: Data? {
    if let restoredState { return restoredState }

    return readInteraction()
  }

  /// Counts the changes that make the kept record stale. The applet keys its own kept description
  /// on it, so a change here reaches the applet without a second signal.
  private(set) var historyVersion = 0

  /// The last record read, or nil when nothing is kept. The inner nil is a tab with no page.
  private var keptInteraction: Data??

  private func readInteraction() -> Data? {
    var record: Data?

    if isMaterialized, webView.url != nil { record = webView.interactionState as? Data }

    if let record, committedURL != nil { lastReadInteraction = record }

    keptInteraction = .some(record)

    return record
  }

  /// The history changed: a commit, a finish, a step, a same-document navigation, or a load. A
  /// title or a loading toggle is not one.
  private func historyChanged() {
    keptInteraction = nil
    historyVersion &+= 1
  }

  // MARK: Loading

  /// Loads an address that already passed the scheme rule for its source. The caller checks it,
  /// since a refusal is the caller's to present. `assumed` is set when the policy chose HTTPS for
  /// a scheme-less address, which is the one load that can offer plain HTTP when it fails.
  ///
  /// `byUser` is true for an address the user typed. Such a load on a web view that already exists
  /// arms the bound for a content process that never answers.
  func load(_ url: URL, assumed: AssumedLoad? = nil, byUser: Bool = false) {
    let existed = isMaterialized
    let held = restoredState

    loadState = .loading(error: nil, history: nil)
    gate.resetForLoad()
    lastRequested = url
    historyChanged()
    failedLoad = nil
    self.assumed = assumed
    gate.cancelPending()

    if let held { webView.interactionState = held }

    if byUser { userNavigation.typedLoad() } else { userNavigation.end() }

    webView.load(URLRequest(url: url))

    if byUser, existed { hangRecovery.arm(.typed(url, assumed)) }
  }

  /// Records that the stored address was refused, so selecting the tab again does not try it again.
  /// The pane explains the refusal in place of a page, and the history records it once. The stored
  /// address stays in the description. The refusal never commits a page, so the rule that limits
  /// what a commit stores does not touch it. The user's own load clears the explanation.
  func refuseStoredAddress(_ address: String, _ refusal: SchemeRefusal) {
    let page = LoadErrorPage.refusedStoredAddress(address: address, refusal: refusal)

    loadState = loadState.showing(page)
    failedLoad = nil

    delegate?.tab(self, explained: page.historyText)
    delegate?.tabDidChange(self)
  }

  /// Starts the tab's first load from an address that passed the scheme rule for a restored tab.
  /// A reopened tab brings WebKit's history back instead, so its back and forward steps work. A tab
  /// with a history record and no address, such as a pop-up that opened on a preview, has only the
  /// record to bring back. With neither, there is nothing to load.
  func loadStored(_ url: URL?) {
    guard let state = restoredState else {
      if let url { load(url) }
      return
    }

    loadState = .loading(error: errorPage, history: nil)
    historyChanged()
    webView.interactionState = state

    if gate.restoresFormResult {
      gate.restoresFormResult = false

      loadState = loadState.showing(.formNotSent(address: url?.absoluteString ?? ""))

      delegate?.tabDidChange(self)
    }
  }

  func reload() -> HistoryMove {
    if errorPage != nil, let failed = failedLoad {
      load(failed.url, assumed: failed.assumed, byUser: true)
      return .moved
    }

    guard isMaterialized, webView.url != nil else { return reloadUnloaded() }

    leaveStop()

    gate.intent = .reload

    webView.reload()
    hangRecovery.arm(.restore)
    return .moved
  }

  /// Reload on a tab with no page. The stop stays until the tab knows it will load, so a refused
  /// address or a tab with nothing to bring back keeps its message.
  private func reloadUnloaded() -> HistoryMove {
    if let address = record.url {
      guard let stored = URL(string: address) else {
        return .refused(.notAnAddress, address: address)
      }

      switch SchemePolicy.decide(stored, source: .restored) {
      case .allow:
        leaveStop()
        loadStored(stored)
        return .moved

      case .refuse(let refusal):
        return .refused(refusal, address: address)
      }
    }

    guard restoredState != nil || lastRequested != nil else { return .unavailable }

    leaveStop()
    loadStored(lastRequested)
    return .moved
  }

  private func leaveStop() {
    guard isStopped else { return }

    loadState = loadState.withoutError()
    delegate?.tabDidChange(self)
  }

  func goBack() -> HistoryMove {
    guard isMaterialized, webView.backForwardList.backItem != nil else { return .unavailable }

    gate.intent = .history

    _ = webView.goBack()
    hangRecovery.arm(.restore)
    return .moved
  }

  func goForward() -> HistoryMove {
    guard isMaterialized, webView.backForwardList.forwardItem != nil else { return .unavailable }

    gate.intent = .history

    _ = webView.goForward()
    hangRecovery.arm(.restore)
    return .moved
  }

  /// Stops loading and drops every reference between the web view and this tab. A question the tab
  /// was waiting on is answered no, so the navigation it held ends.
  func close() {
    isClosed = true

    hangRecovery.cancel()
    gate.cancelPending()
    resetDownloads()
    loadState = loadState.withoutHistory().withoutError()
    failedLoad = nil
    assumed = nil
    observations = []

    unsent.onChange = nil
    unsent.remove()

    guard isMaterialized else { return }

    let view = webView
    let pid = hangPolicy.process.identifier(of: view)

    view.stopLoading()
    detach(view)

    if let pid { ClosedProcessWatch.watch(pid: pid, policy: hangPolicy) }
  }

  /// Takes every reference between the web view and this tab away, and the web view off the screen.
  private func detach(_ view: WKWebView) {
    LiveContentViews.remove(view)

    view.navigationDelegate = nil
    view.uiDelegate = nil
    (view as? BrowserWebView)?.onHistoryButton = nil
    (view as? BrowserWebView)?.onMouseUp = nil
    (view as? BrowserWebView)?.onMenuChoice = nil
    view.removeFromSuperview()
  }

  // MARK: Recovery

  /// The content process ended or hung. The tab drops its web view, so the next load builds a new
  /// one from the address and the history record, the way a reopened tab is built. It never asks
  /// the old process, which may never answer.
  ///
  /// What the page left waiting ends here. A question about sending a form again resolves as no.
  /// The unsent mark clears, since the input went with the process. A load after this never sends a
  /// form, since the new view restores history and the gate refuses a repeated post.
  private func replaceWebView() {
    hangRecovery.cancel()

    let state = restoredState ?? currentInteraction()

    gate.cancelPending()
    unsent.clear()
    unsent.remove()

    let old = current

    observations = []

    if let old { detach(old) }

    current = nil
    pageTitle = nil
    loadState = .idle(history: state)
    keptInteraction = nil
    isLoading = false
    currentURL = nil
    committedURL = nil
    canGoBack = false
    canGoForward = false
    showsSecurityWarning = false
    failedLoad = nil
    assumed = nil
    gate.noteWebViewLost()
    dialogsThisLoad = 0
    dialogsStopped = false
    warnedAboutDialogs = false
    scriptTabs.reset()
    resetDownloads()
    gesture = LinkGesture()
    windowGesture = LinkGesture()
    generation &+= 1

    historyChanged()
  }

  /// The history record of the page the tab has now. A view that has not committed a page reports a
  /// small record of its own, measured at 186 bytes against 719 for two pages, and a stop must
  /// never replace the history with it. Such a view stands in with the last record read from a view
  /// that did commit one.
  private func currentInteraction() -> Data? {
    guard isMaterialized else { return nil }

    guard committedURL != nil else { return lastReadInteraction }

    return readInteraction() ?? lastReadInteraction
  }

  /// Shows the message that the page stopped, when there is a page to bring back. A tab with
  /// nothing to restore stays blank, since the user lost no page.
  func showStopped() {
    guard hasPageToRestore else { return }

    let page = LoadErrorPage.contentStopped(
      address: record.url ?? lastRequested?.absoluteString ?? "", fromForm: gate.restoresFormResult)

    loadState = .stopped(page, history: restoredState)

    delegate?.tab(self, explained: page.historyText)
    delegate?.tabDidChange(self)
  }

  /// A tab the user is looking at loads again at once, as the user asked. Any other tab drops its
  /// hung view and waits to be selected or attached, since a reload there would wake a tab nobody
  /// is looking at.
  func replaceHung(_ replay: HangRecovery.Replay?) {
    endHungProcess()

    guard delegate?.tabIsViewed(self) == true else {
      lose(recovering: false)
      return
    }

    lose(recovering: true)

    switch replay {
    case .typed(let url, let assumed):
      load(url, assumed: assumed)

    case .restore, nil:
      _ = reload()
    }
  }

  /// Ends the content process of the hung view before the tab builds another. A new view for the
  /// same site could otherwise land in the process that still spins. A tab that shares the process
  /// hears it end, and recovers as it does from any content process that stops.
  private func endHungProcess() {
    guard let view = current, let identity = hangPolicy.process.identity(of: view) else { return }

    hangPolicy.process.kill(identity)
  }

  /// Replaces the web view, then tells the applet. `hadFocus` is read before the old view leaves.
  private func lose(recovering: Bool) {
    let hadFocus = current.map { Self.holdsFocus($0) } ?? false

    replaceWebView()
    delegate?.tab(self, didLoseContentWithFocus: hadFocus, recovering: recovering)
  }

  private static func holdsFocus(_ view: NSView) -> Bool {
    guard let responder = view.window?.firstResponder as? NSView else { return false }

    return responder.isDescendant(of: view)
  }

  // MARK: Observation

  private func observe(_ webView: WKWebView) {
    observations = [
      webView.observe(\.title) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.titleChanged() }
      },
      webView.observe(\.isLoading) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.stateChanged() }
      },
      webView.observe(\.canGoBack) { [weak self] _, _ in
        MainActor.assumeIsolated {
          self?.historyChanged()
          self?.stateChanged()
        }
      },
      webView.observe(\.canGoForward) { [weak self] _, _ in
        MainActor.assumeIsolated {
          self?.historyChanged()
          self?.stateChanged()
        }
      },
      webView.observe(\.url) { [weak self] _, _ in
        MainActor.assumeIsolated {
          self?.historyChanged()
          self?.stateChanged()
        }
      },
      webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.stateChanged() }
      },
    ]
  }

  private func titleChanged() {
    let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
    pageTitle = title

    if webView.url != nil, BrowserDescription.storableURL(webView.url) != nil {
      record.title = BrowserDescription.boundedTitle(title)
    }

    delegate?.tabDidChange(self)
  }

  private func stateChanged() {
    currentURL = webView.url
    isLoading = webView.isLoading
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
    showsSecurityWarning = SecurityIndicator.warns(
      url: webView.url, hasOnlySecureContent: webView.hasOnlySecureContent)

    delegate?.tabDidChange(self)
  }

  private func committed() {
    userNavigation.end()
    historyChanged()
    loadState = loadState.withoutError()
    failedLoad = nil
    assumed = nil
    dialogsThisLoad = 0
    dialogsStopped = false
    warnedAboutDialogs = false
    scriptTabs.reset()
    resetDownloads()
    committedURL = webView.url
    unsent.clear()
    gate.noteCommit(item: webView.backForwardList.currentItem)

    guard let stored = BrowserDescription.storableURL(webView.url) else { return }

    record.url = stored
    record.title = BrowserDescription.boundedTitle(webView.title)
  }

  /// `isProvisional` is true for a load that failed before the page committed. Only those can put
  /// an error page in the pane. A failure after commit leaves the page that did load.
  private func report(_ error: any Error, for url: URL?, isProvisional: Bool = false) {
    let failure = error as NSError

    if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }

    let failing = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)

    // Any interruption that no decision of this tab ended is a failure the user has not heard about.
    if failure.domain == "WebKitErrorDomain", failure.code == 102,
      gate.consumeCancelled(matching: failing?.absoluteString)
    {
      return
    }

    if isProvisional, let failing, let page = loadErrorPage(for: failure, failing: failing) {
      loadState = loadState.showing(page)
      failedLoad = (failing, assumed)

      delegate?.tab(self, explained: page.historyText)
      delegate?.tabDidChange(self)
      return
    }

    let address = AddressDisplay.bounded(
      failing?.absoluteString ?? url?.absoluteString ?? "the page")

    delegate?.tab(
      self, notice: .warning, text: "Could not load \(address). \(failure.localizedDescription)")
  }

  /// The page for a failed HTTPS load. A certificate failure always gets one, and never an action.
  /// A connection failure gets the offer only for the address whose HTTPS the browser assumed,
  /// and never for a host under HSTS.
  private func loadErrorPage(for error: NSError, failing: URL) -> LoadErrorPage? {
    guard failing.scheme?.lowercased() == "https",
      let host = failing.host(percentEncoded: false)
    else { return nil }

    switch LoadFailure(error).kind {
    case .certificate:
      return .certificate(host: host, reason: error.localizedDescription)

    case .unreachable:
      guard let assumed, isSameServer(failing, assumed.url), !hsts.contains(host: host) else {
        return nil
      }

      return .offerHTTP(host: host, typed: assumed.typed)

    case .other:
      return nil
    }
  }

  /// Whether two HTTPS addresses name the same host and port. A redirect to another host is not
  /// the address the user typed, so it never earns the offer.
  private func isSameServer(_ a: URL, _ b: URL) -> Bool {
    a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
      && (a.port ?? 443) == (b.port ?? 443)
  }
}

extension BrowserTab: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    hangRecovery.sawLife()

    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }

    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

    // WebKit reports a script's click as a followed link, so only a real mouse-up seen in the view
    // makes a link the user's. Every link decision takes the note, whatever it loads, so a click
    // on one link cannot be spent on another. A link in a subframe is never the user's, since the
    // page chose that frame.
    let followedByUser =
      navigationAction.navigationType == .linkActivated && gesture.consume(at: clock())
      && navigationAction.sourceFrame.isMainFrame

    if followedByUser {
      loadOrigin = .user
      windowGesture.noteMouseUp(at: clock())
    }

    let byUserAction = userNavigation.decideAction(
      followedByUser: followedByUser, isMainFrame: isMainFrame,
      isRedirectLike: navigationAction.navigationType == .other)

    if navigationAction.shouldPerformDownload {
      switch SchemePolicy.decideDownload(url) {
      case .allow:
        // WebKit reports the navigation a download replaced as an interrupted load. The download
        // has its own outcome, so the load stays quiet.
        decideDownload(url, name: url.lastPathComponent, byUser: byUserAction) { allowed in
          decisionHandler(allowed ? .download : .cancel)
        }

      case .refuse(let refusal):
        cancel(url, notice: refusal.message(for: url.absoluteString), decisionHandler)
      }

      return
    }

    switch SchemePolicy.decide(url, source: .page, isMainFrame: isMainFrame) {
    case .allow:
      break

    case .refuse(let refusal):
      if navigationAction.navigationType == .linkActivated,
        case .unsupported(let scheme) = refusal, AppHandoff.mayHandOff(scheme: scheme)
      {
        gate.cancelledAddress = url.absoluteString
        decisionHandler(.cancel)

        if followedByUser {
          delegate?.tab(self, handOff: url)
        } else {
          delegate?.tab(self, notice: .warning, text: Self.unattendedHandOff(url))
        }

        return
      }

      cancel(url, notice: refusal.message(for: url.absoluteString), decisionHandler)
      return
    }

    // A reload, a swipe, a menu Reload, and a history step can each land on a form post. WebKit
    // reports the reload and the resubmit with their own types, and a history step as a step with
    // the post's method. One gate here covers every path that would send the form again. A form's
    // first submission, and a redirect it follows, are not these types.
    let intent = gate.takeIntent(isMainFrame: isMainFrame)

    if isMainFrame, ResendGate.repeatsPost(navigationAction) {
      resendOrRefuse(url, navigationAction, intent: intent, decisionHandler)
      return
    }

    if isMainFrame {
      gate.lastMainFrameMethod = navigationAction.request.httpMethod ?? "GET"
    }

    decisionHandler(.allow)
  }

  /// A response the browser cannot show, or one the server marks as an attachment, becomes a
  /// download. That holds for a frame too, since a subframe's attachment has nowhere to show.
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    hangRecovery.sawLife()

    guard let url = navigationResponse.response.url else {
      decisionHandler(.allow)
      return
    }

    if navigationResponse.isForMainFrame {
      hsts.noteResponse(
        from: url,
        header: (navigationResponse.response as? HTTPURLResponse)?
          .value(forHTTPHeaderField: "Strict-Transport-Security"))
    }

    let disposition = (navigationResponse.response as? HTTPURLResponse)?
      .value(forHTTPHeaderField: "Content-Disposition")?
      .trimmingCharacters(in: .whitespaces).lowercased()
    let isAttachment = disposition?.hasPrefix("attachment") ?? false

    let byUser = userNavigation.response(isMainFrame: navigationResponse.isForMainFrame)

    guard navigationResponse.canShowMIMEType, !isAttachment else {
      switch SchemePolicy.decideDownload(url) {
      case .allow:
        decideDownload(url, name: navigationResponse.response.suggestedFilename, byUser: byUser) {
          allowed in
          decisionHandler(allowed ? .download : .cancel)
        }

      case .refuse(let refusal):
        gate.cancelledAddress = url.absoluteString
        delegate?.tab(self, notice: .warning, text: refusal.message(for: url.absoluteString))
        decisionHandler(.cancel)
      }

      return
    }

    decisionHandler(.allow)
  }

  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    adopt(download)
  }

  func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    adopt(download)
  }

  /// Decides a download the policy allows. A download of the user's own click or load starts at
  /// once. The first few that a page starts by itself start as well. The next one waits for the
  /// pane's question, and a refused page has its downloads cancelled at the decision, where
  /// cancelling is safe.
  private func decideDownload(
    _ url: URL, name: String?, byUser: Bool, resolve: @escaping @MainActor (Bool) -> Void
  ) {
    let answer: @MainActor (Bool) -> Void = { [weak self] allowed in
      self?.gate.cancelledAddress = url.absoluteString
      resolve(allowed)
    }

    if byUser {
      answer(true)
      return
    }

    switch downloadHold.phase {
    case .granted:
      answer(true)

    case .refused:
      answer(false)

    case .waiting, .asking:
      holdDownload(DownloadHold.Held(name: name, resolve: answer))

    case .counting:
      guard !downloadHold.countStart() else {
        answer(true)
        return
      }

      guard delegate != nil else {
        answer(false)
        return
      }

      holdDownload(DownloadHold.Held(name: name, resolve: answer))
      downloadHold.setPhase(.waiting)
      delegate?.tabNeedsDownloadQuestion(self)
    }
  }

  private func holdDownload(_ decision: DownloadHold.Held) {
    if !downloadHold.hold(decision) { decision.resolve(false) }
  }

  /// The user let the page download until its next load. Every held decision starts its download.
  func grantDownloads() {
    downloadHold.setPhase(.granted)

    for decision in downloadHold.takeHeld() { decision.resolve(true) }
  }

  /// The user refused. Every held decision is cancelled, and the page's further downloads are
  /// cancelled until its next load. Returns how many were held.
  @discardableResult
  func refuseDownloads() -> Int {
    downloadHold.setPhase(.refused)

    let held = downloadHold.takeHeld()

    for decision in held { decision.resolve(false) }

    return held.count
  }

  /// Cancels every held decision and forgets the page's count. A close, a loss of the web view, or
  /// a new load ends what the page asked for, so nothing waits on a handler that has no page.
  private func resetDownloads() {
    let held = downloadHold.takeHeld()

    downloadHold.reset()

    for decision in held { decision.resolve(false) }
  }

  /// A download no pane holds would run with nobody to name it, so a tab with no delegate ends it.
  private func adopt(_ download: WKDownload) {
    guard let delegate else {
      download.cancel { _ in }
      return
    }

    delegate.tab(self, download: download)
  }

  /// Whether the entry the navigation lands on is one this tab saw a form post produce. WebKit
  /// has already made the target the current entry when the gate runs, so the entry's identity
  /// answers. A tab restored or reopened from history has seen none, so its post results never
  /// qualify, whatever address a seen post had.
  private func landsOnSeenPost() -> Bool {
    guard isMaterialized, let item = webView.backForwardList.currentItem else { return false }

    return gate.isPostResult(item)
  }

  /// The one place a form can be sent again. The user is asked, and the navigation waits for the
  /// answer. Only a repeat the applet's own Reload, Back, or Forward started can ask, and only
  /// onto a post this tab saw a form produce. Every other repeat is refused with no question. That
  /// covers a page's script, a swipe, which cannot be told from a script, a background tab, and a
  /// restored tab. A second repeat while one question is open is cancelled, not queued.
  private func resendOrRefuse(
    _ url: URL, _ action: WKNavigationAction, intent asked: ResendGate.Intent?,
    _ decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let address = AddressDisplay.bounded(url.absoluteString)

    guard ResendGate.intent(asked, covers: action), landsOnSeenPost(), let delegate else {
      cancel(
        url,
        notice:
          "Did not load \(address). The page came from a form, and loading it again would send the form again.",
        decisionHandler)
      return
    }

    guard !gate.isAsking else {
      gate.cancelledAddress = url.absoluteString
      decisionHandler(.cancel)
      return
    }

    let pending = PendingResend(decisionHandler)

    gate.hold(pending)

    let request = AppletConfirmation(
      title: "Send the form again?",
      detail: "\u{201C}\(address)\u{201D} came from a form. Loading it again sends the form to "
        + "the site a second time, which can repeat what the first one did.",
      confirmTitle: "Send Again", cancelTitle: "Cancel")

    Task { @MainActor [weak self, weak delegate] in
      var allowed = false

      if let self, let delegate {
        allowed = await delegate.tab(self, confirm: request)
      }

      guard let self else {
        pending.resolve(.cancel)
        return
      }

      gate.release(pending)

      if allowed, !pending.isResolved {
        pending.resolve(.allow)
      } else {
        if !pending.isResolved { gate.cancelledAddress = url.absoluteString }

        pending.resolve(.cancel)
      }
    }
  }

  private func cancel(
    _ url: URL, notice text: String,
    _ decisionHandler: @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    gate.cancelledAddress = url.absoluteString
    delegate?.tab(self, notice: .warning, text: text)
    decisionHandler(.cancel)
  }

  private static func unattendedHandOff(_ url: URL) -> String {
    "Did not open \(AddressDisplay.bounded(url.absoluteString)). A page can open another app only "
      + "from a click on its link, and this was not one."
  }

  /// A new load began, so an earlier error page no longer describes the pane. A failure of this
  /// load builds its own page when it earns one. Without this, a failed Back or a failed page
  /// navigation that builds none would leave the old offer over the pane.
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    hangRecovery.sawLife()

    userNavigation.started()

    guard let page = errorPage else { return }

    if case .formNotSent = page { return }

    loadState = loadState.withoutError()
    failedLoad = nil
    delegate?.tabDidChange(self)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    hangRecovery.sawLife()

    gate.intent = nil
    committed()
    stateChanged()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    hangRecovery.sawLife()
    historyChanged()
  }

  /// A page's content process ended, by a crash or because the system reclaimed its memory. The tab
  /// handles its own web view and nothing else's, since a pop-up that shares its opener's process
  /// gets its own call.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === current, !isClosed else { return }

    lose(recovering: false)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    hangRecovery.sawLife()

    userNavigation.end()

    gate.intent = nil
    report(error, for: nil, isProvisional: true)
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
    hangRecovery.sawLife()

    userNavigation.end()

    gate.intent = nil
    report(error, for: webView.url)
  }
}

extension BrowserTab: WKUIDelegate {
  /// Camera and microphone are denied. This is the backstop. The app has no usage strings, so WebKit
  /// hides the native API, and `MediaCaptureScript` answers a page's request. With usage strings,
  /// WebKit asks macOS before this method, so it cannot keep a system prompt away.
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    hangRecovery.sawLife()

    decisionHandler(.deny)
  }

  /// A page's own window, or a link that opens one, becomes a tab built from WebKit's
  /// configuration. The browser turns off `javaScriptCanOpenWindowsAutomatically`, so a script with
  /// no user gesture never reaches this method. The applet may still refuse, as for a scheme the
  /// browser does not load, or when scripts have opened too many tabs. A window the user asked
  /// for, with a real click or a menu choice, passes `byUser` and is never refused for the limit.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    hangRecovery.sawLife()

    let byUser = windowGesture.consume(at: clock())

    if byUser { loadOrigin = .user }

    return delegate?.tab(
      self, openWindowWith: configuration, for: navigationAction, byUser: byUser)?.webView
  }

  func webViewDidClose(_ webView: WKWebView) {
    hangRecovery.sawLife()

    delegate?.tabDidRequestClose(self)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    present(.alert, message, frame) { _ in completionHandler() }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    present(.confirm, message, frame) { completionHandler($0 == .accepted) }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    present(.prompt(defaultText: defaultText ?? ""), prompt, frame) { answer in
      if case .text(let text) = answer {
        completionHandler(text)
      } else {
        completionHandler(nil)
      }
    }
  }

  /// The user chose to stop this page's dialogs. Every later dialog is dismissed until the page
  /// loads again.
  func stopDialogs() {
    dialogsStopped = true
  }

  /// Hands a dialog to the applet, which owns its answer. Once the user has stopped the page's
  /// dialogs, the rest are dismissed and the user hears so once. A tab with no applet dismisses
  /// at once, since WebKit must hear back from every dialog exactly once.
  private func present(
    _ kind: PageDialog.Kind, _ message: String, _ frame: WKFrameInfo,
    completion: @escaping @MainActor (PageDialog.Answer) -> Void
  ) {
    hangRecovery.sawLife()

    let dialog = PageDialog(
      kind: kind, message: message,
      source: frame.request.url?.host(percentEncoded: false) ?? "", tab: self,
      offersToStop: dialogsThisLoad >= 1, completion: completion)

    guard let delegate else {
      dialog.answer(.dismissed)
      return
    }

    guard !dialogsStopped else {
      dialog.answer(.dismissed)

      if !warnedAboutDialogs {
        warnedAboutDialogs = true
        delegate.tab(
          self, notice: .warning,
          text:
            "You stopped dialogs from this page. The browser dismisses them until it loads again.")
      }

      return
    }

    dialogsThisLoad += 1
    delegate.tab(self, present: dialog)
  }
}

extension BrowserTab: HangRecoveryOwner {
  var watchedView: WKWebView? { current }

  var holdsDialog: Bool { delegate?.tabHoldsDialog(self) == true }

  var canAsk: Bool { delegate != nil }

  func askToReplace() async -> Bool {
    guard let delegate else { return false }

    return await delegate.tab(confirmReplacingUnresponsive: self)
  }
}
