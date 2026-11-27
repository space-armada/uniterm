import ControllerPackage
import Darwin
import FileRouting
import Foundation
import PaneModel
import ProcessInspection
import QuestionForm
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost
@testable import ScriptWire

/// The form calls through the host, as a raw peer sends them over the wire. The window layer is a
/// fake that hands the test each form and lets it answer, so these tests prove what the host does
/// with a form and its result: the handle, the deferred wait, the authority that is read again,
/// and every way a form ends. They cannot prove placement or the badge, which the window layer's
/// own tests prove with real windows.
@MainActor
final class ScriptFormTests: XCTestCase {
  private static let spec =
    #"{"title": "T", "items": [{"id": "name", "text": "Name?", "type": "string"}]}"#

  private var directory: URL!
  private var center: StatusCenter!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!
  private var peers: [FramedSocket] = []

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    center = StatusCenter()
    windows = FakeWindowAPI()

    let center = center!

    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows,
      reaper: .inert)
    host.start()

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    for peer in peers { peer.shutdownAndClose() }

    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: Helpers

  /// A raw peer that began as a plain program in the test's own session, so it is a bare terminal
  /// caller.
  private func connect() async throws -> FramedSocket {
    let peer = try await ScriptFixtures.openPeer(host: host)

    peers.append(peer)

    try peer.send(ScriptHelperMessage.begin(name: "bash").frame())

    return peer
  }

  private func send(_ peer: FramedSocket, _ id: UInt32, _ call: ScriptCall) throws {
    try peer.send(ScriptHelperMessage.request(id: id, call: call).frame())
  }

  /// The next reply for `id`. Other messages are skipped.
  private func reply(_ peer: FramedSocket, _ id: UInt32) async throws -> ScriptResult {
    while true {
      if case .reply(let answered, let result) = try await ScriptFixtures.readMessage(peer),
        answered == id
      {
        return result
      }
    }
  }

  /// The replies for every id in `ids`, in whatever order they come.
  private func replies(_ peer: FramedSocket, _ ids: Set<UInt32>) async throws
    -> [UInt32: ScriptResult]
  {
    var found: [UInt32: ScriptResult] = [:]

    while found.count < ids.count {
      if case .reply(let id, let result) = try await ScriptFixtures.readMessage(peer),
        ids.contains(id)
      {
        found[id] = result
      }
    }

    return found
  }

  private func call(_ peer: FramedSocket, _ id: UInt32, _ call: ScriptCall) async throws
    -> ScriptResult
  {
    try send(peer, id, call)

    return try await reply(peer, id)
  }

  private func handle(of result: ScriptResult) throws -> UInt64 {
    guard case .ok(let payload) = result,
      case .integer(let handle) = try ScriptValue.decode(payload)
    else { throw Unexpected(text: "the call did not return a handle: \(result)") }

    return handle
  }

  private func record(_ result: ScriptResult) throws -> [String: ScriptValue] {
    guard case .ok(let payload) = result, case .record(let fields) = try ScriptValue.decode(payload)
    else { throw Unexpected(text: "the call did not return a record: \(result)") }

    return fields
  }

  private func openForm(_ peer: FramedSocket, id: UInt32 = 1, spec: String = ScriptFormTests.spec)
    async throws -> UInt64
  {
    try handle(of: try await call(peer, id, .openForm(spec: spec)))
  }

  private func failure(_ result: ScriptResult) -> (ScriptFailureKind, String)? {
    if case .failure(let kind, let text) = result { return (kind, text) }

    return nil
  }

  /// The connection of the one peer acting for pane 1.
  private func onlyConnection() throws -> UInt64 {
    try XCTUnwrap(host.controllers(actingFrom: 1, pane: NodeID(rawValue: 1)).first)
  }

  private var submitted: FormOutcome {
    .submitted(submission: 1, action: "ok", answers: ["name": .text("Ada")])
  }

  // MARK: Open, wait, discard

  /// Catches an `open-form` that waits for the user, which would let a form that has an effect
  /// hold the call. The reply is the handle, and the window layer received the form from the caller
  /// the host derived.
  func testOpenFormRepliesWithAHandleAtOnce() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)

    XCTAssertGreaterThan(handle, 0)
    XCTAssertEqual(windows.askedForms.count, 1)
    XCTAssertEqual(windows.askedForms.first?.caller.window, 1)
    XCTAssertEqual(windows.askedForms.first?.caller.pane, NodeID(rawValue: 1))
    XCTAssertEqual(windows.askedForms.first?.spec.questions.map(\.id), ["name"])
  }

  /// Catches a `wait-form` that answers before the user does, and one that never answers. The
  /// reply is deferred, and the user's answer completes it with the documented result shape.
  func testWaitFormHoldsItsReplyUntilTheFormResolves() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)

    try send(peer, 2, .waitForm(form: handle))

    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: submitted)

    let fields = try record(try await reply(peer, 2))

    XCTAssertEqual(fields["form"], .integer(handle))
    XCTAssertEqual(fields["submission"], .integer(1))
    XCTAssertEqual(fields["action"], .string("ok"))
    XCTAssertEqual(fields["answers"], .record(["name": .string("Ada")]))
  }

  /// Catches a result that a read consumes, which would lose the first answer to a second wait.
  /// A wait that comes after the form resolved answers at once, as many times as it is asked, until
  /// the handle is discarded.
  func testReadingAResultDoesNotConsumeIt() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: .dismissed)

    for id: UInt32 in [2, 3] {
      let fields = try record(try await call(peer, id, .waitForm(form: handle)))

      XCTAssertEqual(fields["outcome"], .string("dismissed"))
    }

    let next = try await call(peer, 4, .openForm(spec: Self.spec))

    XCTAssertEqual(try self.handle(of: next), handle + 1)
  }

  /// Catches a cancel press that reads as a submission. It returns the action and no answers.
  func testACancelPressReturnsCancelledWithNoAnswers() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: .cancelled(action: "cancel"))

    let fields = try record(try await call(peer, 2, .waitForm(form: handle)))

    XCTAssertEqual(fields["outcome"], .string("cancelled"))
    XCTAssertEqual(fields["action"], .string("cancel"))
    XCTAssertNil(fields["answers"])
  }

  /// Catches a result that goes with its tab. A resolved tab gives way to a newer requester's form,
  /// and the window layer ends the requester. The handle's result stays readable until the program
  /// discards it.
  func testAResultStaysReadableAfterItsTabGivesWay() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: submitted)
    windows.endForms(requester: key, window: 1)

    let fields = try record(try await call(peer, 2, .waitForm(form: handle)))

    XCTAssertEqual(fields["action"], .string("ok"))
    XCTAssertEqual(fields["answers"], .record(["name": .string("Ada")]))
  }

  /// Catches a handle that is freed and still readable, and a handle that a stranger can read. A
  /// discarded handle names nothing, and another connection's handle names nothing either.
  func testADiscardedOrForeignHandleIsNotFound() async throws {
    let peer = try await connect()
    let other = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: submitted)

    let foreignWait = try await call(other, 1, .waitForm(form: handle))

    XCTAssertEqual(failure(foreignWait)?.0, .notFound)
    let foreignDiscard = try await call(other, 2, .discardForm(form: handle))
    XCTAssertEqual(failure(foreignDiscard)?.0, .notFound)

    guard case .ok = try await call(peer, 2, .discardForm(form: handle)) else {
      return XCTFail("the owner could not discard its handle")
    }

    let waitAfterDiscard = try await call(peer, 3, .waitForm(form: handle))

    XCTAssertEqual(failure(waitAfterDiscard)?.0, .notFound)
    let discardAfterDiscard = try await call(peer, 4, .discardForm(form: handle))
    XCTAssertEqual(failure(discardAfterDiscard)?.0, .notFound)
  }

  /// Catches discarding an open form leaving it on screen, or its pending wait hanging. The form
  /// ends with nothing submitted, the wait fails as ended, and the handle is gone.
  func testDiscardingAnOpenFormEndsItAndFailsItsWait() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    try send(peer, 2, .waitForm(form: handle))

    try send(peer, 3, .discardForm(form: handle))

    let answered = try await replies(peer, [2, 3])

    guard case .ok? = answered[3] else { return XCTFail("the discard failed") }

    XCTAssertEqual(failure(try XCTUnwrap(answered[2]))?.0, .ended)
    XCTAssertEqual(windows.discardedForms, [key])
    XCTAssertFalse(windows.hasOpenForm(requester: key))

    let after = try await call(peer, 4, .waitForm(form: handle))

    XCTAssertEqual(failure(after)?.0, .notFound)
  }

  /// Catches a second wait on one form taking over the first, which would leave the first
  /// unanswered.
  func testASecondWaitOnTheSameFormIsBusy() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)

    try send(peer, 2, .waitForm(form: handle))

    let secondWait = try await call(peer, 3, .waitForm(form: handle))

    XCTAssertEqual(failure(secondWait)?.0, .busy)
  }

  // MARK: Refusals

  /// Catches a spec that reaches the window layer unchecked. The strict reader refuses it, and the
  /// refusal names the field, as a bad argument.
  func testASpecTheReaderRefusesIsABadArgumentNamingTheField() async throws {
    let peer = try await connect()
    let result = try await call(peer, 1, .openForm(spec: #"{"items": [], "extra": 1}"#))
    let (kind, text) = try XCTUnwrap(failure(result))

    XCTAssertEqual(kind, .badArgument)
    XCTAssertTrue(text.contains("extra"), text)
    XCTAssertTrue(windows.askedForms.isEmpty)
  }

  /// Catches a busy refusal that reaches the script as another kind. A second form while one is
  /// open, and a form past the pane's cap, are both the wire's `busy`.
  func testASecondFormAndAFormPastTheCapAreBusy() async throws {
    let peer = try await connect()

    _ = try await openForm(peer)

    let secondForm = try await call(peer, 2, .openForm(spec: Self.spec))

    XCTAssertEqual(failure(secondForm)?.0, .busy)
    XCTAssertEqual(windows.askedForms.count, 1)

    let other = try await connect()

    windows.formCap = 1

    let formPastCap = try await call(other, 1, .openForm(spec: Self.spec))

    XCTAssertEqual(failure(formPastCap)?.0, .busy)
  }

  /// Catches a refused open that still takes a handle. Nothing opened, so the handle table has no
  /// entry, and the next form still opens.
  func testARefusedOpenLeavesNoHandle() async throws {
    let peer = try await connect()

    windows.formRefusal = .busy("no room")

    let refusedOpen = try await call(peer, 1, .openForm(spec: Self.spec))

    XCTAssertEqual(failure(refusedOpen)?.0, .busy)
    XCTAssertTrue(host.forms.isEmpty)

    windows.formRefusal = nil

    _ = try await openForm(peer, id: 2)

    XCTAssertEqual(host.forms.slots(of: try onlyConnection()).count, 1)
  }

  /// Catches a connection's results growing without a bound. A connection that never discards keeps
  /// its newest results, and the oldest settled one is dropped when it asks again.
  func testTheOldestSettledResultIsDroppedAtTheCap() async throws {
    let peer = try await connect()
    var handles: [UInt64] = []

    for index in 0...FormSlots.perConnection {
      let handle = try await openForm(peer, id: UInt32(index + 1))

      handles.append(handle)

      let key = try XCTUnwrap(windows.askedForms.last?.requester.key)

      windows.resolveForm(requester: key, with: submitted)
    }

    let oldest = try XCTUnwrap(handles.first)
    let newest = try XCTUnwrap(handles.last)

    let droppedResult = try await call(peer, 100, .waitForm(form: oldest))

    XCTAssertEqual(failure(droppedResult)?.0, .notFound)
    let last = try await call(peer, 101, .waitForm(form: newest))

    XCTAssertNotNil(try record(last)["form"])
  }

  // MARK: Authority

  /// Catches a wait that outlives the program's authority. Revoking the controller fails the wait
  /// as ended and frees the handle, and the form's requester is told to let go.
  func testRevocationFailsAPendingWaitAsEnded() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let connection = try onlyConnection()
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    try send(peer, 2, .waitForm(form: handle))
    expect(await waitUntil { self.host.forms[handle]?.waiting != nil })

    host.revokeControllers([connection])

    let revokedWait = try await reply(peer, 2)

    XCTAssertEqual(failure(revokedWait)?.0, .ended)
    XCTAssertNil(host.forms[handle])
    XCTAssertFalse(windows.hasOpenForm(requester: key))
  }

  /// Catches a dropped connection leaving its form open. The form ends, and a bare terminal
  /// session's tab stays, since the shell is still the requester.
  func testADroppedConnectionEndsItsOpenFormAndKeepsASessionTab() async throws {
    let peer = try await connect()

    _ = try await openForm(peer)

    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    peer.shutdownAndClose()

    expect(await waitUntil { !self.windows.hasOpenForm(requester: key) })
    XCTAssertEqual(windows.discardedForms, [key])
    XCTAssertEqual(windows.endedForms, [])
    XCTAssertTrue(host.forms.isEmpty)
  }

  /// Catches a program that ends after it was answered taking its terminal session's tab with it.
  /// The tab stays until the requester's next form, its shell ending, or the user closing it.
  func testAResolvedSessionTabSurvivesItsProgram() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: submitted)

    _ = try await call(peer, 2, .discardForm(form: handle))

    peer.shutdownAndClose()

    expect(await waitUntil { self.host.sessions.isEmpty })
    XCTAssertEqual(windows.discardedForms, [])
    XCTAssertEqual(windows.endedForms, [])
  }

  /// Catches a shell that ends leaving its resolved tab behind. The session root's removal ends a
  /// terminal-session requester, so the resolved tab closes.
  func testAShellEndingClosesItsRequestersTab() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: submitted)

    _ = try await call(peer, 2, .discardForm(form: handle))

    TestSessionRoot.remove(from: host)

    XCTAssertEqual(windows.endedForms, [key])
  }

  /// Catches answers delivered to a caller that now acts for another pane. The form was asked from
  /// pane 1. Pane 1's session root moves to pane 2 while the wait waits, and the user answers.
  /// The wait fails as ended and carries no answers.
  func testAWaitIsFailedWhenTheCallerNowActsForAnotherPane() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    try send(peer, 2, .waitForm(form: handle))
    expect(await waitUntil { self.host.forms[handle]?.waiting != nil })

    let root = TestSessionRoot.identity

    host.paneRoots[ScriptHost.PaneKey(window: 1, pane: 1)] = nil
    host.paneRoots[ScriptHost.PaneKey(window: 1, pane: 2)] = [root]

    windows.resolveForm(requester: key, with: submitted)

    let result = try await reply(peer, 2)
    let (kind, text) = try XCTUnwrap(failure(result))

    XCTAssertEqual(kind, .ended)
    XCTAssertFalse(text.contains("Ada"))
  }

  /// Catches a wait that reads a result after the caller lost its binding and was granted nothing.
  /// A wait asked after the form resolved is checked as a deferred one is.
  func testAnImmediateWaitIsCheckedAgainToo() async throws {
    let peer = try await connect()
    let handle = try await openForm(peer)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: submitted)

    host.paneRoots[ScriptHost.PaneKey(window: 1, pane: 1)] = nil
    host.paneRoots[ScriptHost.PaneKey(window: 1, pane: 2)] = [TestSessionRoot.identity]

    let movedPaneWait = try await call(peer, 2, .waitForm(form: handle))

    XCTAssertEqual(failure(movedPaneWait)?.0, .ended)
  }

  /// Catches answers delivered to a program that was orphaned while its form waited, such as
  /// `( uniterm ask ... & )` whose shell's child exited. Its ancestry no longer leads to the
  /// session root it was bound to, and `authorize` would unbind it at its next call. No call comes while a
  /// wait waits, so the wait's own check must read the ancestry. The test binds a connection to the
  /// test process's parent as a stand-in for a root the program no longer descends from, and a
  /// connection bound to the root it does descend from still passes.
  func testAWaitIsFailedWhenTheProgramNoLongerDescendsFromItsRoot() throws {
    let parent = try XCTUnwrap(ProcessInspection.parent(of: getpid()))
    let parentRoot = ProcessIdentity(pid: parent.pid, started: parent.started)

    host.recordSessionRoot(parentRoot, sessionGeneration: 1, window: 1, pane: NodeID(rawValue: 1))

    let spec = try FormSpecReader.decode(Data(Self.spec.utf8))

    func holds(boundTo root: ProcessIdentity, id: UInt64) throws -> Bool {
      let (app, peerEnd) = try FramedSocket.pair()

      defer { withExtendedLifetime(peerEnd) {} }

      let peer = ScriptPeer(
        uid: getuid(), pid: getpid(), token: ScriptPeer.liveToken(descriptor: app.rawDescriptor))
      let connection = ScriptConnection(
        id: id, peer: peer, peerStartTime: TestSessionRoot.identity.started, socket: app,
        onOverflow: { _ in })

      connection.bind(to: root, generation: 1)

      let caller = ScriptCaller(connection: id, window: 1, pane: NodeID(rawValue: 1))
      let slot = FormSlot(
        handle: 1, connection: id, caller: caller,
        requester: FormRequester(key: "k", name: "n"), kind: .session, spec: spec)

      return host.formAuthorityHolds(slot, on: connection)
    }

    XCTAssertTrue(try holds(boundTo: TestSessionRoot.identity, id: 10))
    XCTAssertFalse(try holds(boundTo: parentRoot, id: 11))
  }

  /// Catches a stopped host that leaves its forms on screen with nobody to answer them. Stopping
  /// ends each open form through the path a closed connection takes, so the window layer lets go
  /// of it, and a late answer reaches no slot.
  func testStoppingTheHostEndsItsOpenForms() async throws {
    let peer = try await connect()

    _ = try await openForm(peer)

    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    host.stop()

    XCTAssertEqual(windows.discardedForms, [key])
    XCTAssertFalse(windows.hasOpenForm(requester: key))
    XCTAssertTrue(host.forms.isEmpty)
  }

  // MARK: Callers

  /// Catches a caller bound to no pane opening a form. It is refused as other calls are, with a
  /// pending request for the user, and once granted a pane its form opens in that pane's window.
  func testACallerBoundToNoPaneIsRefusedThenGrantedAPane() async throws {
    TestSessionRoot.remove(from: host)

    let peer = try await connect()
    let result = try await call(peer, 1, .openForm(spec: Self.spec))
    let (kind, text) = try XCTUnwrap(failure(result))

    XCTAssertEqual(kind, .refused)
    XCTAssertTrue(text.contains("not running in a uniterm pane"), text)
    XCTAssertTrue(windows.askedForms.isEmpty)

    let pending = try XCTUnwrap(host.allPendingRequests().first)

    TestSessionRoot.record(in: host, window: 3, pane: NodeID(rawValue: 4))

    XCTAssertEqual(
      host.grantAccess(connection: pending.id, window: 3, pane: NodeID(rawValue: 4)), .granted)

    _ = try await openForm(peer, id: 2)

    let asked = try XCTUnwrap(windows.askedForms.first)

    XCTAssertEqual(asked.caller.window, 3)
    XCTAssertEqual(asked.caller.pane, NodeID(rawValue: 4))
    XCTAssertTrue(asked.requester.key.hasPrefix("connection:"), asked.requester.key)
    XCTAssertTrue(asked.requester.name.contains("granted Pane 4"), asked.requester.name)
    XCTAssertFalse(asked.requester.name.contains("Terminal session"), asked.requester.name)
  }

  /// Catches the prompt that the proposal rules out for a bare caller, and its absence for another
  /// power. Asking passes with nothing waiting for the user, while the same caller's clipboard
  /// read is held for an answer.
  func testABareCallerAsksWithoutAPromptButAnotherPowerStillAsks() async throws {
    let peer = try await connect()

    _ = try await openForm(peer)

    XCTAssertFalse(host.hasPendingWork)

    try send(peer, 2, .readClipboard)
    expect(await waitUntil { self.host.hasPendingWork })
  }

  /// Catches a header that names more than the transport established. A bare caller's header is
  /// its terminal session in the asking pane, and nothing it sent changes it.
  func testABareCallersHeaderNamesItsTerminalSessionAndPane() async throws {
    let peer = try await connect()

    _ = try await openForm(peer)

    let asked = try XCTUnwrap(windows.askedForms.first)

    XCTAssertEqual(asked.requester.name, "Terminal session in Pane 1")
    XCTAssertTrue(asked.requester.key.hasPrefix("session:"), asked.requester.key)
  }

  /// Catches two terminal tabs of one pane sharing a requester, which would refuse one as busy, and
  /// one tab splitting into two requesters. A session root and its generation key the requester.
  func testEachTerminalTabIsItsOwnRequester() throws {
    func connection(id: UInt64, root: ProcessIdentity, generation: UInt64) throws -> (
      ScriptConnection, FramedSocket
    ) {
      let (app, peerEnd) = try FramedSocket.pair()
      let peer = ScriptPeer(
        uid: getuid(), pid: getpid(), token: ScriptPeer.liveToken(descriptor: app.rawDescriptor))
      let made = ScriptConnection(
        id: id, peer: peer, peerStartTime: TestSessionRoot.identity.started, socket: app,
        onOverflow: { _ in })

      made.bind(to: root, generation: generation)

      return (made, peerEnd)
    }

    let tabA = TestSessionRoot.identity
    let tabB = ProcessIdentity(pid: tabA.pid &+ 1, started: tabA.started)
    let caller = ScriptCaller(connection: 1, window: 1, pane: NodeID(rawValue: 1))

    let (first, endA) = try connection(id: 1, root: tabA, generation: 1)
    let (again, endB) = try connection(id: 2, root: tabA, generation: 1)
    let (second, endC) = try connection(id: 3, root: tabB, generation: 1)
    let (restarted, endD) = try connection(id: 4, root: tabA, generation: 2)

    defer { withExtendedLifetime([endA, endB, endC, endD]) {} }

    let keys = [first, again, second, restarted].map {
      host.formRequester(for: $0, caller: caller).0.key
    }

    XCTAssertEqual(keys[0], keys[1], "one tab's next command is one requester")
    XCTAssertNotEqual(keys[0], keys[2], "two tabs of a pane are two requesters")
    XCTAssertNotEqual(keys[0], keys[3], "a restarted session is another requester")
  }

  // MARK: Declared runs

  private func admitRun(
    connection: UInt64, artifact: ControllerArtifact, id: String, scopes: Set<ControllerPermission>,
    standing: Set<ControllerPermission>
  ) throws {
    let found = try XCTUnwrap(host.listener.findConnection(connection))
    let token = try XCTUnwrap(found.peer.token)

    host.controllerRuns[connection] = ControllerRun(
      identity: ControllerIdentity(
        controllerID: id, version: "version", keyFingerprint: nil, artifact: artifact),
      name: "a name that proves nothing", entryKind: .janet, entryPath: "main.janet",
      scopes: scopes, approval: .session, standing: standing, pid: getpid(),
      generation: token.pidVersion, connection: connection, sourceRoot: TestSessionRoot.identity,
      window: 1, pane: NodeID(rawValue: 1), snapshot: directory)
  }

  /// Catches a run that never declared the power opening a form, and a message that does not say
  /// which kind it lacks. The refusal names `ask-user`, and nothing opens.
  func testAnUndeclaredUseIsRefusedWithTheKindNamed() async throws {
    let peer = try await connect()

    _ = try await call(peer, 1, .postStatus(level: .info, text: "begin"))
    try admitRun(
      connection: try onlyConnection(), artifact: .package, id: "dev.example.notes",
      scopes: [.paneControl], standing: [.paneControl])

    let refused = try await call(peer, 2, .openForm(spec: Self.spec))
    let (kind, text) = try XCTUnwrap(failure(refused))

    XCTAssertEqual(kind, .refused)
    XCTAssertTrue(text.contains("ask-user"), text)
    XCTAssertTrue(windows.askedForms.isEmpty)
  }

  /// Catches a declared run's header that shows a name the run chose, or a bare caller's wording.
  /// A package shows its verified ID, and a declared file says so, and a run's form is keyed by the
  /// run.
  func testADeclaredRunsHeaderNamesWhatWasVerified() async throws {
    let peer = try await connect()

    _ = try await call(peer, 1, .postStatus(level: .info, text: "begin"))

    let connection = try onlyConnection()

    try admitRun(
      connection: connection, artifact: .file, id: "notes.janet", scopes: [.askUser],
      standing: [.askUser])

    _ = try await openForm(peer, id: 2)

    let asked = try XCTUnwrap(windows.askedForms.first)

    XCTAssertEqual(asked.requester.name, "notes.janet (declared file)")
    XCTAssertEqual(asked.requester.key, "run:\(connection)")
  }

  /// Catches a run's end leaving its tab behind. A run's form is keyed by the run, so the run's end
  /// closes the tab, resolved or not.
  func testARunsEndClosesItsTab() async throws {
    let peer = try await connect()

    _ = try await call(peer, 1, .postStatus(level: .info, text: "begin"))
    try admitRun(
      connection: try onlyConnection(), artifact: .package, id: "dev.example.notes",
      scopes: [.askUser], standing: [.askUser])

    let handle = try await openForm(peer, id: 2)
    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(requester: key, with: submitted)

    _ = try await call(peer, 3, .waitForm(form: handle))

    peer.shutdownAndClose()

    expect(await waitUntil { !self.windows.endedForms.isEmpty })
    XCTAssertEqual(windows.endedForms, [key])
  }

  // MARK: REPL

  /// Catches a REPL's header that names a terminal session, and a stop request that leaves the
  /// REPL's VM waiting. The header names the REPL's pane. The stop fails the pending wait as
  /// ended, the connection stays, and the REPL's next call is answered.
  func testAReplsStopFailsItsPendingWaitAndKeepsItsConnection() async throws {
    let channel = openTestRepl(host: host)
    let token = try XCTUnwrap(ReplEnvironmentHex.decode(channel.launch.token))
    let peer = try ScriptFixtures.connectPeer(path: channel.launch.address)

    peers.append(peer)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try peer.send(ScriptHelperMessage.attach(token: token).frame())

    guard case .history = try await ScriptFixtures.readMessage(peer) else {
      return XCTFail("the REPL was not attached")
    }

    let handle = try await openForm(peer)
    let asked = try XCTUnwrap(windows.askedForms.first)

    XCTAssertEqual(asked.requester.name, "REPL in Pane 1")
    XCTAssertTrue(asked.requester.key.hasPrefix("connection:"), asked.requester.key)

    try send(peer, 2, .waitForm(form: handle))
    expect(await waitUntil { self.host.forms[handle]?.waiting != nil })

    channel.requestStop()

    let stoppedWait = try await reply(peer, 2)

    XCTAssertEqual(failure(stoppedWait)?.0, .ended)
    XCTAssertTrue(windows.hasOpenForm(requester: asked.requester.key), "a stop closes no form")

    let laterCall = try await call(peer, 3, .waitForm(form: 999_999))

    XCTAssertEqual(
      failure(laterCall)?.0, .notFound,
      "the REPL's connection still serves calls")
  }
}

/// The slots of the form handles, without a host.
final class FormSlotsTests: XCTestCase {
  private func slot(_ handle: UInt64, connection: UInt64, settled: Bool) throws -> FormSlot {
    let spec = try FormSpecReader.decode(
      Data(#"{"items": [{"id": "a", "text": "A?", "type": "boolean"}]}"#.utf8))

    var made = FormSlot(
      handle: handle, connection: connection,
      caller: ScriptCaller(connection: connection, window: 1, pane: NodeID(rawValue: 1)),
      requester: FormRequester(key: "k\(handle)", name: "n"), kind: .session, spec: spec)

    if settled { made.outcome = .dismissed }

    return made
  }

  /// Catches a table that refuses a connection whose results have all settled, and one that makes
  /// room by dropping a form that is still open. A connection with every slot open has no room.
  /// With a settled slot it has room, and the oldest settled one is the one dropped.
  @MainActor
  func testRoomComesOnlyFromASettledSlotAndTheOldestGoesFirst() throws {
    var slots = FormSlots()

    for handle in 1...UInt64(FormSlots.perConnection) {
      slots.insert(try slot(handle, connection: 1, settled: false))
    }

    XCTAssertFalse(slots.hasRoom(for: 1))
    XCTAssertTrue(slots.hasRoom(for: 2), "another connection's slots are its own")

    slots.update(3) { $0.outcome = .dismissed }
    slots.update(5) { $0.outcome = .dismissed }

    XCTAssertTrue(slots.hasRoom(for: 1))

    slots.insert(try slot(100, connection: 1, settled: false))

    XCTAssertNil(slots[3], "the oldest settled slot made the room")
    XCTAssertNotNil(slots[5])
    XCTAssertNotNil(slots[1], "a slot still open is never dropped")
    XCTAssertEqual(slots.slots(of: 1).count, FormSlots.perConnection)
  }

  /// Catches a handle that a freed slot gives to the next form, which would let a stale handle
  /// read another form's answers.
  @MainActor
  func testAHandleIsNeverReused() throws {
    var slots = FormSlots()
    let first = try XCTUnwrap(slots.nextHandle())

    slots.insert(try slot(first, connection: 1, settled: true))
    slots.remove(first)

    XCTAssertGreaterThan(try XCTUnwrap(slots.nextHandle()), first)
  }
}

private struct Unexpected: Error {
  let text: String
}
