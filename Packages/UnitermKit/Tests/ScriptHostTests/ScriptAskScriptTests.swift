import ControllerTestSupport
import Darwin
import Foundation
import QuestionForm
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// A Janet script that asks forms, run through the real helper, the wire, and the real host, with a
/// stand-in for the window layer that hands the test each form. They prove each shorthand and the
/// full form from a script, that Ctrl-C during a wait discards the form and stops the script, and
/// that the session matches the wait's reply and the discard's by request ID in either order.
/// They cannot prove how a form looks, which the UI tests prove.
@MainActor
final class ScriptAskScriptTests: XCTestCase {
  private var directory: URL!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!
  private var answered = 0

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    windows = FakeWindowAPI()

    let center = StatusCenter()

    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows)
    host.start()

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  private func answer(_ outcome: FormOutcome) async throws {
    let arrived = await waitUntil { self.windows.askedForms.count > self.answered }

    XCTAssertTrue(arrived, "the script never asked form \(answered + 1)")

    let key = try XCTUnwrap(windows.askedForms[answered].requester.key)

    answered += 1
    windows.resolveForm(requester: key, with: outcome)
  }

  /// Catches a helper that asks another question than its name says, or hands back another shape
  /// than its answer. A script asks each shorthand and the full form in turn, and prints what it
  /// got. The forms the app received are the ones the helpers describe.
  func testAScriptAsksEachShorthandAndTheFullForm() async throws {
    let process = try ScriptFixtures.start(
      socket: host.instanceAddress, script: ScriptFixtures.script("ask-all"))

    try await answer(.submitted(submission: 1, action: "yes", answers: [:]))
    try await answer(.submitted(submission: 1, action: "ok", answers: ["answer": .text("dev")]))
    try await answer(
      .submitted(submission: 1, action: "ok", answers: ["answer": .list(["a", "c"])]))
    try await answer(.submitted(submission: 1, action: "ok", answers: ["answer": .number("7")]))
    try await answer(
      .submitted(submission: 1, action: "ok", answers: ["answer": .text("#FF0000")]))
    try await answer(
      .submitted(submission: 1, action: "ok", answers: ["answer": .text("/tmp/out.json")]))
    try await answer(
      .submitted(submission: 1, action: "go", answers: ["region": .text("eu")]))
    try await answer(.cancelled(action: "cancel"))

    let run = try await ScriptFixtures.finish(process)

    XCTAssertEqual(run.status, 0, run.standardError)
    XCTAssertEqual(
      run.standardOutput,
      "true\ndev\na,c\n7\n#ff0000ff\n/tmp/out.json\ngo eu\nnothing\ndone\n")

    let forms = windows.askedForms.map(\.spec)

    XCTAssertEqual(forms.count, 8)
    XCTAssertEqual(forms[0].buttons.map(\.id), ["yes", "no"])
    XCTAssertEqual(forms[7].questions.map(\.id), ["answer"])
    XCTAssertEqual(forms[6].title, "Deploy settings")
    XCTAssertEqual(forms[6].questions.map(\.id), ["region"])
    XCTAssertEqual(forms[6].buttons.map(\.id), ["go", "cancel"])
    XCTAssertTrue(host.forms.isEmpty, "a handle outlived the script")
  }

  /// Catches Ctrl-C that leaves the form open or lets the script go on. The script is stopped
  /// before its next line prints, the app closes the form as ended, and no handle is left. The
  /// helper exits as a run that Ctrl-C stopped does.
  func testCtrlCDuringAWaitDiscardsTheFormAndStopsTheScript() async throws {
    let process = try ScriptFixtures.start(
      socket: host.instanceAddress, script: ScriptFixtures.script("ask-wait"))

    let arrived = await waitUntil { !self.windows.askedForms.isEmpty }

    XCTAssertTrue(arrived)

    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    XCTAssertEqual(process.signal(SIGINT), .sent)

    let run = try await ScriptFixtures.finish(process)

    XCTAssertEqual(run.exit, .exited(130), run.standardError)
    XCTAssertEqual(run.standardOutput, "before\n")
    XCTAssertEqual(windows.discardedForms, [key])
    XCTAssertFalse(windows.hasOpenForm(requester: key))
    XCTAssertTrue(host.forms.isEmpty)
    XCTAssertFalse(run.standardError.contains("nobody asked"), run.standardError)
  }

  /// Catches an interrupt that waits for the reply it no longer needs, or reads the replies as one.
  /// An app that answers the discard before the wait and one that answers the wait before the
  /// discard both end the run with the interrupted status, and neither reply is taken for the
  /// other's.
  func testTheWaitsReplyAndTheDiscardsReplyArriveInEitherOrder() async throws {
    for discardFirst in [true, false] {
      let path = directory.appendingPathComponent("order\(discardFirst).sock").path
      let server = try FakeApp.listen(path: path)
      let seen = SeenFlag()

      let served = Task.detached { () -> [String] in
        let accepted = accept(server, nil, nil)
        let socket = FramedSocket(descriptor: accepted)

        defer { socket.shutdownAndClose() }

        func next() -> ScriptHelperMessage? {
          guard let frame = try? socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))
          else { return nil }

          return try? ScriptHelperMessage.decode(type: frame.type, body: frame.body)
        }

        var names: [String] = []
        var waitID: UInt32?

        guard next() != nil else { return names }

        try? socket.send(ScriptAppMessage.hello(version: ScriptProtocol.version).frame())

        guard case .identity? = next() else { return names }
        guard case .undeclaredBegin? = next() else { return names }

        try? socket.send(ScriptAppMessage.undeclaredAdmitted.frame())

        while let message = next() {
          guard case .request(let id, let call) = message else { continue }

          switch call {
          case .openForm:
            names.append("open")
            try? socket.send(
              ScriptAppMessage.reply(
                id: id, result: .ok((try? ScriptValue.integer(4).encoded()) ?? Data())
              ).frame())

          case .waitForm:
            names.append("wait")
            waitID = id
            seen.set()

          case .discardForm:
            names.append("discard")

            let ended = ScriptAppMessage.reply(id: waitID ?? 0, result: .failure(.ended, "ended"))
            let freed = ScriptAppMessage.reply(id: id, result: .ok(Data()))

            for reply in discardFirst ? [freed, ended] : [ended, freed] {
              try? socket.send(reply.frame())
            }

          default:
            break
          }
        }

        return names
      }

      defer { Darwin.close(server) }

      let process = try ScriptFixtures.start(
        socket: path, script: ScriptFixtures.script("ask-wait"))

      let waiting = await pollUntil(timeout: .seconds(30)) { seen.isSet }

      XCTAssertTrue(waiting, "the script never waited")
      XCTAssertEqual(process.signal(SIGINT), .sent)

      let run = try await ScriptFixtures.finish(process)

      XCTAssertEqual(run.exit, .exited(130), "discardFirst \(discardFirst): \(run.standardError)")
      XCTAssertEqual(run.standardOutput, "before\n")

      let names = await served.value

      XCTAssertEqual(names, ["open", "wait", "discard"], "discardFirst \(discardFirst)")
    }
  }

  /// Catches a submit that lands at the moment of Ctrl-C being undone by the discard. The answers
  /// reach the wait, and the discard that follows frees the handle and leaves the tab as the
  /// submit left it, since the host only knows that the answers were sent.
  func testASubmitJustBeforeTheDiscardIsDeliveredAndTheDiscardLeavesTheTab() async throws {
    let peer = try await ScriptFixtures.openPeer(host: host)

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.begin(name: "bash").frame())

    func send(_ id: UInt32, _ call: ScriptCall) throws {
      try peer.send(ScriptHelperMessage.request(id: id, call: call).frame())
    }

    func reply(_ id: UInt32) async throws -> ScriptResult {
      while true {
        if case .reply(let answered, let result) = try await ScriptFixtures.readMessage(peer),
          answered == id
        {
          return result
        }
      }
    }

    try send(1, .openForm(spec: #"{"items": [{"id": "a", "text": "x", "type": "string"}]}"#))

    guard case .ok(let payload) = try await reply(1),
      case .integer(let handle) = try ScriptValue.decode(payload)
    else { return XCTFail("the form did not open") }

    try send(2, .waitForm(form: handle))

    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    windows.resolveForm(
      requester: key, with: .submitted(submission: 1, action: "ok", answers: ["a": .text("v")]))
    try send(3, .discardForm(form: handle))

    guard case .ok(let waited) = try await reply(2),
      case .record(let fields) = try ScriptValue.decode(waited)
    else { return XCTFail("the wait did not deliver the answers") }

    XCTAssertEqual(fields["answers"], .record(["a": .string("v")]))

    guard case .ok = try await reply(3) else { return XCTFail("the discard failed") }

    XCTAssertTrue(windows.discardedForms.isEmpty, "the discard touched a tab that was answered")
    XCTAssertTrue(host.forms.isEmpty)
  }
}

/// A flag a detached task sets and the test polls.
private final class SeenFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }

    return value
  }
}
