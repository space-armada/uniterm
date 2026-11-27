import AppKit
import AppletFixtures
import XCTest

@testable import AppletKit

/// The per-command permission check in shared dispatch. The queue is stepped by hand.
///
/// These prove that a command whose power the caller lacks is refused before the applet sees it,
/// at submission and again at delivery, that one power never unlocks the other's commands, and
/// that the applet is handed the caller and the tab the host resolved. They cannot prove who the
/// caller is. The window's tests prove how its powers are found.
@MainActor
final class ControlDispatcherPermissionTests: XCTestCase {
  private var pending: [@MainActor () -> Void] = []

  private func dispatcher() -> ControlDispatcher {
    ControlDispatcher { [weak self] body in self?.pending.append(body) }
  }

  private func turn() {
    let bodies = pending
    pending = []
    for body in bodies { body() }
  }

  private func submission(_ name: String) -> AppletCommandSubmission {
    AppletCommandSubmission(
      appletType: PoweredFixture.typeID, schemaVersion: AppletSchemaVersion(0, 0), name: name,
      arguments: .object([:]))
  }

  private let grant = AppletCaller(grant: "connection 7")

  /// Catches a command that reaches the applet without its power, or one power that unlocks the
  /// other's commands.
  func testEachPowerUnlocksOnlyItsOwnCommands() {
    let dispatch = dispatcher()
    let applet = PoweredFixture()

    var results: [String: Result<JSONValue, AppletCommandError>] = [:]

    func send(_ name: String, holding powers: Set<AppletCommandPermission>) {
      dispatch.submit(
        submission(name), to: applet, authority: { nil },
        caller: { CommandCaller(identity: self.grant, permissions: powers) },
        reply: { results[name + powers.map(\.rawValue).sorted().joined()] = $0 })
    }

    send("go", holding: [])
    send("go", holding: [.browserRead])
    send("look", holding: [.browserNavigation])
    send("go", holding: [.browserNavigation])
    send("look", holding: [.browserRead])
    send("free", holding: [])
    turn()

    XCTAssertEqual(results["go"]?.failureCode, .permissionMissing)
    XCTAssertEqual(results["gobrowser-read"]?.failureCode, .permissionMissing)
    XCTAssertEqual(results["lookbrowser-navigation"]?.failureCode, .permissionMissing)
    XCTAssertNil(results["gobrowser-navigation"]?.failureCode)
    XCTAssertNil(results["lookbrowser-read"]?.failureCode)
    XCTAssertNil(results["free"]?.failureCode)
    XCTAssertEqual(applet.performed, 3, "only the three permitted commands reached the applet")
  }

  /// Catches a refusal that is not answered at once, or one that queues work.
  func testAMissingPowerIsAnsweredAtOnceAndNeverQueued() {
    let dispatch = dispatcher()
    let applet = PoweredFixture()
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(
      submission("go"), to: applet, authority: { nil }, caller: { .none },
      reply: { result = $0 })

    XCTAssertEqual(result?.failureCode, .permissionMissing)
    XCTAssertEqual(dispatch.queuedCount, 0)
    XCTAssertTrue(pending.isEmpty)

    if case .failure(let error)? = result {
      XCTAssertTrue(error.message.contains("browser-navigation"), error.message)
    }
  }

  /// Catches a power revoked between validation and delivery that still takes effect.
  func testAPowerLostAfterValidationLeavesNoEffect() {
    let dispatch = dispatcher()
    let applet = PoweredFixture()
    var held: Set<AppletCommandPermission> = [.browserNavigation]
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(
      submission("go"), to: applet, authority: { nil },
      caller: { CommandCaller(identity: self.grant, permissions: held) },
      reply: { result = $0 })

    XCTAssertNil(result)
    XCTAssertEqual(dispatch.queuedCount, 1)

    held = []
    turn()

    XCTAssertEqual(result?.failureCode, .permissionMissing)
    XCTAssertEqual(applet.performed, 0)
  }

  /// Catches a caller or tab the host named that the applet is not handed, and a tab handed to a
  /// command that named none.
  func testTheAppletIsHandedTheGrantAndTheTabTheHostResolved() {
    let dispatch = dispatcher()
    let applet = PoweredFixture()
    let tab = AppletTabID(epoch: 1, serial: 5)

    dispatch.submit(
      submission("go"), to: applet, authority: { nil },
      caller: { CommandCaller(identity: self.grant, permissions: [.browserNavigation]) },
      tab: tab, reply: { _ in })
    turn()

    XCTAssertEqual(applet.lastCaller, grant)
    XCTAssertEqual(applet.lastTab, tab)

    dispatch.submit(
      submission("free"), to: applet, authority: { nil }, reply: { _ in })
    turn()

    XCTAssertNil(applet.lastCaller)
    XCTAssertNil(applet.lastTab)
  }

  /// Catches a tab reference that does not read back as the ID it came from.
  func testATabReferenceRoundTrips() {
    let tab = AppletTabID(epoch: 0xDEAD_BEEF_0000_0001, serial: 42)

    XCTAssertEqual(AppletTabID(reply: tab.replyText), tab)

    for bad in ["", "1", "x-1", "1-x", "1-2-3", "-1"] {
      XCTAssertNil(AppletTabID(reply: bad), bad)
    }
  }
}

extension Result where Failure == AppletCommandError {
  fileprivate var failureCode: AppletCommandError.Code? {
    if case .failure(let error) = self { return error.code }

    return nil
  }
}
