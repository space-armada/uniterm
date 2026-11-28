import ControllerPackage
import ControllerTestSupport
import ControllerTrust
import Darwin
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import SourceAccess
import StatusKit
import XCTest

@testable import ScriptHost

/// The startup review, remembered trust, and the typed clipboard, end to end: the real bundle-like
/// command runs real packages against a host whose user is this test. The test answers each
/// review and each permission question through the same calls the Pending Requests panel makes.
@MainActor
final class ControllerConsentTests: XCTestCase {
  private var directory: URL!
  private var work: URL!
  private var trust: URL!
  private var host: ScriptHost!
  private let spawned = SpawnedHelpers()
  private var windows: FakeWindowAPI!
  private var clipboard: MemoryClipboard!
  private var watch: ChangeObservers.Token?

  /// The plain scripts here run in unsafe mode, and each undeclared review is answered to ask on
  /// each use.
  private var settings: TestScriptSettings!
  private var undeclaredWatch: ChangeObservers.Token?

  /// How the test answers each startup review it sees. Nil leaves reviews waiting.
  private var reviewAnswer: ControllerReviewChoice?

  /// How the test answers each waiting operation. Nil leaves it waiting.
  private var operationAnswer: ((PermissionRequests.Row) -> PermissionRequests.Answer?)?

  /// Every review the test saw, by ID, and every answer it gave an operation.
  private var reviewsSeen: [UInt64: ControllerReview] = [:]
  private var operationAnswers: [(title: String, answer: PermissionRequests.Answer)] = []

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    trust = work.appendingPathComponent("trust")
    clipboard = MemoryClipboard(text: "synthetic clipboard")
    settings = TestScriptSettings(mode: .unsafe)

    let center = StatusCenter()

    windows = FakeWindowAPI()

    // The listener holds no command identity here. The tests of a generic peer and a REPL pane run
    // the unsigned SwiftPM helper as a program that is not the bundled command, and a listener
    // that held the command's identity would refuse it for the identity it sends.
    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows,
      controllers: ControllerSettings(
        runsRoot: work.appendingPathComponent("runs"),
        helper: BundleHelperIdentity(helperURL: try HardenedHelper.url()), trustDirectory: trust),
      clipboard: clipboard, settings: settings.store)
    host.start()
    undeclaredWatch = host.answerUndeclaredReviews(with: .askEachUse)
    watch = host.changes.add { [weak self] in self?.answerWhatWaits() }

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    host.stop()
    settings.remove()
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: work)
  }

  private func answerWhatWaits() {
    for review in host.controllerReviews {
      reviewsSeen[review.id] = review

      if let reviewAnswer {
        Task { @MainActor in await self.host.decideReview(review.id, reviewAnswer) }
      }
    }

    guard let operationAnswer else { return }

    for row in host.permissionRequests.rows {
      guard let answer = operationAnswer(row) else { continue }

      operationAnswers.append((row.title, answer))
      host.permissionRequests.decide(row.id, answer)
    }
  }

  // MARK: Helpers

  private func package(
    _ entry: String, permissions: [String], format: Int = ControllerDescriptor.format,
    id: String = "dev.uniterm.fixture.consent",
    signedWith key: (any ControllerSigningKey)? = nil
  ) throws -> URL {
    var builder = ControllerPackageBuilder(files: [
      "main.janet": Data(("(import uniterm)\n" + entry).utf8)
    ])

    builder.id = id
    builder.format = format
    builder.permissions = permissions

    return try builder.write(
      signedWith: key, to: work.appendingPathComponent("package-\(UUID().uuidString.prefix(6))"))
  }

  private static let paneControl = #"{"kind": "pane-control"}"#
  private static let navigation = #"{"kind": "browser-navigation"}"#
  private static let browserRead = #"{"kind": "browser-read"}"#
  private static let read = #"{"kind": "clipboard-read"}"#
  private static let write = #"{"kind": "clipboard-write"}"#
  private static let fsRead = #"{"kind": "capability", "name": "fs-read"}"#

  /// Runs a plain script, or a package, with the bundle-like command.
  private func run(
    _ package: URL, allow: [String] = [], executable: URL? = nil
  ) async throws -> HelperRun {
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }

    environment["UNITERM_SOCKET"] = nil

    let helper = try HelperHandle.spawn(
      executable: try executable ?? HardenedHelper.url(),
      arguments: ["run", "--socket", host.instanceAddress] + allow.flatMap { ["--allow", $0] }
        + [package.path],
      environment: environment,
      deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)])

    spawned.add(helper)

    return try await ScriptFixtures.finish(helper)
  }

  /// Ends the run the host admitted as process `pid`, through the handle of the helper this test
  /// started. The admitted pid must be one of those helpers. A pid that is none of them is a run
  /// that this test did not start, so nothing is signalled.
  private func endRun(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
    guard let helper = spawned.helper(pid: pid) else {
      return XCTFail(
        "the admitted process \(pid) is none of the helpers this test started: \(spawned.pids)",
        file: file, line: line)
    }

    helper.signal(SIGKILL)
  }

  private var reviewCount: Int { reviewsSeen.count }

  // MARK: The startup review

  /// Catches a run that starts, or runs any code, before the user answers its review, a review
  /// that leaves out a requested power, and Trust This Identity offered for an unsigned package.
  func testTheReviewListsEveryPowerOnceBeforeAnythingRuns() async throws {
    let unsigned = try package(
      "(print \"ran\")\n", permissions: [Self.paneControl, Self.read, Self.fsRead])
    let started = Task { try await self.run(unsigned, allow: ["fs-read"]) }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review appeared")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertEqual(
      Set(review.requested), [.paneControl, .clipboardRead, .capability("fs-read")])
    XCTAssertFalse(review.isSigned)
    XCTAssertTrue(review.canRemember)
    XCTAssertTrue(host.allControllerRuns().isEmpty, "the run started before the review")
    XCTAssertTrue(host.hasPendingWork)

    await host.decideReview(review.id, .allowForSession)

    let result = try await started.value

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, "ran\n")
    XCTAssertTrue(result.standardError.contains("waits for your approval"), result.standardError)
    XCTAssertEqual(reviewCount, 1)

    reviewAnswer = .allowForSession

    let signed = try package(
      "(print \"ran\")\n", permissions: [Self.paneControl],
      signedWith: try ControllerFixtures.signingKey())

    _ = try await run(signed)

    XCTAssertEqual(reviewsSeen.values.filter(\.isSigned).count, 1)
  }

  /// Catches Allow once behaving as Allow for this session: under Allow once each read asks again,
  /// and coalesced asks release one read per answer. Under the session answer neither read asks.
  func testAllowOnceAsksForEachUseAndTheSessionAnswerDoesNot() async throws {
    let reader = try package(
      "(print (uniterm/read-clipboard))\n(print (uniterm/read-clipboard))\n",
      permissions: [Self.read])

    reviewAnswer = .allowOnce
    operationAnswer = { _ in .allowOnce }

    let once = try await run(reader)

    XCTAssertEqual(once.status, 0, once.standardError)
    XCTAssertEqual(once.standardOutput, "synthetic clipboard\nsynthetic clipboard\n")
    XCTAssertEqual(operationAnswers.count, 2)

    operationAnswers = []
    reviewAnswer = .allowForSession

    let session = try await run(reader)

    XCTAssertEqual(session.status, 0, session.standardError)
    XCTAssertEqual(operationAnswers.count, 0)
    XCTAssertEqual(clipboard.reads, 4)
  }

  /// Catches Allow once that lets a second pane call through, and a question row that does not
  /// name the process asking. Under Allow once each pane call asks, as each clipboard request does.
  /// Each row carries the run's PID, the same one its startup review showed.
  func testAllowOnceAsksForEachPaneCall() async throws {
    let lister = try package(
      "(protect (uniterm/list-windows))\n(protect (uniterm/list-windows))\n",
      permissions: [Self.paneControl])
    var pids: [pid_t?] = []

    reviewAnswer = .allowOnce
    operationAnswer = { row in
      pids.append(row.pid)

      return .allowOnce
    }

    let result = try await run(lister)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(
      operationAnswers.map(\.title), Array(repeating: "Control panes it may address", count: 2))

    let reviewed = try XCTUnwrap(reviewsSeen.values.first?.waiting.first?.pid)
    XCTAssertEqual(pids, [reviewed, reviewed])
  }

  // MARK: Browser powers

  private static let browserCommand = """
    (def pane {:window 1 :pane 1})
    (print (get (protect (uniterm/send-command pane :fixture-slides 0 :status)) 0))
    """

  /// Catches a browser command that runs on pane control alone, one that asks about a power the
  /// controller never declared, and a stored approval that grows to cover the new kinds. A power
  /// the controller declared and the user allowed for the run asks nothing. A controller that
  /// declared pane control alone reaches the window with no browser power, so the window's
  /// dispatch gives it the structured refusal, and the user is never asked.
  func testABrowserPowerIsHeldOnlyWhenDeclaredAndAllowedAndNeverAskedWhenUndeclared() async throws {
    windows.commandPowers["status"] = .browserNavigation

    let declared = try package(
      Self.browserCommand, permissions: [Self.paneControl, Self.navigation])
    let paneOnly = try package(Self.browserCommand, permissions: [Self.paneControl])

    reviewAnswer = .allowForSession
    operationAnswer = { _ in .deny }

    let held = try await run(declared)

    XCTAssertEqual(held.status, 0, held.standardError)
    XCTAssertTrue(operationAnswers.isEmpty, "a power allowed for the run asked again")
    XCTAssertEqual(windows.heldPowers.last, [.paneControl, .browserNavigation])

    let undeclared = try await run(paneOnly)

    XCTAssertEqual(undeclared.status, 0, undeclared.standardError)
    XCTAssertTrue(operationAnswers.isEmpty, "an undeclared power was asked about")
    XCTAssertEqual(windows.heldPowers.last, [.paneControl])
  }

  /// Catches a Janet controller whose browser commands reach the app under the wrong powers. With
  /// both powers every command is answered. With navigation alone the read is refused, and with
  /// pane control alone every call is. A refusal is a struct the script reads and goes on from.
  func testAScriptSeesEachBrowserCommandAnsweredOrRefusedByItsPower() async throws {
    windows.commandPowers = [
      "open": .browserNavigation, "navigate": .browserNavigation,
      "reload": .browserNavigation, "read": .browserRead,
    ]

    let source = try String(contentsOf: ScriptFixtures.script("browser-commands"), encoding: .utf8)

    reviewAnswer = .allowForSession

    for (permissions, expected) in [
      (
        [Self.paneControl, Self.navigation, Self.browserRead],
        "open ok\nnavigate ok\nreload ok\nread ok\n"
      ),
      (
        [Self.paneControl, Self.navigation],
        "open ok\nnavigate ok\nreload ok\nread refused\n"
      ),
      (
        [Self.paneControl],
        "open refused\nnavigate refused\nreload refused\nread refused\n"
      ),
    ] {
      let result = try await run(try package(source, permissions: permissions))

      XCTAssertEqual(result.status, 0, result.standardError)
      XCTAssertEqual(result.standardOutput, expected, "\(permissions)")
    }

    XCTAssertTrue(operationAnswers.isEmpty, "a standing or undeclared power asked")
  }

  /// Catches a run allowed once that cannot use a declared browser power at all, and one that asks
  /// once and then treats the answer as standing. The call needs two powers, so it asks about each
  /// in turn, and the window sees both held for that call alone.
  func testAllowOnceAsksForPaneControlAndTheBrowserPowerEachTime() async throws {
    windows.commandPowers["status"] = .browserNavigation

    let twice = try package(
      Self.browserCommand + "\n" + Self.browserCommand,
      permissions: [Self.paneControl, Self.navigation])

    reviewAnswer = .allowOnce
    operationAnswer = { _ in .allowOnce }

    let result = try await run(twice)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(
      operationAnswers.map(\.title).sorted(),
      Array(repeating: ControllerPermission.paneControl.displayText, count: 2)
        + Array(repeating: ControllerPermission.browserNavigation.displayText, count: 2))
    XCTAssertEqual(windows.heldPowers.count, 2)
    XCTAssertTrue(windows.heldPowers.allSatisfy { $0.contains(.browserNavigation) })
  }

  /// Catches a denied browser power that lets the call through.
  func testADeniedBrowserPowerRunsNothingInTheWindow() async throws {
    windows.commandPowers["status"] = .browserNavigation

    let denied = try package(
      Self.browserCommand, permissions: [Self.paneControl, Self.navigation])

    reviewAnswer = .allowOnce
    operationAnswer = { row in
      row.title == ControllerPermission.browserNavigation.displayText ? .deny : .allowOnce
    }

    let result = try await run(denied)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertTrue(windows.calls.isEmpty, "the window ran a call whose power was denied")
  }

  /// Catches a stored approval from before the browser kinds that covers a run now asking for
  /// them. ADR-09 says a change in permission meaning cannot grow an approval, and the browser
  /// kinds are new powers, so the review comes back and a refusal runs nothing.
  func testAnApprovalFromBeforeTheBrowserKindsDoesNotCoverThem() async throws {
    let before = try package("(print \"ran\")\n", permissions: [Self.paneControl])

    reviewAnswer = .trustVersion

    _ = try await run(before)

    XCTAssertEqual(reviewCount, 1)

    reviewAnswer = .deny

    let again = try await run(before)

    XCTAssertEqual(again.status, 0, again.standardError)
    XCTAssertEqual(reviewCount, 1, "the approved run was reviewed again")

    let wider = try package(
      "(print \"ran\")\n", permissions: [Self.paneControl, Self.navigation, Self.browserRead])
    let refused = try await run(wider)

    XCTAssertNotEqual(refused.status, 0)
    XCTAssertFalse(refused.standardOutput.contains("ran"), refused.standardOutput)
    XCTAssertEqual(reviewCount, 2, "the browser kinds were covered by an older approval")

    let asked = try XCTUnwrap(reviewsSeen.values.first { $0.requested.contains(.browserRead) })

    XCTAssertTrue(asked.requested.contains(.browserNavigation))
  }

  /// Catches a plain script, which has no controller identity, reaching the clipboard without the
  /// user, or being offered more than its own run. The bundled command's connection is its run, so
  /// the question says Run. The session answer lasts for that run alone, and the next run asks
  /// again.
  func testAPlainScriptsClipboardAsksForItsRunAlone() async throws {
    let script = work.appendingPathComponent("plain.janet")

    try Data(
      "(import uniterm)\n(print (uniterm/read-clipboard))\n(print (uniterm/read-clipboard))\n".utf8
    ).write(to: script)

    var titles: [String] = []

    operationAnswer = { row in
      titles.append(row.sessionTitle)

      return .allowForSession
    }

    let first = try await run(script)

    XCTAssertEqual(first.status, 0, first.standardError)
    XCTAssertEqual(first.standardOutput, "synthetic clipboard\nsynthetic clipboard\n")
    XCTAssertEqual(titles, ["Allow for This Run"])
    XCTAssertEqual(reviewCount, 0, "a plain script was reviewed as a controller")

    _ = try await run(script)

    XCTAssertEqual(titles.count, 2, "a run's session answer covered the next run")
  }

  /// Catches a program that is not the bundled command being named a run. Its connection is not a
  /// run, so its question says Connection. The unsigned SwiftPM helper stands in for any other
  /// program that speaks the wire.
  func testAGenericPeersClipboardAsksForItsConnection() async throws {
    let script = work.appendingPathComponent("generic.janet")

    try Data("(import uniterm)\n(print (uniterm/read-clipboard))\n".utf8).write(to: script)

    var titles: [String] = []

    operationAnswer = { row in
      titles.append(row.sessionTitle)

      return .allowOnce
    }

    let result = try await run(script, executable: ScriptFixtures.helper())

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(titles, ["Allow for This Connection"])
  }

  /// Catches a REPL pane's question being named a run. A REPL stays open until its pane closes, so
  /// its question says Connection.
  func testAReplPanesClipboardAsksForItsConnection() async throws {
    var titles: [String] = []

    operationAnswer = { row in
      titles.append(row.sessionTitle)

      return .deny
    }

    let channel = openTestRepl(host: host)
    let events = ReplEvents(channel)
    let process = try ReplProcess(
      address: channel.launch.address,
      environment: [ScriptProtocol.replTokenVariable: channel.launch.token])

    expect(await waitUntil { events.attachedProcess != nil })

    process.write("(uniterm/read-clipboard)\n")

    expect(await waitUntil { !titles.isEmpty }, process.standardOutput + process.standardError)
    XCTAssertEqual(titles, ["Allow for This Connection"])

    channel.end()
  }

  /// Catches a denial that a program escapes by reconnecting. Its connection's rows go when it
  /// disconnects, but the denial holds for the next run of an ordinary script in the same pane,
  /// and for the next run of the same controller version, until Ask Again.
  func testADenialOutlivesTheConnectionThatAsked() async throws {
    let script = work.appendingPathComponent("plain.janet")

    try Data("(import uniterm)\n(print (get (protect (uniterm/read-clipboard)) 0))\n".utf8)
      .write(to: script)

    operationAnswer = { _ in .deny }

    let denied = try await run(script)
    let again = try await run(script)

    XCTAssertEqual(denied.standardOutput, "false\n")
    XCTAssertEqual(again.standardOutput, "false\n")
    XCTAssertEqual(operationAnswers.count, 1, "a reconnected script asked again")

    let reader = try package(
      "(print (get (protect (uniterm/read-clipboard)) 0))\n", permissions: [Self.read])

    reviewAnswer = .allowOnce

    _ = try await run(reader)
    _ = try await run(reader)

    XCTAssertEqual(operationAnswers.count, 2, "a rerun of a denied controller version asked again")

    let denial = try XCTUnwrap(host.permissionRequests.denials.first, "the script's denial is gone")

    host.permissionRequests.askAgain(denial.id)
    operationAnswer = { _ in .allowOnce }

    let retried = try await run(script)

    XCTAssertEqual(retried.standardOutput, "true\n")
    XCTAssertEqual(operationAnswers.count, 3)
  }

  /// Catches a read granted by a write's approval, or a check made before the wait and not at the
  /// clipboard. A run allowed to write for its session still asks to read, a denied read sends no
  /// text, and an undeclared power is refused without asking.
  func testReadsAndWritesAreSeparatePowersCheckedAtTheClipboard() async throws {
    let both = try package(
      """
      (uniterm/write-clipboard "written by the controller")
      (print (get (protect (uniterm/read-clipboard)) 0))
      (uniterm/write-clipboard "again")

      """, permissions: [Self.read, Self.write])

    reviewAnswer = .allowOnce
    operationAnswer = {
      $0.title == ControllerPermission.clipboardWrite.displayText ? .allowForSession : .deny
    }

    let result = try await run(both)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, "false\n")
    XCTAssertEqual(clipboard.text, "again")
    XCTAssertEqual(clipboard.reads, 0, "a denied read reached the clipboard")
    XCTAssertEqual(operationAnswers.map(\.answer), [.allowForSession, .deny])

    let writerOnly = try package(
      "(print (get (protect (uniterm/read-clipboard)) 0))\n", permissions: [Self.write])

    operationAnswers = []
    reviewAnswer = .allowForSession

    let refused = try await run(writerOnly)

    XCTAssertEqual(refused.standardOutput, "false\n")
    XCTAssertEqual(operationAnswers.count, 0, "an undeclared power asked the user")
  }

  // MARK: Remembered trust

  /// Catches a version policy that misses a later run of the same version, one that covers a
  /// wider or new request, or a corrupt policy file that grants anything.
  func testTrustingAVersionCoversItsNarrowerRunsAndNothingWider() async throws {
    let printer = try package(
      "(print \"ran\")\n", permissions: [Self.paneControl, Self.fsRead])

    reviewAnswer = .trustVersion

    _ = try await run(printer, allow: ["fs-read"])

    XCTAssertEqual(reviewCount, 1)

    reviewAnswer = .deny

    let again = try await run(printer, allow: ["fs-read"])
    let narrower = try await run(printer)

    XCTAssertEqual(again.status, 0, again.standardError)
    XCTAssertEqual(narrower.status, 0, narrower.standardError)
    XCTAssertEqual(reviewCount, 1, "a covered run was reviewed again")
    XCTAssertFalse(
      try String(contentsOf: trust.appendingPathComponent("policy.json"), encoding: .utf8)
        .contains("ran"),
      "the policy file holds package content")

    let wider = try package(
      "(print \"ran\")\n", permissions: [Self.paneControl, Self.fsRead, Self.write])
    let refused = try await run(wider, allow: ["fs-read"])

    XCTAssertNotEqual(refused.status, 0)
    XCTAssertEqual(reviewCount, 2, "a wider version was not reviewed")

    try Data("{\"format\": 1, \"policies\": [".utf8)
      .write(to: trust.appendingPathComponent("policy.json"))
    reviewAnswer = .allowForSession

    _ = try await run(printer, allow: ["fs-read"])

    XCTAssertEqual(reviewCount, 3, "a corrupt policy file granted a run")
  }

  /// Catches identity trust that covers a version signed by another key, an unsigned package with
  /// the same controller ID, or a package whose signature does not verify, and identity trust
  /// that misses a later version the same key signed.
  func testTrustingAnIdentityCoversItsKeyAlone() async throws {
    let key = try ControllerFixtures.signingKey()
    let first = try package("(print 1)\n", permissions: [Self.paneControl], signedWith: key)

    reviewAnswer = .trustIdentity

    let trusted = try await run(first)

    XCTAssertEqual(trusted.status, 0, trusted.standardError)
    XCTAssertEqual(reviewCount, 1)

    reviewAnswer = .deny

    let update = try package("(print 2)\n", permissions: [Self.paneControl], signedWith: key)
    let updated = try await run(update)

    XCTAssertEqual(updated.status, 0, updated.standardError)
    XCTAssertEqual(updated.standardOutput, "2\n")
    XCTAssertEqual(reviewCount, 1, "a later version under the same key was reviewed")

    let otherKey = try package(
      "(print 3)\n", permissions: [Self.paneControl], signedWith: InMemorySigningKey())
    let unsigned = try package("(print 4)\n", permissions: [Self.paneControl])

    let byOtherKey = try await run(otherKey)
    let byNoKey = try await run(unsigned)

    XCTAssertNotEqual(byOtherKey.status, 0)
    XCTAssertNotEqual(byNoKey.status, 0)
    XCTAssertEqual(reviewCount, 3)

    let tampered = try package("(print 5)\n", permissions: [Self.paneControl], signedWith: key)
    var changed = ControllerPackageBuilder(
      files: ["main.janet": Data("(import uniterm)\n(print 6)\n".utf8)])

    changed.id = "dev.uniterm.fixture.consent"
    changed.format = ControllerDescriptor.format
    changed.permissions = [Self.paneControl]
    try changed.write(to: tampered)

    let bad = try await run(tampered)

    XCTAssertNotEqual(bad.status, 0)
    XCTAssertEqual(bad.standardOutput, "")
    XCTAssertTrue(bad.standardError.contains("signature does not match"), bad.standardError)
    XCTAssertEqual(reviewCount, 3, "a package with a bad signature reached a review")
  }

  /// Catches a forgotten policy that still covers a run, or that leaves a run it admitted with
  /// its authority.
  func testForgettingAPolicyEndsItsRunsAndAsksAgain() async throws {
    let waiter = try package(
      "(print \"started\")\n(flush)\n(os/sleep 30)\n", permissions: [Self.paneControl])

    reviewAnswer = .trustVersion

    let running = Task { try await self.run(waiter) }

    expect(await waitUntil { !self.host.allControllerRuns().isEmpty }, "the run never started")

    let admitted = try XCTUnwrap(host.allControllerRuns().first)
    let remembered = await host.rememberedTrust()
    let selector = try XCTUnwrap(remembered.policies.first?.selector)

    XCTAssertEqual(admitted.approval, .remembered(selector))

    let failure = await host.forgetPolicy(selector)
    let after = await host.rememberedTrust()

    XCTAssertNil(failure)
    XCTAssertTrue(host.allControllerRuns().isEmpty, "the run kept its authority")
    XCTAssertEqual(after.policies, [])

    endRun(admitted.pid)
    _ = try await running.value

    reviewAnswer = .deny

    let asked = try await run(waiter)

    XCTAssertNotEqual(asked.status, 0)
    XCTAssertEqual(reviewCount, 2)
  }

  /// Catches a run admitted under a policy the user removed while the run's package was read.
  /// Admission reads the policy file off the main actor, so a removal can land between that read
  /// and the run's start. A run whose admission overlapped a removal is reviewed instead.
  ///
  /// The test holds the policy file's lock, so the admission's read waits for it, and starts the
  /// removal as it lets go. The read then nearly always goes first. The test pins the fix for
  /// that order. It cannot force the order where the removal also finishes before the run starts.
  func testARevokeDuringAdmissionLeavesTheRunToAReview() async throws {
    let waiter = try package(
      "(print \"started\")\n(flush)\n(os/sleep 30)\n", permissions: [Self.paneControl])

    reviewAnswer = .trustVersion

    let first = Task { try await self.run(waiter) }

    expect(await waitUntil { !self.host.allControllerRuns().isEmpty }, "the run never started")

    endRun(try XCTUnwrap(host.allControllerRuns().first).pid)
    _ = try await first.value

    let remembered = await host.rememberedTrust()
    let selector = try XCTUnwrap(remembered.policies.first?.selector)
    var approvals: [ControllerApproval] = []
    let seen = host.changes.add { [weak self] in
      approvals += self?.host.allControllerRuns().map(\.approval) ?? []
    }

    defer { _ = seen }

    reviewAnswer = .deny

    let runs = work.appendingPathComponent("runs").path
    let before = Set((try? FileManager.default.contentsOfDirectory(atPath: runs)) ?? [])
    let lock = open(trust.appendingPathComponent("policy.lock").path, O_RDWR | O_CLOEXEC)

    XCTAssertGreaterThanOrEqual(lock, 0)
    XCTAssertEqual(flock(lock, LOCK_EX), 0)

    let second = Task { try await self.run(waiter) }

    expect(
      await waitUntil(timeout: .seconds(20)) {
        !Set((try? FileManager.default.contentsOfDirectory(atPath: runs)) ?? []).subtracting(
          before
        ).isEmpty
      }, "the second run made no snapshot")

    let forgetting = Task { await self.host.forgetPolicy(selector) }

    flock(lock, LOCK_UN)
    close(lock)

    let failure = await forgetting.value

    XCTAssertNil(failure)
    expect(await waitUntil { self.reviewCount == 2 }, "the run was not reviewed")

    let refused = try await second.value

    XCTAssertNotEqual(refused.status, 0)
    XCTAssertFalse(
      approvals.contains(.remembered(selector)), "a run started under a policy being removed")
  }

  /// Catches a host launch covered by anything but the run's own standing approval: a broader
  /// directory, an extra environment key, another executable, or a run allowed once.
  func testALaunchIsCoveredOnlyByTheRunsStandingHostLaunch() async throws {
    let resolvedWork = try XCTUnwrap(realpath(work.path, nil))

    defer { free(resolvedWork) }

    // Covered folders must exist, since a launch's folder is compared with its links resolved.
    let parent = String(cString: resolvedWork)
    let folder = parent + "/launch"

    try FileManager.default.createDirectory(
      atPath: folder + "/a", withIntermediateDirectories: true)

    let launcher = try package(
      "(print \"started\")\n(flush)\n(os/sleep 30)\n",
      permissions: [
        Self.paneControl,
        #"{"kind": "host-launch", "executable": "/usr/bin/true", "directory": ""#
          + folder + #"", "environment": ["TOKEN"]}"#,
      ])

    for answer in [ControllerReviewChoice.allowForSession, .allowOnce, .trustVersion, .deny] {
      reviewAnswer = answer

      let running = Task { try await self.run(launcher) }

      expect(await waitUntil { !self.host.allControllerRuns().isEmpty }, "the run never started")

      let admitted = try XCTUnwrap(host.allControllerRuns().first)
      let covers = { (executable: String, directory: String, keys: [String]) async -> Bool in
        await self.host.coversLaunch(
          connection: admitted.connection, executable: executable, directory: directory,
          environmentKeys: keys)
      }

      // The last pass is a later run that the trusted version's policy admits with no review.
      let standing = answer == .allowForSession || answer == .trustVersion || answer == .deny
      let inside = await covers("/usr/bin/true", folder + "/a", ["TOKEN"])
      let itself = await covers("/usr/bin/true", folder, [])
      let above = await covers("/usr/bin/true", parent, ["TOKEN"])
      let extraKey = await covers("/usr/bin/true", folder, ["TOKEN", "OTHER"])
      let otherProgram = await covers("/bin/sh", folder, [])
      let missing = await covers("/usr/bin/true", folder + "/missing", [])

      XCTAssertEqual(inside, standing)
      XCTAssertEqual(itself, standing)
      XCTAssertFalse(above)
      XCTAssertFalse(extraKey)
      XCTAssertFalse(otherProgram)
      XCTAssertFalse(missing)

      endRun(admitted.pid)
      _ = try await running.value
      expect(await waitUntil { self.host.allControllerRuns().isEmpty })
    }

    XCTAssertEqual(reviewCount, 3, "the trusted version was reviewed again")

    let file = try String(contentsOf: trust.appendingPathComponent("policy.json"), encoding: .utf8)

    XCTAssertTrue(file.contains("\"TOKEN\""), file)
    XCTAssertTrue(file.contains("\"\(folder)\""), file)
  }

  /// Catches a read scope that stands for a run that was never allowed to keep it, and one that
  /// outlives its run. Allow for This Run and a trusted version keep the scope. Allow once does not,
  /// so its reads are refused. A run that ended holds none.
  func testAReadScopeStandsOnlyForARunAllowedToKeepIt() async throws {
    let folder = work.path
    let reader = try package(
      "(print \"started\")\n(flush)\n(os/sleep 30)\n",
      permissions: [
        Self.paneControl,
        #"{"kind": "path-read", "directories": [""# + folder + #""]}"#,
      ])

    for answer in [ControllerReviewChoice.allowForSession, .allowOnce, .trustVersion] {
      reviewAnswer = answer

      let running = Task { try await self.run(reader) }

      expect(await waitUntil { !self.host.allControllerRuns().isEmpty }, "the run never started")

      let admitted = try XCTUnwrap(host.allControllerRuns().first)
      let access = host.readAccess(for: admitted.connection)

      XCTAssertEqual(
        access.isDeclaredButNotGranted, answer == .allowOnce,
        "only a run that declared the power and was allowed once is told so")

      if answer == .allowOnce {
        XCTAssertNil(access.scope, "an Allow once answer does not stand")
      } else {
        XCTAssertEqual(access.scope, try ReadScope(directories: [folder]))
      }

      endRun(admitted.pid)
      _ = try await running.value
      expect(await waitUntil { self.host.allControllerRuns().isEmpty })

      XCTAssertNil(host.readAccess(for: admitted.connection).scope, "the run ended")
    }
  }

  /// Catches a scope approved through a link hiding the real paths inside it from its own run. The
  /// panes hand `mayShow` real paths, and the scope as written holds none of them. A reply sent
  /// before the links are resolved may still hide, so the check waits for the resolution.
  func testAReadScopeWrittenThroughALinkShowsTheRealPathsInsideIt() async throws {
    let real = work.appendingPathComponent("real-pics")
    let link = work.appendingPathComponent("link-pics")

    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
    try Data([0]).write(to: real.appendingPathComponent("a.png"))

    let pointer = try XCTUnwrap(realpath(real.appendingPathComponent("a.png").path, nil))
    let target = String(cString: pointer)

    free(pointer)

    let reader = try package(
      "(print \"started\")\n(flush)\n(os/sleep 30)\n",
      permissions: [
        Self.paneControl,
        #"{"kind": "path-read", "directories": [""# + link.path + #""]}"#,
      ])

    reviewAnswer = .allowForSession

    let running = Task { try await self.run(reader) }

    expect(await waitUntil { !self.host.allControllerRuns().isEmpty }, "the run never started")

    let admitted = try XCTUnwrap(host.allControllerRuns().first)

    expect(
      await waitUntil { self.host.readAccess(for: admitted.connection).mayShow(source: target) },
      "the real path inside a scope written through a link stayed hidden")

    endRun(admitted.pid)
    _ = try await running.value
  }

  /// Catches standing scopes that add up wrongly: none gives nothing, and two give both.
  func testStandingReadScopesAddUp() throws {
    XCTAssertNil(ScriptHost.readScope(of: [.paneControl]))
    XCTAssertEqual(
      ScriptHost.readScope(
        of: [
          .pathRead(try ReadScope(directories: ["/a"])),
          .pathRead(try ReadScope(directories: ["/b"])), .paneControl,
        ]),
      try ReadScope(directories: ["/a", "/b"]))
  }

  /// Catches a launch let out of its approved folder by a link inside it. The text of the path is
  /// inside the folder, but the driver would run where the link leads. A folder is compared with
  /// every link resolved, so a link that stays inside is covered and one that leads out is not.
  func testALinkCannotLeadALaunchOutOfItsApprovedFolder() async throws {
    let resolvedWork = try XCTUnwrap(realpath(work.path, nil))

    defer { free(resolvedWork) }

    let approved = String(cString: resolvedWork) + "/approved"
    let outside = work.appendingPathComponent("outside").path

    for folder in [approved + "/inside", outside] {
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    try FileManager.default.createSymbolicLink(
      atPath: approved + "/leads-out", withDestinationPath: outside)
    try FileManager.default.createSymbolicLink(
      atPath: approved + "/stays-in", withDestinationPath: approved + "/inside")

    let launcher = try package(
      "(print \"started\")\n(flush)\n(os/sleep 30)\n",
      permissions: [
        Self.paneControl,
        #"{"kind": "host-launch", "executable": "/usr/bin/true", "directory": ""#
          + approved + #"", "environment": []}"#,
      ])

    reviewAnswer = .allowForSession

    let running = Task { try await self.run(launcher) }

    expect(await waitUntil { !self.host.allControllerRuns().isEmpty }, "the run never started")

    let admitted = try XCTUnwrap(host.allControllerRuns().first)
    let covers = { (directory: String) async -> Bool in
      await self.host.coversLaunch(
        connection: admitted.connection, executable: "/usr/bin/true", directory: directory,
        environmentKeys: [])
    }

    let inside = await covers(approved + "/inside")
    let staysIn = await covers(approved + "/stays-in")
    let leadsOut = await covers(approved + "/leads-out")

    XCTAssertTrue(inside)
    XCTAssertTrue(staysIn)
    XCTAssertFalse(leadsOut, "a link led the launch out of its folder")

    endRun(admitted.pid)
    _ = try await running.value
  }

  // MARK: Coalescing and denial

  /// Catches coalesced runs that one Allow once admits together. Two runs of one version share one
  /// review, and Allow once starts the oldest alone.
  func testTwoWaitingRunsShareAReviewAndAllowOnceStartsOne() async throws {
    let printer = try package("(print \"ran\")\n", permissions: [Self.paneControl])
    let first = Task { try await self.run(printer) }
    let second = Task { try await self.run(printer) }

    expect(
      await waitUntil { self.host.controllerReviews.first?.waiting.count == 2 },
      "the runs did not share a review")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertEqual(host.controllerReviews.count, 1)

    await host.decideReview(review.id, .allowOnce)

    XCTAssertEqual(host.controllerReviews.first?.waiting.count, 1)

    await host.decideReview(review.id, .deny)

    let results = [try await first.value, try await second.value]

    XCTAssertEqual(results.filter { $0.status == 0 }.count, 1)
  }

  /// Catches a denial that asks again, or a denied operation that opens another question. A
  /// denied version is refused at once until Ask Again, and so is a denied power within a run.
  func testADenialAsksNothingUntilAskAgain() async throws {
    let printer = try package("(print \"ran\")\n", permissions: [Self.paneControl])

    reviewAnswer = .deny

    let denied = try await run(printer)

    XCTAssertNotEqual(denied.status, 0)

    let refused = try await run(printer)

    XCTAssertTrue(refused.standardError.contains("You denied this version"), refused.standardError)
    XCTAssertEqual(reviewCount, 1)

    let denial = try XCTUnwrap(host.permissionRequests.denials.first)

    host.permissionRequests.askAgain(denial.id)
    reviewAnswer = .allowForSession

    let retried = try await run(printer)

    XCTAssertEqual(retried.status, 0)
    XCTAssertEqual(reviewCount, 2)

    let reader = try package(
      """
      (print (get (protect (uniterm/read-clipboard)) 0))
      (print (get (protect (uniterm/read-clipboard)) 0))
      (print (get (protect (uniterm/read-clipboard)) 0))

      """, permissions: [Self.read])

    reviewAnswer = .allowOnce
    operationAnswer = { _ in .deny }

    let deniedReads = try await run(reader)

    XCTAssertEqual(deniedReads.standardOutput, "false\nfalse\nfalse\n")
    XCTAssertEqual(operationAnswers.count, 1, "a denied power asked again")
  }

  // MARK: Revocation

  /// Catches a waiting clipboard request that outlives the authority it asked under: a revoke, a
  /// disconnect, or the end of the session the program runs in. None reaches the clipboard.
  func testRevokeDisconnectAndSessionEndDropWaitingClipboardRequests() async throws {
    let reader = try package(
      "(print (get (protect (uniterm/read-clipboard)) 0))\n", permissions: [Self.read])

    reviewAnswer = .allowOnce

    let revoked = Task { try await self.run(reader) }

    expect(await waitUntil { !self.host.permissionRequests.rows.isEmpty })
    host.revokeControllers(Set(host.allControllerRuns().map(\.connection)))
    XCTAssertTrue(host.permissionRequests.rows.isEmpty)
    let revokedRun = try await revoked.value

    XCTAssertEqual(revokedRun.standardOutput, "false\n")

    let disconnected = Task { try await self.run(reader) }

    expect(await waitUntil { !self.host.permissionRequests.rows.isEmpty })

    let pid = try XCTUnwrap(host.allControllerRuns().first?.pid)

    endRun(pid)
    _ = try await disconnected.value
    expect(
      await waitUntil { self.host.permissionRequests.rows.isEmpty },
      "the request outlived its program")

    let replaced = Task { try await self.run(reader) }

    expect(await waitUntil { !self.host.permissionRequests.rows.isEmpty })
    host.removeSessionRoot(TestSessionRoot.identity, window: 1, pane: NodeID(rawValue: 1))
    XCTAssertTrue(host.permissionRequests.rows.isEmpty)
    let replacedRun = try await replaced.value

    XCTAssertEqual(replacedRun.standardOutput, "false\n")
    XCTAssertEqual(clipboard.reads, 0)
  }
}

/// The helpers a test started, so a test can end the run the host admitted through the handle of
/// the helper that made it.
private final class SpawnedHelpers: @unchecked Sendable {
  private let lock = NSLock()
  private var helpers: [HelperHandle] = []

  func add(_ helper: HelperHandle) {
    lock.withLock { helpers.append(helper) }
  }

  func helper(pid: pid_t) -> HelperHandle? {
    lock.withLock { helpers.first { $0.pid == pid } }
  }

  var pids: [pid_t] {
    lock.withLock { helpers.map(\.pid) }
  }
}
