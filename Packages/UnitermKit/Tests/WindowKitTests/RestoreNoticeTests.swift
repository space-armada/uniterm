import AppKit
import AppletKit
import DefaultsTestSupport
import LayoutKit
import PaneModel
import Preferences
import StatusKit
import Theme
import XCTest

@testable import WindowKit

/// An applet that loads something on start and tells the bar about it through the shared alert
/// helper, the way the viewers do. It loads with the origin the window starts it with.
@MainActor
private final class LoadingApplet: Applet {
  let typeID = "loading"
  let view = NSView()
  var title = "Loading"
  let segments: [AppletSegment] = []
  let isRunningSomething = false
  let publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: "Loading"))
  weak var host: (any AppletHost)?

  private var alerts = AppletAlerts()

  /// What the window said built the applet when it started it.
  private(set) var startedWith: StartOrigin?

  func start(origin: StartOrigin) {
    startedWith = origin
    alerts.deliver(
      AppletNotice(.info, "Moved. Found at the new path."), origin: origin.loadOrigin, from: self,
      to: host)
    alerts.deliver(
      AppletNotice(.warning, "Rows were cut."), origin: origin.loadOrigin, from: self, to: host)
  }

  func close() {}
  func focus() {}
  func describe() -> AppletDescription {
    AppletDescription(type: typeID, version: 1, payload: .string(title))
  }
}

/// A launch that restores many panes, through the real window, host, and status center.
@MainActor
final class RestoreNoticeTests: XCTestCase {
  private let testDefaults = TestDefaults(prefix: "uniterm-restore-notice")

  override func tearDown() async throws {
    testDefaults.discard()
  }

  private func controller(
    panes: Int, center: StatusCenter = StatusCenter()
  ) throws -> MainWindowController {
    let store = SettingsStore(defaults: testDefaults.defaults)

    let children = (1...panes).map {
      (
        SavedNode.pane(
          id: NodeID(rawValue: UInt64($0)),
          applet: AppletDescription(type: "loading", version: 1, payload: .string("Pane \($0)"))),
        1.0
      )
    }

    let saved = savedWindow(
      tree: savedSplit(UInt64(panes + 1), .row, children), focus: 1, mark: UInt64(panes + 1))

    return try MainWindowController(
      appearance: AppearanceController(store: store), settings: store, statusCenter: center,
      restoring: RestoredWindow(saved: saved),
      restoreApplet: { description in
        let applet = LoadingApplet()

        if case .string(let name) = description.payload { applet.title = name }

        return applet
      },
      makeApplet: { _, _ in LoadingApplet() })
  }

  /// Catches a launch whose many restored panes bury current activity. Twelve panes each load with
  /// an info and a warning. Every one lands in the history. None takes a turn on the bar. The
  /// warnings raise the lesser signal, and no error signal rises.
  func testALaunchThatRestoresManyPanesTakesNoTurnsAndKeepsEveryRecord() throws {
    let restored = try controller(panes: 12)
    defer { restored.window?.close() }

    restored.showWindow(nil)

    let center = restored.statusCenter

    XCTAssertNil(center.display, "\(String(describing: center.display))")
    XCTAssertEqual(center.queue.pendingCount, 0)
    XCTAssertEqual(center.history.count, 24)
    XCTAssertEqual(center.history.filter { $0.level == .warning }.count, 12)
    XCTAssertEqual(Set(center.history.compactMap(\.source.paneID)).count, 12)
    XCTAssertTrue(center.hasUnseenWarning)
    XCTAssertEqual(center.queue.unseenWarningCount, 12)
    XCTAssertFalse(center.hasUnseenError)
  }

  /// Catches a pane reopened by undo that is told it is a launch restore. Undo is a user action,
  /// so its notices post normally.
  func testAPaneReopenedByUndoPostsNormally() throws {
    let restored = try controller(panes: 2)
    defer { restored.window?.close() }

    restored.showWindow(nil)

    XCTAssertNil(restored.statusCenter.display)

    restored.paneArea.focus(NodeID(rawValue: 2))
    restored.dispatch(.close)
    restored.reopenClosed()

    XCTAssertEqual(restored.paneIDs.count, 2)
    XCTAssertEqual(restored.statusCenter.display?.message.level, .info)

    let first = try XCTUnwrap(restored.paneArea.applet(for: NodeID(rawValue: 1)) as? LoadingApplet)
    let reopened = try XCTUnwrap(
      restored.paneIDs.compactMap { restored.paneArea.applet(for: $0) as? LoadingApplet }
        .first { $0 !== first && $0.startedWith == .user })

    XCTAssertEqual(first.startedWith, .restore)
    XCTAssertEqual(reopened.startedWith, .user)
  }
}
