import Darwin
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
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
  private let handles = ReplHandles()
  private var center: StatusCenter!

  override func setUp() async throws {
    center = StatusCenter()
  }

  override func tearDown() async throws {
    for process in processes {
      process.process.signal(SIGCONT)
      process.process.signal(SIGKILL)
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
    footprints: FakeFootprints = FakeFootprints(), killed: KilledPIDs = KilledPIDs(),
    stops: FakeStops? = nil, reaperDelay: Duration = .milliseconds(20)
  ) throws -> ScriptHost {
    let directory = try ScriptFixtures.makeSocketDirectory()
    let center = center!
    let handles = handles

    directories.append(directory)

    let reaper = ProcessReaper(
      delay: reaperDelay, isRunning: { $0.isRunning },
      kill: {
        killed.add($0.pid)
        handles.signal($0.pid, SIGKILL)

        // A helper under a wrapper is not a handle's own process, so the guarded call reaches it.
        _ = ProcessInspection.signal(
          SIGKILL, pid: $0.pid, startedMicroseconds: $0.startedMicroseconds)
      })

    let host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) }, reaper: reaper,
      replLimits: limits,
      replProbes: ReplProbes(
        footprint: { footprints.read($0) }, now: { clock.now },
        isStopped: { stops?.read($0) ?? ProcessInspection.isStopped(pid: $0) }))

    host.start()
    recordTestProcessAsSessionRoot(host)
    hosts.append(host)

    return host
  }

  /// Limits whose timer never fires inside a test, so a test samples when it means to.
  private static let quietLimits = ReplLimits(
    helperCap: 1 << 30, killMargin: 1 << 28, budget: 4 << 30, sampleInterval: .seconds(3600),
    pongGrace: .seconds(3))

  /// Starts a helper. With `wrapped`, it starts the way the app's terminal starts it: a wrapper
  /// that leads a process group of its own, with the helper as its child and a member of that group,
  /// not a leader. The channel's session root is the wrapper, as the terminal reports it.
  private func start(
    _ channel: ScriptReplChannel, arguments: [String] = [], wrapped: Bool = false
  ) throws -> ReplProcess {
    let process = try ReplProcess(
      address: channel.launch.address,
      environment: [ScriptProtocol.replTokenVariable: channel.launch.token], arguments: arguments,
      wrapped: wrapped)

    processes.append(process)
    handles.add(process.process)

    if wrapped {
      let identity = ProcessIdentity(
        pid: process.pid, started: ProcessInspection.startTime(of: process.pid) ?? 0)

      // Nothing yields between the spawn and this call, so the helper cannot attach under the test
      // process's own root first.
      hosts.last?.recordSessionRoot(
        identity, sessionGeneration: 1, window: 1, pane: NodeID(rawValue: 2))
      channel.setSessionRoot(identity, generation: 1)
    }

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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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

  /// Catches a helper that stops answering being left running. The helper is stopped with SIGSTOP,
  /// and the injected reading says it runs, so it is a helper that cannot answer and is not stopped
  /// as far as the app can tell. Once the ping has gone unanswered past the grace, the app kills it
  /// and says it stopped answering.
  func testAHelperThatStopsAnsweringWithoutReadingAsStoppedIsKilledAsHung() async throws {
    let clock = ManualClock()
    let killed = KilledPIDs()
    let stops = FakeStops(false)
    let host = try makeHost(clock: clock, killed: killed, stops: stops)
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))

    XCTAssertEqual(repl.process.signal(SIGSTOP), .sent)

    clock.advance(by: .seconds(1))
    await host.sampleRepls()
    clock.advance(by: .seconds(4))
    await host.sampleRepls()

    XCTAssertEqual(terminations(events), [.unresponsive])
    XCTAssertEqual(killed.all, [repl.pid])
    expect(await processIsGone(repl.pid), "the hung helper is still there")
  }

  /// Catches a hang check that ends a helper someone stopped. The helper is stopped with SIGSTOP
  /// from outside, as `kill -STOP` would, and the app reads it as stopped. However long the clock
  /// runs, the check stands down.
  func testAHelperThatIsStoppedIsNeverEndedAsHung() async throws {
    let clock = ManualClock()
    let killed = KilledPIDs()
    let host = try makeHost(clock: clock, killed: killed)
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, wrapped: true)

    expect(await attached(events))

    let outside = ProcessInspection.signal(
      SIGSTOP, pid: repl.helperPid, startedMicroseconds: repl.helperStartedMicroseconds)

    XCTAssertTrue([.byToken, .byPid].contains(outside), "the outside stop did not go out")

    expect(await waitUntil { channel.suspension.isSuspended }, "the stop was not seen")
    XCTAssertFalse(channel.suspension.isSuspendedByUniterm, "an outside stop counted as uniterm's")

    for _ in 0..<5 {
      clock.advance(by: .seconds(10))
      await host.sampleRepls()
    }

    XCTAssertEqual(terminations(events), [])
    XCTAssertEqual(killed.all, [])
    XCTAssertTrue(repl.process.isRunning)

    channel.resume()

    expect(await waitUntil { !channel.suspension.isSuspended }, "Resume did not continue it")
  }

  /// Catches a ping left unanswered while the helper was stopped ending it once it runs again.
  /// The helper is really stopped, and the injected reading first says it runs, so a ping goes out
  /// that nothing can answer. The reading then says stopped, and the clock runs far past the grace.
  /// When the helper continues, its ping clock starts over, so it is neither ended for the old ping
  /// nor left unpinged.
  func testTheHangClockRestartsOnResumeSoAnOldPingNeverEndsTheHelper() async throws {
    let clock = ManualClock()
    let killed = KilledPIDs()
    let stops = FakeStops(false)
    let host = try makeHost(clock: clock, killed: killed, stops: stops)
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, wrapped: true)

    expect(await attached(events))

    channel.suspend()

    expect(await waitUntil { ProcessInspection.isStopped(pid: repl.helperPid) == true })

    clock.advance(by: .seconds(1))
    await host.sampleRepls()

    stops.set(true)
    clock.advance(by: .seconds(10))
    await host.sampleRepls()

    XCTAssertTrue(channel.suspension.isSuspendedByUniterm)
    XCTAssertEqual(terminations(events), [], "the hang check ended a stopped helper")

    stops.set(false)
    channel.resume()

    let answered = channel.pongsReceived

    await host.sampleRepls()

    XCTAssertFalse(channel.suspension.isSuspended)
    XCTAssertEqual(terminations(events), [], "a ping left from before the stop ended the helper")

    expect(
      await waitUntil(timeout: .seconds(10)) { channel.pongsReceived > answered },
      "the helper was not pinged again after it continued")
    XCTAssertEqual(killed.all, [])
    XCTAssertTrue(repl.process.isRunning)

    channel.end()
  }

  // MARK: Suspension

  /// Catches a suspend that loses the REPL's context, one that lets a line run while the helper is
  /// stopped, and a resume that drops the line typed meanwhile. The helper holds a definition. It is
  /// suspended, a line that uses the definition is written, and nothing runs until it resumes.
  func testASuspendedHelperRunsNoLineAndKeepsItsContextAfterResume() async throws {
    let host = try makeHost()
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, wrapped: true)

    expect(await attached(events))

    repl.write("(def kept 5)\n")

    expect(await waitUntil { events.lines == ["(def kept 5)"] })

    channel.suspend()

    expect(await waitUntil { channel.suspension.isSuspendedByUniterm })

    repl.write("(+ kept 1)\n")

    // Cost: this 300 ms wait proves a negative. A stopped helper reports no line, and nothing marks
    // the moment it would have. No cheaper layer shows a stopped process stays silent.
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(events.lines, ["(def kept 5)"], "a suspended helper ran a line")
    XCTAssertFalse(repl.standardOutput.contains("6\n"))

    channel.resume()

    expect(await repl.waitForOutput("6\n"), repl.standardOutput)
    XCTAssertEqual(terminations(events), [])

    channel.end()
  }

  /// Catches a suspend sent to a helper that shares the caller's process group, which would stop
  /// the app or the test run with it. The helper has no group of its own, so nothing is sent.
  func testASuspendNeverSignalsAHelperThatSharesTheCallersGroup() async throws {
    let host = try makeHost()
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel)

    expect(await attached(events))
    XCTAssertEqual(getpgid(repl.helperPid), getpgrp())

    channel.suspend()

    XCTAssertFalse(channel.suspension.canResume, "the suspend claimed a stop it never sent")
    XCTAssertEqual(ProcessInspection.isStopped(pid: repl.helperPid), false)

    channel.end()
  }

  /// Catches a suspend that stops a helper still inside its declaration window. The channel has no
  /// attached helper yet, so Suspend All leaves it alone, and the listener never drops it for a
  /// silence that uniterm caused.
  func testASuspendBeforeTheHelperHasAttachedStopsNothing() async throws {
    let host = try makeHost()
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)

    channel.suspend()

    XCTAssertFalse(channel.suspension.canResume)
    XCTAssertEqual(events.all, [])

    let repl = try start(channel, wrapped: true)

    expect(await attached(events))
    XCTAssertEqual(ProcessInspection.isStopped(pid: repl.helperPid), false)

    channel.end()
  }

  /// Catches a Ctrl-C that neither continues a stopped helper nor interrupts its form, and one that
  /// counts toward the second press that ends the helper. The form is stuck in a call the interrupt
  /// cannot reach. A press on the suspended helper continues it and asks it to stop, and a second
  /// press after the gap is a first press again, not a kill.
  func testCtrlCOnASuspendedHelperResumesThenStopsAndDoesNotCountTowardTheKill() async throws {
    let clock = ManualClock()
    let killed = KilledPIDs()
    let host = try makeHost(clock: clock, killed: killed)
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, wrapped: true)

    expect(await attached(events))

    repl.write("(do (print \"reading\") (flush) (file/read stdin 1))\n")

    expect(await waitUntil { events.lastEvaluating == true })
    expect(await repl.waitForOutput("reading"), repl.standardOutput)
    expect(await waitUntilBlocked(repl.helperPid), "the form never blocked in the read")

    channel.suspend()

    expect(await waitUntil { channel.suspension.isSuspendedByUniterm })

    XCTAssertEqual(channel.interruptPressed(), .stop)

    expect(await waitUntil { !channel.suspension.isSuspended }, "the press did not continue it")

    clock.advance(by: .seconds(1))

    XCTAssertEqual(
      channel.interruptPressed(), .stop,
      "the press that resumed the helper counted toward the double press")
    XCTAssertEqual(killed.all, [])

    clock.advance(by: .seconds(1))

    XCTAssertEqual(channel.interruptPressed(), .kill)
    expect(await processIsGone(repl.helperPid))
  }

  /// Catches a Ctrl-C at an idle prompt that does anything beyond continuing the helper.
  func testCtrlCOnAnIdleSuspendedHelperOnlyResumes() async throws {
    let host = try makeHost()
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, wrapped: true)

    expect(await attached(events))

    channel.suspend()

    expect(await waitUntil { channel.suspension.isSuspendedByUniterm })

    XCTAssertEqual(channel.interruptPressed(), .ignore)

    expect(await waitUntil { !channel.suspension.isSuspended })
    XCTAssertEqual(terminations(events), [])
    XCTAssertTrue(repl.process.isRunning)

    channel.end()
  }

  /// Catches an end that leaves a suspended helper frozen. The reaper's delay is long, so only the
  /// continue that comes before the close lets the helper read the closed connection and leave.
  func testEndingASuspendedHelperContinuesItSoItLeavesOnItsOwn() async throws {
    let killed = KilledPIDs()
    let host = try makeHost(killed: killed, reaperDelay: .seconds(60))
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, wrapped: true)

    expect(await attached(events))

    channel.suspend()

    expect(await waitUntil { channel.suspension.isSuspendedByUniterm })

    channel.end()

    expect(
      await processIsGone(repl.helperPid, timeout: .seconds(10)), "the suspended helper stayed")
    XCTAssertEqual(killed.all, [], "the reaper had to kill it")
  }

  /// Catches an end that continues a helper only when uniterm's record says it is stopped. A stop
  /// from outside may not be seen, and the injected reading says the helper runs. The reaper's delay
  /// is long, so only the unconditional continue lets the helper read the closed connection and
  /// leave. A closing terminal session waits for its child, so a helper left stopped would block the
  /// main thread.
  func testEndingAHelperContinuesItEvenWhenTheStopWasNeverSeen() async throws {
    let killed = KilledPIDs()
    let host = try makeHost(
      killed: killed, stops: FakeStops(false), reaperDelay: .seconds(60))
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, wrapped: true)

    expect(await attached(events))

    let outside = ProcessInspection.signal(
      SIGSTOP, pid: repl.helperPid, startedMicroseconds: repl.helperStartedMicroseconds)

    XCTAssertTrue([.byToken, .byPid].contains(outside), "the outside stop did not go out")
    expect(await waitUntil { ProcessInspection.isStopped(pid: repl.helperPid) == true })
    XCTAssertFalse(channel.suspension.canResume, "the stop was seen, so the test proves nothing")

    channel.end()

    expect(await processIsGone(repl.helperPid, timeout: .seconds(10)), "the stopped helper stayed")
    XCTAssertEqual(killed.all, [], "the reaper had to kill it")
  }

  /// Catches a quit that leaves a suspended helper, or what it started, frozen. The reaper's delay is
  /// long and the channel is never closed first, so only the group kill that the quit sends can
  /// end the helper in time.
  func testQuitEndsASuspendedHelperAtOnce() async throws {
    let host = try makeHost(reaperDelay: .seconds(60))
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try start(channel, wrapped: true)

    expect(await attached(events))

    channel.suspend()

    expect(await waitUntil { channel.suspension.isSuspendedByUniterm })

    channel.endForQuit()

    expect(await processIsGone(repl.helperPid, timeout: .seconds(5)), "the suspended helper stayed")
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

    let first = openTestRepl(host: host, history: [])
    let second = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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
    let channel = openTestRepl(host: host, history: [])
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

/// The helpers a test started, found by process ID. The reaper's kill closure runs off the main
/// actor, so it looks a helper up here and signals it through its handle, which never signals a
/// helper that has been reaped. A process ID with no handle is not signalled.
private final class ReplHandles: @unchecked Sendable {
  private let lock = NSLock()
  private var handles: [pid_t: HelperHandle] = [:]

  func add(_ handle: HelperHandle) {
    lock.withLock { handles[handle.pid] = handle }
  }

  func signal(_ pid: pid_t, _ number: Int32) {
    lock.withLock { handles[pid] }?.signal(number)
  }
}

/// What the app reads as a helper's stopped state, so a test can say a helper runs while it is
/// really stopped. Nothing set reads the real process.
final class FakeStops: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool?

  init(_ value: Bool? = nil) {
    self.value = value
  }

  func set(_ value: Bool?) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func read(_ pid: pid_t) -> Bool? {
    lock.lock()
    defer { lock.unlock() }

    return value
  }
}
