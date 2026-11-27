import AppKit
import AppletTestSupport
import StatusKit
import XCTest

@testable import AppletKit

@MainActor
final class AppletAlertsTests: XCTestCase {
  private func applet() -> PlaceholderApplet {
    PlaceholderApplet(
      keeping: AppletDescription(type: "x", version: 1, payload: .null), reason: "test")
  }

  /// Catches a delivery table that drifts from the settled restore rule. Each row is worked out
  /// from the rule: restore info goes to history, restore warnings raise attention only, errors
  /// and every other origin take a turn, and a pane that says it already stays history only.
  func testTheDeliveryFollowsOriginAndLevel() {
    let table: [(LoadOrigin, StatusLevel, AppletNotice.Delivery, StatusDelivery)] = [
      (.restore, .info, .message, .historyOnly),
      (.restore, .warning, .message, .attention),
      (.restore, .error, .message, .message),
      (.user, .info, .message, .message),
      (.user, .warning, .message, .message),
      (.reload, .info, .message, .message),
      (.reload, .warning, .message, .message),
      (.restore, .warning, .historyOnly, .historyOnly),
      (.user, .error, .historyOnly, .historyOnly),
    ]

    for (origin, level, own, expected) in table {
      let notice = AppletNotice(level, "x", delivery: own)

      XCTAssertEqual(
        AppletAlerts.delivery(of: notice, origin: origin), expected,
        "\(origin) \(level) \(own)")
    }
  }

  func testAnAlertIsDeliveredAtOnceAsItsOriginSays() {
    let alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()

    alerts.deliver(AppletNotice(.warning, "cut"), origin: .restore, from: applet, to: host)
    alerts.deliver(AppletNotice(.warning, "later"), origin: .user, from: applet, to: host)

    XCTAssertEqual(host.sent.map(\.delivery), [.attention, .message])
  }
}
