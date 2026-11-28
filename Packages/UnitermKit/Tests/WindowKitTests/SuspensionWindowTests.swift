import AppKit
import AppletFixtures
import AppletKit
import ExecDriver
import PaneModel
import ProcessInspection
import ProcessTestSupport
import ScriptHost
import XCTest

@testable import WindowKit

/// A scripting host's stand-in that reports a local program its shell stopped, as `uniterm run`
/// is after Ctrl-Z. It acts for every pane, and uniterm never spawned it.
@MainActor
private final class StoppedByShellAuthority: ControllerAuthority {
  static let connection: UInt64 = 7

  func controllers(actingFrom window: UInt64, pane: NodeID) -> Set<UInt64> { [Self.connection] }
  func controllers(actingIn window: UInt64) -> Set<UInt64> { [Self.connection] }
  func revokeControllers(_ ids: Set<UInt64>) {}
  func controllerName(_ id: UInt64) -> String? { "run.janet (PID 99)" }

  func controllerProcessState(_ id: UInt64) -> ControllerProcessState { .other(stopped: true) }

  func coversLaunch(
    connection: UInt64, executable: String, directory: String, environmentKeys: [String]
  ) async -> Bool { false }
}

/// An applet that stands in for a REPL pane's helper. It follows the same protocol the REPL
/// applet does, with the state a stop and a continue would give, so the window's palette commands,
/// Suspend All, and slot are proven without a helper process. The REPL's own process handling is
/// proven where the helper runs.
@MainActor
private final class SuspendableApplet: FakeApplet, ControllerSuspending {
  var controllerSuspension: SuspensionState? = SuspensionState()
  var controllerName: String { "REPL" }
  private(set) var quitEnds = 0

  func suspendController() {
    controllerSuspension?.stopSent()
    controllerSuspension?.observe(stopped: true)
    host?.appletDidChange(self)
  }

  func resumeController() {
    controllerSuspension?.continueSent()
    controllerSuspension?.observe(stopped: false)
    host?.appletDidChange(self)
  }

  func endControllerForQuit() { quitEnds += 1 }
}

/// Real windows with real driver processes, to prove what the window shows and does for Suspend
/// and Resume. They cannot prove how the badge, strip, slot, and menu look. The UI test and the
/// user's own eyes do.
@MainActor
final class SuspensionWindowTests: XCTestCase {
  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()

    addTeardownBlock { @MainActor in
      // A stopped driver is continued before it is closed, so nothing outlives the test frozen.
      for controller in fixture.windows.controllers {
        for attachment in controller.execAttachments.values {
          if let pid = attachment.channel?.pid {
            killpg(pid, SIGCONT)
          }
        }
      }

      fixture.cleanUp()
    }

    return fixture
  }

  private func waitUntil(
    _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)

    while !condition() {
      guard Date() < deadline else {
        return XCTFail("timed out waiting until \(what)", file: file, line: line)
      }

      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Runs a driver that connects and reads, in the window's focused pane.
  private func startDriver(_ fixture: ExecPaneFixture, in controller: MainWindowController)
    async throws -> NodeID
  {
    let pane = controller.focusedPane

    try controller.declareExecDriver(fixture.declaration("drain"), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver connects") {
      controller.execAttachments[pane]?.channel?.isConnected == true
    }

    return pane
  }

  private func suspension(_ controller: MainWindowController, _ pane: NodeID) -> SuspensionState? {
    controller.execAttachments[pane]?.channel?.suspension
  }

  /// Catches a suspension that shows nowhere, or a strip that offers no way back. The palette's
  /// Suspend stops the focused pane's driver. Its strip then says so, says page code keeps
  /// running, and offers Resume. The badge lists the driver with Resume, and says it too.
  func testSuspendShowsOnTheStripAndTheBadgeAndResumeUndoesIt() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = try await startDriver(fixture, in: controller)
    let before = controller.control(of: pane)

    XCTAssertTrue(controller.canSuspendControllers(of: pane))
    XCTAssertFalse(controller.canResumeControllers(of: pane))

    controller.dispatch(.suspendControllers)

    await waitUntil("the driver reads as suspended") {
      suspension(controller, pane)?.isSuspendedByUniterm == true
    }

    let status = try XCTUnwrap(controller.execStatus(of: pane))

    XCTAssertTrue(status.isSuspended)
    XCTAssertEqual(status.action, "Resume")
    XCTAssertTrue(status.text.contains(SuspensionWording.pageCodeNote), status.text)

    let mark = controller.controlMark(for: pane)

    XCTAssertEqual(mark.controllerLines.map(\.state), [.suspended])
    XCTAssertTrue(mark.summary.contains { $0.contains(SuspensionWording.pageCodeNote) })

    let view = try XCTUnwrap(controller.paneArea.paneView(for: pane))

    view.controlMark = mark

    let titles = view.controlMenu().items.map(\.title)

    XCTAssertTrue(titles.contains { $0.hasPrefix("Resume ") }, "\(titles)")
    XCTAssertFalse(titles.contains { $0.hasPrefix("Suspend ") })

    XCTAssertFalse(controller.canSuspendControllers(of: pane))
    XCTAssertTrue(controller.canResumeControllers(of: pane))

    view.onExecAction?()

    await waitUntil("the driver reads as running") {
      suspension(controller, pane)?.isSuspended == false
    }

    XCTAssertEqual(
      controller.control(of: pane), before, "the suspension changed the pane's control")
    XCTAssertNotNil(controller.execAttachments[pane]?.owner)
    XCTAssertEqual(controller.execAttachments[pane]?.channel?.phase, .connected)
  }

  /// Catches a Resume All that continues a process something else stopped, and a Suspend All that
  /// misses a window. Two windows each run a driver, and a third driver party stops one from
  /// outside. Suspend All stops only the one that runs, the slot counts it in every window, and
  /// Resume All continues it and leaves the outside stop alone.
  func testSuspendAllAndResumeAllAcrossWindowsTouchOnlyWhatUnitermStopped() async throws {
    let fixture = try makeFixture()
    let first = try fixture.openWindow()
    let firstPane = try await startDriver(fixture, in: first)
    let second = try fixture.openWindow()
    let secondPane = try await startDriver(fixture, in: second)
    let outsidePid = try XCTUnwrap(second.execAttachments[secondPane]?.channel?.pid)

    XCTAssertEqual(kill(outsidePid, SIGSTOP), 0)

    await waitUntil("the outside stop shows") {
      suspension(second, secondPane)?.isSuspended == true
    }

    XCTAssertNil(
      fixture.windows.windowStates.text(of: .suspendedControllers), "outside stop counted")

    fixture.windows.suspendAllControllers()

    await waitUntil("the first driver is suspended by uniterm") {
      suspension(first, firstPane)?.isSuspendedByUniterm == true
    }

    XCTAssertEqual(
      suspension(second, secondPane)?.madeByUniterm, false,
      "Suspend All took over a stop that was not its own")
    XCTAssertEqual(fixture.windows.windowStates.label(of: .suspendedControllers), "1 suspended")

    for controller in fixture.windows.controllers {
      XCTAssertEqual(
        controller.windowStates.label(of: .suspendedControllers), "1 suspended",
        "a window did not get the slot")
    }

    let text = try XCTUnwrap(fixture.windows.windowStates.text(of: .suspendedControllers))

    XCTAssertTrue(text.contains(SuspensionWording.pageCodeNote), text)
    XCTAssertEqual(first.suspendedMenuEntries().count, 1)

    fixture.windows.resumeAllControllers()

    await waitUntil("the first driver runs again") {
      suspension(first, firstPane)?.isSuspended == false
    }

    XCTAssertEqual(
      suspension(second, secondPane)?.isSuspended, true,
      "Resume All continued a driver that uniterm did not stop")
    XCTAssertNil(fixture.windows.windowStates.text(of: .suspendedControllers), "the slot stayed")

    second.dispatch(.resumeControllers)

    await waitUntil("the pane's own Resume continues the outside stop") {
      suspension(second, secondPane)?.isSuspended == false
    }
  }

  /// Catches a suspension that reaches a driver that starts afterwards. Suspend acts on the
  /// controllers running when it is chosen, so a driver started later runs.
  func testADriverStartedAfterSuspendAllRunsAndIsNotSuspended() async throws {
    let fixture = try makeFixture()
    let first = try fixture.openWindow()
    let firstPane = try await startDriver(fixture, in: first)

    fixture.windows.suspendAllControllers()

    await waitUntil("the first driver is suspended") {
      suspension(first, firstPane)?.isSuspendedByUniterm == true
    }

    let second = try fixture.openWindow()
    let secondPane = try await startDriver(fixture, in: second)

    // Cost: this 100 ms wait proves a negative. A driver that was wrongly suspended would stay
    // stopped, and no event marks the stop that never came. A real process is the only proof.
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(suspension(second, secondPane)?.isSuspended, false)
    XCTAssertEqual(second.execAttachments[secondPane]?.channel?.phase, .connected)
  }

  /// Catches a revoked driver that loses its way back. The run's revoked flag is the one a revoke
  /// sets. The driver stays suspended and keeps its channel, and its strip and the window slot
  /// still offer Resume.
  func testARevokedDriverStaysSuspendedAndStillOffersResume() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = try await startDriver(fixture, in: controller)

    controller.dispatch(.suspendControllers)

    await waitUntil("the driver is suspended") {
      suspension(controller, pane)?.isSuspendedByUniterm == true
    }

    controller.execAttachments[pane]?.revoked = true
    controller.refreshControlMarks()

    XCTAssertEqual(suspension(controller, pane)?.isSuspended, true)
    XCTAssertEqual(controller.execStatus(of: pane)?.action, "Resume")
    XCTAssertEqual(controller.suspendedMenuEntries().count, 1)
    XCTAssertEqual(fixture.windows.windowStates.label(of: .suspendedControllers), "1 suspended")

    fixture.windows.resumeAllControllers()

    await waitUntil("the revoked driver runs again") {
      suspension(controller, pane)?.isSuspended == false
    }
  }

  /// Catches a shell-stopped program that gets a Resume it cannot honor, or that the slot counts.
  /// uniterm did not start it, so its badge says its shell stopped it, names `fg`, and has no
  /// Suspend or Resume for it.
  func testAShellStoppedProgramShowsItsShellStoppedItAndGetsNoResume() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    let authority = StoppedByShellAuthority()

    controller.controllerAuthority = authority
    controller.refreshControlMarks()

    let mark = controller.controlMark(for: pane)

    XCTAssertEqual(mark.controllerLines.map(\.state), [.stoppedByShell])
    XCTAssertNil(mark.controllerLines.first?.target)

    let line = try XCTUnwrap(mark.summary.first { $0.contains("Stopped by its shell") })

    XCTAssertTrue(line.contains("fg"), line)

    let view = try XCTUnwrap(controller.paneArea.paneView(for: pane))

    view.controlMark = mark

    let titles = view.controlMenu().items.map(\.title)

    XCTAssertFalse(
      titles.contains { $0.hasPrefix("Resume") || $0.hasPrefix("Suspend") }, "\(titles)")
    XCTAssertNil(fixture.windows.windowStates.text(of: .suspendedControllers))
    XCTAssertFalse(controller.canResumeControllers(of: pane))
    withExtendedLifetime(authority) {}
  }

  /// Catches a REPL that controls no pane being out of reach of the commands. It has no badge, yet
  /// the palette's Suspend and Resume, Suspend All, the window slot, and the slot's menu all reach
  /// it, and a quit hands it to be ended.
  func testAReplWithNoBadgeIsReachedByTheCommandsTheSlotAndTheQuit() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let applet = SuspendableApplet()

    fixture.nextApplet = { applet }
    controller.openPane(.hosted(typeID: "fake"), axis: .row)

    let pane = controller.focusedPane

    XCTAssertTrue(controller.paneArea.applet(for: pane) === applet)
    XCTAssertFalse(controller.controlMark(for: pane).isShown, "the REPL grew a badge")
    XCTAssertTrue(controller.canSuspendControllers(of: pane))

    controller.dispatch(.suspendControllers)

    XCTAssertEqual(applet.controllerSuspension?.isSuspendedByUniterm, true)
    XCTAssertEqual(fixture.windows.windowStates.label(of: .suspendedControllers), "1 suspended")
    XCTAssertEqual(controller.suspendedMenuEntries().map(\.title), ["Resume REPL"])

    controller.resume(try XCTUnwrap(controller.suspendedMenuEntries().first).target)

    XCTAssertEqual(applet.controllerSuspension?.isSuspended, false)
    XCTAssertNil(fixture.windows.windowStates.text(of: .suspendedControllers))

    fixture.windows.suspendAllControllers()

    XCTAssertEqual(applet.controllerSuspension?.isSuspendedByUniterm, true)

    fixture.windows.endDriversForQuit()

    XCTAssertEqual(applet.quitEnds, 1, "the quit did not reach the suspended REPL")

    fixture.windows.resumeAllControllers()

    XCTAssertEqual(applet.controllerSuspension?.isSuspended, false)
  }
}
