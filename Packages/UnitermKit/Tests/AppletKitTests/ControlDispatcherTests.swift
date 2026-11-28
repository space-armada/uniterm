import AppKit
import AppletFixtures
import XCTest

@testable import AppletKit

/// Shared dispatch, the one path every applet command takes, from a remote caller or an exec
/// driver alike. The queue is stepped by hand, so each test controls exactly when delivery runs.
///
/// These prove the order of the checks, delivery in order within a per-turn bound, the second
/// authority check at delivery, and that an applet with no commands refuses them all. They cannot
/// prove who the caller is. The window's and the driver's tests prove that.
@MainActor
final class ControlDispatcherTests: XCTestCase {
  private var pending: [@MainActor () -> Void] = []

  private func dispatcher(
    perTurn: Int = 32, queued: Int = 256, pendingLimit: Int = 64
  ) -> ControlDispatcher {
    ControlDispatcher(
      maximumQueued: queued, deliveriesPerTurn: perTurn, maximumPending: pendingLimit
    ) { [weak self] body in
      self?.pending.append(body)
    }
  }

  private func turn() {
    let bodies = pending
    pending = []
    for body in bodies { body() }
  }

  private func submission(
    _ name: String, _ arguments: JSONValue = .object([:]), type: String = SlidesFixture.typeID,
    version: AppletSchemaVersion = AppletSchemaVersion(0, 0)
  ) -> AppletCommandSubmission {
    AppletCommandSubmission(
      appletType: type, schemaVersion: version, name: name, arguments: arguments)
  }

  private func deck(_ titles: [String]) -> JSONValue {
    .object(["titles": .array(titles.map(JSONValue.string))])
  }

  /// Catches a check that runs out of order or not at all: each refused submission must be
  /// answered at once, with the right code, and leave the applet unchanged.
  func testEveryCheckRefusesBeforeAnyEffect() {
    let dispatch = dispatcher()
    let applet = SlidesFixture()
    var codes: [AppletCommandError.Code] = []

    let refused: [(AppletCommandSubmission, ControlDispatcher.Authority)] = [
      (submission("set-deck", deck(["a"])), { AppletCommandError(.refused, "no") }),
      (submission("set-deck", deck(["a"]), type: "fixture-chart"), { nil }),
      (submission("set-deck", deck(["a"]), version: AppletSchemaVersion(2, 0)), { nil }),
      (submission("set-deck", deck(["a"]), version: AppletSchemaVersion(1, 0)), { nil }),
      (submission("set-deck", deck(["a"]), version: AppletSchemaVersion(0, 1)), { nil }),
      (submission("launch-run"), { nil }),
      (submission("set-deck", .object(["titles": .string("a")])), { nil }),
      (submission("set-deck", .object(["titles": .array([]), "extra": .bool(true)])), { nil }),
      (submission("show-slide", .object(["index": .number(1.5)])), { nil }),
      (submission("show-slide", .array([])), { nil }),
    ]

    for (submitted, authority) in refused {
      dispatch.submit(submitted, to: applet, authority: authority) { result in
        if case .failure(let error) = result { codes.append(error.code) }
      }
    }

    XCTAssertEqual(
      codes,
      [
        .refused, .unsupportedApplet, .unsupportedVersion, .unsupportedVersion, .unsupportedVersion,
        .unknownCommand, .badArgument, .badArgument, .badArgument, .badArgument,
      ])
    XCTAssertEqual(dispatch.queuedCount, 0)
    XCTAssertTrue(pending.isEmpty)
    XCTAssertEqual(applet.titles, [])
  }

  /// Catches a grant revoked between validation and delivery that still takes effect.
  func testAuthorityRevokedAfterValidationLeavesNoEffect() {
    let dispatch = dispatcher()
    let applet = SlidesFixture()
    let allowed = Flag()
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(
      submission("set-deck", deck(["a"])), to: applet,
      authority: { allowed.on ? nil : AppletCommandError(.refused, "revoked") },
      reply: { result = $0 })

    XCTAssertNil(result)
    allowed.on = false
    turn()

    XCTAssertEqual(result, .failure(AppletCommandError(.refused, "revoked")))
    XCTAssertEqual(applet.titles, [])
  }

  /// Catches commands delivered out of order, or a flood delivered in one main-thread turn.
  func testDeliveryIsInOrderAndBoundedPerTurn() {
    let dispatch = dispatcher(perTurn: 2)
    let applet = SlidesFixture()
    var replies: [Int] = []

    dispatch.submit(
      submission("set-deck", deck(["a", "b", "c", "d", "e"])), to: applet, authority: { nil },
      reply: { _ in })

    for index in [3, 1, 4, 0] {
      dispatch.submit(
        submission("show-slide", .object(["index": .number(Double(index))])), to: applet,
        authority: { nil },
        reply: { result in
          if case .success(.object(let fields)) = result, case .number(let shown)? = fields["index"]
          {
            replies.append(Int(shown))
          }
        })
    }

    turn()
    XCTAssertEqual(replies, [3])
    turn()
    XCTAssertEqual(replies, [3, 1, 4])
    turn()
    XCTAssertEqual(replies, [3, 1, 4, 0])
    XCTAssertEqual(applet.index, 0)
  }

  /// Catches a queue that grows without bound, or a refusal past the bound that drops a command
  /// with no answer.
  func testAFullQueueRefusesWithBusyAndAnswersEveryCommand() {
    let dispatch = dispatcher(queued: 3)
    let applet = SlidesFixture()
    var answers: [AppletCommandError.Code?] = []

    for _ in 0..<5 {
      dispatch.submit(
        submission("status"), to: applet, authority: { nil },
        reply: { result in
          switch result {
          case .success: answers.append(nil)
          case .failure(let error): answers.append(error.code)
          }
        })
    }

    XCTAssertEqual(answers, [.busy, .busy])
    turn()
    XCTAssertEqual(answers, [.busy, .busy, nil, nil, nil])
  }

  /// Catches an applet error that is reported as success, or an applet error that changes state.
  func testAnAppletErrorChangesNothing() {
    let dispatch = dispatcher()
    let applet = SlidesFixture()
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(submission("set-deck", deck(["only"])), to: applet) {
      nil
    } reply: { _ in
    }
    dispatch.submit(submission("show-slide", .object(["index": .number(5)])), to: applet) {
      nil
    } reply: {
      result = $0
    }
    turn()

    guard case .failure(let error)? = result else {
      return XCTFail("\(String(describing: result))")
    }

    XCTAssertEqual(error.code, .badArgument)
    XCTAssertEqual(applet.index, 0)
  }

  /// Catches an applet without the hook, such as a terminal or a REPL, taking a command.
  func testAnAppletWithNoCommandsRefusesEveryCommand() {
    let dispatch = dispatcher()
    let applet = PlaceholderApplet(
      keeping: AppletDescription(type: "x", version: 1, payload: .null), reason: "synthetic")
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(submission("status", type: "placeholder"), to: applet) {
      nil
    } reply: {
      result = $0
    }

    XCTAssertEqual(
      result, .failure(AppletCommandError(.refused, "this pane's applet takes no commands")))
  }

  // MARK: Schema versions

  /// Catches a version check that stays an exact match, or one that lets a newer minor or another
  /// major run. This tests the rule for a declared-stable schema. The applet claims 1.2, so 1.0 through 1.2 run and 1.3, 2.0, and 0.9 are refused
  /// before any effect, with a message that names both versions.
  func testADeclaredStableAppletTakesItsMajorAndAnyMinorUpToItsOwn() {
    let dispatch = dispatcher()
    let applet = NotesFixture()
    var outcomes: [String] = []

    applet.schemaVersion = AppletSchemaVersion(1, 2)

    for (major, minor) in [(1, 0), (1, 2), (1, 3), (2, 0), (0, 9)] {
      dispatch.submit(
        submission(
          "set-notes", .object(["text": .string("v\(major).\(minor)")]), type: NotesFixture.typeID,
          version: AppletSchemaVersion(major, minor)),
        to: applet, authority: { nil },
        reply: { result in
          switch result {
          case .success: outcomes.append("ran")
          case .failure(let error): outcomes.append("\(error.code.rawValue): \(error.message)")
          }
        })
    }

    XCTAssertEqual(dispatch.queuedCount, 2, "only the accepted versions were queued")
    XCTAssertEqual(outcomes.count, 3, "the refusals were answered at once")
    XCTAssertTrue(outcomes.allSatisfy { $0.hasPrefix("unsupported-version") })
    XCTAssertTrue(outcomes[0].contains("1.3") && outcomes[0].contains("minor up to 2"), outcomes[0])
    XCTAssertTrue(outcomes[1].contains("2.0") && outcomes[1].contains("version 1"), outcomes[1])
    XCTAssertEqual(applet.text, "", "a refused version had an effect")

    turn()

    XCTAssertEqual(outcomes.suffix(2), ["ran", "ran"])
    XCTAssertEqual(applet.text, "v1.2")
  }

  // MARK: Pending replies

  private struct Waiting {
    let dispatch: ControlDispatcher
    let applet: NotesFixture
    let allowed: Flag
    let results: Results
  }

  @MainActor
  private final class Results {
    var all: [String: Result<JSONValue, AppletCommandError>] = [:]
  }

  private func wait(
    _ tag: String, for text: String, on setup: Waiting, allowed: Flag? = nil
  ) {
    let gate = allowed ?? setup.allowed

    setup.dispatch.submit(
      submission("wait-for-notes", .object(["contains": .string(text)]), type: NotesFixture.typeID),
      to: setup.applet,
      authority: { gate.on ? nil : AppletCommandError(.refused, "revoked") },
      reply: { setup.results.all[tag] = $0 })
  }

  private func waiting(pendingLimit: Int = 64) -> Waiting {
    Waiting(
      dispatch: dispatcher(pendingLimit: pendingLimit), applet: NotesFixture(), allowed: Flag(),
      results: Results())
  }

  private func set(_ text: String, on setup: Waiting) {
    setup.dispatch.submit(
      submission("set-notes", .object(["text": .string(text)]), type: NotesFixture.typeID),
      to: setup.applet, authority: { nil }, reply: { _ in })
    turn()
  }

  /// Catches a pending reply that answers early, never answers, or answers before an unrelated
  /// command that arrived later. The wait sits pending while an immediate command is answered, and
  /// the wait's answer comes later, when the notes hold its text.
  func testAPendingReplyAnswersLaterAndOutOfOrder() {
    let setup = waiting()

    wait("wait", for: "deadline", on: setup)
    turn()

    XCTAssertNil(setup.results.all["wait"])
    XCTAssertEqual(setup.dispatch.pendingCount, 1)

    set("not yet", on: setup)

    XCTAssertNil(setup.results.all["wait"], "the wait answered before its text came")

    set("the deadline moved", on: setup)

    XCTAssertEqual(setup.results.all["wait"], .success(.object(["length": .number(18)])))
    XCTAssertEqual(setup.dispatch.pendingCount, 0)
    XCTAssertEqual(setup.applet.waitingCount, 0)
  }

  /// Catches a wait whose condition already holds being held pending, and a pending reply the
  /// applet settles inside `perform`, before the dispatcher joins it.
  func testAWaitThatIsAlreadyTrueAnswersAtOnce() {
    let setup = waiting()

    set("the deadline", on: setup)
    wait("wait", for: "deadline", on: setup)
    turn()

    XCTAssertEqual(setup.results.all["wait"], .success(.object(["length": .number(12)])))
    XCTAssertEqual(setup.dispatch.pendingCount, 0)
  }

  /// Catches a pending reply that skips the second authority check. The grant is revoked while
  /// the applet still holds the reply, then the applet completes it. Nothing reaches the caller.
  func testACompletedPendingReplyChecksAuthorityAgain() {
    let setup = waiting()

    wait("wait", for: "deadline", on: setup)
    turn()

    setup.allowed.on = false
    set("deadline", on: setup)

    XCTAssertEqual(
      setup.results.all["wait"], .failure(AppletCommandError(.refused, "revoked")))
    XCTAssertEqual(setup.dispatch.pendingCount, 0)
  }

  /// Catches a revocation that leaves the caller waiting until the applet happens to answer. A
  /// revalidation fails the pending reply at once and tells the applet to drop it.
  func testRevalidationFailsAPendingReplyWhoseAuthorityEnded() {
    let setup = waiting()
    let other = Flag()

    wait("revoked", for: "never", on: setup)
    wait("kept", for: "never", on: setup, allowed: other)
    turn()

    setup.dispatch.revalidatePending()

    XCTAssertNil(setup.results.all["revoked"])
    XCTAssertNil(setup.results.all["kept"])

    setup.allowed.on = false
    setup.dispatch.revalidatePending()

    XCTAssertEqual(
      setup.results.all["revoked"], .failure(AppletCommandError(.refused, "revoked")))
    XCTAssertNil(setup.results.all["kept"], "a caller that kept its authority was failed")
    XCTAssertEqual(setup.applet.cancelledWaits, 1)
    XCTAssertEqual(setup.applet.waitingCount, 1)
    XCTAssertEqual(setup.dispatch.pendingCount, 1)

    set("never", on: setup)

    XCTAssertEqual(setup.results.all["kept"], .success(.object(["length": .number(5)])))
  }

  /// Catches an applet that is gone with callers still waiting on it, which would leave them
  /// waiting for a reply that can never come. The window's pane close and window close are proved
  /// in the WindowKit tests.
  func testAReleasedAppletFailsItsPendingRepliesOnRevalidation() {
    let setup = waiting()
    var applet: NotesFixture? = NotesFixture()
    let results = Results()

    wait("wait", for: "never", on: setup)
    setup.dispatch.submit(
      submission(
        "wait-for-notes", .object(["contains": .string("never")]), type: NotesFixture.typeID),
      to: applet!, authority: { nil }, reply: { results.all["gone"] = $0 })
    turn()

    applet = nil
    setup.dispatch.revalidatePending()

    XCTAssertEqual(
      results.all["gone"], .failure(AppletCommandError(.notFound, "the pane closed")))
    XCTAssertNil(setup.results.all["wait"])

    setup.dispatch.failAllPending(AppletCommandError(.notFound, "the window closed"))

    XCTAssertEqual(
      setup.results.all["wait"], .failure(AppletCommandError(.notFound, "the window closed")))
    XCTAssertEqual(setup.dispatch.pendingCount, 0)
  }

  /// Catches the contract held only by a comment. A command not marked as waiting that answers
  /// pending is an applet bug. The caller gets a `failed` error, the applet is told to drop the
  /// reply, and nothing stays pending. A marked command still waits.
  func testACommandNotMarkedAsWaitingCannotPend() {
    let setup = waiting()
    var violations: [String] = []

    setup.dispatch.reportContractViolation = { violations.append($0) }
    setup.applet.declaresWaits = false

    wait("wait", for: "never", on: setup)
    turn()

    XCTAssertEqual(setup.results.all["wait"]?.failureCode, .failed)
    XCTAssertEqual(setup.dispatch.pendingCount, 0)
    XCTAssertEqual(setup.applet.cancelledWaits, 1)
    XCTAssertEqual(setup.applet.waitingCount, 0)
    XCTAssertEqual(violations.count, 1)
    XCTAssertTrue(violations[0].contains("wait-for-notes"), violations[0])

    setup.applet.declaresWaits = true
    wait("marked", for: "never", on: setup)
    turn()

    XCTAssertNil(setup.results.all["marked"])
    XCTAssertEqual(setup.dispatch.pendingCount, 1)
    XCTAssertEqual(violations.count, 1)
  }

  /// Catches a window that holds an unbounded number of pending replies. A wait past the cap is
  /// answered busy, the applet is told to drop it, and the others still complete.
  func testThePendingCapRefusesTheExtraWaitAsBusy() {
    let setup = waiting(pendingLimit: 2)

    for tag in ["a", "b", "c"] { wait(tag, for: "go", on: setup) }

    turn()

    XCTAssertEqual(setup.dispatch.pendingCount, 2)
    XCTAssertEqual(setup.results.all["c"]?.failureCode, .busy)
    XCTAssertEqual(setup.applet.waitingCount, 2)
    XCTAssertEqual(setup.applet.cancelledWaits, 1)

    set("go", on: setup)

    XCTAssertEqual(setup.results.all["a"], .success(.object(["length": .number(2)])))
    XCTAssertEqual(setup.results.all["b"], .success(.object(["length": .number(2)])))
  }

  /// Catches a dispatcher that is released with callers still waiting, which would leave a
  /// continuation that never resumes.
  func testReleasingTheDispatcherAnswersEveryWaitingCaller() {
    var dispatch: ControlDispatcher? = dispatcher()
    let applet = NotesFixture()
    var answers: [AppletCommandError.Code?] = []

    for (name, text) in [("wait-for-notes", "never"), ("set-notes", "x")] {
      dispatch?.submit(
        submission(
          name, .object([name == "set-notes" ? "text" : "contains": .string(text)]),
          type: NotesFixture.typeID),
        to: applet, authority: { nil }, reply: { answers.append($0.failureCode) })

      if name == "wait-for-notes" { pending.removeFirst()() }
    }

    XCTAssertEqual(dispatch?.pendingCount, 1)
    XCTAssertEqual(dispatch?.queuedCount, 1)

    dispatch = nil
    pending = []

    XCTAssertEqual(answers, [.notFound, .notFound])
  }

  /// Catches an outlet that keeps events while no driver is attached, which would grow a queue.
  func testEventsWithNoSinkGoNowhere() {
    let applet = SlidesFixture()
    let sink = RecordingSink()

    for _ in 0..<10_000 { applet.button.performClick(nil) }

    XCTAssertFalse(applet.events.isConnected)
    XCTAssertTrue(applet.events.connect(sink))

    applet.button.performClick(nil)

    XCTAssertEqual(sink.events.count, 1, "events from before the sink were kept")

    applet.close()

    XCTAssertTrue(sink.closed)
    XCTAssertFalse(applet.events.connect(sink), "a closed outlet took a sink")
  }
}

@MainActor
private final class RecordingSink: AppletEventSink {
  var events: [String] = []
  var closed = false

  func deliver(event name: String, data: JSONValue) { events.append(name) }
  func outletClosed() { closed = true }
}

@MainActor
private final class Flag {
  var on = true
}

extension Result where Failure == AppletCommandError {
  fileprivate var failureCode: AppletCommandError.Code? {
    if case .failure(let error) = self { return error.code }

    return nil
  }
}
