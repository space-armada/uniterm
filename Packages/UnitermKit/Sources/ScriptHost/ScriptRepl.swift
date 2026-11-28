import Darwin
import Foundation
import HelperHost
import OSLog
import ProcessInspection
import ScriptWire

/// What a REPL's helper needs to start: where to connect, and the token that binds its connection
/// to the pane that asked for it.
public struct ScriptReplLaunch: Sendable, Equatable {
  /// This instance's own address, never another instance's and never the well-known one.
  public let address: String

  /// The single-use token, as 64 hex digits. It passes to the helper in its environment.
  public let token: String
}

/// What happened to a REPL's helper, as the app sees it.
public enum ScriptReplEvent: Sendable, Equatable {
  /// The helper presented its token and is bound to this pane. The ID names the process.
  case attached(ProcessIdentity)

  /// The user entered a line. The app keeps its own history from these.
  case line(String)

  /// A form started or finished evaluating.
  case evaluating(Bool)

  /// The helper's connection closed, so the helper is gone or about to be.
  case ended

  /// The helper was stopped or continued, as the process reads, or uniterm sent a stop or a
  /// continue. The state says which stops are uniterm's own.
  case suspensionChanged(SuspensionState)

  /// uniterm could not stop or continue the helper's group. The text says why, for the pane to
  /// show. Nothing was sent.
  case suspendFailed(String)

  /// The helper was ended for a reason the pane can say. It comes before `ended`, and the app has
  /// already killed the helper when it comes from the app.
  case terminated(ScriptReplEnd)
}

/// How the app makes sure a helper it started is gone. The app never trusts a process ID alone,
/// since the system reuses them.
public struct ProcessReaper: Sendable {
  /// A helper as the reaper kills it: its identity, and the microsecond it started, both read in
  /// one look at the process. The identity's start time has one-second resolution, which leaves
  /// room for a reused process ID. The microsecond start time is what the kill checks.
  public struct Target: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let startedMicroseconds: Int

    public var pid: pid_t { identity.pid }

    public init(identity: ProcessIdentity, startedMicroseconds: Int) {
      self.identity = identity
      self.startedMicroseconds = startedMicroseconds
    }

    /// Reads the process `pid` names now. A process that is gone, or whose start the system will
    /// not report, reads as having started at zero, which no live process matches.
    static func reading(_ pid: pid_t) -> Target {
      let started = ProcessInspection.startTimeMicroseconds(of: pid) ?? 0

      return Target(
        identity: ProcessIdentity(pid: pid, started: started / 1_000_000),
        startedMicroseconds: started)
    }
  }

  /// How long a helper has to leave on its own after its connection closes and its pty hangs up.
  public var delay: Duration

  /// True while the process the identity names is still running. A reused process ID is another
  /// process, so it reads false.
  public var isRunning: @Sendable (ProcessIdentity) -> Bool

  public var kill: @Sendable (Target) -> Void

  public init(
    delay: Duration, isRunning: @escaping @Sendable (ProcessIdentity) -> Bool,
    kill: @escaping @Sendable (Target) -> Void
  ) {
    self.delay = delay
    self.isRunning = isRunning
    self.kill = kill
  }

  public static let live = guarded(delay: .seconds(2), signal: ProcessInspection.signal)

  private static let log = Logger(subsystem: "dev.uniterm.app", category: "repl")

  /// A reaper whose kill sends SIGKILL through `signal`, the guarded call or a test's stand-in, and
  /// logs what the call did. A process the call reports gone needs no word.
  static func guarded(
    delay: Duration,
    signal: @escaping @Sendable (Int32, pid_t, Int) -> ProcessInspection.SignalResult
  ) -> ProcessReaper {
    ProcessReaper(
      delay: delay, isRunning: { $0.isRunning },
      kill: { target in
        let pid = target.pid

        switch signal(SIGKILL, pid, target.startedMicroseconds) {
        case .byToken, .gone:
          break

        case .byPid:
          log.notice("ended helper \(pid) by its process ID: the system gave no audit token")

        case .unreached:
          log.error("could not end helper \(pid): the signal did not reach it")

        case .refused:
          log.error("not ending helper \(pid): the process ID is never signalled")
        }
      })
  }

  /// Kills the process now, when it is still the one that was recorded. A process ID that the
  /// system has given to another process is left alone.
  func killNow(_ target: Target) {
    if isRunning(target.identity) { kill(target) }
  }

  /// Kills the process after the delay, when it is still the one that was recorded.
  func reap(_ target: Target) {
    let reaper = self

    Task.detached {
      try? await Task.sleep(for: reaper.delay)

      if reaper.isRunning(target.identity) { reaper.kill(target) }
    }
  }
}

/// One REPL pane's side of its helper: the token it issued, the connection that spent it, and the
/// events that connection reports.
///
/// The token binds a connection to this pane, so a helper cannot attach to the wrong one. It is
/// not a defense against another process of the same user, which can read the helper's original
/// environment. Nothing relies on it as one.
@MainActor
public final class ScriptReplChannel {
  public let launch: ScriptReplLaunch

  /// The helper's process, once it has attached.
  public var helper: ProcessIdentity? { helperTarget?.identity }

  /// The helper's process as the reaper kills it, once it has attached.
  private(set) var helperTarget: ProcessReaper.Target?

  /// The terminal session the helper runs under, once the terminal reports the process it
  /// spawned. Only a descendant of it may spend the token.
  private(set) var sessionRoot: ProcessIdentity?

  /// The session root's start time in microseconds, read when the terminal reported it. A root whose
  /// start the system will not report, or reports differently, is never signalled.
  private var sessionRootMicroseconds: Int?

  /// The generation the terminal reported with the session root.
  private(set) var sessionGeneration: UInt64?

  public var onEvent: (@MainActor (ScriptReplEvent) -> Void)?

  /// Whether the helper's process is stopped, and whether uniterm stopped it. The process's
  /// observed state is the truth, and the record marks only the stops uniterm made.
  public private(set) var suspension = SuspensionState()

  private var stopWatcher: ProcessStopWatcher?

  let tokenData: Data
  let history: [String]

  private weak var host: ScriptHost?
  private var connection: ScriptConnection?
  private let reaper: ProcessReaper
  private let limits: ReplLimits
  private let probes: ReplProbes
  private var ended = false
  private var liveness: HelperLiveness
  private var escalation = ReplInterruptEscalation()

  /// True from the helper's report that a form started until its report that the form ended.
  public private(set) var isEvaluating = false

  /// How many pongs the helper has sent, so a test waits for an answer and not for a delay.
  private(set) var pongsReceived = 0

  /// The helper's footprint at the last look, which the app-wide budget adds up.
  var lastFootprint = 0

  init(
    launch: ScriptReplLaunch, tokenData: Data, history: [String], host: ScriptHost,
    reaper: ProcessReaper, limits: ReplLimits, probes: ReplProbes
  ) {
    self.launch = launch
    self.tokenData = tokenData
    self.history = history
    self.host = host
    self.reaper = reaper
    self.limits = limits
    self.probes = probes
    self.liveness = HelperLiveness(
      timeBound: nil, pongGrace: limits.pongGrace, footprintCap: Int.max)
  }

  /// True from the moment the helper attaches until its connection closes.
  public var isAttached: Bool { connection != nil && !ended }

  /// Records the terminal session the helper runs under. The applet calls it when the terminal
  /// reports the process it spawned. A helper that attached before then is checked now.
  public func setSessionRoot(_ root: ProcessIdentity, generation: UInt64) {
    sessionRoot = root
    sessionGeneration = generation

    let started = ProcessInspection.startTimeMicroseconds(of: root.pid)

    sessionRootMicroseconds = started.flatMap { $0 / 1_000_000 == root.started ? $0 : nil }

    host?.sessionRootArrived(for: self)
  }

  func bind(_ connection: ScriptConnection) {
    self.connection = connection

    let target = ProcessReaper.Target.reading(connection.peer.pid)

    helperTarget = target
    liveness.markBusy(now: probes.now())
    watchStops(of: target)
    onEvent?(.attached(target.identity))
  }

  func connectionClosed() {
    guard !ended else { return }

    stopWatcher?.cancel()
    stopWatcher = nil
    connection = nil
    onEvent?(.ended)
  }

  private func watchStops(of target: ProcessReaper.Target) {
    let probe = probes.isStopped

    let watcher = ProcessStopWatcher(
      pid: target.pid, startedMicroseconds: target.startedMicroseconds,
      read: { pid, started in
        ProcessInspection.startTimeMicroseconds(of: pid) == started ? probe(pid) : nil
      },
      onChange: { [weak self] stopped in
        self?.applyObserved(stopped: stopped, now: self?.probes.now())
      })

    stopWatcher = watcher
    watcher.start()
  }

  /// Takes the process's observed state. A helper seen running again after a stop gets a fresh
  /// ping clock, so a ping left unanswered while it was stopped never ends it.
  func applyObserved(stopped: Bool, now: ContinuousClock.Instant?) {
    let wasStopped = suspension.isStopped

    guard suspension.observe(stopped: stopped) else { return }

    if wasStopped && !stopped { liveness.markBusy(now: now ?? probes.now()) }

    onEvent?(.suspensionChanged(suspension))
  }

  /// Stops the whole helper and what it started, by its process group, as Ctrl-Z does for a
  /// program in a shell. The helper must be attached. One that is still inside its declaration
  /// window is left alone, so the listener never drops it for a silence uniterm caused.
  ///
  /// A refusal is never silent. The pane is told, so a Ctrl-Z that does nothing says why.
  public func suspend() {
    guard isAttached, let helperTarget else { return }

    guard signalGroup(SIGSTOP, helperTarget) == .sent else { return }

    suspension.stopSent()
    stopWatcher?.settle()
    onEvent?(.suspensionChanged(suspension))
  }

  /// Continues the helper and its group. It works on a stop from outside too.
  public func resume() {
    guard isAttached, let helperTarget, suspension.canResume else { return }

    guard signalGroup(SIGCONT, helperTarget) == .sent else { return }

    suspension.continueSent()
    stopWatcher?.settle()
    onEvent?(.suspensionChanged(suspension))
  }

  private enum GroupSignal {
    case sent
    case gone
    case failed
  }

  /// Signals the group the helper lives in. The terminal starts the helper through a wrapper that
  /// stays its parent, so the helper is a member of the group and not its leader. The leader is the
  /// session's child, the one process uniterm started for this pane, named by pid and start time.
  /// The helper must belong to that group, and the group is never uniterm's own. Anything else is
  /// refused, and `reports` says so to the pane.
  private func signalGroup(
    _ number: Int32, _ target: ProcessReaper.Target, reports: Bool = true
  ) -> GroupSignal {
    guard let root = sessionRoot, let started = sessionRootMicroseconds else {
      return fail("uniterm does not know which process started this REPL", reports: reports)
    }

    switch ProcessInspection.signalGroup(
      number, leader: root.pid, startedMicroseconds: started, member: target.pid)
    {
    case .byToken, .byPid:
      return .sent

    case .gone:
      return .gone

    case .refused:
      Self.log.error("not signalling helper \(target.pid): its group is not its session's own")

      return fail(
        "uniterm cannot suspend this REPL, since its process group is not one uniterm started for "
          + "it.", reports: reports)

    case .unreached:
      Self.log.error("could not signal helper \(target.pid)'s group")

      return fail("uniterm could not stop this REPL's process group.", reports: reports)
    }
  }

  private func fail(_ text: String, reports: Bool) -> GroupSignal {
    if reports { onEvent?(.suspendFailed(text)) }

    return .failed
  }

  private static let log = Logger(subsystem: "dev.uniterm.app", category: "repl")

  /// Lets nothing the helper started stay frozen once the helper is on its way out. The continue
  /// goes out whatever the record says. A stop from outside may not be seen yet, and a closing
  /// terminal session waits for its child, so a stopped one would block the main thread.
  ///
  /// A helper whose leader is already gone is not reached. The guarded call needs the leader's
  /// recorded start time, since only the leader's pid names the group safely. A stopped member left
  /// behind is then ended by the terminal's hang-up.
  private func releaseGroup() {
    guard let helperTarget else { return }

    _ = signalGroup(SIGCONT, helperTarget, reports: false)
    suspension.continueSent()
  }

  func evaluationChanged(_ running: Bool) {
    isEvaluating = running

    if !running { escalation = ReplInterruptEscalation() }

    onEvent?(.evaluating(running))
  }

  func pong(_ nonce: UInt32, now: ContinuousClock.Instant) {
    pongsReceived += 1
    liveness.pong(nonce, now: now)
  }

  /// Forgets a ping the app left outstanding while its own main actor was busy, so the helper is
  /// not held to a deadline the app itself missed.
  func forgetOutstandingPing(now: ContinuousClock.Instant) {
    liveness.markBusy(now: now)
  }

  /// Acts on one look at the helper. A footprint past the cap and its margin kills the helper. An
  /// unanswered ping past the grace kills it as hung. A helper that answers is never ended for how
  /// long it works.
  ///
  /// A helper that reads as stopped is never taken for hung. Its pings stay unanswered because it
  /// cannot run. The check comes back with a fresh ping clock once the helper runs again.
  func observe(
    footprint: Int?, stopped: Bool? = nil, now: ContinuousClock.Instant, limits: ReplLimits
  ) {
    guard isAttached else { return }

    if let stopped { applyObserved(stopped: stopped, now: now) }

    if let footprint {
      lastFootprint = footprint

      if footprint > limits.killThreshold {
        terminate(.overFootprint(footprint))

        return
      }
    }

    guard !suspension.isStopped else { return }

    switch liveness.probe(footprint: nil, now: now) {
    case .healthy:
      break

    case .sendPing(let nonce):
      connection?.send(.ping(nonce))

    case .end:
      terminate(.unresponsive)
    }
  }

  /// The helper's allocator reached the cap and is ending the process. The helper says so before
  /// it goes, so the pane can name the reason instead of reporting a lost connection.
  func helperReachedMemoryLimit() {
    guard !ended else { return }

    onEvent?(.terminated(.memoryLimit))
  }

  /// Asks the helper to stop the form it is running. It is the same request Ctrl-C makes through
  /// the pty, and it reaches the helper whether or not the pty's signal does.
  public func requestStop() {
    guard let connection else { return }

    host?.replStopRequested(on: connection.id)
    connection.send(.stop)
  }

  /// One Ctrl-C press in the pane. The first while a form runs asks the helper to stop it. A
  /// second after a short gap, with the form still running, ends the helper.
  @discardableResult
  public func interruptPressed() -> ReplInterruptAction {
    guard isAttached else { return .ignore }

    // A press on a suspended helper continues it and, when a form runs, asks it to stop that form.
    // It never counts toward the second press that ends the helper.
    if suspension.canResume {
      resume()

      guard isEvaluating else { return .ignore }

      requestStop()

      return .stop
    }

    let action = escalation.press(evaluating: isEvaluating, now: probes.now())

    switch action {
    case .stop: requestStop()
    case .kill: terminate(.stoppedByUser)
    case .ignore: break
    }

    return action
  }

  /// Kills the helper, when it is still the process that attached, and says why.
  func terminate(_ reason: ScriptReplEnd) {
    guard !ended, let helperTarget else { return }

    releaseGroup()
    reaper.killNow(helperTarget)
    connection?.close()
    connection = nil
    onEvent?(.terminated(reason))
  }

  /// Ends a suspended helper and its whole group at once. The app is quitting, so no delayed kill
  /// would run, and a frozen group has no one left to continue it.
  public func endForQuit() {
    if suspension.canResume, let helperTarget {
      _ = signalGroup(SIGKILL, helperTarget, reports: false)
    }

    end()
  }

  /// Ends the helper. The token is withdrawn when no helper has used it yet. The connection
  /// closes, which makes the helper exit, and a helper that is still there after the delay is
  /// killed. The channel reports nothing more.
  public func end() {
    guard !ended else { return }

    ended = true
    onEvent = nil

    stopWatcher?.cancel()
    stopWatcher = nil
    releaseGroup()

    host?.withdraw(self)

    connection?.close()
    connection = nil

    if let helperTarget { reaper.reap(helperTarget) }
  }
}

extension ScriptHost {
  /// Splits a history into messages that each fit a control frame. The last one carries the final
  /// flag, and an empty history is one empty message, so the helper always hears that it was
  /// accepted.
  static func historyMessages(_ lines: [String]) -> [ScriptAppMessage] {
    let recalled = Array(lines.suffix(ScriptProtocol.recallLines))
    var chunks: [[String]] = []
    var current: [String] = []
    var bytes = 0

    for line in recalled {
      let size = min(line.utf8.count, ScriptProtocol.maxReplLineBytes) + 2

      if !current.isEmpty
        && (current.count >= ScriptProtocol.historyLinesPerMessage
          || bytes + size > historyChunkBytes)
      {
        chunks.append(current)
        current = []
        bytes = 0
      }

      current.append(line)
      bytes += size
    }

    chunks.append(current)

    return chunks.enumerated().map { index, lines in
      .history(lines: lines, final: index == chunks.count - 1)
    }
  }

  /// The most text one history message carries. The control frame holds 64 KiB, so this leaves
  /// room for its header and for lines that change size when they are cut at a character.
  static let historyChunkBytes = 24 * 1024

  /// Issues a token for a REPL pane's helper. The helper connects to this instance's own address
  /// and presents the token, which the host spends on first use. `history` is what the helper
  /// recalls, oldest first, and is never evaluated.
  public func openRepl(history: [String]) -> ScriptReplChannel {
    var bytes = Data(count: ScriptProtocol.tokenBytes)

    bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }

    let token = bytes.map { String(format: "%02x", $0) }.joined()
    let channel = ScriptReplChannel(
      launch: ScriptReplLaunch(address: instanceAddress, token: token), tokenData: bytes,
      history: history, host: self, reaper: reaper, limits: replLimits, probes: replProbes)

    pendingRepls[bytes] = channel

    return channel
  }

  /// Takes the token of a channel that ends before its helper used it. The helper's connection
  /// loses its binding, so a call it sent that is not answered yet is never run.
  func withdraw(_ channel: ScriptReplChannel) {
    pendingRepls[channel.tokenData] = nil

    for (id, bound) in boundRepls where bound === channel {
      boundRepls[id] = nil
      listener.findConnection(id)?.unbind()
      sessions[id, default: Session()].refused = true
      authorityEnded(id)
    }

    for (id, waiting) in awaitingRoot where waiting.channel === channel {
      awaitingRoot[id] = nil
      waiting.connection.close()
    }
  }

  /// Spends the token a helper presented. A token the host did not issue, or one already spent,
  /// is refused with a message and the connection closes.
  ///
  /// The terminal reports the session root on its own schedule, so a helper can attach first. Its
  /// attach then waits for the root, and is checked against it when it arrives.
  func attach(_ connection: ScriptConnection, token: Data) {
    guard let channel = pendingRepls.removeValue(forKey: token) else {
      refuseAttach(connection)

      return
    }

    guard channel.sessionRoot != nil else {
      awaitingRoot[connection.id] = (connection, channel)

      return
    }

    completeAttach(connection, to: channel)
  }

  /// Completes the attach that waited for this channel's session root.
  func sessionRootArrived(for channel: ScriptReplChannel) {
    guard let (id, waiting) = awaitingRoot.first(where: { $0.value.channel === channel }) else {
      return
    }

    awaitingRoot[id] = nil
    completeAttach(waiting.connection, to: channel)
  }

  /// Binds the helper to its pane when the peer descends from the channel's own session root, and
  /// that root is still the recorded one. A token used from any other process is refused.
  private func completeAttach(_ connection: ScriptConnection, to channel: ScriptReplChannel) {
    let peer = ProcessIdentity(pid: connection.peer.pid, started: connection.peerStartTime)

    guard !connection.isClosed, peer.isRunning, let channelRoot = channel.sessionRoot,
      let generation = channel.sessionGeneration,
      ProcessAncestry.findRoot(for: peer, in: sessionRoots) == channelRoot,
      sessionRoots.sessionGeneration(for: channelRoot) == generation
    else {
      refuseAttach(connection)

      return
    }

    connection.bind(to: channelRoot, generation: generation)
    forget(connection: connection.id)

    boundRepls[connection.id] = channel
    sessions[connection.id, default: Session()].name = "repl"
    controllersChanged()

    for message in Self.historyMessages(channel.history) {
      connection.send(message)
    }

    channel.bind(connection)
  }

  private func refuseAttach(_ connection: ScriptConnection) {
    sessions[connection.id, default: Session()].refused = true

    connection.send(
      .attachRefused(
        "uniterm did not accept this REPL. Its token was not issued by this uniterm, or was "
          + "already used."))
    connection.closeAfterSending()

    onRefusal(.replTokenRefused)
  }
}
