import ControllerPackage
import ControllerTestSupport
import Darwin
import FileRouting
import Foundation
import PaneModel
import Preferences
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// A helper whose cheap check fails for the command, as a command replaced on disk under a running
/// app does, while the full check passes.
private struct StaleHelper: ControllerHelperIdentity {
  func refusal(forPeer token: AuditToken) -> String? { nil }

  func isRunningCommand(_ token: AuditToken) -> Bool { false }
}

/// A helper whose full check of a peer waits for the test. The cheap check answers at once, so the
/// host takes the peer for the command and then waits off the main actor, like an admission that
/// is in flight.
private struct GatedHelper: ControllerHelperIdentity {
  let gate: DispatchSemaphore

  func refusal(forPeer token: AuditToken) -> String? {
    gate.wait()

    return nil
  }

  func isRunningCommand(_ token: AuditToken) -> Bool { true }
}

/// A helper whose cheap check fails for the command and whose full check waits for the test, so a
/// peer's calls are held for as long as the test wants.
private struct StaleGatedHelper: ControllerHelperIdentity {
  let gate: DispatchSemaphore

  func refusal(forPeer token: AuditToken) -> String? {
    gate.wait()

    return nil
  }

  func isRunningCommand(_ token: AuditToken) -> Bool { false }
}

/// Script files that declare nothing: strict mode, the unsafe review, and what each choice grants.
///
/// The raw peers play the bundled command against a host that takes every peer for it. The runs
/// use the signed copy of the command that the controller tests use. The test is the user: it
/// answers each review through the same calls the Pending Requests panel makes.
@MainActor
final class UndeclaredFileTests: XCTestCase {
  private var directory: URL!
  private var work: URL!
  private var host: ScriptHost!
  private var settings: TestScriptSettings!
  private var clipboard: MemoryClipboard!
  private var refusals: [ScriptRefusal] = []
  private var peers: [FramedSocket] = []

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    settings = TestScriptSettings()
    clipboard = MemoryClipboard(text: "synthetic clipboard")
  }

  override func tearDown() async throws {
    for peer in peers { peer.shutdownAndClose() }

    host?.stop()
    settings.remove()
    try? FileManager.default.removeItem(at: directory)
    ControllerSnapshot.removeStale(in: work.appendingPathComponent("runs"))
    try? FileManager.default.removeItem(at: work)
  }

  private func startHost(helper: any ControllerHelperIdentity) throws {
    host = try ScriptFixtures.makeFileHost(
      directory: directory, work: work, helper: helper,
      onRefusal: { [weak self] in self?.refusals.append($0) }, clipboard: clipboard,
      settings: settings.store)
  }

  private func startCommandHost() throws {
    try startHost(helper: BundleHelperIdentity(helperURL: try HardenedHelper.url()))
  }

  // MARK: Helpers

  private func connect() async throws -> FramedSocket {
    let peer = try await ScriptFixtures.openPeer(host: host)

    peers.append(peer)

    return peer
  }

  private func read(_ peer: FramedSocket) async throws -> ScriptAppMessage {
    try await ScriptFixtures.readMessage(peer)
  }

  /// A raw peer that has begun an undeclared script and been told it waits for review.
  private func waitingPeer(
    name: String = "waiting.janet", capabilities: [String] = []
  ) async throws -> (peer: FramedSocket, review: UndeclaredReview) {
    let peer = try await connect()

    try peer.send(
      ScriptHelperMessage.undeclaredBegin(
        UndeclaredBegin(name: name, capabilities: capabilities)
      ).frame())

    guard case .controllerReviewing = try await read(peer) else {
      throw Unexpected(text: "the begin was not put before the user")
    }

    return (peer, try XCTUnwrap(host.undeclaredReviews.first))
  }

  /// A raw peer whose undeclared script the user admitted with `choice`.
  private func admittedPeer(
    _ choice: UndeclaredReviewChoice
  ) async throws -> (peer: FramedSocket, run: UndeclaredRun) {
    let (peer, review) = try await waitingPeer()

    XCTAssertNil(host.decideUndeclaredReview(review.id, choice))

    guard case .undeclaredAdmitted = try await read(peer) else {
      throw Unexpected(text: "the run was not admitted")
    }

    return (peer, try XCTUnwrap(host.allUndeclaredRuns().first))
  }

  private func call(
    _ peer: FramedSocket, _ call: ScriptCall, id: UInt32 = 1
  ) async throws -> ScriptResult {
    try peer.send(ScriptHelperMessage.request(id: id, call: call).frame())

    guard case .reply(let answered, let result) = try await read(peer), answered == id else {
      throw Unexpected(text: "the call was not answered")
    }

    return result
  }

  private func refusalText(_ result: ScriptResult) -> String? {
    if case .failure(.refused, let text) = result { return text }

    return nil
  }

  private func script(_ text: String, named name: String = "plain") throws -> URL {
    let file = work.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).janet")

    try Data(text.utf8).write(to: file)

    return file
  }

  private func runCommand(
    _ file: URL, allow: [String] = []
  ) throws -> HelperHandle {
    try ScriptFixtures.start(
      socket: host.instanceAddress, script: file, allow: allow, executable: try HardenedHelper.url()
    )
  }

  // MARK: Strict mode

  /// Catches an undeclared file that runs, or that starts to, in strict mode. The first form
  /// prints, so any output means code ran. The refusal must name the mode, the form to add, what
  /// cannot be declared, and the setting, with or without `--allow`.
  func testStrictModeRefusesAnUndeclaredFileBeforeItsFirstFormRuns() async throws {
    try startCommandHost()

    let marker = work.appendingPathComponent("strict-marker")
    let file = try script("(spit \"\(marker.path)\" \"x\")\n(print :ran)\n")

    for allow in [["fs-write"], ["fs-read", "fs-write"]] {
      let run = try await ScriptFixtures.finish(try runCommand(file, allow: allow))

      XCTAssertEqual(run.status, 77, run.standardError)
      XCTAssertEqual(run.standardOutput, "", "code ran in strict mode")
      XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "code ran")

      for fragment in [
        "strict mode", "(declare-permissions ...)", "ffi", "modules", "Script files",
      ] {
        XCTAssertTrue(run.standardError.contains(fragment), "\(fragment): \(run.standardError)")
      }
    }

    XCTAssertTrue(host.undeclaredReviews.isEmpty)
    XCTAssertTrue(host.controllerReviews.isEmpty)
  }

  /// Catches a stored mode this version does not know opening the permissive mode, end to end.
  func testAnUnknownStoredModeRefusesLikeStrict() async throws {
    settings.defaults.set("permissive", forKey: "scriptFileMode")
    try startCommandHost()

    let run = try await ScriptFixtures.finish(try runCommand(try script("(print :ran)\n")))

    XCTAssertEqual(run.status, 77, run.standardError)
    XCTAssertEqual(run.standardOutput, "")
    XCTAssertTrue(host.undeclaredReviews.isEmpty)
  }

  /// Pins a refused begin shutting the connection to a request that follows it at once. A clipboard
  /// read would ask the user if it were let through. It cannot prove the window itself: the queued
  /// close wins the race every time here, so the test passes without the refused mark too.
  func testARequestRightBehindARefusedBeginIsNeverServed() async throws {
    try startHost(helper: AcceptingHelper())

    var asked = false

    let watch = host.permissionRequests.changes.add { [host] in
      if host?.permissionRequests.rows.isEmpty == false { asked = true }
    }

    defer { _ = watch }

    let peer = try await connect()

    try peer.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "strict")).frame())
    try peer.send(ScriptHelperMessage.request(id: 1, call: .readClipboard).frame())

    guard case .controllerRefused = try await read(peer) else {
      return XCTFail("the begin was not refused in strict mode")
    }

    do {
      _ = try await read(peer)
      XCTFail("the refused connection was answered again")
    } catch {
      XCTAssertEqual(error as? WireError, .closed)
    }

    XCTAssertFalse(asked, "a request behind a refused begin reached the user")
    XCTAssertEqual(clipboard.reads, 0)
  }

  /// Catches strict mode reaching a program that is not the bundled command. A generic peer keeps
  /// the admission any program on the socket gets: its plain begin and its undeclared begin are
  /// served with no review, and its calls follow the pane rules.
  func testAGenericPeerKeepsItsAdmissionInStrictMode() async throws {
    try startHost(helper: RejectingHelper())

    let plain = try await connect()

    try plain.send(ScriptHelperMessage.begin(name: "plain").frame())

    guard case .ok = try await call(plain, .postStatus(level: .info, text: "hi")) else {
      return XCTFail("a generic peer's plain begin was not served")
    }

    let undeclared = try await connect()

    try undeclared.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "u")).frame())

    guard case .undeclaredAdmitted = try await read(undeclared) else {
      return XCTFail("a generic peer's undeclared begin was not admitted")
    }

    guard case .ok = try await call(undeclared, .postStatus(level: .info, text: "hi")) else {
      return XCTFail("a generic peer's undeclared session was not served")
    }

    XCTAssertTrue(host.undeclaredReviews.isEmpty)
    XCTAssertTrue(refusals.isEmpty, "\(refusals)")
  }

  /// Catches the real unsigned helper, which the app takes for any other program, being refused
  /// in strict mode.
  func testTheUnsignedHelperRunsAnUndeclaredFileInStrictMode() async throws {
    try startCommandHost()

    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("post-status"))

    XCTAssertEqual(run.status, 0, run.standardError)
  }

  /// Catches a command that fails the cheap check being admitted as a generic peer. The cheap check
  /// compares with a copy of the command's signature that an update on disk makes stale. The full
  /// check passes, so the peer is the command, and strict mode refuses its undeclared begin.
  func testACommandThatFailsTheCheapCheckIsStillHeldToStrictMode() async throws {
    try startHost(helper: StaleHelper())

    let peer = try await connect()

    try peer.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "stale")).frame())

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("a stale-cache command was admitted without a review")
    }

    XCTAssertTrue(text.contains("strict mode"), text)
  }

  /// Catches a stale-cache command's plain begin being served. Its call is sent at once, so the
  /// connection is also shown to hold calls until the check decides, and to serve none of them.
  func testAPlainBeginFromACommandThatFailsTheCheapCheckIsRefused() async throws {
    try startHost(helper: StaleHelper())

    let peer = try await connect()

    try peer.send(ScriptHelperMessage.begin(name: "stale").frame())
    try peer.send(
      ScriptHelperMessage.request(id: 1, call: .postStatus(level: .info, text: "early")).frame())

    do {
      _ = try await read(peer)
      XCTFail("a plain begin from the command was served")
    } catch {
      XCTAssertEqual(error as? WireError, .closed)
    }

    XCTAssertEqual(refusals, [.plainBeginFromCommand])
  }

  /// Catches calls held during the full check growing without bound. The connection stops reading
  /// at its in-flight limit, and a held call has no answer yet, so a flood never holds more than
  /// the limit. Every call is answered once the check passes.
  func testAFloodDuringTheFullCheckHoldsNoMoreThanTheInFlightLimit() async throws {
    settings.set(.unsafe)

    let gate = DispatchSemaphore(value: 0)

    try startHost(helper: StaleGatedHelper(gate: gate))

    let peer = try await connect()
    let limit = ScriptConnection.maxInFlight
    let sent = limit * 3

    try peer.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "flood")).frame())

    for id in 1...sent {
      try peer.send(
        ScriptHelperMessage.request(id: UInt32(id), call: .postStatus(level: .info, text: "x"))
          .frame())
    }

    var most = 0

    let filled = await waitUntil(timeout: .seconds(5)) {
      most = max(most, self.host.heldRequests.values.map(\.count).max() ?? 0)

      return most >= limit
    }

    // The flood is already sent, so a reader that kept reading would pass the limit within this
    // bounded wait. The wait ends when the time does.
    let grew = await waitUntil(timeout: .milliseconds(500)) {
      (self.host.heldRequests.values.map(\.count).max() ?? 0) > limit
    }

    most = max(most, host.heldRequests.values.map(\.count).max() ?? 0)
    gate.signal()

    XCTAssertFalse(grew, "the host held more calls than the in-flight limit")

    expect(filled, "the calls were never held")
    XCTAssertEqual(most, limit)

    var answered: Set<UInt32> = []

    while answered.count < sent {
      if case .reply(let id, _) = try await read(peer) { answered.insert(id) }
    }

    XCTAssertEqual(answered, Set((1...sent).map { UInt32($0) }))
  }

  /// Catches a stale-cache command skipping the one-session rule. Its file begin is admitted, and a
  /// second begin from the same process is refused.
  func testACommandThatFailsTheCheapCheckStillClaimsItsPlace() async throws {
    try startHost(helper: StaleHelper())

    let file = try script("(declare-permissions)\n(print :ran)\n", named: "declared")
    let first = try await connect()

    try first.send(
      ScriptHelperMessage.fileBegin(FileBegin(path: file.resolvingSymlinksInPath().path)).frame())

    guard case .fileAdmitted = try await read(first) else {
      return XCTFail("the declared file was not admitted")
    }

    let second = try await connect()

    try second.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "again")).frame())

    guard case .controllerRefused(let text) = try await read(second) else {
      return XCTFail("a second begin from the same process was not refused")
    }

    XCTAssertEqual(text, ScriptHost.secondSessionText)
  }

  /// Catches a plain begin from the bundled command being served. The command says whether its
  /// file declares anything, so a plain begin from it is script code on a second connection.
  func testAPlainBeginFromTheBundledCommandIsRefused() async throws {
    try startHost(helper: AcceptingHelper())

    let peer = try await connect()

    try peer.send(ScriptHelperMessage.begin(name: "plain").frame())

    do {
      _ = try await read(peer)
      XCTFail("a plain begin from the command was answered")
    } catch {
      XCTAssertEqual(error as? WireError, .closed)
    }

    XCTAssertEqual(refusals, [.plainBeginFromCommand])
  }

  // MARK: The unsafe review

  /// Catches code that runs before the answer, a review that leaves out the `--allow`
  /// capabilities, and a trust choice. The script prints in its first form, so output means code
  /// ran.
  func testUnsafeModeReviewsAnUndeclaredFileAndRunsNothingUntilAdmitted() async throws {
    settings.set(.unsafe)
    try startCommandHost()

    let marker = work.appendingPathComponent("unsafe-marker")
    let file = try script("(spit \"\(marker.path)\" \"x\")\n(print :ran)\n")
    let process = try runCommand(file, allow: ["fs-write", "net-connect"])

    expect(await waitUntil { !self.host.undeclaredReviews.isEmpty }, "no review was put up")

    let review = try XCTUnwrap(host.undeclaredReviews.first)

    XCTAssertEqual(review.name, file.lastPathComponent)
    XCTAssertEqual(review.capabilities, ["fs-write", "net-connect"])
    XCTAssertTrue(host.controllerReviews.isEmpty, "an undeclared file was reviewed as a controller")
    XCTAssertEqual(UndeclaredReviewChoice.allCases, [.reject, .askEachUse, .allowEverything])

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: marker.path),
      "code ran before the review was answered")

    let answeredAt = Date()

    XCTAssertNil(host.decideUndeclaredReview(review.id, .askEachUse))

    let run = try await ScriptFixtures.finish(process)

    XCTAssertEqual(run.status, 0, run.standardError)
    XCTAssertEqual(run.standardOutput, "ran\n")
    XCTAssertTrue(run.standardError.contains("waits for your approval"), run.standardError)

    // The first form wrote the marker. A write before the answer would be older than it.
    let written = try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate]

    XCTAssertGreaterThanOrEqual(try XCTUnwrap(written as? Date), answeredAt, "code ran too early")
  }

  /// Catches a rejected run starting, or a rejection that records a denial that would refuse the
  /// next run without asking.
  func testRejectingTheReviewRunsNothing() async throws {
    settings.set(.unsafe)
    try startCommandHost()

    let process = try runCommand(try script("(print :ran)\n"))

    expect(await waitUntil { !self.host.undeclaredReviews.isEmpty }, "no review was put up")

    let review = try XCTUnwrap(host.undeclaredReviews.first)

    XCTAssertNil(host.decideUndeclaredReview(review.id, .reject))

    let run = try await ScriptFixtures.finish(process)

    XCTAssertEqual(run.status, 77, run.standardError)
    XCTAssertEqual(run.standardOutput, "")
    XCTAssertTrue(run.standardError.contains("rejected"), run.standardError)
    XCTAssertTrue(host.undeclaredReviews.isEmpty)
    XCTAssertTrue(host.permissionRequests.denials.isEmpty)
  }

  /// Catches an undeclared file with a later declaration being reviewed or run. The command refuses
  /// it before it connects, so the app never sees the begin.
  func testALaterDeclarationIsRefusedBeforeAnyCodeRuns() async throws {
    settings.set(.unsafe)
    try startCommandHost()

    let file = try script("(print :ran)\n(declare-permissions {:kind :pane-control})\n")
    let run = try await ScriptFixtures.finish(try runCommand(file))

    XCTAssertEqual(run.status, 65, run.standardError)
    XCTAssertEqual(run.standardOutput, "")
    XCTAssertTrue(run.standardError.contains("must be the first form"), run.standardError)
    XCTAssertTrue(host.undeclaredReviews.isEmpty)
    XCTAssertTrue(host.allUndeclaredRuns().isEmpty)
  }

  /// Catches a call served before admission, while the run waits for review and while it is
  /// authenticated.
  func testARequestBeforeAdmissionIsRefused() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let (peer, review) = try await waitingPeer()
    let before = try await call(peer, .postStatus(level: .info, text: "early"))

    XCTAssertTrue(
      refusalText(before)?.contains("has not admitted this script") == true, "\(before)")

    XCTAssertNil(host.decideUndeclaredReview(review.id, .askEachUse))

    guard case .undeclaredAdmitted = try await read(peer) else {
      return XCTFail("the run was not admitted")
    }

    guard case .ok = try await call(peer, .postStatus(level: .info, text: "late"), id: 2) else {
      return XCTFail("an admitted run was refused")
    }
  }

  /// Catches an undeclared run joining no table. A second begin from the same process is refused,
  /// whichever way it begins.
  func testAnUndeclaredRunTakesPartInTheOneSessionRule() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    _ = try await waitingPeer()

    let second = try await connect()

    try second.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "second")).frame())

    guard case .controllerRefused(let text) = try await read(second) else {
      return XCTFail("a second begin was not refused")
    }

    XCTAssertEqual(text, ScriptHost.secondSessionText)
  }

  // MARK: The choices

  /// Catches Allow and Ask Each Use granting more than a plain script has: a clipboard call must
  /// ask, naming the run.
  func testAskEachUseKeepsAPlainScriptsClipboardQuestions() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let (peer, run) = try await admittedPeer(.askEachUse)

    XCTAssertEqual(run.choice, .askEachUse)

    try peer.send(ScriptHelperMessage.request(id: 5, call: .readClipboard).frame())
    expect(
      await waitUntil { !self.host.permissionRequests.rows.isEmpty }, "the clipboard did not ask")

    let row = try XCTUnwrap(host.permissionRequests.rows.first)

    XCTAssertEqual(row.sessionTitle, "Allow for This Run")
    XCTAssertEqual(clipboard.reads, 0)

    host.permissionRequests.decide(row.id, .deny)

    guard case .reply(5, .failure(.refused, _)) = try await read(peer) else {
      return XCTFail("a denied read was not refused")
    }
  }

  /// Catches Allow Everything asking for the clipboard, or covering a host launch. Both clipboard
  /// calls run with no question, and a host launch is not covered, so it asks each use.
  func testAllowEverythingLetsClipboardCallsRunWithoutAsking() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let (peer, run) = try await admittedPeer(.allowEverything)

    XCTAssertEqual(run.choice, .allowEverything)

    guard case .ok(let read) = try await call(peer, .readClipboard) else {
      return XCTFail("the clipboard read was not allowed")
    }

    XCTAssertEqual(read, Data([1]) + Data("synthetic clipboard".utf8))

    guard case .ok = try await call(peer, .writeClipboard(text: "replaced"), id: 2) else {
      return XCTFail("the clipboard write was not allowed")
    }

    XCTAssertEqual(clipboard.text, "replaced")
    XCTAssertTrue(host.permissionRequests.rows.isEmpty, "an allowed call asked")

    let covered = await host.coversLaunch(
      connection: run.connection, executable: "/usr/bin/git", directory: work.path,
      environmentKeys: [])

    XCTAssertFalse(covered, "Allow Everything covered a host launch")
  }

  /// Catches a revoked grant that still serves the run, and a revoked run that stays listed.
  func testRevokingAllowEverythingRefusesTheRunsNextCall() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let (peer, run) = try await admittedPeer(.allowEverything)

    guard case .ok = try await call(peer, .readClipboard) else {
      return XCTFail("the clipboard read was not allowed")
    }

    host.revokeUndeclaredRun(connection: run.connection)

    let after = try await call(peer, .readClipboard, id: 2)

    XCTAssertNotNil(refusalText(after), "\(after)")
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertTrue(host.allUndeclaredRuns().isEmpty)
  }

  /// Catches Allow Everything failing in the real command, or lasting past its run. The first run
  /// reads the clipboard with no question. The next run, admitted with Ask Each Use, asks.
  func testAllowEverythingRunsThroughTheCommandAndDoesNotCarryToTheNextRun() async throws {
    settings.set(.unsafe)
    try startCommandHost()

    let file = try script(
      "(import uniterm)\n(print (get (protect (uniterm/read-clipboard)) 0))\n")
    var token: ChangeObservers.Token? = host.answerUndeclaredReviews(with: .allowEverything)

    let first = try await ScriptFixtures.finish(try runCommand(file))

    XCTAssertEqual(first.status, 0, first.standardError)
    XCTAssertEqual(first.standardOutput, "true\n")
    XCTAssertTrue(host.permissionRequests.rows.isEmpty)
    expect(await waitUntil { self.host.allUndeclaredRuns().isEmpty }, "the run stayed listed")

    token = host.answerUndeclaredReviews(with: .askEachUse)

    let second = try runCommand(file)

    expect(
      await waitUntil { !self.host.permissionRequests.rows.isEmpty },
      "the next run did not ask for the clipboard")

    host.permissionRequests.decide(try XCTUnwrap(host.permissionRequests.rows.first).id, .deny)

    let denied = try await ScriptFixtures.finish(second)

    XCTAssertEqual(denied.standardOutput, "false\n")
    XCTAssertNotNil(token)
  }

  // MARK: Switching modes

  /// Catches a review that stays answerable after the user switched to strict. Every waiting
  /// review is refused, with a message naming strict mode.
  func testSwitchingToStrictRefusesEveryWaitingReview() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let (peer, _) = try await waitingPeer()

    settings.set(.strict)

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("a waiting review was not refused")
    }

    XCTAssertTrue(text.contains("strict mode"), text)
    XCTAssertTrue(host.undeclaredReviews.isEmpty)
  }

  /// Catches an answer that finishes after the switch starting the run. The switch is stored but
  /// the host has not yet seen the change, so the answer itself must read the mode again.
  func testAReviewAnswerAfterTheSwitchIsRefused() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let (peer, review) = try await waitingPeer()

    settings.set(.strict)

    let message = host.decideUndeclaredReview(review.id, .allowEverything)

    XCTAssertTrue(message?.contains("strict mode") == true, "\(String(describing: message))")

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("the run was not refused")
    }

    XCTAssertTrue(text.contains("strict mode"), text)
    XCTAssertTrue(host.allUndeclaredRuns().isEmpty)
    XCTAssertTrue(host.pendingClipboardGrantsAreEmpty)
  }

  /// Catches an admission that is in flight when the user switches. The full check of the command
  /// waits for the test, the mode changes, and the run is refused when the check finishes.
  func testAnAdmissionInFlightDuringTheSwitchIsRefused() async throws {
    settings.set(.unsafe)

    let gate = DispatchSemaphore(value: 0)

    try startHost(helper: GatedHelper(gate: gate))

    let peer = try await connect()

    try peer.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "inflight")).frame())
    expect(
      await waitUntil { !self.host.controllerAdmissions.isEmpty }, "the admission never began")

    settings.set(.strict)
    gate.signal()

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("an admission in flight was not refused")
    }

    XCTAssertTrue(text.contains("strict mode"), text)
    XCTAssertTrue(host.undeclaredReviews.isEmpty)
  }

  /// Catches a switch to strict ending a live run, and a Revoke that leaves one running. The run
  /// keeps serving its calls, and Revoke refuses the next one.
  func testALiveRunKeepsRunningAfterTheSwitchAndRevokeEndsIt() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let (peer, run) = try await admittedPeer(.askEachUse)

    let notified = Flag()
    let watch = settings.store.addObserver { notified.value = true }

    defer { watch.cancel() }

    settings.set(.strict)

    // Every observer of the store runs in one pass, so the host has seen the switch by now.
    expect(await waitUntil { notified.value }, "the store never reported the switch")

    guard case .ok = try await call(peer, .postStatus(level: .info, text: "still here")) else {
      return XCTFail("a live run was ended by the switch")
    }

    XCTAssertEqual(host.allUndeclaredRuns().map(\.connection), [run.connection])

    host.revokeUndeclaredRun(connection: run.connection)

    let after = try await call(peer, .postStatus(level: .info, text: "again"), id: 2)

    XCTAssertNotNil(refusalText(after), "\(after)")
  }

  /// Catches a switch to unsafe not reaching a run that starts afterward. The first run is refused
  /// in strict mode, and a run begun after the switch is reviewed.
  func testSwitchingToUnsafeAffectsRunsThatStartAfterward() async throws {
    try startCommandHost()

    let file = try script("(print :ran)\n")
    let early = try await ScriptFixtures.finish(try runCommand(file))

    XCTAssertEqual(early.status, 77, early.standardError)

    settings.set(.unsafe)

    let late = try runCommand(file)

    expect(
      await waitUntil { !self.host.undeclaredReviews.isEmpty }, "the later run was not reviewed")
    XCTAssertNil(
      host.decideUndeclaredReview(try XCTUnwrap(host.undeclaredReviews.first).id, .askEachUse))

    let run = try await ScriptFixtures.finish(late)

    XCTAssertEqual(run.standardOutput, "ran\n")
  }
}

extension ScriptHost {
  /// True when no connection holds a standing clipboard grant.
  fileprivate var pendingClipboardGrantsAreEmpty: Bool {
    clipboardGrants.values.allSatisfy { $0.isEmpty }
  }
}

private final class Flag {
  var value = false
}

private struct Unexpected: Error {
  let text: String
}
