import AppKit
import AppletKit
import PaneModel
import StatusKit

/// The host an applet holds. It is bound to one pane when the applet takes the pane, and it posts
/// for that pane only.
///
/// The pane ID is a stable identity. It does not depend on the pane still being in the tree, so a
/// message from an applet that outlives its pane keeps the ID it had. The `applet` argument of each
/// call is ignored for identity, so an applet cannot post as another pane.
///
/// The window owns the host's lifetime. It holds each one weakly bound to its applet and drops the
/// entries of applets that are gone.
@MainActor
final class PaneStatusHost: AppletHost {
  let pane: NodeID
  private weak var window: MainWindowController?
  private weak var bound: (any Applet)?
  private var lastTitle: String

  init(pane: NodeID, applet: any Applet, window: MainWindowController) {
    self.pane = pane
    self.window = window
    bound = applet
    lastTitle = applet.title
  }

  private var source: StatusSource {
    if let bound { lastTitle = bound.title }

    return .pane(id: pane.rawValue, name: lastTitle)
  }

  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String
  ) -> StatusRecordID? {
    window?.statusCenter.deliver(delivery, level: level, source: source, text: text)
  }

  func appletDidExit(_ applet: any Applet) {
    window?.appletDidExit(applet)
  }

  func appletDidChange(_ applet: any Applet) {
    window?.appletDidChange(applet)
  }

  func appletTabsDidChange(_ applet: any Applet) {
    window?.appletTabsDidChange(applet)
  }

  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool {
    guard let window else { return false }

    return await window.applet(applet, confirm: request)
  }

  func applet(_ applet: any Applet, askPermission request: AppletPermissionRequest) async
    -> AppletPermissionAnswer
  {
    guard let window else { return .deny }

    return await window.applet(applet, askPermission: request)
  }

  func issueCloseStamp() -> UInt64 {
    window?.issueCloseStamp() ?? 0
  }

  func applet(
    _ applet: any Applet, sessionStarted tab: AppletTabID, pid: pid_t, started: Int,
    generation: UInt64
  ) {
    window?.applet(
      applet, in: pane, sessionStarted: tab, pid: pid, started: started, generation: generation)
  }

  func applet(_ applet: any Applet, sessionEnded tab: AppletTabID, pid: pid_t, started: Int) {
    window?.applet(applet, in: pane, sessionEnded: tab, pid: pid, started: started)
  }

  func applet(_ applet: any Applet, open file: URL) {
    window?.applet(applet, in: pane, open: file)
  }
}
