import AppKit
import StatusKit
import Theme

/// One slot an applet fills in the status bar, such as a mode or a line and column.
public struct AppletSegment: Sendable, Equatable {
  public enum Style: Sendable, Equatable {
    case normal
    case emphasized
    case warning
    case error
  }

  public var symbolName: String?
  public var text: String?
  public var style: Style

  public init(symbolName: String? = nil, text: String? = nil, style: Style = .normal) {
    self.symbolName = symbolName
    self.text = text
    self.style = style
  }
}

/// A question an applet asks the user. The host shows it, names the pane, and returns the answer.
public struct AppletConfirmation: Sendable, Equatable {
  public var title: String
  public var detail: String
  public var confirmTitle: String
  public var cancelTitle: String

  /// What in the pane asks, such as the tab a request came from. The host names it in place of
  /// the applet's title, which follows the selected tab. Nil names the applet.
  public var subject: String?

  public init(
    title: String, detail: String, confirmTitle: String, cancelTitle: String,
    subject: String? = nil
  ) {
    self.title = title
    self.detail = detail
    self.confirmTitle = confirmTitle
    self.cancelTitle = cancelTitle
    self.subject = subject
  }
}

/// A permission an applet asks the user for on behalf of programs in a pane. The user may allow
/// the one request, allow requests of the same kind for the rest of the session, or deny it.
public struct AppletPermissionRequest: Sendable, Equatable {
  public var title: String
  public var detail: String

  /// What in the pane asks, as for a confirmation.
  public var subject: String?

  /// The session button says exactly what it covers, such as every program in one terminal tab.
  public var sessionTitle: String

  /// What one denial covers, such as reads in one tab under one control generation. Requests with
  /// the same scope from the same pane share one question, and after a denial they are refused
  /// without one until the user asks to be asked again. Nil asks each request on its own.
  public var scope: String?

  public init(
    title: String, detail: String, subject: String? = nil, sessionTitle: String,
    scope: String? = nil
  ) {
    self.title = title
    self.detail = detail
    self.subject = subject
    self.sessionTitle = sessionTitle
    self.scope = scope
  }
}

/// The user's answer to a permission request.
public enum AppletPermissionAnswer: Sendable, Equatable {
  case deny
  case allowOnce
  case allowForSession
}

/// The pane side of the applet contract. The host knows which pane an applet runs in, so it fills in
/// the message source.
@MainActor
public protocol AppletHost: AnyObject {
  /// Delivers `text` the way `delivery` says, and admits a new history record for it. Returns the
  /// record's ID. The protocol has no default for it, so a host cannot drop a delivery unnoticed.
  @discardableResult
  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String
  ) -> StatusRecordID?

  /// The applet has nothing left to run, so its pane should close.
  func appletDidExit(_ applet: any Applet)

  /// The title or the segments changed.
  func appletDidChange(_ applet: any Applet)

  /// The applet's tab list changed: a tab opened, closed, or was selected, or a tab's title or
  /// details changed. It fires for tabs in the background too, which `appletDidChange` does not
  /// report.
  func appletTabsDidChange(_ applet: any Applet)

  /// Asks the user. Nothing happens until the user answers.
  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool

  /// Asks the user for a permission. Nothing happens until the user answers. A host that cannot
  /// ask answers deny.
  func applet(_ applet: any Applet, askPermission request: AppletPermissionRequest) async
    -> AppletPermissionAnswer

  /// The next close stamp of the window. Stamps only grow, and pane closes draw from the same
  /// counter, so the window can order a closed tab against a closed pane. An applet asks for one
  /// when it records a close, after any question has been answered.
  func issueCloseStamp() -> UInt64

  /// Reports that a terminal or REPL session started in the given tab. The PID and start time
  /// identify the spawned process. The session generation identifies this session instance within
  /// the tab. The host records this as a session root for authority checking.
  func applet(
    _ applet: any Applet, sessionStarted tab: AppletTabID, pid: pid_t, started: Int,
    generation: UInt64)

  /// Reports that a session ended in the given tab. The host removes the session root.
  func applet(_ applet: any Applet, sessionEnded tab: AppletTabID, pid: pid_t, started: Int)

  /// The user clicked a path in the pane, and the pane checked that the path is the file it
  /// showed. The host routes it as an open from this pane, beside the pane.
  func applet(_ applet: any Applet, open file: URL)
}

extension AppletHost {
  /// A turn on the status bar, an entry in the history, and the unseen signal of the level.
  public func applet(_ applet: any Applet, post level: StatusLevel, text: String) {
    self.applet(applet, send: .message, level: level, text: text)
  }

  /// A host that has no way to open files says so, so a click never fails silently.
  public func applet(_ applet: any Applet, open file: URL) {
    self.applet(applet, post: .warning, text: "uniterm cannot open files from this pane.")
  }

  /// A host that has no way to ask denies, so a permission is never granted by omission.
  public func applet(_ applet: any Applet, askPermission request: AppletPermissionRequest) async
    -> AppletPermissionAnswer
  { .deny }
}

/// What built an applet that is about to start.
public enum StartOrigin: Sendable, Equatable {
  /// The window rebuilt the applet from the saved layout of an earlier launch.
  case restore

  /// Anything else: a new pane, a pane reopened by undo, or a launcher swap.
  case user

  /// The origin of the first load the applet begins.
  public var loadOrigin: LoadOrigin {
    switch self {
    case .restore: return .restore
    case .user: return .user
    }
  }
}

/// How an applet answers a request to reopen one of its closed tabs.
public enum TabReopenResult: Sendable, Equatable {
  /// The tab is back. The title names it for the window's message.
  case reopened(title: String)

  /// The applet holds no closed tab with this stamp.
  case missing

  /// The tab could not come back, and the applet is unchanged. The entry stays for another try.
  /// The reason is what the window shows after the tab's name. It says why, and what to do next
  /// when the applet knows. The window adds a full stop when the reason has none.
  case failed(title: String, reason: String)
}

/// How an applet answers a request to close its current tab.
public enum TabCloseResult: Sendable, Equatable {
  /// The tab closed.
  case closed

  /// The user was asked and said no, or a close of the same tab is already waiting for an answer.
  case declined

  /// The applet has no tab to close. Closing the last tab is a pane close, which the host owns.
  case nothingToClose
}

/// What a pane runs. Every applet implements this contract.
///
/// The host sends the lifecycle events: `start`, `willQuit`, and `close`. It sends each when it
/// happens and does nothing else on the applet's behalf. It never keeps an applet alive after
/// closing it, and it never stops or signals the applet's work itself. Hiding a view is not an
/// event, so an applet in a hidden window or a hidden pane keeps running. Each applet decides what
/// an event means for its own content.
///
/// Undo reopens a closed pane from its description, in the same place, with the same kind of
/// applet. An applet that wants an undo to bring back more saves it in the description's undo-only
/// part, which a layout file never holds.
@MainActor
public protocol Applet: AnyObject {
  var typeID: String { get }

  /// The view the pane hosts. It stays the same for the applet's life.
  var view: NSView { get }

  var title: String { get }
  var segments: [AppletSegment] { get }

  /// The tabs the palette finds. It is never empty. An applet with nothing to switch between
  /// publishes one tab for its whole session. The applet tells the host when it changes, with
  /// `appletTabsDidChange`.
  var publishedTabs: AppletTabList { get }

  /// True when closing the applet would kill work that undo cannot bring back.
  var isRunningSomething: Bool { get }

  /// What a confirmation dialog calls the parts of the applet that are running something. An
  /// applet with tabs names each such tab, by title or by command. An applet that is not running
  /// anything names nothing.
  var runningLabels: [String] { get }

  /// Work a close would lose that saving keeps, such as pin edits not yet written to their file.
  /// Nil when there is none. Closing the pane, its window, or the app asks Save, Don't Save, or
  /// Cancel first.
  var unsavedWork: AppletUnsavedWork? { get }

  /// Saves the unsaved work. It may ask the user where, so it can take a while. True when the work
  /// is saved. False when the user cancelled or the save failed, which the applet reports itself,
  /// and the close does not go ahead.
  func saveUnsavedWork() async -> Bool

  var host: (any AppletHost)? { get set }

  /// The directory the applet's current work is in, as an absolute local path. A new pane opened
  /// from this one starts there. An applet with no such concept, or with no usable directory right
  /// now, returns nil and says nothing.
  var currentDirectory: String? { get }

  /// The applet is in a pane and on screen. It begins its work.
  ///
  /// The origin says what built the applet. `restore` means the window rebuilt it from the saved
  /// layout of an earlier launch, so the loads it begins are a restore and its notices say so. A
  /// pane reopened by undo, a launcher swap, and a new pane pass `user`. The origin has no default.
  /// An applet with no loads ignores it.
  func start(origin: StartOrigin)

  /// The host is done with the applet, and it is unusable afterwards. What the applet does next is
  /// its own choice. It may end its work at once, finish it after a delay, or save more state into
  /// its description. Work it keeps alive after close must be bounded in time and visible to the
  /// user.
  func close()

  /// The app is quitting, and the layout is saved as soon as this returns. The applet puts into
  /// its description what is too costly to keep there all the time. The host sends it only when
  /// this instance saves the layout. An applet with nothing of that kind does nothing.
  func willQuit()

  /// Selects the tab with this ID. Returns false when the applet has no such tab, as when it
  /// closed. An applet with one tab selects nothing and returns true when the ID is that tab's.
  func selectTab(id: AppletTabID) -> Bool

  /// Gives the applet keyboard focus.
  func focus()

  /// Closes the applet's current tab, after asking when it is running something. The answer says
  /// whether it closed, the user declined, or the applet has no tab to close. Only the last lets
  /// the host close the pane. An applet without tabs always answers that it has none.
  func closeCurrentTab() async -> TabCloseResult

  /// The stamps of the closed tabs the applet can reopen, newest first. The applet keeps the list.
  /// The host keeps no copy. An applet without tabs reports none.
  var closedTabStamps: [UInt64] { get }

  /// Reopens the closed tab with this stamp, in its former place. A failure keeps the entry, adds
  /// no tab, and leaves the selection as it was.
  func reopenTab(stamp: UInt64) -> TabReopenResult

  func describe() -> AppletDescription

  /// Tells the applet the palette to draw its own chrome with. The host calls it when the applet
  /// is installed and whenever the palette changes.
  func apply(_ palette: ThemePalette)

  /// Tells the applet its pane's control state. The host calls it as the applet takes a pane,
  /// before it starts, and on every change. A change that makes the pane controlled arrives before
  /// any program can address the pane, so the applet tightens its own policies first. An applet
  /// with no policy that depends on control ignores it.
  func controlDidChange(_ control: PaneControl)

  /// The host draws its control badge over the applet's top right corner, and this is how far in
  /// from the applet's trailing edge the badge reaches, gap included. Zero when no badge shows. An
  /// applet with a bar along its top edge keeps its trailing controls clear of that width.
  func hostBadgeReachDidChange(_ width: CGFloat)
}

extension Applet {
  public func willQuit() {}

  public func controlDidChange(_ control: PaneControl) {}

  public func hostBadgeReachDidChange(_ width: CGFloat) {}

  public func closeCurrentTab() async -> TabCloseResult { .nothingToClose }

  public var closedTabStamps: [UInt64] { [] }

  public func reopenTab(stamp: UInt64) -> TabReopenResult { .missing }

  public func apply(_ palette: ThemePalette) {}

  public func selectTab(id: AppletTabID) -> Bool {
    publishedTabs.contains(id)
  }

  public var currentDirectory: String? { nil }

  public var unsavedWork: AppletUnsavedWork? { nil }

  public func saveUnsavedWork() async -> Bool { true }

  /// An applet with one part running names itself by its title.
  public var runningLabels: [String] {
    isRunningSomething ? [title] : []
  }
}

/// Unsaved work an applet holds, as a close dialog names it.
public struct AppletUnsavedWork: Sendable, Equatable {
  /// What the dialog lists, such as the file's name. It is shown as is, so it carries no
  /// program-supplied text.
  public let label: String

  public init(label: String) {
    self.label = label
  }
}
