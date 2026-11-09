import Darwin
import Foundation
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// The REPL helper's limits, with real helper processes against a real host in this process.
///
/// These prove that the app's stop request interrupts a form and keeps the definitions, that the
/// watchdog answers the app's ping while a form runs, that a helper which answers is never killed
/// for working long, that one which stops answering is, that a footprint past the cap and its
/// margin is killed while the app-wide total kills nothing, that a form stuck in C is ended by the
/// user's second Ctrl-C, and that the helper's own allocator ends it at the cap with a notice.
/// Time moves by hand where a bound is seconds. Every wait is bounded, and a helper that outlives
/// its test is killed. They cannot prove the pane, which `ReplAppletTests` covers, or the key path
/// from the keyboard, which the UI tests drive.
@MainActor
final class ScriptReplLimitsTests: XCTestCase {
  private var directories: [URL] = []
  private var hosts: [ScriptHost] = []
  private var processes: [ReplProcess] = []
  private var center: StatusCenter!

  override func setUp() async throws {
    center = StatusCenter()
  }

  override func tearDown() async throws {
    for process in processes where process.process.isRunning {
      kill(process.pid, SIGCONT)
      kill(process.pid, SIGKILL)
    }

    for host in hosts {
      host.stop()
    }

    for directory in directories {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// A host whose limits, clock, and footprints the test controls. The reaper kills for real and
  /// records each process it killed.
  private func makeHost(
    limits: ReplLimits = ScriptReplLimitsTests.quietLimits, clock: ManualClock = ManualClock(),
    footprints: FakeFootprints = FakeFootprints(), killed: KilledPIDs = KilledPIDs()
  ) throws -> ScriptHost {
    let directory = try ScriptFixtures.makeSocketDirectory()
    let center = center!

    directories.append(directory)

    let reaper = ProcessReaper(
      delay: .milliseconds(20), isRunning: { $0.isRunning },
      kill: {
        killed.add($0)
        _ = Darwin.kill($0, SIGKILL)
      })

    let host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, reaper: reaper,
      replLimits: limits,
      replProbes: ReplProbes(footprint: { footprints.read($0) }, now: { clock.now }))

    host.start()
    hosts.append(host)

    return host
  }

  /// Limits whose timer never fires inside a test, so a test samples when it means to.
  private static let quietLimits = ReplLimits(
    helperCap: 1 << 30, killMargin: 1 << 28, budget: 4 << 30, sampleInterval: .seconds(3600),
    pongGrace: .seconds(3))

  private func start(_ channel: ScriptReplChannel, arguments: [String] = []) throws -> ReplProcess {
    let process = try ReplProcess(
      address: channel.launch.address,
      environment: [ScriptProtocol.replTokenVariable: channel.launch.token], arguments: arguments)

    processes.append(process)

    return process
  }

  private func attached(_ events: ReplEvents) async -> Bool {
    await waitUntil { events.attachedProcess != nil }
  }

  private func terminations(_ events: ReplEvents) -> [ScriptReplEnd] {
    events.all.compactMap {
      if case .terminated(let end) = $0 { return end }

      return nil
    }
  }

  // MARK: Stop request

  /// Catches a stop request that does not reach the VM, one that loses the definitions, and one
  /// that leaves an interrupt behind. The request is the app's own message on the control channel,
  /// so it works whether or not the pty's SIGINT ever arrives. The form after the stop must run to
  /// the end.
  func testTheAppsStopRequestInterruptsAFormAndKeepsTheDefinitions() async throws {
    let host = try makeHost()
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(def kept 5)\n")
    repl.write("(while true)\n")

    expect(await waitUntil { events.lastEvaluating == true && events.lines.count == 2 })

    channel.requestStop()

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

  /// Catches a stop request that, with nothing running, stops the next form at its first
  /// instruction. Three requests arrive at an idle prompt, and the form typed after them runs.
  func testAStopRequestAtAnIdlePromptChangesNothing() async throws {
    let host = try makeHost()
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(+ 1 1)\n")

    expect(await repl.waitForOutput("2\n"))

    for _ in 0..<3 {
      channel.requestStop()
    }

    // A stop request has no reply, and the signal it raises lands on another thread. Nothing
    // marks the moment the idle helper has dropped all three, so this wait stays a bounded sleep.
    try await Task.sleep(for: .milliseconds(300))

    repl.write("(var n 0)\n")
    repl.write("(for i 0 100000 (+= n 1))\n")
    repl.write("n\n")

    expect(await repl.waitForOutput("100000\n"), repl.standardOutput)
    XCTAssertTrue(repl.process.isRunning)

    channel.end()
  }

  // MARK: Liveness

  /// Catches a watchdog that answers only while the VM is idle, and a policy that kills a helper
  /// for working long. The form runs for ten seconds of the app's clock, and the app pings it at
  /// each second. It answers every ping from its watchdog thread, so nothing is ever ended.
  func testALongLegitimateLoopIsNeverKilledBecauseTheWatchdogAnswers() async throws {
    let clock = ManualClock()
    let killed = KilledPIDs()
    let host = try makeHost(clock: clock, killed: killed)
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(while true)\n")

    expect(await waitUntil { events.lastEvaluating == true })

    for round in 1...10 {
      let answered = channel.pongsReceived

      clock.advance(by: .seconds(1))

      await host.sampleRepls()

      expect(
        await waitUntil(timeout: .seconds(10)) { channel.pongsReceived > answered },
        "the helper never answered the ping of round \(round)")
    }

    XCTAssertEqual(terminations(events), [], "a busy helper that answered was ended")
    XCTAssertEqual(killed.all, [])
    XCTAssertTrue(repl.process.isRunning)
    XCTAssertEqual(events.lastEvaluating, true)

    channel.end()
  }

  /// Catches a helper that stops answering being left running. The process is stopped with SIGSTOP,
  /// so nothing in it can answer. Once the ping has gone unanswered past the grace, the app kills
  /// it and says it stopped answering.
  func testAHelperThatStopsAnsweringIsKilledAsHung() async throws {
    let clock = ManualClock()
    let killed = KilledPIDs()
    let host = try makeHost(clock: clock, killed: killed)
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    kill(repl.pid, SIGSTOP)

    clock.advance(by: .seconds(1))
    await host.sampleRepls()
    clock.advance(by: .seconds(4))
    await host.sampleRepls()

    XCTAssertEqual(terminations(events), [.unresponsive])
    XCTAssertEqual(killed.all, [repl.pid])
    expect(await processIsGone(repl.pid), "the hung helper is still there")
  }

  // MARK: Footprint and budget

  /// Catches a kill that waits for the allocator's cap, a kill of the wrong helper, and a total
  /// that kills a running REPL. The cap is 1000 and the margin 250. Two helpers together pass the
  /// budget, so a new REPL is refused and neither helper is touched. One helper then passes the
  /// cap and its margin, and only that one is killed.
  func testAFootprintPastTheMarginIsKilledAndTheTotalKillsNothing() async throws {
    let footprints = FakeFootprints()
    let killed = KilledPIDs()
    let limits = ReplLimits(
      helperCap: 1000, killMargin: 250, budget: 1500, sampleInterval: .seconds(3600),
      pongGrace: .seconds(3))
    let host = try makeHost(limits: limits, footprints: footprints, killed: killed)

    let first = host.openRepl(history: [])
    let second = host.openRepl(history: [])
    let firstEvents = ReplEvents(first)
    let secondEvents = ReplEvents(second)
    let firstRepl = try start(first)
    let secondRepl = try start(second)

    expect(await attached(firstEvents))
    expect(await attached(secondEvents))

    footprints.set(900, for: firstRepl.pid)
    footprints.set(800, for: secondRepl.pid)

    await host.sampleRepls()

    XCTAssertEqual(host.replFootprintTotal, 1700)

    guard case .refused(.overBudget(let used, let budget, _)) = host.admitRepl(history: []) else {
      return XCTFail("a REPL started over the budget")
    }

    XCTAssertEqual(used, 1700)
    XCTAssertEqual(budget, 1500)
    XCTAssertEqual(killed.all, [], "the total killed a running REPL")
    XCTAssertEqual(terminations(firstEvents), [])
    XCTAssertEqual(terminations(secondEvents), [])

    footprints.set(1300, for: firstRepl.pid)

    await host.sampleRepls()

    XCTAssertEqual(terminations(firstEvents), [.overFootprint(1300)])
    XCTAssertEqual(terminations(secondEvents), [])
    XCTAssertEqual(killed.all, [firstRepl.pid])
    expect(await processIsGone(firstRepl.pid))
    XCTAssertTrue(secondRepl.process.isRunning)

    expect(
      await waitUntil {
        if case .channel(let opened) = host.admitRepl(history: []) {
          opened.end()

          return true
        }

        return false
      }, "the budget never freed after the helper died")

    second.end()
  }

  /// Catches a footprint at the cap, or inside the margin, being killed. The allocator's own cap
  /// is the first layer, and the app kills only past the margin.
  func testAFootprintInsideTheMarginIsLeftAlone() async throws {
    let footprints = FakeFootprints()
    let killed = KilledPIDs()
    let limits = ReplLimits(
      helperCap: 1000, killMargin: 250, budget: 100_000, sampleInterval: .seconds(3600),
      pongGrace: .seconds(3))
    let host = try makeHost(limits: limits, footprints: footprints, killed: killed)
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    footprints.set(1250, for: repl.pid)

    await host.sampleRepls()

    XCTAssertEqual(killed.all, [])
    XCTAssertEqual(terminations(events), [])

    footprints.set(1251, for: repl.pid)

    await host.sampleRepls()

    XCTAssertEqual(killed.all, [repl.pid])

    channel.end()
  }

  /// Catches a burst of REPLs opened inside one sample interval that passes the budget. Each REPL
  /// that was admitted and has not attached counts for the floor, so the admissions stop once the
  /// floors add up past the budget, though no helper has a footprint to read yet.
  func testABurstOfAdmissionsCountsEachUnattachedHelperAtTheFloor() {
    let limits = ReplLimits(
      helperCap: 1000, killMargin: 250, budget: 1000, startingFloor: 400,
      sampleInterval: .seconds(3600), pongGrace: .seconds(3))

    guard let host = try? makeHost(limits: limits) else { return XCTFail("no host") }

    var admitted: [ScriptReplChannel] = []
    var refusal: ScriptReplRefusal?

    for _ in 0..<6 {
      switch host.admitRepl(history: []) {
      case .channel(let channel): admitted.append(channel)
      case .refused(let reason): refusal = reason
      }

      if refusal != nil { break }
    }

    XCTAssertEqual(admitted.count, 3)
    XCTAssertEqual(refusal, .overBudget(used: 1200, budget: 1000, announce: true))

    for channel in admitted {
      channel.end()
    }

    guard case .channel(let again) = host.admitRepl(history: []) else {
      return XCTFail("the floors stayed counted after the channels ended")
    }

    again.end()
  }

  /// Catches an admission that trusts a footprint the last look read. A helper attached after the
  /// last look reads as nothing, and one that grew since reads as its old size. The footprint here
  /// is set after the attach and no look follows, and the admission must still refuse.
  func testAdmissionReadsAttachedFootprintsFresh() async throws {
    let footprints = FakeFootprints()
    let limits = ReplLimits(
      helperCap: 1 << 30, killMargin: 1 << 28, budget: 1000, startingFloor: 10,
      sampleInterval: .seconds(3600), pongGrace: .seconds(3))
    let host = try makeHost(limits: limits, footprints: footprints)
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    XCTAssertEqual(host.replFootprintTotal, 0, "no look has run yet")

    footprints.set(5000, for: repl.pid)

    guard case .refused(.overBudget(let used, _, _)) = host.admitRepl(history: []) else {
      return XCTFail("a REPL started over the budget that no look had read yet")
    }

    XCTAssertEqual(used, 5000)

    channel.end()
  }

  /// Catches a warning for every refused pane. An episode begins at the first refusal over the
  /// budget and ends once an admission, or a look, finds the total back under it. Only the first
  /// refusal of an episode announces, and a later episode announces again.
  func testOnlyTheFirstRefusalOfAnEpisodeAnnounces() async throws {
    let footprints = FakeFootprints()
    let limits = ReplLimits(
      helperCap: 1 << 30, killMargin: 1 << 28, budget: 1000, startingFloor: 10,
      sampleInterval: .seconds(3600), pongGrace: .seconds(3))
    let host = try makeHost(limits: limits, footprints: footprints)
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    func refusal() -> ScriptReplRefusal? {
      if case .refused(let reason) = host.admitRepl(history: []) { return reason }

      return nil
    }

    footprints.set(5000, for: repl.pid)

    XCTAssertEqual(refusal(), .overBudget(used: 5000, budget: 1000, announce: true))
    XCTAssertEqual(refusal(), .overBudget(used: 5000, budget: 1000, announce: false))
    XCTAssertEqual(refusal(), .overBudget(used: 5000, budget: 1000, announce: false))

    footprints.set(10, for: repl.pid)
    await host.sampleRepls()

    footprints.set(5000, for: repl.pid)

    XCTAssertEqual(refusal(), .overBudget(used: 5000, budget: 1000, announce: true))

    channel.end()
  }

  // MARK: Stuck in C

  /// Catches a helper stuck in a C call that nothing can end. The form reads standard input, which
  /// the test never writes to. The first Ctrl-C asks the helper to stop, and the call never reads
  /// the flag, so the form keeps running. A second after the gap kills the helper, and the pane
  /// learns the user did it.
  func testASecondCtrlCEndsAFormStuckInACallTheInterruptNeverReaches() async throws {
    let clock = ManualClock()
    let killed = KilledPIDs()
    let host = try makeHost(clock: clock, killed: killed)
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(do (print \"reading\") (flush) (file/read stdin 1))\n")

    expect(await waitUntil { events.lastEvaluating == true })
    expect(await repl.waitForOutput("reading"), repl.standardOutput)

    // The helper prints just before the read. An interrupt that lands before the read begins would
    // stop the form at the call, so the first press waits until the main thread is blocked.
    expect(await waitUntilBlocked(repl.pid), "the form never blocked in the read")

    XCTAssertEqual(channel.interruptPressed(), .stop)

    // Cost: this 1 s wait proves a negative. A helper stuck in C survives one interrupt, and no
    // event marks that nothing happened. Only a real helper blocked in a real read shows that the
    // signal does not end the call, so no cheaper layer can prove it.
    try await Task.sleep(for: .seconds(1))

    XCTAssertTrue(repl.process.isRunning, "the first interrupt ended a call it cannot reach")
    XCTAssertEqual(events.lastEvaluating, true)

    clock.advance(by: .seconds(1))

    XCTAssertEqual(channel.interruptPressed(), .kill)
    XCTAssertEqual(terminations(events), [.stoppedByUser])
    XCTAssertEqual(killed.all, [repl.pid])
    expect(await processIsGone(repl.pid), "the stuck helper is still there")
  }

  /// Catches a double tap killing a helper that was about to stop. The second press comes before
  /// the gap, so it is ignored, and the form ends on the first request.
  func testADoubleTapOnAnOrdinaryLoopStopsItWithoutKillingTheHelper() async throws {
    let clock = ManualClock()
    let killed = KilledPIDs()
    let host = try makeHost(clock: clock, killed: killed)
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    repl.write("(while true)\n")

    expect(await waitUntil { events.lastEvaluating == true })

    XCTAssertEqual(channel.interruptPressed(), .stop)

    clock.advance(by: .milliseconds(100))

    XCTAssertEqual(channel.interruptPressed(), .ignore)

    expect(await repl.waitForError("interrupted"), repl.standardError)
    expect(await waitUntil { events.lastEvaluating == false })
    XCTAssertEqual(killed.all, [])
    XCTAssertTrue(repl.process.isRunning)

    channel.end()
  }

  /// Pins the escalation rule alone: what each press means, the gap, the window, and the reset
  /// when nothing runs.
  func testTheEscalationRule() {
    var rule = ReplInterruptEscalation()
    let start = ContinuousClock.Instant.now

    XCTAssertEqual(rule.press(evaluating: false, now: start), .ignore)
    XCTAssertEqual(rule.press(evaluating: true, now: start), .stop)
    XCTAssertEqual(rule.press(evaluating: true, now: start + .milliseconds(100)), .ignore)
    XCTAssertEqual(rule.press(evaluating: true, now: start + .seconds(1)), .kill)
    XCTAssertEqual(rule.press(evaluating: true, now: start + .seconds(2)), .stop)
    XCTAssertEqual(rule.press(evaluating: true, now: start + .seconds(30)), .stop)
    XCTAssertEqual(rule.press(evaluating: false, now: start + .seconds(31)), .ignore)
    XCTAssertEqual(rule.press(evaluating: true, now: start + .seconds(32)), .stop)
  }

  // MARK: Memory

  /// Catches a REPL helper that survives a runaway allocation, or one that dies without telling the
  /// pane why. The cap is 64 MiB here. The helper ends with the memory status and message, and the
  /// app hears it say so before the connection closes.
  func testARunawayAllocationEndsTheHelperWithANoticeTheAppHears() async throws {
    let host = try makeHost()
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, arguments: ["--memory-cap", String(64 << 20)])

    expect(await attached(events))

    repl.write("(def kept 1)\n")
    repl.write("(buffer/new 100000000)\n")

    expect(await repl.waitForError("out of memory"), repl.standardError)

    let status = await repl.exitStatus()

    XCTAssertEqual(status, 79)
    expect(await waitUntil { self.terminations(events) == [.memoryLimit] })
    XCTAssertTrue(repl.standardError.contains("64 MiB"), repl.standardError)

    channel.end()
  }

  // MARK: Sandbox

  /// Catches a REPL that grants itself anything. Each denied operation fails with the sandbox's
  /// error, and the REPL goes on afterwards.
  func testADeniedOperationFailsInTheReplToo() async throws {
    let host = try makeHost()
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    let attempts = [
      "(os/getenv \"HOME\")", "(slurp \"/etc/hosts\")", "(spit \"/tmp/uniterm-denied\" \"x\")",
      "(os/execute [\"/usr/bin/true\"])", "(net/listen \"127.0.0.1\" \"0\")", "(ffi/native)",
    ]

    for attempt in attempts {
      repl.write(attempt + "\n")
    }

    repl.write("(+ 20 22)\n")

    expect(await repl.waitForOutput("42\n"), repl.standardOutput)

    let denied = repl.standardError.components(separatedBy: "sandbox").count - 1

    XCTAssertGreaterThanOrEqual(denied, attempts.count, repl.standardError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/uniterm-denied"))

    channel.end()
  }

  // MARK: Measurement

  /// Records what a REPL helper costs at rest, for the design's numbers. The figures go to the
  /// test log. The helper has attached and evaluated one form, then sits waiting for the next. The
  /// assertion only holds the footprint under the per-helper cap.
  func testTheReplHelperRestingFootprintAndStartupTime() async throws {
    let host = try makeHost()
    let channel = host.openRepl(history: [])
    let events = ReplEvents(channel)
    let clock = ContinuousClock()
    let launch = clock.now
    let repl = try start(channel)

    expect(await attached(events))

    let startup = clock.now - launch

    repl.write("(+ 1 1)\n")

    expect(await repl.waitForOutput("2\n"), repl.standardOutput)

    // Not a negative. The helper's startup allocations settle before the resting footprint is read,
    // and nothing reports the moment they have.
    try await Task.sleep(for: .milliseconds(300))

    let footprint = try XCTUnwrap(ScriptFixtures.footprint(of: repl.pid))

    print(
      "repl helper \(ScriptFixtures.helper().lastPathComponent): resting footprint "
        + "\(footprint) bytes (\(footprint / 1024) KiB), startup to attach \(startup)")

    XCTAssertGreaterThan(footprint, 0)
    XCTAssertLessThan(footprint, ScriptProtocol.helperMemoryCap)

    channel.end()
  }
}
