import AppletFixtures
import AppletKit
import Darwin
import ExecTestSupport
import Foundation
import ProcessInspection
import ProcessTestSupport
import StatusKit
import XCTest

@testable import ExecDriver

/// Runs a real driver process against a real hosted fixture, through the real pipes, wire, and
/// shared dispatch. The driver is a perl script with one mode for each behavior, good or bad.
///
/// These prove what crosses the process boundary: hellos, commands, events, stderr, exits, and
/// every bound. They cannot prove the window's chrome or its launch approval. The window's tests
/// prove those.
@MainActor
final class ExecDriverChannelTests: XCTestCase {
  private var center: StatusCenter!
  private var applet: SlidesFixture!
  private var dispatcher: ControlDispatcher!
  private var ended: [ExecDriverChannel.End] = []
  private var channels: [ExecDriverChannel] = []
  private var scratch: URL!

  override func setUp() async throws {
    center = StatusCenter()
    applet = SlidesFixture()
    dispatcher = ControlDispatcher()
    ended = []
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "exec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    for channel in channels { channel.close() }

    channels = []
    try? FileManager.default.removeItem(at: scratch)
  }

  private func start(
    _ mode: String, type: String = SlidesFixture.typeID, schema: String = "0.0",
    _ rest: [String] = [],
    directory: String? = nil, keys: [String] = [], values: [String: String] = [:],
    killGrace: DispatchTimeInterval = .seconds(2), host: ExecDriverChannel.HostHandler? = nil,
    hosting other: (any AppletCommandHandling)? = nil
  ) throws -> ExecDriverChannel {
    let declaration = try ExecDeclaration(
      arguments: ExecTestDriver.arguments(mode, type: type, schema: schema, rest),
      directory: directory, environmentKeys: keys)
    let environment = try XCTUnwrap(ExecEnvironment.current())
    let launch = try ExecLaunch(
      declaration: declaration, environment: values, home: environment.home)

    let channel = ExecDriverChannel(
      launch: launch, environment: environment, applet: other ?? applet, dispatcher: dispatcher,
      authority: { nil }, producer: center.issueProducer(kind: .applet, name: "driver"),
      killGrace: killGrace, host: host, onEnd: { [weak self] end in self?.ended.append(end) })

    channels.append(channel)
    try channel.start()

    return channel
  }

  private func waitUntil(
    _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)

    while !condition() {
      guard Date() < deadline else {
        XCTFail("timed out waiting until \(what)", file: file, line: line)
        return
      }

      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func command(_ name: String, _ arguments: String) -> String {
    #"{"name":"\#(name)","arguments":\#(arguments)}"#
  }

  private var historyTexts: [String] { center.history.map(\.text) }

  /// Catches a driver whose commands never reach the applet, events that never reach the driver,
  /// or a reply that never comes back. The driver answers the user's Next with a show-slide.
  func testTheDriversStdoutDrivesTheAppletAndItsStdinGetsEvents() async throws {
    let channel = try start(
      "script",
      [
        command("set-deck", #"{"titles":["One","Two","Three"]}"#),
        command("show-slide", #"{"index":1}"#),
      ])

    await waitUntil("the second slide shows") { applet.index == 1 }

    XCTAssertEqual(channel.phase, .connected)
    XCTAssertEqual(applet.titles, ["One", "Two", "Three"])

    applet.button.performClick(nil)

    await waitUntil("the driver advances") { applet.index == 2 }
    await waitUntil("the driver logs the replies and events") {
      historyTexts.contains("got reply") && historyTexts.contains("got event advance-requested")
        && historyTexts.contains("got event slide-shown")
    }
  }

  /// Catches stderr that takes a turn on the status bar, that gets a level from its words, or a
  /// flood that the history keeps unbounded or that stalls the main thread.
  func testStderrIsBoundedInfoInTheHistoryOnly() async throws {
    _ = try start("stderr-flood")

    let started = Date()
    var turns = 0

    await waitUntil("the flood ends", timeout: 30) {
      turns += 1
      return historyTexts.contains("flood done")
    }

    XCTAssertGreaterThan(turns, 1, "the main thread got turns during the flood")
    XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    XCTAssertNil(center.display, "stderr took a turn on the status bar")
    XCTAssertTrue(center.history.allSatisfy { $0.level == .info })
    XCTAssertLessThanOrEqual(center.history.count, StatusPolicy.standard.otherHistoryLimit)
    XCTAssertTrue(historyTexts.contains { $0.contains("did not fit and were dropped") })
  }

  /// Catches a partial stderr line that never shows. The driver writes "loading" with no newline
  /// and goes quiet while it stays connected, so only the channel's later drain can show it.
  func testAPartialStderrLineShowsOnceTheDriverGoesQuiet() async throws {
    let channel = try start("partial-stderr")

    await waitUntil("the partial line reaches the history") { historyTexts.contains("loading") }

    XCTAssertEqual(channel.phase, .connected, "the channel ended: \(ended)")
  }

  /// Catches a driver exit that goes unreported, or one reported at a level guessed from text.
  func testAnExitIsATypedWarningAndEndsTheChannel() async throws {
    let channel = try start("exit", ["3"])

    await waitUntil("the driver exits") { !ended.isEmpty }

    XCTAssertEqual(ended, [.exited(3 << 8)])
    XCTAssertEqual(channel.phase, .ended(.exited(3 << 8)))
    XCTAssertEqual(center.display?.message.level, .warning)
    XCTAssertEqual(center.display?.message.text, "The driver exited with status 3.")
  }

  /// Catches a mismatch in either direction that lets a command run: a driver that names another
  /// protocol or schema version, one that refuses the app's hello, and one that sends a command
  /// before its hello. Each driver sends a set-deck that must never land.
  func testEveryHelloMismatchEndsTheChannelWithNoCommandRun() async throws {
    let cases: [(String, String, [String], String)] = [
      ("hello-protocol", "0.0", ["1"], "exec protocol 1"),
      ("hello-protocol", "0.0", ["2"], "exec protocol 2"),
      ("hello-protocol", "0.0", ["3"], "exec protocol 3"),
      ("hello-protocol", "0.0", ["4"], "exec protocol 4"),
      (
        "hello-protocol", "0.0", ["4"], "Rebuild the driver against this uniterm, or update uniterm"
      ),
      ("stale-hello", "0.0", ["4"], "exec protocol 4"),
      ("hello-schema", "0.0", ["2.0"], "schema version 2.0"),
      ("hello-schema", "0.0", ["1.0"], "schema version 1.0"),
      ("hello-schema", "0.0", ["0.1"], "schema version 0.1"),
      ("refuse", "0.0", [], "needs exec protocol 9"),
      ("command-first", "0.0", [], "before its hello"),
      ("script", "0.0", [], "written for a fixture-chart"),
    ]

    for (mode, schema, rest, needle) in cases {
      ended = []
      applet = SlidesFixture()

      let type = mode == "script" ? ChartFixture.typeID : SlidesFixture.typeID
      _ = try start(mode, type: type, schema: schema, rest)

      await waitUntil("\(mode) ends") { !ended.isEmpty }
      try? await Task.sleep(for: .milliseconds(200))

      XCTAssertEqual(applet.titles, [], "\(mode) ran a command")
      XCTAssertTrue(
        ended.first?.description.contains(needle) == true, "\(mode): \(ended)")
      XCTAssertEqual(center.display?.message.level, .warning, mode)
    }
  }

  /// Catches a pending reply that blocks the replies behind it, or one matched to the wrong
  /// request. The driver sends a wait, a command that answers at once, and the command that ends
  /// the wait. The replies must arrive as 2, 1, 3, each under its own ID.
  func testAPendingReplyArrivesOutOfOrderUnderItsOwnID() async throws {
    let notes = NotesFixture()

    _ = try start("pending-order", type: NotesFixture.typeID, hosting: notes)

    await waitUntil("the driver reports the order") {
      historyTexts.contains("reply order: 2 1 3")
    }

    XCTAssertEqual(notes.text, "go")
  }

  /// Catches an app that takes a driver written for a later minor, or refuses one written for an
  /// earlier minor. This tests the major and minor rule that applies from a declared-stable schema
  /// 1.0. The pane claims 1.2, so a driver at 1.1 connects.
  func testADeclaredStableSchemaTakesADriverWrittenForAnEarlierMinor() async throws {
    let notes = NotesFixture()

    notes.schemaVersion = AppletSchemaVersion(1, 2)

    let channel = try start(
      "script", type: NotesFixture.typeID, schema: "1.1",
      [command("set-notes", #"{"text":"minor"}"#)], hosting: notes)

    await waitUntil("the notes change") { notes.text == "minor" }

    XCTAssertEqual(channel.phase, .connected)
  }

  /// Catches an event or a field that a later minor added reaching a driver written for an earlier
  /// one, which could not know to ignore it. This tests the rule for a declared-stable schema. The
  /// pane claims 1.1. A driver at 1.0 gets `notes-shown`
  /// without its `empty` field, and never gets `notes-cleared`. The set-notes after the clear is the
  /// barrier, since it shows the driver kept receiving events past the dropped one.
  func testAnEventAndAFieldANewerMinorAddedNeverReachAnOlderDriver() async throws {
    let notes = NotesFixture()

    notes.schemaVersion = AppletSchemaVersion(1, 1)

    _ = try start(
      "script", type: NotesFixture.typeID, schema: "1.0",
      [
        command("set-notes", #"{"text":"abc"}"#), command("clear", "{}"),
        command("set-notes", #"{"text":"z"}"#),
      ], hosting: notes)

    await waitUntil("the last notes show") { notes.text == "z" }
    await waitUntil("the driver saw three notes events") {
      historyTexts.filter { $0 == "got event notes-shown" }.count >= 3
    }

    XCTAssertFalse(historyTexts.contains("got event notes-cleared"))
    XCTAssertTrue(historyTexts.contains(#"event data: {"length":3}"#), "\(historyTexts)")
    XCTAssertFalse(historyTexts.contains { $0.contains("empty") })
  }

  /// Proves the gate above is not a blanket drop. A driver at 1.1 gets the later minor's event and
  /// its field.
  func testADriverAtTheCurrentMinorGetsTheLaterMinorsEventAndFields() async throws {
    let notes = NotesFixture()

    notes.schemaVersion = AppletSchemaVersion(1, 1)

    _ = try start(
      "script", type: NotesFixture.typeID, schema: "1.1",
      [command("set-notes", #"{"text":"abc"}"#), command("clear", "{}")], hosting: notes)

    await waitUntil("the driver sees the cleared event") {
      historyTexts.contains("got event notes-cleared")
    }

    XCTAssertTrue(historyTexts.contains(#"event data: {"length":0,"previous-length":3}"#))
    XCTAssertTrue(historyTexts.contains(#"event data: {"empty":false,"length":3}"#))
  }

  /// Catches a malformed line, a partial line at the end, or a line past the frame bound that
  /// leaves the channel open or that runs anything.
  func testBadFramesCloseTheChannelVisibly() async throws {
    let cases = [
      ("malformed", "not a message"), ("partial", "middle of a line"),
      ("long-line", "longer than"),
    ]

    for (mode, needle) in cases {
      ended = []
      _ = try start(mode)

      await waitUntil("\(mode) fails") { !ended.isEmpty }

      guard case .failed(let reason)? = ended.first else {
        XCTFail("\(mode) ended as \(ended)")
        continue
      }

      XCTAssertTrue(reason.contains(needle), "\(mode): \(reason)")
    }
  }

  /// Catches a driver whose message holds a key or a type this build does not know, which an
  /// ignoring decoder would run under the meaning it had. The driver's command must never land, and
  /// the text must name the key or type and say to rebuild the driver or update uniterm.
  func testAnUnknownKeyOrTypeEndsTheChannelByNameWithNoCommandRun() async throws {
    let cases = [
      ("unknown-key", "the key \"tab\" in a \"command\" message"),
      ("unknown-type", "the message type \"retire-me\""),
    ]

    for (mode, needle) in cases {
      ended = []
      applet = SlidesFixture()

      _ = try start(mode)

      await waitUntil("\(mode) fails") { !ended.isEmpty }
      try? await Task.sleep(for: .milliseconds(200))

      XCTAssertEqual(applet.titles, [], "\(mode) ran a command")

      guard case .failed(let reason)? = ended.first else {
        XCTFail("\(mode) ended as \(ended)")
        continue
      }

      XCTAssertTrue(reason.contains(needle), "\(mode): \(reason)")
      XCTAssertTrue(reason.contains("Rebuild the driver against this uniterm"), reason)
    }
  }

  /// Catches a clipboard write that ends the driver for its size. A write at the bound, every byte
  /// escaped to six, still fits one frame and reaches the window. A write one byte longer is
  /// refused as that call alone, before the window sees it, and the driver's next command runs.
  func testAnOversizeClipboardWriteIsRefusedAloneAndOneAtTheBoundArrives() async throws {
    var writes: [Int] = []
    let bound = ExecProtocol.maxClipboardBytes

    let channel = try start(
      "clipboard-sizes", [String(bound), String(bound + 1)],
      host: { request, reply in
        if case .clipboardWrite(let text) = request { writes.append(text.utf8.count) }

        reply(.success(.object([:])))
      })

    await waitUntil("the channel ends or answers both writes and the command after them") {
      !ended.isEmpty
        || (historyTexts.contains("got error bad-argument")
          && historyTexts.count(where: { $0 == "got reply" }) == 2)
    }

    XCTAssertEqual(channel.phase, .connected, "the channel ended: \(ended)")
    XCTAssertEqual(writes, [bound])
    XCTAssertTrue(historyTexts.contains("got error bad-argument"), "\(historyTexts)")
    XCTAssertTrue(
      historyTexts.contains { $0.hasPrefix("error message:") && $0.contains("\(bound) bytes") },
      "\(historyTexts)")
  }

  /// Catches a flood of small commands from a driver that never reads its replies, growing a
  /// queue without bound or holding the main thread. It must fail visibly once a bound is passed.
  func testEndlessSmallFramesStayBoundedAndFail() async throws {
    _ = try start("flood")

    var turns = 0

    await waitUntil("the flood fails", timeout: 60) {
      turns += 1
      return !ended.isEmpty
    }

    XCTAssertGreaterThan(turns, 1)
    XCTAssertLessThanOrEqual(dispatcher.queuedCount, dispatcher.maximumQueued)

    guard case .failed(let reason)? = ended.first else {
      return XCTFail("the flood ended as \(ended)")
    }

    XCTAssertTrue(reason.contains("MiB"), reason)
  }

  /// Emits up to `count` of the stall test's events to `channel` while it stays connected. Returns
  /// the main thread's median time per emit across chunks of 1,000.
  ///
  /// A median keeps one runner pause from counting. A pause lands in a single chunk, while a stall
  /// that slows every emit moves every chunk.
  private func emitEvents(_ count: Int, to channel: ExecDriverChannel) -> TimeInterval {
    let title = String(repeating: "t", count: 200)
    var costs: [TimeInterval] = []

    for _ in stride(from: 0, to: count, by: 1_000) where channel.isConnected {
      let started = Date()
      var emitted = 0

      for _ in 0..<1_000 where channel.isConnected {
        applet.events.emit("slide-shown", .object(["index": .number(1), "title": .string(title)]))
        emitted += 1
      }

      if emitted > 0 {
        costs.append(Date().timeIntervalSince(started) / Double(emitted))
      }
    }

    let sorted = costs.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
  }

  /// Catches events to a driver that never reads stdin blocking or slowing the main thread, or
  /// piling up past the retained bound instead of failing.
  ///
  /// The stalled emits are measured per emit against emits to a driver that reads them, on the same
  /// machine in the same run. A loaded runner slows both, so only the stall itself can fail it.
  ///
  /// Both measured runs send 10,000 events, about 2.6 MB, under the 4 MiB retained bound. A reader
  /// that falls behind on a loaded runner therefore cannot get the healthy driver cut off. The
  /// stalled run is measured while its writes back up but before it fails, since an emit after
  /// the failure returns at once and would hide a slow path. More events then pass the bound,
  /// unmeasured, so the stalled channel fails.
  func testAStalledStdinFailsWithoutBlockingTheEmitter() async throws {
    let healthy = try start("drain")

    await waitUntil("the healthy driver's hellos finish") { healthy.isConnected }

    let baseline = emitEvents(10_000, to: healthy)

    XCTAssertTrue(healthy.isConnected, "a driver that reads every event was cut off")
    healthy.close()
    ended = []

    let channel = try start("stall")

    await waitUntil("the hellos finish") { channel.isConnected }

    let stalled = emitEvents(10_000, to: channel)

    XCTAssertTrue(channel.isConnected, "the stalled driver failed before its writes were measured")
    XCTAssertLessThan(
      stalled, 2 * baseline,
      "an emit to a stalled driver took \(stalled) s, against \(baseline) s to a reading one")

    _ = emitEvents(30_000, to: channel)

    func failure() -> String? {
      for end in ended {
        if case .failed(let reason) = end { return reason }
      }

      return nil
    }

    await waitUntil("the stall fails") { failure() != nil }

    guard let reason = failure() else { return XCTFail("ended as \(ended)") }

    XCTAssertTrue(reason.contains("stopped reading its input"), reason)
  }

  /// Catches a close that waits for the child, or a child that outlives the close because it
  /// ignores SIGTERM.
  func testCloseReturnsAtOnceAndEndsAChildThatIgnoresTerm() async throws {
    let channel = try start("ignore-term", killGrace: .milliseconds(300))

    await waitUntil("the hellos finish") { channel.isConnected }

    let pid = try XCTUnwrap(channel.pid)
    let started = Date()

    applet.close()

    XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "close waited for the child")
    XCTAssertEqual(ended, [.closed])
    XCTAssertNil(center.display, "a close the user made is not reported")

    await waitUntil("the child is gone") { kill(pid, 0) != 0 }
  }

  /// Catches a close whose SIGKILL never reaches the driver's group because the leader exited on
  /// SIGTERM first. A background child that ignores SIGTERM would then outlive the driver and
  /// hold its stdout open, so the reader threads and pipes would leak too.
  func testCloseEndsABackgroundChildThatIgnoresTerm() async throws {
    let file = scratch.appendingPathComponent("grandchild")
    let channel = try start("grandchild", [file.path], killGrace: .milliseconds(300))

    await waitUntil("the driver connects and names its child") {
      channel.isConnected && FileManager.default.fileExists(atPath: file.path)
    }

    let text = try String(contentsOf: file, encoding: .utf8)
    let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))

    let background = try XCTUnwrap(ProcessRecord(pid: child), "the background child is not running")

    XCTAssertEqual(
      ProcessInspection.parent(of: child)?.pid, channel.pid,
      "the pid the driver wrote is not its own child")

    channel.close()

    await waitUntil("the background child is gone", timeout: 5) { kill(child, 0) != 0 }

    ProcessSender.signal(SIGKILL, background, expecting: .token)
  }

  /// Catches a paused driver that the transport ends as if it had exited.
  ///
  /// Darwin's `waitid` reports a stopped child even to a wait for exits alone. A transport that
  /// believes that report sends the driver's group SIGKILL.
  ///
  /// The test pauses a connected driver with SIGSTOP and resumes it with SIGCONT. The driver stays
  /// connected and still answers the user's Next. It signals the driver through the sender, on the
  /// token path, with the identity it recorded while the channel was connected. The transport
  /// holds the driver unreaped while it runs, and this driver never exits on its own. SIGCONT goes
  /// out only while the driver still reads as stopped, since a driver that was ended may already be
  /// reaped.
  func testAStoppedDriverStaysConnectedAndAnswersOnceContinued() async throws {
    let channel = try start(
      "script",
      [
        command("set-deck", #"{"titles":["One","Two","Three"]}"#),
        command("show-slide", #"{"index":1}"#),
      ])

    await waitUntil("the second slide shows") { applet.index == 1 }

    let pid = try XCTUnwrap(channel.pid)
    let driver = try XCTUnwrap(ProcessRecord(pid: pid), "the connected driver has no start time")

    XCTAssertTrue(ProcessSender.signal(SIGSTOP, driver, expecting: .token))
    await waitUntil("the driver stops or ends") {
      ProcessSender.isStopped(pid) || !ended.isEmpty
    }

    guard ended.isEmpty, ProcessSender.isStopped(pid) else {
      return XCTFail("the driver did not stay paused, so the pause ended it. Ends seen: \(ended)")
    }

    XCTAssertTrue(ProcessSender.signal(SIGCONT, driver, expecting: .token))

    applet.button.performClick(nil)

    await waitUntil("the driver advances or ends") { applet.index == 2 || !ended.isEmpty }

    XCTAssertEqual(ended, [], "the pause ended the driver")
    XCTAssertEqual(applet.index, 2)
    XCTAssertEqual(channel.phase, .connected)
  }

  // MARK: Suspend and resume

  /// Catches a suspend that stops only the driver and leaves a program it started running, one that
  /// leaves the group frozen after a resume, and a state that follows uniterm's record instead of
  /// the process. The driver's background child shares its group, so one stop freezes both.
  func testSuspendStopsTheWholeGroupAndResumeContinuesIt() async throws {
    let file = scratch.appendingPathComponent("grandchild")
    let channel = try start("grandchild", [file.path])

    await waitUntil("the driver connects and names its child") {
      channel.isConnected && FileManager.default.fileExists(atPath: file.path)
    }

    let text = try String(contentsOf: file, encoding: .utf8)
    let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    let pid = try XCTUnwrap(channel.pid)

    var reports: [SuspensionState] = []

    channel.onSuspensionChange = { reports.append($0) }

    channel.suspend()

    await waitUntil("the driver and its child read as stopped") {
      channel.suspension.isSuspendedByUniterm && ProcessSender.isStopped(pid)
        && ProcessSender.isStopped(child)
    }

    XCTAssertEqual(channel.phase, .connected, "the suspension ended the driver")
    XCTAssertEqual(ended, [])

    channel.resume()

    await waitUntil("the driver and its child run again") {
      !channel.suspension.isSuspended && !ProcessSender.isStopped(pid)
        && !ProcessSender.isStopped(child)
    }

    XCTAssertFalse(channel.suspension.canResume)
    XCTAssertEqual(reports.last?.isSuspended, false)
    XCTAssertEqual(reports.contains { $0.isSuspendedByUniterm }, true)
  }

  /// Catches a stop from outside that is not shown, one that Resume All would continue, and an
  /// outside continue that leaves uniterm's record behind. The driver is stopped and continued by
  /// another process, as a `kill -STOP` would.
  func testAStopFromOutsideShowsAsSuspendedButNotAsUnitermsAndResumeContinuesIt() async throws {
    let channel = try start("drain")

    await waitUntil("the driver connects") { channel.isConnected }

    let pid = try XCTUnwrap(channel.pid)

    XCTAssertEqual(kill(pid, SIGSTOP), 0)

    await waitUntil("the stop shows") { channel.suspension.isSuspended }

    XCTAssertFalse(channel.suspension.isSuspendedByUniterm)
    XCTAssertTrue(channel.suspension.canResume)

    channel.resume()

    await waitUntil("the driver runs again") { !channel.suspension.isSuspended }

    channel.suspend()

    await waitUntil("uniterm's stop shows") { channel.suspension.isSuspendedByUniterm }

    XCTAssertEqual(kill(pid, SIGCONT), 0)

    await waitUntil("the outside continue shows") { !channel.suspension.isSuspended }

    XCTAssertFalse(channel.suspension.madeByUniterm, "an outside continue left uniterm's record")
  }

  /// Catches a call that is lost, or a reply that is dropped, by a suspension. The driver sent a call
  /// that waits before it was stopped. The call still runs while the driver is stopped, and the
  /// driver reads its reply once it continues.
  func testACallSentBeforeTheSuspendStillRunsAndItsReplyArrivesOnResume() async throws {
    let notes = NotesFixture()
    let channel = try start("wait-reply", type: NotesFixture.typeID, hosting: notes)

    await waitUntil("the driver's call waits") { notes.waitingCount == 1 }

    channel.suspend()

    await waitUntil("the driver reads as stopped") { channel.suspension.isSuspendedByUniterm }

    dispatcher.submit(
      AppletCommandSubmission(
        appletType: NotesFixture.typeID, schemaVersion: NotesFixture.schema.version,
        name: "set-notes", arguments: .object(["text": .string("go")])),
      to: notes, authority: { nil }, reply: { _ in })

    await waitUntil("the waiting call runs") { notes.waitingCount == 0 }

    // Cost: this 200 ms wait proves a negative. A stopped driver reads nothing, and no event marks the
    // reply it never read. Only a real stopped process shows that, so no cheaper layer can.
    try await Task.sleep(for: .milliseconds(200))

    XCTAssertFalse(
      historyTexts.contains("waited reply"), "a stopped driver read its reply")

    channel.resume()

    await waitUntil("the driver reads its reply") { historyTexts.contains("waited reply") }
  }

  /// Catches a close that leaves a stopped driver frozen. A stopped process ignores SIGTERM until
  /// it is continued, and the kill grace here is long, so only the SIGCONT that follows the SIGTERM
  /// can end it in time.
  func testClosingAStoppedDriverContinuesItSoItCanShutDown() async throws {
    let channel = try start("silent", killGrace: .seconds(60))

    await waitUntil("the driver is running") { channel.pid != nil }

    let pid = try XCTUnwrap(channel.pid)

    XCTAssertEqual(kill(pid, SIGSTOP), 0)

    await waitUntil("the driver reads as stopped") { ProcessSender.isStopped(pid) }

    channel.close()

    await waitUntil("the stopped driver ends on SIGTERM", timeout: 5) { kill(pid, 0) != 0 }
  }

  /// Catches a suspend of a driver that has not finished its hellos. A driver still inside its
  /// declaration is left running, so it is never held past its limit.
  func testSuspendLeavesADriverThatHasNotDeclaredItself() async throws {
    let channel = try start("silent")

    XCTAssertFalse(channel.isConnected)

    channel.suspend()

    XCTAssertFalse(channel.suspension.canResume)

    let pid = try XCTUnwrap(channel.pid)

    XCTAssertFalse(ProcessSender.isStopped(pid))
  }

  /// Catches a channel whose applet closed before it started, and that spawns a child anyway or
  /// never reports its end, so the pane would show a driver running that nothing reaps.
  func testAChannelForAClosedAppletSpawnsNothingAndEnds() throws {
    applet.close()

    let channel = try start("silent")

    XCTAssertEqual(ended, [.closed])
    XCTAssertEqual(channel.phase, .ended(.closed))
    XCTAssertNil(channel.pid, "a child was spawned for an applet that had closed")
  }

  /// Catches a child that inherits uniterm's environment or directory, or misses a declared value.
  func testTheChildGetsOnlyTheDeclaredEnvironmentAndDirectory() async throws {
    let declared = scratch.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: declared, withIntermediateDirectories: true)

    for directory in [declared.path, nil] {
      let output = scratch.appendingPathComponent("env-\(directory == nil ? "home" : "dir")")

      let channel = try start(
        "env", [output.path], directory: directory, keys: ["SYNTHETIC_TOKEN"],
        values: ["SYNTHETIC_TOKEN": "value"])

      await waitUntil("the driver writes its environment") {
        FileManager.default.fileExists(atPath: output.path) && channel.isConnected
      }

      try? await Task.sleep(for: .milliseconds(200))

      let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
      let fields = Dictionary(
        uniqueKeysWithValues: lines.map { line in
          let parts = line.split(separator: "=", maxSplits: 1)
          return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
      let environment = try XCTUnwrap(ExecEnvironment.current())
      let expected = directory ?? environment.home

      XCTAssertEqual(
        Set(fields.keys), ["cwd", "HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "SYNTHETIC_TOKEN"])
      XCTAssertEqual(
        URL(fileURLWithPath: fields["cwd"] ?? "").resolvingSymlinksInPath().path,
        URL(fileURLWithPath: expected).resolvingSymlinksInPath().path)
      XCTAssertEqual(fields["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
      XCTAssertEqual(fields["SYNTHETIC_TOKEN"], "value")
      XCTAssertEqual(fields["HOME"], environment.home)

      channel.close()
    }
  }
}
