import Foundation
import ScriptHost

/// Tells the user that something waits in the Pending Requests panel.
///
/// Every window's pending-permissions slot shows how many of the panel's rows wait for an answer.
/// Each row that appears also posts one line to the status bar, so its arrival is seen and stays in
/// the history. Grants and denials ask nothing, so they are not counted.
///
/// The owner calls `refresh()` after any change to the script host, the launch authority, or the
/// permission questions. A refresh with no new rows posts nothing, however often it runs.
@MainActor
public final class PendingRequestsIndicator {
  /// One waiting row, by what it is about. The kinds keep their own ID spaces.
  enum Key: Hashable {
    case review(UInt64)
    case undeclaredReview(UInt64)
    case request(UInt64)
    case launch(UInt64)
    case question(UInt64)
  }

  struct Item: Equatable {
    let key: Key
    let sentence: String
  }

  private let windows: WindowSet
  private let scriptHost: () -> ScriptHost?
  private var seen: Set<Key> = []

  /// The script host is read on each refresh, since scripting can start after the windows or not
  /// at all.
  public init(windows: WindowSet, scriptHost: @escaping () -> ScriptHost?) {
    self.windows = windows
    self.scriptHost = scriptHost
  }

  public func refresh() {
    let items = waitingItems()

    for item in items where !seen.contains(item.key) {
      windows.post(level: .info, text: "Pending request: \(item.sentence)")
    }

    seen = Set(items.map(\.key))

    if items.isEmpty {
      windows.clearWindowState(.pendingPermissions)
    } else {
      let label = items.count == 1 ? "1 request" : "\(items.count) requests"
      let verb = items.count == 1 ? "waits" : "wait"

      windows.setWindowState(
        .pendingPermissions,
        text: "\(label) \(verb) for your answer. Click to open Pending Requests.", label: label)
    }
  }

  /// The bar has one line, so a program is named by its file name. The panel shows the full path.
  static func sentence(for request: ScriptHost.PendingRequest) -> String {
    "\(request.shortProgramLabel), PID \(request.pid), asks for a pane."
  }

  /// The panel's waiting rows, in the panel's order, each with the words its row shows.
  func waitingItems() -> [Item] {
    let host = scriptHost()

    let reviews = (host?.controllerReviews ?? []).map { review in
      Item(
        key: .review(review.id),
        sentence: "\(review.name) (\(review.identity.controllerID)) waits for review.")
    }

    let undeclared = (host?.undeclaredReviews ?? []).map { review in
      Item(
        key: .undeclaredReview(review.id),
        sentence: "\(review.name) declares nothing and waits for review.")
    }

    let requests = (host?.allPendingRequests() ?? []).map { request in
      Item(key: .request(request.id), sentence: Self.sentence(for: request))
    }

    let launches = windows.launchAuthority.requests.map { request in
      Item(
        key: .launch(request.id),
        sentence:
          "\(request.launch.declaration.executable) wants to run in \(request.paneTitle).")
    }

    let questions = windows.permissionRequests.rows.map { row in
      Item(key: .question(row.id), sentence: "\(row.subject) asks: \(row.title).")
    }

    return reviews + undeclared + requests + launches + questions
  }
}
