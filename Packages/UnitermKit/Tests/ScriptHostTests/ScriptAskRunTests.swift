import ControllerPackage
import ControllerTestSupport
import Darwin
import Foundation
import QuestionForm
import ScriptTestSupport
import ScriptWire
import XCTest

@testable import ScriptHost

/// `uniterm ask` as a user runs it: the real command process against a real listener in this
/// process, with a stand-in for the window layer that hands the test each form. They prove the
/// output and the exit status of each outcome, the form the app receives, and that the form ends
/// with the process. They cannot prove how a form looks or where it opens, which the UI tests
/// prove, and they cannot prove the shipped command's sandbox, which `CommandHelperSandboxTests`
/// runs.
@MainActor
final class ScriptAskRunTests: XCTestCase {
  private var directory: URL!
  private var work: URL!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!
  private var settings: TestScriptSettings!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    settings = TestScriptSettings()
    windows = FakeWindowAPI()
    host = try ScriptFixtures.makeFileHost(
      directory: directory, work: work, helper: AcceptingHelper(), settings: settings.store,
      windows: windows)
  }

  override func tearDown() async throws {
    host.stop()
    settings.remove()
    try? FileManager.default.removeItem(at: directory)
    ControllerSnapshot.removeStale(in: work.appendingPathComponent("runs"))
    try? FileManager.default.removeItem(at: work)
  }

  // MARK: Helpers

  private struct Asking {
    let process: HelperHandle
    let input: Pipe
  }

  private var answered = 0

  /// Starts `uniterm ask` with exactly `arguments`. A form's JSON goes in on standard input, which
  /// closes at once so the command reads to its end.
  ///
  /// `ignoringSIGPIPE` starts it through a shell that ignores SIGPIPE first, as a caller may leave
  /// it. The fixture resets the signal for a process it starts itself.
  private func launch(
    _ arguments: [String], form: String? = nil, ignoringSIGPIPE: Bool = false,
    standardOutput: HelperOutput = .captured
  ) throws -> Asking {
    let input = Pipe()
    var environment = ProcessInfo.processInfo.environment

    environment["UNITERM_SOCKET"] = nil

    let process = try HelperHandle.spawn(
      executable: ignoringSIGPIPE ? URL(fileURLWithPath: "/bin/sh") : ScriptFixtures.helper(),
      arguments: ignoringSIGPIPE
        ? ["-c", "trap '' PIPE; exec \"$0\" \"$@\"", ScriptFixtures.helper().path, "ask"]
          + arguments
        : ["ask"] + arguments,
      environment: environment, standardInput: .file(input.fileHandleForReading),
      standardOutput: standardOutput,
      deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)])

    if let form { try input.fileHandleForWriting.write(contentsOf: Data(form.utf8)) }

    try input.fileHandleForWriting.close()

    return Asking(process: process, input: input)
  }

  /// Starts `uniterm ask kind` against the test's host, with the flags and words after it.
  private func start(
    kind: String, _ arguments: [String], form: String? = nil, socket: String? = nil,
    ignoringSIGPIPE: Bool = false, standardOutput: HelperOutput = .captured
  ) throws -> Asking {
    try launch(
      [kind, "--socket", socket ?? host.instanceAddress] + arguments, form: form,
      ignoringSIGPIPE: ignoringSIGPIPE, standardOutput: standardOutput)
  }

  /// Waits for the app to hold `count` forms.
  private func waitForForms(_ count: Int = 1) async -> Bool {
    await waitUntil { self.windows.askedForms.count >= count }
  }

  /// Answers the next form the app has not answered yet, once the command has asked it.
  private func answer(_ outcome: FormOutcome) async throws {
    let arrived = await waitForForms(answered + 1)

    XCTAssertTrue(arrived, "the command never asked")

    let key = try XCTUnwrap(windows.askedForms[answered].requester.key)

    answered += 1
    windows.resolveForm(requester: key, with: outcome)
  }

  private func submitted(_ answers: [String: FormAnswer], action: String = "ok") -> FormOutcome {
    .submitted(submission: 1, action: action, answers: answers)
  }

  private func finish(_ asking: Asking) async throws -> HelperRun {
    try await ScriptFixtures.finish(asking.process)
  }

  /// Runs one shorthand to its answer and returns what it did.
  private func ask(
    _ kind: String, _ arguments: [String], answering outcome: FormOutcome
  ) async throws -> HelperRun {
    let asking = try start(kind: kind, arguments)

    try await answer(outcome)

    return try await finish(asking)
  }

  // MARK: Answers

  /// Catches a shorthand that prints more than its value, prints it in another shape, or exits
  /// with another status. Each shorthand's output and `--json` output are pinned.
  func testEachShorthandPrintsOnlyItsValue() async throws {
    let cases:
      [(
        kind: String, arguments: [String], answers: [String: FormAnswer], out: String, json: String
      )] = [
        ("text", ["Branch?"], ["answer": .text("main")], "main\n", "\"main\"\n"),
        ("choose", ["Which?", "a", "b"], ["answer": .text("b")], "b\n", "\"b\"\n"),
        (
          "choose", ["--multiple", "Which?", "a", "b"], ["answer": .list(["a", "b"])], "a\nb\n",
          "[\"a\",\"b\"]\n"
        ),
        ("number", ["N?"], ["answer": .number("2.5")], "2.5\n", "2.5\n"),
        ("number", ["--integer", "N?"], ["answer": .number("7")], "7\n", "7\n"),
        ("color", ["C?"], ["answer": .text("#FF0000")], "#ff0000ff\n", "\"#ff0000ff\"\n"),
        (
          "file", ["F?"], ["answer": .text("/tmp/a b.json")], "/tmp/a b.json\n",
          "\"/tmp/a b.json\"\n"
        ),
      ]

    for item in cases {
      let outcome = submitted(item.answers)

      let plain = try await ask(item.kind, item.arguments, answering: outcome)

      XCTAssertEqual(plain.status, 0, "\(item.kind): \(plain.standardError)")
      XCTAssertEqual(plain.standardOutput, item.out, item.kind)
      XCTAssertEqual(plain.standardError, "", item.kind)

      let json = try await ask(
        item.kind, ["--json"] + item.arguments, answering: outcome)

      XCTAssertEqual(json.status, 0, "\(item.kind): \(json.standardError)")
      XCTAssertEqual(json.standardOutput, item.json, item.kind)

    }
  }

  /// Catches the form the app receives differing from the question the user typed. The spec the
  /// host decoded names the one question and its type, and the text flags reach it.
  func testTheAppReceivesTheQuestionTheFlagsDescribe() async throws {
    let asking = try start(
      kind: "text", ["--default", "main", "--pattern", "^[a-z]+$", "Branch?"])

    try await answer(submitted(["answer": .text("dev")]))

    let result = try await finish(asking)
    let question = try XCTUnwrap(windows.askedForms.first?.spec.questions.first)

    XCTAssertEqual(result.standardOutput, "dev\n")
    XCTAssertEqual(question.id, "answer")
    XCTAssertEqual(question.text, "Branch?")
    XCTAssertTrue(question.isRequired)
  }

  /// Catches a confirm that exits with the wrong status for Yes, No, or a closed form. Yes is 0, the
  /// cancel button No is 1, and closing is 3 with a reason on standard error. Standard output is
  /// empty in all three.
  func testConfirmExitsZeroForYesOneForNoAndThreeWhenClosed() async throws {
    let yes = try await ask(
      "confirm", ["Delete 3 files?"], answering: submitted([:], action: "yes"))

    XCTAssertEqual(yes.status, 0, yes.standardError)
    XCTAssertEqual(yes.standardOutput, "")
    XCTAssertEqual(windows.askedForms.last?.spec.buttons.map(\.id), ["yes", "no"])
    XCTAssertEqual(
      windows.askedForms.last?.spec.buttons.map(\.role), [.primary, .cancel])

    let no = try await ask("confirm", ["Delete?"], answering: .cancelled(action: "no"))

    XCTAssertEqual(no.status, 1, no.standardError)
    XCTAssertEqual(no.standardOutput, "")
    XCTAssertEqual(no.standardError, "")

    let closed = try await ask("confirm", ["Delete?"], answering: .dismissed)

    XCTAssertEqual(closed.status, 3, closed.standardError)
    XCTAssertEqual(closed.standardOutput, "")
    XCTAssertFalse(closed.standardError.isEmpty)
  }

  /// Catches a cancel that exits as an answer, which would let `x=$(uniterm ask text ...) && use`
  /// run after the user said no. A cancel press and a close both exit 3 with nothing on standard
  /// output, for a shorthand and for a full form.
  func testACancelOrCloseExitsThreeWithNothingOnStandardOutput() async throws {
    for outcome in [FormOutcome.cancelled(action: "cancel"), .dismissed] {
      let text = try await ask("text", ["Name?"], answering: outcome)

      XCTAssertEqual(text.status, 3, text.standardError)
      XCTAssertEqual(text.standardOutput, "")
      XCTAssertFalse(text.standardError.isEmpty)

      let asking = try start(
        kind: "form", [], form: #"{"items": [{"id": "a", "text": "x", "type": "string"}]}"#)

      try await answer(outcome)

      let full = try await finish(asking)

      XCTAssertEqual(full.status, 3, full.standardError)
      XCTAssertEqual(full.standardOutput, "")

    }
  }

  /// Catches a full form whose result is lost or reshaped. The spec on standard input reaches the
  /// app whole, and the result prints as JSON with the handle, submission, action, and answers.
  func testAFullFormIsReadFromStandardInputAndItsResultIsPrintedAsJSON() async throws {
    let spec = """
      {"title": "Deploy settings", "items": [
        {"block": "notice", "level": "warning", "text": "Production."},
        {"id": "region", "text": "Region?", "type": "choice", "choices": ["us", "eu"]},
        {"id": "count", "text": "Count?", "type": "integer", "default": 3}],
       "actions": [{"id": "deploy", "label": "Deploy", "role": "primary"},
                   {"id": "cancel", "role": "cancel"}]}
      """

    let asking = try start(kind: "form", [], form: spec)

    try await answer(
      submitted(["region": .text("eu"), "count": .number("4")], action: "deploy"))

    let result = try await finish(asking)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(windows.askedForms.first?.spec.title, "Deploy settings")
    XCTAssertEqual(windows.askedForms.first?.spec.questions.map(\.id), ["region", "count"])

    let printed = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? NSDictionary)

    XCTAssertEqual(printed["action"] as? String, "deploy")
    XCTAssertEqual(printed["submission"] as? Int, 1)
    XCTAssertNotNil(printed["form"] as? Int)
    XCTAssertEqual(
      printed["answers"] as? NSDictionary, ["region": "eu", "count": 4] as NSDictionary)
    XCTAssertEqual(result.standardOutput.last, "\n")
  }

  // MARK: Failures

  /// Catches a usage mistake that reaches the app, or exits with another status. The command
  /// prints its usage and exits 64 before it connects.
  func testAUsageErrorExitsSixtyFourAndConnectsToNothing() async throws {
    for arguments in [[], ["nope"], ["confirm"], ["choose", "only a prompt"]] {
      let asking = try launch(arguments)
      let result = try await finish(asking)

      XCTAssertEqual(result.status, 64, "\(arguments): \(result.standardError)")
      XCTAssertTrue(result.standardError.contains("usage: uniterm ask"), result.standardError)
      XCTAssertEqual(result.standardOutput, "")
    }

    XCTAssertTrue(windows.askedForms.isEmpty)
  }

  /// Catches a spec the app refuses exiting as anything but a spec error. The refusal names the
  /// field, nothing is printed on standard output, and no form opens.
  func testASpecTheAppRefusesExitsSixtyFiveNamingTheField() async throws {
    let bad = try start(kind: "form", [], form: #"{"items": [], "extra": 1}"#)
    let result = try await finish(bad)

    XCTAssertEqual(result.status, 65, result.standardError)
    XCTAssertTrue(result.standardError.contains("extra"), result.standardError)
    XCTAssertEqual(result.standardOutput, "")

    let pattern = try start(kind: "text", ["--pattern", "(?<=a)b", "Name?"])
    let refused = try await finish(pattern)

    XCTAssertEqual(refused.status, 65, refused.standardError)
    XCTAssertTrue(windows.askedForms.isEmpty)

    let large = try start(
      kind: "form", [],
      form: "{\"items\": [], \"title\": \"" + String(repeating: "x", count: 40_000) + "\"}")
    let tooLarge = try await finish(large)

    XCTAssertEqual(tooLarge.status, 65, tooLarge.standardError)
    XCTAssertTrue(tooLarge.standardError.contains("larger than"), tooLarge.standardError)
  }

  /// Catches a busy refusal exiting as a failure that cannot be retried. A form past the cap is the
  /// wire's busy kind, which exits 75.
  func testABusyRefusalExitsSeventyFive() async throws {
    windows.formCap = 0

    let asking = try start(kind: "text", ["Name?"])
    let result = try await finish(asking)

    XCTAssertEqual(result.status, 75, result.standardError)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertFalse(result.standardError.isEmpty)
  }

  /// Catches a refusal that exits as unreachable or as an answer. The app reached and said no, so
  /// the status is the refusal's, which a caller must not retry.
  func testARefusalExitsSeventySeven() async throws {
    windows.formRefusal = .refused("uniterm cannot show a form here")

    let asking = try start(kind: "text", ["Name?"])
    let result = try await finish(asking)

    XCTAssertEqual(result.status, 77, result.standardError)
    XCTAssertTrue(result.standardError.contains("cannot show a form here"), result.standardError)
    XCTAssertEqual(result.standardOutput, "")
  }

  /// Catches a form that ended exiting as cancelled or as an answer. The run's end, a revoked
  /// authority, and a closed connection fail the wait as ended, which exits 4.
  func testAFormThatEndedExitsFourWithNothingOnStandardOutput() async throws {
    let asking = try start(kind: "text", ["Name?"])

    try await answer(.ended)

    let result = try await finish(asking)

    XCTAssertEqual(result.status, 4, result.standardError)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertFalse(result.standardError.isEmpty)
  }

  /// Catches an app that is not there exiting as a usage error or hanging. A missing socket is
  /// unreachable, 69, with a message that says to start uniterm.
  func testAnAppThatIsNotThereExitsSixtyNine() async throws {
    let asking = try start(
      kind: "text", ["Name?"], socket: directory.appendingPathComponent("none.sock").path)
    let result = try await finish(asking)

    XCTAssertEqual(result.status, 69, result.standardError)
    XCTAssertEqual(result.standardOutput, "")
  }

  /// Catches a command that talks to an app of another version. The old app greets with another
  /// version, the command ends at the hello with 70, and it sends nothing after it.
  func testTheCommandRefusesAnAppOfAnotherVersionAtTheHello() async throws {
    let path = directory.appendingPathComponent("old.sock").path
    let server = try FakeApp.listen(path: path)

    let seen = Task.detached { () -> Bool in
      let accepted = accept(server, nil, nil)
      let socket = FramedSocket(descriptor: accepted)

      defer { socket.shutdownAndClose() }

      guard let frame = try? socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:)),
        (try? ScriptHelperMessage.decode(type: frame.type, body: frame.body))
          == .hello(version: ScriptProtocol.version)
      else { return false }

      try? socket.send(ScriptAppMessage.hello(version: ScriptProtocol.version + 1).frame())

      return (try? socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))) == nil
    }

    defer { Darwin.close(server) }

    let asking = try start(kind: "text", ["Name?"], socket: path)
    let result = try await finish(asking)

    XCTAssertEqual(result.status, 70, result.standardError)
    XCTAssertTrue(
      result.standardError.contains(
        ScriptProtocol.versionMismatchText(
          program: ScriptProtocol.version, uniterm: ScriptProtocol.version + 1)),
      result.standardError)

    let sentNothingAfterTheHello = await seen.value

    XCTAssertTrue(sentNothingAfterTheHello)
  }

  /// Catches a lost connection that exits as another status or hangs. An app that admits the
  /// session, takes the form, and closes while the command waits makes the command exit 74.
  func testAConnectionLostWhileWaitingExitsSeventyFour() async throws {
    let path = directory.appendingPathComponent("drop.sock").path
    let server = try FakeApp.listen(path: path)

    let served = Task.detached { () -> Bool in
      let accepted = accept(server, nil, nil)
      let socket = FramedSocket(descriptor: accepted)

      defer { socket.shutdownAndClose() }

      func next() -> ScriptHelperMessage? {
        guard let frame = try? socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))
        else { return nil }

        return try? ScriptHelperMessage.decode(type: frame.type, body: frame.body)
      }

      guard next() != nil else { return false }

      try? socket.send(ScriptAppMessage.hello(version: ScriptProtocol.version).frame())

      guard case .identity? = next() else { return false }
      guard case .questionBegin? = next() else { return false }

      try? socket.send(ScriptAppMessage.questionOnlyAdmitted.frame())

      guard case .request(let id, .openForm)? = next() else { return false }

      let handle = (try? ScriptValue.integer(1).encoded()) ?? Data()

      try? socket.send(ScriptAppMessage.reply(id: id, result: .ok(handle)).frame())

      guard case .request(_, .waitForm)? = next() else { return false }

      return true
    }

    defer { Darwin.close(server) }

    let asking = try start(kind: "text", ["Name?"], socket: path)
    let result = try await finish(asking)

    XCTAssertEqual(result.status, 74, result.standardError)
    XCTAssertEqual(result.standardOutput, "")

    let followed = await served.value

    XCTAssertTrue(followed)
  }

  /// Catches Ctrl-C that is caught, or one that leaves the form open. The command keeps SIGINT's
  /// default, so it dies of the signal, which a shell reports as 130, and the app closes the form
  /// when the connection closes.
  func testCtrlCEndsTheCommandAndTheAppClosesTheForm() async throws {
    let asking = try start(kind: "text", ["Name?"])

    let arrived = await waitForForms()

    XCTAssertTrue(arrived)

    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    XCTAssertTrue(windows.hasOpenForm(requester: key))
    XCTAssertEqual(asking.process.signal(SIGINT), .sent)

    let result = try await finish(asking)

    XCTAssertEqual(result.exit, .signalled(SIGINT))
    XCTAssertEqual(result.standardOutput, "")

    let closed = await waitUntil { !self.windows.hasOpenForm(requester: key) }

    XCTAssertTrue(closed, "the form outlived its command")
  }

  /// Catches a handle left behind after an answer, which would leave the form's result slot held
  /// until the connection closes. An app that records its requests sees the command ask, wait, and
  /// then discard the same handle, on the connection it still holds.
  func testTheCommandDiscardsTheHandleAfterTheAnswer() async throws {
    let path = directory.appendingPathComponent("record.sock").path
    let server = try FakeApp.listen(path: path)

    let seen = Task.detached { () -> [ScriptCall] in
      let accepted = accept(server, nil, nil)
      let socket = FramedSocket(descriptor: accepted)

      defer { socket.shutdownAndClose() }

      func next() -> ScriptHelperMessage? {
        guard let frame = try? socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))
        else { return nil }

        return try? ScriptHelperMessage.decode(type: frame.type, body: frame.body)
      }

      var calls: [ScriptCall] = []

      guard next() != nil else { return calls }

      try? socket.send(ScriptAppMessage.hello(version: ScriptProtocol.version).frame())

      guard case .identity? = next() else { return calls }
      guard case .questionBegin? = next() else { return calls }

      try? socket.send(ScriptAppMessage.questionOnlyAdmitted.frame())

      while case .request(let id, let call)? = next() {
        calls.append(call)

        let result: ScriptResult

        switch call {
        case .openForm:
          result = .ok((try? ScriptValue.integer(9).encoded()) ?? Data())

        case .waitForm:
          result = .ok(
            (try? ScriptValue.record([
              "form": .integer(9), "submission": .integer(1), "action": .string("ok"),
              "answers": .record(["answer": .string("x")]),
            ]).encoded()) ?? Data())

        default:
          result = .ok(Data())
        }

        try? socket.send(ScriptAppMessage.reply(id: id, result: result).frame())

        if case .discardForm = call { break }
      }

      return calls
    }

    defer { Darwin.close(server) }

    let asking = try start(kind: "text", ["Name?"], socket: path)
    let result = try await finish(asking)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, "x\n")

    let calls = await seen.value

    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(calls.last, .discardForm(form: 9))
  }

  /// Catches a caller bound to no pane that is refused with another status than a refusal. The app
  /// reached and said no, so the status is 77, with the way to grant a pane in the message.
  func testACallerBoundToNoPaneIsRefusedWithTheRefusedStatus() async throws {
    TestSessionRoot.remove(from: host)

    let first = try await finish(try start(kind: "text", ["Name?"]))

    XCTAssertEqual(first.status, 77, first.standardError)
    XCTAssertEqual(first.standardOutput, "")
    XCTAssertTrue(
      first.standardError.contains("not running in a uniterm pane"), first.standardError)

    XCTAssertTrue(windows.askedForms.isEmpty)
  }

  /// Catches a closed standard output ending the command with an abort. With SIGPIPE ignored, as a
  /// caller may leave it, the write fails with a code and not a signal. The command says so on
  /// standard error and exits 74, the I/O error status. A command that wrote through
  /// `FileHandle` would raise an exception and die with 134 instead.
  func testAClosedStandardOutputExitsSeventyFourAndSaysWhy() async throws {
    let output = Pipe()
    let asking = try start(
      kind: "text", ["Name?"], ignoringSIGPIPE: true,
      standardOutput: .file(output.fileHandleForWriting))

    try output.fileHandleForReading.close()
    try output.fileHandleForWriting.close()
    try await answer(submitted(["answer": .text("Ada")]))

    let ended = await pollUntil(timeout: .seconds(30)) { !asking.process.isRunning }

    XCTAssertTrue(ended, "the command never ended")

    let result = try await finish(asking)

    XCTAssertEqual(result.exit, .exited(74))
    XCTAssertTrue(
      result.standardError.contains("cannot write the answer"), result.standardError)
  }
}
