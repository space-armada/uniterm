import Darwin
import Foundation
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// The REPL helper against a real listener and host in this process. The helper links Janet and
/// the host does not, which is the split the app ships.
///
/// These prove that a REPL binds to the pane that issued its token, that a token works once, that
/// the helper starts in the home folder with none of the caller's environment, that expressions
/// reach the host API, that Ctrl-C stops a form and keeps the definitions, that restored history is
/// recalled and never evaluated, and that each instance's helpers reach that instance. They drive
/// the helper over pipes, where Janet's line editor reads plain lines, except for the recall test,
/// which uses a pty. They cannot prove the app's pane, which the UI tests drive.
@MainActor
final class ScriptReplTests: XCTestCase {
  private var directory: URL!
  private var center: StatusCenter!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    center = StatusCenter()
    windows = FakeWindowAPI()

    let center = center!

    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows,
      reaper: .inert)
    host.start()
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  private func environment(_ channel: ScriptReplChannel) -> [String: String] {
    [ScriptProtocol.replTokenVariable: channel.launch.token]
  }

  private func start(
    _ channel: ScriptReplChannel, shell: Bool = false
  ) throws -> ReplProcess {
    try ReplProcess(
      address: channel.launch.address, environment: environment(channel), shell: shell)
  }

  private func attached(_ events: ReplEvents) async -> Bool {
    await waitUntil { events.attachedProcess != nil }
  }

  // MARK: Evaluation

  /// Catches a REPL that does not evaluate what is typed, that prints a result the way Janet's own
  /// REPL does not, or that reports no line and no evaluation to the app.
  func testATypedExpressionPrintsItsResultAndReportsItsLineAndEvaluation() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(+ 1 2)\n")

    expect(await repl.waitForOutput("3\n"), repl.standardOutput)
    expect(await waitUntil { events.lastEvaluating == false })
    XCTAssertEqual(events.lines, ["(+ 1 2)"])
    XCTAssertTrue(events.all.contains(.evaluating(true)))

    repl.write("(error \"synthetic failure\")\n")

    expect(await repl.waitForError("synthetic failure"), repl.standardError)

    repl.write("(* 6 7)\n")

    expect(await repl.waitForOutput("42\n"), "an error ended the REPL")

    channel.end()
  }

  /// Catches a REPL that cannot call the host API, or whose calls arrive as another source. The
  /// module is imported before the first line, so `uniterm/` works with no import.
  func testExpressionsCallTheHostApiAsTheRepl() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(uniterm/post-status :info \"from the repl\")\n")
    repl.write("(length (uniterm/list-windows))\n")

    expect(await repl.waitForOutput("2\n"), repl.standardOutput)
    XCTAssertEqual(center.history.map(\.text), ["from the repl"])
    XCTAssertEqual(center.history.first?.source.label, "repl")

    channel.end()
  }

  /// Catches a definition that does not outlive an error in a later form, which would lose a
  /// user's work to a typo.
  func testAnErrorReturnsToThePromptWithTheDefinitionsIntact() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(def kept 41)\n")
    repl.write("(undefined-function)\n")
    repl.write("(+ kept 1)\n")

    expect(await repl.waitForOutput("42\n"), repl.standardOutput)
    expect(await repl.waitForError("unknown symbol"), repl.standardError)

    channel.end()
  }

  // MARK: Interrupt

  /// Catches a Ctrl-C that does not stop a loop, one that returns to the prompt without the
  /// earlier definitions, and one that leaves a pending interrupt behind. The second form after
  /// the interrupt would stop at once if the count were left raised.
  func testAnInterruptStopsARunningFormAndKeepsTheDefinitions() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(def kept 5)\n")
    repl.write("(while true)\n")

    expect(await waitUntil { events.lastEvaluating == true && events.lines.count == 2 })

    repl.interrupt()

    expect(await repl.waitForError("interrupted"), repl.standardError)
    expect(await waitUntil { events.lastEvaluating == false })

    repl.write("(+ kept 1)\n")

    expect(await repl.waitForOutput("6\n"), repl.standardOutput)

    repl.write("(var total 0)\n")
    repl.write("(for i 0 1000 (+= total i))\n")
    repl.write("total\n")

    expect(await repl.waitForOutput("499500\n"), "a later form was interrupted")

    channel.end()
  }

  /// Catches a Ctrl-C that stops one form and goes on to run the rest of the line. The line holds a
  /// loop and a print, and the print must never run.
  func testAnInterruptAbandonsTheRestOfTheLine() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(while true) (print \"after-interrupt\")\n")

    expect(await waitUntil { events.lastEvaluating == true })

    repl.interrupt()

    expect(await repl.waitForError("interrupted"), repl.standardError)
    expect(await waitUntil { events.lastEvaluating == false })

    repl.write("(+ 1 1)\n")

    expect(await repl.waitForOutput("2\n"), repl.standardOutput)
    XCTAssertFalse(
      repl.standardOutput.contains("after-interrupt"), "the rest of the line ran after Ctrl-C")

    channel.end()
  }

  /// Catches a Ctrl-C that the terminal's own line discipline cannot deliver. The helper runs under
  /// a pty of its own as a session leader in the foreground, as libghostty starts a program. The
  /// Ctrl-C is the byte 3 written to the pty, which only reaches the helper as SIGINT when the
  /// editor has given the terminal its signal handling back before the form runs.
  func testACtrlCByteOnTheTerminalStopsARunningForm() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try ReplProcess(
      address: channel.launch.address, environment: environment(channel), session: true)

    expect(await attached(events))
    expect(await repl.waitForOutput("repl:1:> "), repl.standardOutput)

    repl.write("(def kept 9)\r")

    expect(await waitUntil { events.lines.count == 1 && events.lastEvaluating == false })

    repl.write("(while true)\r")

    expect(await waitUntil { events.lastEvaluating == true })

    repl.write("\u{03}")

    expect(await repl.waitForOutput("interrupted"), repl.standardOutput)
    expect(await waitUntil { events.lastEvaluating == false })

    repl.write("(+ kept 1)\r")

    expect(await repl.waitForOutput("10\r\n"), repl.standardOutput)

    channel.end()
  }

  /// Runs `(while true)` in a helper started through login, stops it with the byte 3, and checks
  /// that the definitions survive. `prelude` shapes the terminal or the signal state the helper
  /// inherits.
  private func assertACtrlCByteStopsALoop(
    prelude: String, arguments: [String] = [], traced: Bool = false,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try ReplProcess(
      address: channel.launch.address, environment: environment(channel), arguments: arguments,
      login: true, prelude: prelude)

    expect(await attached(events), repl.standardOutput, file: file, line: line)
    expect(await repl.waitForOutput("repl:1:> "), repl.standardOutput, file: file, line: line)

    repl.write("(def kept 9)\r")

    expect(
      await waitUntil { events.lines.count == 1 && events.lastEvaluating == false }, file: file,
      line: line)

    repl.write("(while true)\r")

    expect(await waitUntil { events.lastEvaluating == true }, file: file, line: line)

    repl.write("\u{03}")

    expect(await repl.waitForOutput("interrupted"), repl.standardOutput, file: file, line: line)
    expect(await waitUntil { events.lastEvaluating == false }, file: file, line: line)

    if traced {
      XCTAssertTrue(repl.standardOutput.contains("[sigint evaluating]"), repl.standardOutput)
    }

    repl.write("(+ kept 1)\r")

    expect(await repl.waitForOutput("10\r\n"), repl.standardOutput, file: file, line: line)

    channel.end()
  }

  /// Catches a Ctrl-C that never reaches the helper when libghostty starts it. On macOS the
  /// program runs under `login`, then `bash`, then `/bin/sh -c`, so the helper has parents that
  /// the terminal's signal also reaches. The Ctrl-C is still the byte 3 on the pty.
  func testACtrlCByteStopsARunningFormWhenStartedThroughLogin() async throws {
    try await assertACtrlCByteStopsALoop(prelude: "")
  }

  /// Catches a SIGINT trace that stays silent. A UI run reads these markers to tell a signal that
  /// never arrives from one that arrives and fails to stop the form.
  func testTheSigintTraceReportsASignalThatArrivesDuringAForm() async throws {
    try await assertACtrlCByteStopsALoop(
      prelude: "", arguments: ["--trace-sigint"], traced: true)
  }

  /// Catches a helper that cannot be interrupted because its parent ignored SIGINT. An ignored
  /// signal stays ignored across exec, and a background or detached launch can leave it so.
  func testACtrlCByteStopsARunningFormWhenSIGINTWasInheritedIgnored() async throws {
    try await assertACtrlCByteStopsALoop(prelude: "trap '' INT;")
  }

  /// Catches a helper that evaluates with the terminal's signal characters off. The editor puts
  /// back the settings it found at its first read, so a terminal that starts without ISIG would
  /// keep Ctrl-C a plain byte for the whole session.
  func testACtrlCByteStopsARunningFormWhenTheTerminalStartsWithoutISIG() async throws {
    try await assertACtrlCByteStopsALoop(prelude: "stty -isig;")
  }

  /// Catches a Ctrl-C at an idle prompt that kills the helper or interrupts the next form. The
  /// signal arrives with nothing evaluating, so it must change nothing.
  func testAnInterruptAtAnIdlePromptChangesNothing() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(+ 1 1)\n")

    expect(await repl.waitForOutput("2\n"))

    repl.interrupt()
    repl.interrupt()

    try await Task.sleep(for: .milliseconds(200))

    XCTAssertTrue(repl.process.isRunning, "an idle Ctrl-C ended the helper")

    repl.write("(+ 2 2)\n")

    expect(await repl.waitForOutput("4\n"), repl.standardOutput)

    channel.end()
  }

  // MARK: Token

  /// Catches a token that attaches more than once, and a connection that binds to a pane that did
  /// not issue the token. A raw peer presents the token twice, then an unknown one.
  func testATokenWorksOnceAndAnUnknownTokenIsRefused() async throws {
    let first = host.openRepl(history: ["(+ 1 2)"])
    let events = ReplEvents(first)
    let token = try XCTUnwrap(ReplEnvironmentHex.decode(first.launch.token))

    let peer = try ScriptFixtures.connectPeer(path: first.launch.address)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try peer.send(ScriptHelperMessage.attach(token: token).frame())

    let accepted = try await readApp(peer)

    XCTAssertEqual(accepted, .history(lines: ["(+ 1 2)"], final: true))
    expect(await attached(events))
    XCTAssertEqual(events.attachedProcess?.pid, getpid())

    let again = try ScriptFixtures.connectPeer(path: first.launch.address)

    try again.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try again.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try again.send(ScriptHelperMessage.attach(token: token).frame())

    guard case .attachRefused(let reason) = try await readApp(again) else {
      return XCTFail("a spent token was accepted a second time")
    }

    XCTAssertTrue(reason.contains("did not accept"), reason)
    XCTAssertThrowsError(try again.readFrame(limit: ScriptAppMessage.bodyLimit(type:))) {
      XCTAssertEqual($0 as? WireError, .closed)
    }

    let stranger = try ScriptFixtures.connectPeer(path: first.launch.address)

    try stranger.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try stranger.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try stranger.send(
      ScriptHelperMessage.attach(token: Data(repeating: 7, count: ScriptProtocol.tokenBytes))
        .frame())

    guard case .attachRefused = try await readApp(stranger) else {
      return XCTFail("an unknown token was accepted")
    }

    XCTAssertFalse(events.ended, "a refused peer closed the bound REPL")

    first.end()
  }

  /// Catches a refused connection that can still call the host API, because its calls were
  /// already queued when the refusal happened.
  func testARefusedConnectionCannotCallTheHost() async throws {
    let peer = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try peer.send(
      ScriptHelperMessage.attach(token: Data(repeating: 9, count: ScriptProtocol.tokenBytes))
        .frame())
    try peer.send(
      ScriptHelperMessage.request(id: 1, call: .postStatus(level: .error, text: "smuggled"))
        .frame())

    guard case .attachRefused = try await readApp(peer) else {
      return XCTFail("the token was accepted")
    }

    try await Task.sleep(for: .milliseconds(200))

    XCTAssertTrue(center.history.isEmpty, "a refused connection posted a status")
  }

  /// Catches a connection that attaches after it has already called the host, or begins as a
  /// script and then presents a token.
  func testATokenAfterABeginOrACallIsAProtocolViolation() async throws {
    let channel = host.openRepl(history: [])
    let token = try XCTUnwrap(ReplEnvironmentHex.decode(channel.launch.token))
    let events = ReplEvents(channel)

    for first in [
      ScriptHelperMessage.begin(name: "script.janet"),
      ScriptHelperMessage.request(id: 1, call: .listWindows),
    ] {
      let peer = try ScriptFixtures.connectPeer(path: host.instanceAddress)

      try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
      _ = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
      try peer.send(first.frame())
      try peer.send(ScriptHelperMessage.attach(token: token).frame())

      _ = try? peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      XCTAssertThrowsError(try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:)))
    }

    XCTAssertNil(events.attachedProcess, "a token was spent by a connection that had begun")

    channel.end()
  }

  /// Catches a connection that reports REPL lines without ever attaching.
  func testReplLinesFromAConnectionThatNeverAttachedAreAProtocolViolation() async throws {
    let peer = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try peer.send(ScriptHelperMessage.replLine("(spit \"x\" \"y\")").frame())

    XCTAssertThrowsError(try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))) {
      XCTAssertEqual($0 as? WireError, .closed)
    }
  }

  /// Reads off the main actor. The host answers on the main actor, so a blocking read there would
  /// wait for an answer that only the blocked thread could produce.
  private func readApp(_ peer: FramedSocket) async throws -> ScriptAppMessage {
    try await Task.detached {
      let frame = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
    }.value
  }

  /// Catches a helper that presents the token after user code could have run, or one that exits
  /// without telling the user why a refused token failed. A helper given a spent token exits with
  /// the unavailable status and says why on its own terminal.
  func testAHelperWithASpentTokenSaysWhyAndExits() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let first = try start(channel)

    expect(await attached(events))

    let second = try start(channel)

    let status = await second.exitStatus()
    XCTAssertEqual(status, 69)
    XCTAssertTrue(second.standardError.contains("did not accept"), second.standardError)
    XCTAssertTrue(first.process.isRunning)

    channel.end()
  }

  // MARK: Environment

  /// Catches a REPL that starts in the caller's folder, keeps any inherited variable, or keeps the
  /// token. The helper runs its startup steps and reports what they left. The caller's folder is
  /// the system's temporary folder, and the environment holds a decoy. The probe exists only in
  /// Debug builds, so this test runs the package twin and never the shipped command. A watchdog
  /// kills the helper if it does not finish.
  func testTheReplStartsInHomeWithNoInheritedEnvironment() async throws {
    let process = Process()
    let output = Pipe()

    process.executableURL = ScriptFixtures.helper()
    process.arguments = ["repl", "--probe-environment"]
    process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
    process.environment = [
      ScriptProtocol.replTokenVariable: String(repeating: "ab", count: ScriptProtocol.tokenBytes),
      "UNITERM_DECOY": "inherited", "HOME": "/private/tmp", "PATH": "/usr/bin",
    ]
    process.standardOutput = output
    process.standardError = Pipe()

    try process.run()

    let watchdog = DispatchWorkItem {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)

    let data = output.fileHandleForReading.readDataToEndOfFile()

    process.waitUntilExit()
    watchdog.cancel()

    let report = String(decoding: data, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let home = try XCTUnwrap(ScriptAddress.homeDirectory())
    let resolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path

    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(report, "cwd=\(resolved) environment=0 token=read")
    XCTAssertNotEqual(resolved, "/private/tmp")
  }

  /// Catches a launch that wraps the helper so it is no longer the process the terminal started.
  /// The app signals and kills the peer it sees, so the peer must be the pty's own child.
  func testTheHelperRunsInTheProcessTheShellStarted() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, shell: true)

    expect(await attached(events))
    XCTAssertEqual(events.attachedProcess?.pid, repl.pid)

    channel.end()
  }

  // MARK: History

  /// Catches a restored line that runs. The history holds a status post and a file write, and the
  /// REPL evaluates only what is typed afterwards.
  func testRestoredHistoryIsNeverEvaluated() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ut-repl-\(UUID().uuidString.prefix(8))")

    defer { try? FileManager.default.removeItem(at: marker) }

    let channel = host.openRepl(history: [
      "(uniterm/post-status :error \"restored line ran\")",
      "(spit \"\(marker.path)\" \"ran\")",
      "(os/exit 3)",
    ])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(+ 20 22)\n")

    expect(await repl.waitForOutput("42\n"), repl.standardOutput)
    XCTAssertTrue(center.history.isEmpty, "a restored line posted a status")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a restored line wrote")
    XCTAssertTrue(repl.process.isRunning, "a restored line exited the REPL")
    XCTAssertEqual(events.lines, ["(+ 20 22)"])

    channel.end()
  }

  /// Catches a history that is sent but never reaches the line editor. A pty gives the editor its
  /// full mode. Up Arrow recalls the newest restored line, and the editor draws it at the prompt.
  /// Nothing runs, and Ctrl-C then clears the line.
  func testRestoredHistoryIsRecalledByTheLineEditorOnAPty() async throws {
    let channel = host.openRepl(history: ["(+ 100 200)", "(* 7 8)"])
    let events = ReplEvents(channel)
    let pty = try PseudoTerminal()
    let repl = try ReplProcess(
      address: channel.launch.address, environment: environment(channel), terminal: pty)

    expect(await attached(events))
    expect(await pty.waitForOutput("repl:1:> "), pty.output)

    pty.write("\u{1B}[A")

    expect(await pty.waitForOutput("(* 7 8)"), pty.output)

    pty.write("\u{1B}[A")

    expect(await pty.waitForOutput("(+ 100 200)"), pty.output)
    XCTAssertTrue(events.lines.isEmpty, "recalling a line ran it")
    XCTAssertTrue(center.history.isEmpty)

    let promptsBefore = pty.output.components(separatedBy: "repl:1:> ").count

    pty.write("\u{03}")

    let redrawn = await pty.waitFor {
      $0.components(separatedBy: "repl:1:> ").count > promptsBefore
    }

    XCTAssertTrue(redrawn, "Ctrl-C at the prompt did not return to a fresh prompt")
    XCTAssertTrue(repl.process.isRunning, "Ctrl-C at the prompt ended the helper")
    XCTAssertTrue(events.lines.isEmpty, "Ctrl-C ran the line")

    channel.end()
  }

  /// Catches a misreading of the editor's display of a long recalled line. The editor draws one
  /// row and scrolls it to keep the cursor in view. A recalled line is drawn with the cursor at
  /// its end, so a pane narrower than the line shows the tail and never the head. A check that
  /// looks for the head of a recalled line in a narrow pane cannot pass.
  func testARecalledLineLongerThanThePaneShowsItsTail() async throws {
    let long =
      "(uniterm/open-pane :text-viewer (first (uniterm/list-panes (first (uniterm/list-windows)))))"
    let channel = host.openRepl(history: [long, "(+ 40 2)"])
    let events = ReplEvents(channel)
    let pty = try PseudoTerminal(columns: 30)
    let repl = try ReplProcess(
      address: channel.launch.address, environment: environment(channel), terminal: pty)

    expect(await attached(events))
    expect(await pty.waitForOutput("repl:1:> "), pty.output)

    pty.write("\u{1B}[A")

    expect(await pty.waitForOutput("(+ 40 2)"), pty.output)

    let before = pty.output.count

    pty.write("\u{1B}[A")

    expect(await pty.waitForOutput("windows)))))"), pty.output)

    let redrawn = String(pty.output.dropFirst(before))

    XCTAssertFalse(redrawn.contains("(uniterm/open-pane"), redrawn)
    XCTAssertTrue(events.lines.isEmpty, "recalling a line ran it")
    XCTAssertTrue(repl.process.isRunning)

    channel.end()
  }

  /// Catches a history longer than one message, or one cut in the wrong place. The editor keeps
  /// its newest 100 lines, so the app sends no more, in order.
  func testAHistoryIsSplitIntoMessagesAndLimitedToWhatTheEditorRecalls() throws {
    let lines = (0..<250).map { "(line \($0))" }
    let messages = ScriptHost.historyMessages(lines)

    var sent: [String] = []

    for (index, message) in messages.enumerated() {
      guard case .history(let chunk, let final) = message else { return XCTFail("\(message)") }

      XCTAssertEqual(final, index == messages.count - 1)
      XCTAssertLessThanOrEqual(chunk.count, ScriptProtocol.maxHistoryLines)
      XCTAssertLessThanOrEqual(message.frame().count, ScriptProtocol.maxControlBody)

      sent += chunk
    }

    XCTAssertEqual(sent, Array(lines.suffix(ScriptProtocol.recallLines)))
    XCTAssertEqual(ScriptHost.historyMessages([]), [.history(lines: [], final: true)])

    let wide = Array(repeating: String(repeating: "x", count: 1000), count: 100)

    for message in ScriptHost.historyMessages(wide) {
      XCTAssertLessThanOrEqual(message.frame().count, ScriptProtocol.maxControlBody)
    }
  }

  // MARK: Helper death and close

  /// Catches a REPL whose helper dies and the app never hears. A killed helper closes its
  /// connection, and the channel reports it.
  func testAKilledHelperEndsItsChannel() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    kill(repl.pid, SIGKILL)

    expect(await waitUntil { events.ended })
    XCTAssertFalse(channel.isAttached == true && events.ended == false)
  }

  /// Catches a close that leaves the helper running. Ending the channel closes its connection, and
  /// the helper exits on its own.
  func testEndingTheChannelEndsTheHelper() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    channel.end()

    let status = await repl.exitStatus()
    XCTAssertEqual(status, ScriptHelperExit.connectionLost)
  }

  /// Catches a helper stuck in a loop that survives its pane closing. The watchdog thread ends it
  /// when the connection closes, though the VM thread never reads the socket.
  func testEndingTheChannelEndsAHelperThatIsBusyInALoop() async throws {
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(while true)\n")

    expect(await waitUntil { events.lastEvaluating == true })

    channel.end()

    let status = await repl.exitStatus()
    XCTAssertEqual(status, ScriptHelperExit.connectionLost)
  }

  /// Catches the app trusting a process ID alone. A helper still there after the delay, and still
  /// the process that attached, is killed. A process ID that now names another process is not.
  func testALingeringHelperIsKilledOnlyWhileItIsTheProcessThatAttached() async throws {
    let killed = KilledPIDs()
    let checked = KilledPIDs()

    for (running, expected) in [(true, 1), (false, 0)] {
      let reaper = ProcessReaper(
        delay: .milliseconds(30),
        isRunning: {
          checked.add($0.pid)
          return running
        }, kill: { killed.add($0) })
      let local = try makeHost(reaper: reaper)
      let channel = local.host.openRepl(history: [])
      let peer = try await attach(channel, to: local.host)

      let before = killed.all.count
      let checksBefore = checked.all.count

      channel.end()

      expect(await waitUntil { checked.all.count == checksBefore + 1 }, "the reaper never looked")
      expect(
        await waitUntil { killed.all.count - before == expected }, "running \(running)")
      XCTAssertEqual(killed.all.count - before, expected, "running \(running)")

      if expected == 1 { XCTAssertEqual(killed.all.last, getpid()) }

      _ = peer
      local.host.stop()
    }
  }

  private func makeHost(reaper: ProcessReaper) throws -> (host: ScriptHost, directory: URL) {
    let directory = try ScriptFixtures.makeSocketDirectory()
    let center = center!
    let host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, reaper: reaper)

    host.start()

    return (host, directory)
  }

  private func attach(_ channel: ScriptReplChannel, to host: ScriptHost) async throws
    -> FramedSocket
  {
    let token = try XCTUnwrap(ReplEnvironmentHex.decode(channel.launch.token))
    let peer = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try peer.send(ScriptHelperMessage.attach(token: token).frame())
    _ = try await readApp(peer)

    return peer
  }

  // MARK: Two instances

  /// Catches a REPL helper that reaches another instance. Two hosts listen at once. Each issues a
  /// token and an address of its own, each helper binds to the host that issued its token, and a
  /// line typed in one never reaches the other.
  func testEachReplReachesTheInstanceThatStartedIt() async throws {
    let other = try makeHost(reaper: .inert)

    defer {
      other.host.stop()
      try? FileManager.default.removeItem(at: other.directory)
    }

    XCTAssertNotEqual(other.host.instanceAddress, host.instanceAddress)

    let mine = host.openRepl(history: [])
    let theirs = other.host.openRepl(history: [])

    XCTAssertEqual(mine.launch.address, host.instanceAddress)
    XCTAssertEqual(theirs.launch.address, other.host.instanceAddress)

    let mineEvents = ReplEvents(mine)
    let theirEvents = ReplEvents(theirs)
    let mineRepl = try start(mine)
    let theirRepl = try start(theirs)

    expect(await waitUntil { mineEvents.attachedProcess != nil })
    expect(await waitUntil { theirEvents.attachedProcess != nil })
    XCTAssertEqual(mineEvents.attachedProcess?.pid, mineRepl.pid)
    XCTAssertEqual(theirEvents.attachedProcess?.pid, theirRepl.pid)

    mineRepl.write("(+ 1 1)\n")
    theirRepl.write("(+ 2 2)\n")

    expect(await mineRepl.waitForOutput("2\n"))
    expect(await theirRepl.waitForOutput("4\n"))
    expect(await waitUntil { mineEvents.lines.count == 1 && theirEvents.lines.count == 1 })
    XCTAssertEqual(mineEvents.lines, ["(+ 1 1)"])
    XCTAssertEqual(theirEvents.lines, ["(+ 2 2)"])

    mine.end()
    theirs.end()
  }
}

extension ProcessReaper {
  /// A reaper that never kills. A raw peer in these tests is the test process itself, so a live
  /// reaper would kill the test runner two seconds after a channel ended.
  static let inert = ProcessReaper(delay: .seconds(2), isRunning: { _ in false }, kill: { _ in })
}

/// Process IDs a test reaper was asked to kill.
final class KilledPIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var pids: [pid_t] = []

  func add(_ pid: pid_t) {
    lock.lock()
    pids.append(pid)
    lock.unlock()
  }

  var all: [pid_t] {
    lock.lock()
    defer { lock.unlock() }

    return pids
  }
}

enum ScriptHelperExit {
  /// The status the helper ends with when its connection to the app closes.
  static let connectionLost: Int32 = 74
}

/// Decodes the hex a launch carries, independent of the helper's own decoder.
enum ReplEnvironmentHex {
  static func decode(_ hex: String) -> Data? {
    guard hex.count == ScriptProtocol.tokenBytes * 2 else { return nil }

    var data = Data()
    var index = hex.startIndex

    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)

      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }

      data.append(byte)
      index = next
    }

    return data
  }
}
