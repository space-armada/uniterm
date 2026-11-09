import Darwin
import Foundation
import HelperHost
import ScriptWire

/// What bounds the REPL helpers the app started.
///
/// The cap is per helper. The budget is for all of them together. Neither is a setting, since a
/// setting waits until users need other values.
public struct ReplLimits: Sendable, Equatable {
  /// The footprint a helper's own allocator is held to. The allocator ends the helper at this
  /// mark, and the app only reads a footprint past it plus a margin as a helper to kill.
  public var helperCap: Int

  /// How far past the cap a footprint may go before the app kills the helper. The allocator counts
  /// what Janet asks for, and the footprint counts everything the process holds.
  public var killMargin: Int

  /// The most that REPL helpers may hold together before a new REPL is refused.
  public var budget: Int

  /// What a helper counts for at admission while it has been admitted and has not attached, and
  /// so has no footprint to read. It is above a helper's measured resting footprint, so a burst of
  /// REPLs opened together cannot slip past the budget while each still reads as nothing.
  public var startingFloor: Int

  /// How often the app looks at each helper's footprint and sends it a ping.
  public var sampleInterval: Duration

  /// How long a helper may leave a ping unanswered before the app takes it for hung. The watchdog
  /// thread answers, so a helper busy in Janet or in a C call still answers.
  public var pongGrace: Duration

  public init(
    helperCap: Int, killMargin: Int, budget: Int, startingFloor: Int = 8 << 20,
    sampleInterval: Duration, pongGrace: Duration
  ) {
    self.helperCap = helperCap
    self.killMargin = killMargin
    self.budget = budget
    self.startingFloor = startingFloor
    self.sampleInterval = sampleInterval
    self.pongGrace = pongGrace
  }

  /// 1 GiB a helper, killed at 1.25 GiB. The budget is 4 GiB, or a quarter of physical memory when
  /// that is smaller. A look every second, and 3 seconds to answer a ping.
  public static let live = ReplLimits(
    helperCap: ScriptProtocol.helperMemoryCap, killMargin: ScriptProtocol.footprintKillMargin,
    budget: min(4 << 30, Int(clamping: ProcessInfo.processInfo.physicalMemory) / 4),
    sampleInterval: .seconds(1), pongGrace: .seconds(3))

  /// The footprint at which a helper is killed.
  public var killThreshold: Int { helperCap + killMargin }
}

/// Where the app reads a helper's footprint and the time, so a test can inject both.
public struct ReplProbes: Sendable {
  /// The footprint of a process in bytes, or nil when it cannot be read. It runs off the main
  /// thread.
  public var footprint: @Sendable (pid_t) -> Int?

  public var now: @Sendable () -> ContinuousClock.Instant

  public init(
    footprint: @escaping @Sendable (pid_t) -> Int?,
    now: @escaping @Sendable () -> ContinuousClock.Instant
  ) {
    self.footprint = footprint
    self.now = now
  }

  public static let live = ReplProbes(
    footprint: { HelperProcess.footprint(ofPID: $0) }, now: { .now })
}

/// Why the app or the helper ended a REPL helper, for the pane's message.
public enum ScriptReplEnd: Sendable, Equatable {
  /// The helper's allocator reached the cap and ended the helper.
  case memoryLimit

  /// The app read a footprint past the cap and its margin, and killed the helper.
  case overFootprint(Int)

  /// The helper stopped answering pings, so the app killed it.
  case unresponsive

  /// The user pressed Ctrl-C twice while a form that the first interrupt never reached was still
  /// running, so the app killed the helper.
  case stoppedByUser
}

/// What the app does with one Ctrl-C press in a REPL pane.
public enum ReplInterruptAction: Sendable, Equatable {
  /// Ask the helper to stop the running form.
  case stop

  /// The first request did not end the form, so end the helper.
  case kill

  /// Nothing is running, or the press repeats one that is still being served.
  case ignore
}

/// How Ctrl-C escalates in a REPL pane. The first press while a form runs asks the helper to stop
/// it. A second press that comes after a short gap, while the form still runs, ends the helper.
///
/// The gap keeps a double tap on an ordinary loop from killing a helper that was about to answer.
/// The window keeps an old press from counting toward a new one. A form stuck in a C call that the
/// interrupt never reaches, such as a long `peg/match`, is the case the second press exists for.
public struct ReplInterruptEscalation: Sendable, Equatable {
  public var minimumGap: Duration
  public var window: Duration

  private var firstPress: ContinuousClock.Instant?

  public init(minimumGap: Duration = .milliseconds(500), window: Duration = .seconds(5)) {
    self.minimumGap = minimumGap
    self.window = window
  }

  public mutating func press(evaluating: Bool, now: ContinuousClock.Instant) -> ReplInterruptAction
  {
    guard evaluating else {
      firstPress = nil

      return .ignore
    }

    guard let first = firstPress, now - first <= window else {
      firstPress = now

      return .stop
    }

    guard now - first >= minimumGap else { return .ignore }

    firstPress = nil

    return .kill
  }
}

/// What a request to open a REPL got.
public enum ScriptReplOpening {
  case channel(ScriptReplChannel)
  case refused(ScriptReplRefusal)
}

/// Why a REPL did not start. The pane says why and offers a retry that only the user can run.
public enum ScriptReplRefusal: Equatable, Sendable {
  /// Scripting is not running, so there is no listener for a helper to reach.
  case scriptingOff

  /// The REPL helpers hold more than the budget together, so no new one starts. No running REPL is
  /// ended for the total. `announce` is true for the first refusal of an over-budget episode, and
  /// that refusal's pane posts the one history warning. The episode ends when the total is back
  /// under the budget.
  case overBudget(used: Int, budget: Int, announce: Bool)
}

extension ScriptHost {
  /// The footprints the last look read, added up over the helpers that are attached now.
  var replFootprintTotal: Int {
    attachedRepls().reduce(0) { $0 + $1.lastFootprint }
  }

  private func attachedRepls() -> [ScriptReplChannel] {
    var seen = Set<ObjectIdentifier>()

    return boundRepls.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
  }

  /// What the helpers hold now, for the admission of one more. An attached helper's footprint is
  /// read fresh, since the last look may be a second old and a helper that attached after it has
  /// none. `proc_pid_rusage` is one bounded system call per helper, so ADR-08 lets it run here. A
  /// helper whose footprint cannot be read counts for what the last look saw, and at least the
  /// floor. A helper that was admitted and has not attached counts for the floor.
  private func admissionTotal() -> Int {
    var total = pendingRepls.count * replLimits.startingFloor

    for channel in attachedRepls() {
      if let identity = channel.helper, identity.isRunning,
        let fresh = replProbes.footprint(identity.pid)
      {
        channel.lastFootprint = fresh
        total += fresh
      } else {
        total += max(channel.lastFootprint, replLimits.startingFloor)
      }
    }

    return total
  }

  /// Opens a REPL unless the helpers already hold more than the budget. A refusal is never a
  /// retry the app runs on its own, and the first refusal of an episode is the one that announces.
  ///
  /// The total at admission is at most the budget, so one admission adds at most one cap beyond
  /// it. Helpers that already run may still grow, each to its own cap, and the total never ends
  /// one of them.
  public func admitRepl(history: [String]) -> ScriptReplOpening {
    let used = admissionTotal()

    guard used <= replLimits.budget else {
      let announce = !budgetEpisodeAnnounced

      budgetEpisodeAnnounced = true

      return .refused(.overBudget(used: used, budget: replLimits.budget, announce: announce))
    }

    budgetEpisodeAnnounced = false

    return .channel(openRepl(history: history))
  }

  func startMonitor() {
    guard monitor == nil else { return }

    let interval = replLimits.sampleInterval

    monitor = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)

        guard !Task.isCancelled else { return }

        await self?.sampleRepls()
      }
    }
  }

  /// Reads each attached helper's footprint off the main thread, then acts on what it read: a
  /// helper past the cap and its margin is killed, and a helper that left a ping unanswered past the
  /// grace is killed as hung. A helper that answers is never killed for working too long, and the
  /// total is never a reason to kill anything.
  func sampleRepls() async {
    let now = replProbes.now()
    let stalled = lastSample.map { now - $0 > replLimits.sampleInterval * 4 } ?? false

    lastSample = now

    var seen = Set<ObjectIdentifier>()
    var targets: [(channel: ScriptReplChannel, identity: ProcessIdentity)] = []

    for channel in boundRepls.values where seen.insert(ObjectIdentifier(channel)).inserted {
      if let identity = channel.helper { targets.append((channel, identity)) }
    }

    let probe = replProbes.footprint
    let readings = await Self.readFootprints(targets.map(\.identity), using: probe)

    // The main actor may have been busy for longer than the grace. A pong that arrived meanwhile
    // is still queued behind this call, so a stalled app forgives the pings it has outstanding.
    for (index, target) in targets.enumerated() where target.channel.isAttached {
      if stalled { target.channel.forgetOutstandingPing(now: now) }

      target.channel.observe(footprint: readings[index], now: now, limits: replLimits)
    }

    if replFootprintTotal <= replLimits.budget { budgetEpisodeAnnounced = false }
  }

  private nonisolated static func readFootprints(
    _ identities: [ProcessIdentity], using probe: @Sendable (pid_t) -> Int?
  ) async -> [Int?] {
    identities.map { identity in
      guard identity.isRunning else { return nil }

      return probe(identity.pid)
    }
  }
}
