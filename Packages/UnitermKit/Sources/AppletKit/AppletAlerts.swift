import Foundation
import StatusKit

/// What began a load. A notice about the load follows the origin it carries.
///
/// An applet sets the origin when it starts a load, and keeps it with that load's generation. A
/// later load sets its own. The origin is never a stored flag that outlives its load, since a
/// sort or filter the user makes on a restored pane is a user action.
public enum LoadOrigin: Sendable, Equatable {
  /// The first load of a pane that the host built from the saved layout of an earlier launch.
  case restore

  /// The user's own action: opening a file, a drop, choosing a sheet, or sorting.
  case user

  /// The same file read again, as when a file watcher sees a change or the user reverts.
  case reload
}

/// How an applet's alerts reach the user.
///
/// An alert is delivered by its origin. A restore-origin info goes to the history only, a
/// restore-origin warning raises the lesser unseen signal without a turn on the bar, and everything
/// else takes a turn on the bar. A notice that says its pane already explains it goes to the
/// history only, whatever its origin.
@MainActor
public struct AppletAlerts {
  public init() {}

  /// How a notice reaches the user.
  public static func delivery(of notice: AppletNotice, origin: LoadOrigin) -> StatusDelivery {
    guard notice.delivery == .message else { return .historyOnly }

    guard origin == .restore else { return .message }

    switch notice.level {
    case .info: return .historyOnly
    case .warning: return .attention
    case .error: return .message
    }
  }

  /// Delivers `notice` by its origin.
  public func deliver(
    _ notice: AppletNotice, origin: LoadOrigin, from applet: any Applet,
    to host: (any AppletHost)?
  ) {
    host?.applet(
      applet, send: Self.delivery(of: notice, origin: origin), level: notice.level,
      text: notice.text)
  }

  /// Delivers an alert that has no load behind it, such as a terminal notification.
  public func deliver(
    _ level: StatusLevel, _ text: String, from applet: any Applet, to host: (any AppletHost)?
  ) {
    deliver(AppletNotice(level, text), origin: .user, from: applet, to: host)
  }
}
