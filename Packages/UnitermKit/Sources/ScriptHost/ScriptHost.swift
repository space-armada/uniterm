import ControllerPackage
import Foundation
import PaneModel
import Preferences
import ProcessInspection
import ScriptWire
import StatusKit

/// The main actor's side of scripting. It answers each call a connected script makes, and never
/// waits on a peer.
///
/// A script's status messages post through a producer that this app issued, so a script never
/// posts as uniterm. The producer's name is the script's, which the user can read in the history.
@MainActor
public final class ScriptHost {
  /// Issues a script producer, or says why none came back.
  public typealias ProducerIssuer = @MainActor (_ name: String) -> ProducerRequest

  /// The longest producer name shown, in UTF-8 bytes.
  static let maxLabelBytes = 64

  struct Session {
    var name = "script"
    var producer: StatusProducer?

    /// The connection presented a token the host turned away. Nothing it sends is answered.
    var refused = false

    var kind = SessionKind.genericPeer
  }

  /// What a connection is, which decides how long its choices last and what they are called. A
  /// run's connection is its run. Any other connection is named a connection.
  enum SessionKind {
    /// A program that is not the bundled command. It keeps the admission any other program on the
    /// socket gets.
    case genericPeer

    /// The bundled command running a script file that declares nothing.
    case bundledRun

    /// A controller run, from a package or a native entry.
    case controllerRun

    /// The bundled command running a declared script file.
    case fileRun

    /// A REPL pane's helper.
    case repl

    /// A `uniterm open` command.
    case openCommand

    /// The bundled command running a question-only session. It runs no script code, and it may
    /// make only the form calls.
    case questionOnly

    var lastsOneRun: Bool { self == .bundledRun || self == .controllerRun || self == .fileRun }
  }

  let listener: ScriptListener
  private let issueProducer: ProducerIssuer
  let windows: (any ScriptWindowAPI)?
  private let sentContent: ScriptSentContent?

  /// Where the content programs sent waits, if the host holds any.
  var sentContentRoot: String? { sentContent?.rootPath }
  let onRefusal: @MainActor (ScriptRefusal) -> Void
  var sessions: [UInt64: Session] = [:]

  /// The REPL channels whose token no helper has spent yet, by token.
  var pendingRepls: [Data: ScriptReplChannel] = [:]

  /// The REPL channel each connection is bound to, by connection.
  var boundRepls: [UInt64: ScriptReplChannel] = [:]

  let reaper: ProcessReaper

  /// What bounds a REPL helper, and how the app reads its footprint and the time.
  let replLimits: ReplLimits
  let replProbes: ReplProbes
  var monitor: Task<Void, Never>?
  var lastSample: ContinuousClock.Instant?

  /// True from the first refusal for the budget until the total is back under it. One warning is
  /// recorded for the episode, however many panes are refused.
  var budgetEpisodeAnnounced = false

  /// Tracks spawned terminal session roots for authority checking.
  public let sessionRoots = SessionRootRegistry()

  /// The file each pane holds from a script's send. It is the only one the pane may still read.
  private struct Held {
    var file: URL
    var size: Int
  }

  struct PaneKey: Hashable {
    var window: UInt64
    var pane: UInt64
  }

  private var held: [PaneKey: Held] = [:]
  private var task: Task<Void, Never>?

  /// The requests of unbound connections that the user has not answered, oldest first. A
  /// connection holds at most one, so its repeated calls coalesce. Each connection holds one of
  /// the listener's slots, so the list never passes the listener's limit.
  private var pendingRequests: [PendingRequest] = []

  /// The most requests that wait at once.
  static let maxPendingRequests = ScriptListener.maxConnections

  /// The connections whose request the user denied, or whose grant the user revoked. Their calls
  /// stay refused and are not asked about again. A reconnect is a new connection, so it asks again.
  private var declined: Set<UInt64> = []

  /// The session roots running in each pane, oldest first. A terminal pane holds one per tab. Only
  /// this table says which pane a root belongs to, so a grant names a pane and gets its root here.
  var paneRoots: [PaneKey: [ProcessIdentity]] = [:]

  /// The grants the user made, by connection. A grant binds one connection to one pane's session.
  var grants: [UInt64: ExplicitGrant] = [:]

  /// REPL helpers that presented a valid token before their pane's session root arrived, by
  /// connection. The attach completes or is refused once the root is known.
  var awaitingRoot: [UInt64: (connection: ScriptConnection, channel: ScriptReplChannel)] = [:]

  /// The connections whose control the user revoked. Their calls stay refused for as long as they
  /// stay connected, even when they still run in a remote-controlled pane.
  private var revokedControllers: Set<UInt64> = []

  /// A watch on each connection's peer process, by connection. It reports an exec or an exit as
  /// it happens, so a connection whose peer started another executable loses its authority at
  /// once, and not only at its next call.
  private var peerWatches: [UInt64: any DispatchSourceProcess] = [:]

  /// A watch on each connection's peer for a stop or a continue, by connection. A shell's Ctrl-Z
  /// on a `uniterm run`, or a `kill -STOP` from anywhere, shows through it.
  private var peerStopWatches: [UInt64: ProcessStopWatcher] = [:]

  /// The connections whose peer reads as stopped now.
  var stoppedPeers: Set<UInt64> = []

  /// Where controller snapshots live and how the bundle's command is known. Without it, every
  /// controller run is refused.
  let controllerSettings: ControllerSettings?

  /// The admitted controller runs, by the connection each is bound to.
  var controllerRuns: [UInt64: ControllerRun] = [:] {
    didSet { refreshReadResolutions() }
  }

  /// The read-scope directories of the live runs with their links resolved, by the directory as
  /// written. Resolving reads the disk, so it happens off the main actor whenever a run gains a
  /// directory. A directory with no link in it, or none on disk, maps to itself.
  var resolvedReadDirectories: [String: String] = [:]

  /// The directories being resolved, so one change does not start the same work twice.
  var resolvingReadDirectories: Set<String> = []

  /// The snapshot of each Janet run, by connection. It outlives the run's authority, which a revoke
  /// ends, and goes when the connection closes, since the helper may still load from it until then.
  var controllerSnapshots: [UInt64: URL] = [:]

  /// Connections that asked for a controller run the host has not answered yet.
  var controllerAdmissions: Set<UInt64> = []

  /// Counts the starts and ends of removals of remembered policies, and how many are under way.
  /// The policy file is read and changed off the main actor, so a read that a removal overlapped
  /// may hold a policy that is gone. What was read covers a run only when no removal began or
  /// ended since the read began, and none is under way.
  var trustRemovals: UInt64 = 0
  var trustRemovalsUnderWay = 0

  /// Verified runs that wait for the user's startup review, by connection.
  var waitingAdmissions: [UInt64: WaitingAdmission] = [:]

  /// Declared files whose copy the app made and whose declaration has not come, by connection.
  var pendingDeclarations: [UInt64: PendingDeclaration] = [:]

  /// How long the command has to report a declaration once the app has answered its file begin.
  var fileDeclarationTimeout: TimeInterval = ScriptListener.declarationTimeout

  /// The command processes that have begun a session, admitted or not, and the REPL helpers that
  /// attached. A command opens its session before any script code runs, so a second begin from the
  /// same process comes from script code. Entries outlive the connection that made them, and go
  /// only when their process has exited and the table needs the room.
  var processSessions: [ProcessSessionKey: UInt64] = [:]

  /// Whether a process is still running. Only a test replaces it, to fill the table with processes
  /// that live and with processes that do not.
  var processIsLive: (pid_t, Int) -> Bool = { ProcessInspection.isRunning(pid: $0, started: $1) }

  /// The most processes the table keeps. A begin that finds it full of live processes is refused.
  static let maxProcessSessions = 1024

  /// Where the user chose how undeclared script files are treated. Without it, they are refused.
  let settings: SettingsStore?
  private var settingsWatch: SettingsObservation?

  /// The reviews of undeclared script files that wait, oldest first, and the runs behind them.
  public internal(set) var undeclaredReviews: [UndeclaredReview] = []
  var waitingUndeclared: [UInt64: WaitingUndeclared] = [:]

  /// The forms every connection opened, by handle.
  var forms = FormSlots()

  /// The calls of connections whose begin waits for the full check of the command, in order. They
  /// run, or are refused, once the check decides what the connection is.
  var heldRequests: [UInt64: [ScriptEvent]] = [:]

  /// Connections of a file or controller begin that the cheap check did not take for the command.
  /// Their place in the one-session table is claimed when the full check passes.
  var lateClaims: Set<UInt64> = []

  /// The undeclared runs the user admitted, by connection.
  var undeclaredRuns: [UInt64: UndeclaredRun] = [:]

  /// The startup reviews that wait, oldest first.
  public internal(set) var controllerReviews: [ControllerReview] = []
  var lastReviewID: UInt64 = 0

  /// The permission questions and denials the Pending Requests panel shows. Exec drivers and
  /// terminals put theirs here too.
  public let permissionRequests: PermissionRequests

  /// The clipboard the typed clipboard calls reach. Without one, they are refused.
  let clipboard: (any ScriptClipboard)?

  private var permissionWatch: ChangeObservers.Token?

  /// Where `uniterm open` sends the paths the user allowed. Without it, every open is refused.
  public var fileOpener: (any ScriptFileOpening)?

  /// The terminal sessions the user allowed to open files. Memory only, so no restore brings one
  /// back. It ends with the session root, the window, or the host.
  var openGrants: Set<OpenSessionGrant> = []

  /// The clipboard powers the user allowed for the session of an ordinary script connection.
  var clipboardGrants: [UInt64: Set<ControllerPermission>] = [:]

  /// Runs on every change the panel or the Controllers & Permissions window shows: a request, a
  /// review, a run, or a remembered policy.
  public let changes = ChangeObservers()

  /// Native controller launches, by the process that runs them.
  var nativeLaunches: [pid_t: NativeLaunch] = [:]

  /// Runs with a connection's ID when its authority to control panes ends: it closed, the user
  /// revoked it, or its binding to a pane ended. The window layer takes away every group it owns.
  /// It may run more than once for one connection.
  public var onControllerEnded: ((UInt64) -> Void)?

  /// Runs whenever a connection starts or stops acting for a pane: a binding through ancestry, a
  /// grant, a REPL attach, or any end of one. Pane chrome that names controllers reads them again.
  public var onControllersChanged: (() -> Void)?

  /// Runs when a request or a grant appears or goes away.
  public var onPendingRequestsChanged: (() -> Void)?

  /// Runs with true while any request waits, and with false once none does.
  public var onPendingRequestsActiveChanged: ((Bool) -> Void)?

  /// A request from a connection that is in no uniterm pane. It names the program, so the user can
  /// tell what is asking.
  public struct PendingRequest: Identifiable, Sendable, Equatable {
    public let id: UInt64
    public let pid: pid_t
    public let executablePath: String?
    public let name: String
    public let timestamp: Date

    /// How the user sees the program. The verified path wins. Without one, the name is whatever the
    /// program reported for itself, so it is marked the way the questions header marks it.
    public var programLabel: String {
      executablePath ?? Self.unverified(name)
    }

    /// The same as `programLabel`, with a verified path cut to its file name for a one-line view.
    public var shortProgramLabel: String {
      executablePath.map { ($0 as NSString).lastPathComponent } ?? Self.unverified(name)
    }

    private static func unverified(_ name: String) -> String {
      "\(name) (unverified script)"
    }
  }

  /// One connection's grant: the pane the user chose, and the session it was running when the
  /// user chose it.
  public struct ExplicitGrant: Sendable, Equatable {
    public let connection: UInt64
    public let pid: pid_t
    public let executablePath: String?
    public let window: UInt64
    public let pane: NodeID
    public let root: ProcessIdentity
    public let generation: UInt64
    public let grantedAt: Date
  }

  /// What came of the user's grant.
  public enum GrantResult: Equatable, Sendable {
    case granted

    /// The program left before the grant, so there is nothing to grant.
    case connectionClosed

    /// The grant was not made. The text says why, for the user.
    case failed(String)
  }

  /// Without `windows` or `sentContent`, the calls that need them are refused.
  public init(
    listener: ScriptListener, issueProducer: @escaping ProducerIssuer,
    windows: (any ScriptWindowAPI)? = nil, sentContent: ScriptSentContent? = nil,
    onRefusal: @escaping @MainActor (ScriptRefusal) -> Void = { _ in },
    reaper: ProcessReaper = .live, replLimits: ReplLimits = .live,
    replProbes: ReplProbes = .live, controllers: ControllerSettings? = nil,
    clipboard: (any ScriptClipboard)? = nil,
    permissionRequests: PermissionRequests = PermissionRequests(), settings: SettingsStore? = nil
  ) {
    self.settings = settings
    self.controllerSettings = controllers
    self.clipboard = clipboard
    self.permissionRequests = permissionRequests
    self.reaper = reaper
    self.replLimits = replLimits
    self.replProbes = replProbes
    self.listener = listener
    self.issueProducer = issueProducer
    self.windows = windows
    self.sentContent = sentContent
    self.onRefusal = onRefusal

    permissionWatch = permissionRequests.changes.add { [weak self] in self?.pendingChanged() }

    if let settings {
      settings.watch(.scriptFileMode)
      settingsWatch = settings.addObserver { [weak self] in self?.scriptFileModeMayHaveChanged() }
    }
  }

  /// The address of this instance, which no other instance shares. A REPL's helper takes it, so
  /// the helper reaches the instance that started it and not another one that is running.
  public var instanceAddress: String { listener.path }

  public func start() {
    guard task == nil else { return }

    if let helper = controllerSettings?.helper {
      Task.detached { helper.prepare() }
    }

    let events = listener.events

    task = Task { [weak self] in
      for await event in events {
        self?.handle(event)
      }
    }

    startMonitor()
  }

  public func stop() {
    for connection in forms.connections { endForms(of: connection) }

    listener.stop()
    task?.cancel()
    task = nil
    monitor?.cancel()
    monitor = nil

    for session in sessions.values {
      session.producer?.retire()
    }

    sessions = [:]
    processSessions = [:]
    stopControllers()
    settingsWatch?.cancel()
    settingsWatch = nil
    waitingUndeclared = [:]
    undeclaredReviews = []
    undeclaredRuns = [:]
    heldRequests = [:]
    lateClaims = []
    forms.removeAll()

    for watch in peerWatches.values { watch.cancel() }
    for watcher in peerStopWatches.values { watcher.cancel() }

    peerWatches = [:]
    peerStopWatches = [:]
    stoppedPeers = []
    pendingRepls = [:]
    boundRepls = [:]
    awaitingRoot = [:]
    pendingRequests = []
    declined = []
    grants = [:]
    revokedControllers = []
    clipboardGrants = [:]
    openGrants = []
    permissionRequests.end { if case .connection = $0 { return true } else { return false } }
  }

  func handle(_ event: ScriptEvent) {
    switch event {
    case .begun(let connection, let name):
      begin(connection, .plain(name))

    case .controllerBegun(let connection, let request):
      sessions[connection.id, default: Session()].name = "controller"
      sessions[connection.id, default: Session()].kind = .controllerRun

      guard claimIfBundledCommand(connection) else {
        refuseController(connection, Self.secondSessionText)
        onRefusal(.secondSession)

        return
      }

      watchPeer(of: connection)
      bindConnection(connection)
      beginController(connection, request)

    case .fileBegun(let connection, let request):
      sessions[connection.id, default: Session()].name = "script"
      sessions[connection.id, default: Session()].kind = .fileRun

      guard claimIfBundledCommand(connection) else {
        refuseController(connection, Self.secondSessionText)
        onRefusal(.secondSession)

        return
      }

      watchPeer(of: connection)
      bindConnection(connection)
      beginFile(connection, request)

    case .fileDeclared(let connection, let json):
      receiveDeclaration(connection, json: json)

    case .undeclaredBegun(let connection, let request):
      begin(connection, .undeclared(request))

    case .openBegun(let connection, let request):
      beginOpen(connection, request)

    case .questionBegun(let connection):
      beginQuestionOnly(connection)

    case .attached(let connection, let token):
      sessions[connection.id, default: Session()].kind = .repl

      // A token the host did not issue is refused by the attach itself. Only a valid attach counts
      // as the process's session, so a bad token never costs a REPL helper its place.
      if pendingRepls[token] != nil, !claimProcessSession(connection) {
        refuseSecondAttach(connection)

        return
      }

      watchPeer(of: connection)
      attach(connection, token: token)

    case .replLine(let connection, let text):
      boundRepls[connection.id]?.onEvent?(.line(text))

      if boundRepls[connection.id] == nil { connection.close() }

    case .replEvaluating(let connection, let running):
      boundRepls[connection.id]?.evaluationChanged(running)

      if boundRepls[connection.id] == nil { connection.close() }

    case .pong(let connection, let nonce):
      boundRepls[connection.id]?.pong(nonce, now: replProbes.now())

    case .replMemoryLimit(let connection):
      boundRepls[connection.id]?.helperReachedMemoryLimit()

      if boundRepls[connection.id] == nil { connection.close() }

    case .request(let connection, let id, let call):
      guard sessions[connection.id]?.refused != true, !connection.isClosed else { return }

      if heldRequests[connection.id] != nil {
        heldRequests[connection.id]?.append(event)

        return
      }

      releaseFilesOfClosedPanes()

      if let refusal = authorize(connection) { return connection.reply(id: id, result: refusal) }

      routeRequest(call, id: id, on: connection, once: [])

    case .closed(let connection):
      peerWatches.removeValue(forKey: connection.id)?.cancel()
      peerStopWatches.removeValue(forKey: connection.id)?.cancel()
      stoppedPeers.remove(connection.id)
      clipboardGrants[connection.id] = nil
      controllerConnectionClosed(connection.id)
      dropUndeclared(connection.id)
      heldRequests[connection.id] = nil
      lateClaims.remove(connection.id)
      sessions[connection.id]?.producer?.retire()
      sessions[connection.id] = nil
      boundRepls.removeValue(forKey: connection.id)?.connectionClosed()
      awaitingRoot[connection.id] = nil
      declined.remove(connection.id)
      revokedControllers.remove(connection.id)
      forget(connection: connection.id)
      authorityEnded(connection.id)

    case .refused(_, let refusal):
      onRefusal(refusal)
    }
  }

  /// Runs a call whose power check passed, or that the user allowed once. `once` carries that
  /// one allowed power, so the check at the effect sees the same answer and nothing more.
  func dispatch(
    _ call: ScriptCall, id: UInt32, on connection: ScriptConnection, once: Set<ControllerPermission>
  ) {
    guard !connection.isClosed else { return }

    switch call {
    case .openPane, .openTab, .sendCommand, .requestLayout:
      Task { @MainActor [weak self] in
        let result =
          await self?.runAsync(call, connection: connection, once: once)
          ?? .failure(.refused, "uniterm is quitting")

        connection.reply(id: id, result: result)
      }

    case .readClipboard, .writeClipboard:
      Task { @MainActor [weak self] in
        let result =
          await self?.performClipboard(call, on: connection, once: once)
          ?? .failure(.refused, "uniterm is quitting")

        connection.reply(id: id, result: result)
      }

    case .openForm, .waitForm, .discardForm:
      runFormCall(call, id: id, on: connection)

    default:
      connection.reply(id: id, result: run(call, on: connection, once: once))
    }
  }

  /// The refusal for a call whose power no longer holds at its effect, or nil.
  private func powerRefusal(
    _ call: ScriptCall, on connection: ScriptConnection, once: Set<ControllerPermission>
  ) -> ScriptResult? {
    switch checkPower(call, on: connection, once: once) {
    case .allowed: return nil
    case .refused(let result): return result
    case .needsApproval: return .failure(.refused, "The permission for this call has ended.")
    }
  }

  private func run(
    _ call: ScriptCall, on connection: ScriptConnection, once: Set<ControllerPermission>
  ) -> ScriptResult {
    if let refusal = authorize(connection) { return refusal }

    if let refusal = powerRefusal(call, on: connection, once: once) { return refusal }

    switch call {
    case .postStatus(let level, let text):
      switch producer(for: connection) {
      case .issued(let producer):
        producer.post(level: Self.level(level), text: text)

      case .noWindow:
        return .failure(.refused, "uniterm has no window to show the message")

      case .limitReached:
        return .failure(
          .refused,
          "uniterm is at its limit of live status sources. Post again after a script or applet ends."
        )
      }

      return .ok(Data())

    case .listWindows:
      return answer { try requireWindows().listWindows(caller: try requireCaller(connection)) }

    case .listPanes(let window):
      return answer {
        try requireWindows().listPanes(
          window: window, caller: try requireCaller(connection),
          access: readAccess(for: connection.id))
      }

    case .openPane, .openTab, .sendCommand, .requestLayout, .readClipboard, .writeClipboard,
      .openForm, .waitForm, .discardForm:
      return .failure(.failed, "the call has its own path, and was run as if it did not")

    case .send(let target, let name, let content):
      return answer {
        try send(content, named: name, to: target, caller: try requireCaller(connection))
      }
    }
  }

  /// The calls that check a directory run off the main actor and answer later.
  private func runAsync(
    _ call: ScriptCall, connection: ScriptConnection, once: Set<ControllerPermission>
  ) async -> ScriptResult {
    if let refusal = authorize(connection) { return refusal }

    if let refusal = powerRefusal(call, on: connection, once: once) { return refusal }

    do {
      let caller = try requireCaller(connection)

      // A call that waits keeps the caller it started with. A connection that came to act for
      // another pane meanwhile is refused, so the call never runs with authority it no longer has.
      let stillAllowed: @MainActor () throws -> Void = {
        try self.requireAuthority(connection)

        if case .failure(let kind, let text)? = self.powerRefusal(call, on: connection, once: once)
        {
          throw ScriptCallError(kind, text)
        }

        guard try self.requireCaller(connection) == caller else {
          throw ScriptCallError.refused("This program no longer acts for the pane it called from.")
        }
      }

      switch call {
      case .openPane(let kind, let beside, let axis, let directory, let access):
        return Self.result(
          of: try await requireWindows().openPane(
            kind: kind, beside: beside, axis: axis, directory: directory, access: access,
            caller: caller, stillAllowed: stillAllowed))

      case .openTab(let pane, let directory):
        return Self.result(
          of: try await requireWindows().openTab(
            pane: pane, directory: directory, caller: caller, stillAllowed: stillAllowed))

      case .sendCommand(let pane, let type, let version, let command, let arguments):
        return Self.result(
          of: try await requireWindows().sendCommand(
            to: pane, appletType: type, schemaVersion: version, command: command,
            arguments: arguments, caller: caller,
            access: { [weak self] in self?.readAccess(for: connection.id) ?? .none },
            powers: { [weak self] in self?.heldPowers(for: connection.id, once: once) ?? [] },
            stillAllowed: stillAllowed),
          commandRan: true)

      case .requestLayout(let pane, let layout):
        return Self.result(
          of: try await requireWindows().requestLayout(
            anchor: pane, layout: layout, caller: caller,
            powers: { [weak self] in self?.heldPowers(for: connection.id, once: once) ?? [] },
            stillAllowed: stillAllowed),
          commandRan: true)

      default:
        return .failure(.failed, "the call does not wait")
      }
    } catch {
      return Self.failure(error)
    }
  }

  /// The refusal for a call the connection may not make, or nil when it may. An unbound connection
  /// is asked about once. A binding is checked again on every call, so a peer that exited, or a
  /// session that closed, takes its authority with it.
  func authorize(_ connection: ScriptConnection) -> ScriptResult? {
    if peerWasReplaced(connection) {
      peerReplaced(connection)

      return .failure(
        .refused,
        "The program that opened this connection has since started another executable, or handed "
          + "the connection on, so the connection has no authority. It must reconnect.")
    }

    if revokedControllers.contains(connection.id) {
      return .failure(
        .refused,
        "You revoked this program's control of uniterm panes. It must reconnect to try again.")
    }

    guard connection.isBound else {
      // A REPL helper waiting for its session root is not a program to ask about. It binds to its
      // own pane or not at all.
      if awaitingRoot[connection.id] != nil {
        return .failure(.refused, "This REPL is not attached to its pane yet.")
      }

      if declined.contains(connection.id) {
        return .failure(.refused, "You denied this program access to a uniterm pane.")
      }

      recordPendingRequest(for: connection)

      return .failure(
        .refused,
        "This program is not running in a uniterm pane. Grant it a pane from Window > Pending "
          + "Requests.")
    }

    guard connection.validateBinding(registry: sessionRoots) else {
      endGrants { $0.connection == connection.id }
      authorityEnded(connection.id)

      return .failure(.refused, "The session this program was running in has closed.")
    }

    // A binding found through ancestry lasts only while the ancestry does. A process whose parent
    // exited has been moved to launchd, so it now asks like any program outside the panes. A
    // grant is the user's answer for that connection, so it needs no ancestry.
    if grants[connection.id] == nil, let binding = connection.binding {
      let peer = ProcessIdentity(pid: connection.peer.pid, started: connection.peerStartTime)

      guard ProcessAncestry.findRoot(for: peer, in: sessionRoots) == binding.root else {
        connection.unbind()
        authorityEnded(connection.id)

        return authorize(connection)
      }
    }

    return nil
  }

  /// Watches the connection's peer for an exec or an exit. The watch only hurries the end along.
  /// Every call checks the peer's generation itself, so an event that arrives late changes nothing.
  func watchPeer(of connection: ScriptConnection) {
    guard peerWatches[connection.id] == nil else { return }

    let watch = DispatchSource.makeProcessSource(
      identifier: connection.peer.pid, eventMask: [.exec, .exit], queue: .main)

    watch.setEventHandler { [weak self, weak connection] in
      MainActor.assumeIsolated {
        guard let self, let connection, !connection.isClosed, self.peerWasReplaced(connection)
        else { return }

        self.peerReplaced(connection)
      }
    }

    peerWatches[connection.id] = watch
    watch.activate()

    watchStops(of: connection)

    // An exec that came before the watch started raised no event, so the generation is read once
    // the watch is in place.
    if peerWasReplaced(connection) { peerReplaced(connection) }
  }

  /// Watches the peer for a stop or a continue, and reads its state until it settles. The peer's
  /// start time is read again in microseconds, and a peer that is no longer the admitted process
  /// is not watched.
  private func watchStops(of connection: ScriptConnection) {
    guard peerStopWatches[connection.id] == nil,
      let started = ProcessInspection.startTimeMicroseconds(of: connection.peer.pid),
      started / 1_000_000 == connection.peerStartTime
    else { return }

    let id = connection.id

    let watcher = ProcessStopWatcher(pid: connection.peer.pid, startedMicroseconds: started) {
      [weak self] stopped in
      guard let self else { return }

      if stopped {
        stoppedPeers.insert(id)
      } else {
        stoppedPeers.remove(id)
      }

      controllersChanged()
    }

    peerStopWatches[id] = watcher
    watcher.start()
  }

  /// True when the process the connection admitted still runs but is no longer what speaks on it:
  /// it started another executable, or a process it forked has taken the socket over. A peer that
  /// exited is not counted here. Its binding fails on its own, as a closed session's does.
  func peerWasReplaced(_ connection: ScriptConnection) -> Bool {
    !connection.peerGenerationHolds
      && ProcessInspection.isRunning(pid: connection.peer.pid, started: connection.peerStartTime)
  }

  /// Ends everything a connection could do once its peer is no longer the process it admitted.
  /// Its binding, grant, request, controller run, and owned groups go at once. A Janet run's
  /// snapshot stays until the connection closes. Every call it makes after that is
  /// refused, including one it sent before the exec, since each call reads the generation again.
  private func peerReplaced(_ connection: ScriptConnection) {
    endGrants { $0.connection == connection.id }
    forget(connection: connection.id)

    if connection.isBound { connection.unbind() }

    declined.insert(connection.id)
    controllerRuns[connection.id] = nil
    dropWaitingAdmission(connection.id)
    dropPendingDeclaration(connection.id)
    dropUndeclared(connection.id)
    authorityEnded(connection.id)
  }

  /// Throws the refusal `authorize` gives. A call that waits checks again after the wait, since
  /// a grant, a session, or the peer itself can end while it waits.
  private func requireAuthority(_ connection: ScriptConnection) throws {
    guard case .failure(let kind, let text)? = authorize(connection) else { return }

    throw ScriptCallError(kind, text)
  }

  /// The pane a bound connection acts for: the pane of its grant, or the pane whose session root
  /// its ancestry leads to. Nil when the root is in no pane the host knows.
  func caller(for connection: ScriptConnection) -> ScriptCaller? {
    if let grant = grants[connection.id] {
      return ScriptCaller(connection: connection.id, window: grant.window, pane: grant.pane)
    }

    guard let root = connection.binding?.root,
      let key = paneRoots.first(where: { $0.value.contains(root) })?.key
    else { return nil }

    return ScriptCaller(
      connection: connection.id, window: key.window, pane: NodeID(rawValue: key.pane))
  }

  private func requireCaller(_ connection: ScriptConnection) throws -> ScriptCaller {
    guard let caller = caller(for: connection) else {
      throw ScriptCallError.refused("uniterm cannot tell which pane this program acts for.")
    }

    return caller
  }

  func isRevoked(_ id: UInt64) -> Bool {
    revokedControllers.contains(id)
  }

  /// A connection's authority ended. Its clipboard grants and the operations it has waiting go
  /// with it, so no queued request outlives the authority it asked under.
  func authorityEnded(_ id: UInt64) {
    endForms(of: id)
    clipboardGrants[id] = nil
    permissionRequests.end(.connection(id))
    permissionRequests.end(.unboundOpen(id))
    onControllerEnded?(id)
    controllersChanged()
  }

  func controllersChanged() {
    onControllersChanged?()
    changes.notify()
  }

  // MARK: Controllers

  /// The connections that act for a pane now: those whose grant names it, and those whose
  /// ancestry leads to one of its session roots. The ones the user revoked are left out, since
  /// their calls are refused. An ancestry binding outlasts the revoke, so only the revoked set
  /// tells the two apart.
  public func controllers(actingFrom window: UInt64, pane: NodeID) -> Set<UInt64> {
    controllers { $0.window == window && $0.pane == pane }.subtracting(revokedControllers)
  }

  /// The connections that act for any pane of a window now, leaving out the ones the user
  /// revoked, since their calls are refused.
  public func controllers(actingIn window: UInt64) -> Set<UInt64> {
    controllers { $0.window == window }.subtracting(revokedControllers)
  }

  /// The session root the connection acts for, when its binding would be accepted on its next call.
  /// It asks the questions `authorize` asks, and changes nothing. A lapse is found, and the binding
  /// taken away, by the connection's next call. A connection the user revoked, or whose peer is no
  /// longer the process it admitted, has none.
  public func controllerSessionRoot(_ id: UInt64) -> ProcessIdentity? {
    guard !revokedControllers.contains(id), let connection = findConnection(id),
      !connection.isClosed, let binding = connection.binding,
      connection.validateBinding(registry: sessionRoots)
    else { return nil }

    guard grants[id] == nil else { return binding.root }

    let peer = ProcessIdentity(pid: connection.peer.pid, started: connection.peerStartTime)

    return ProcessAncestry.findRoot(for: peer, in: sessionRoots) == binding.root
      ? binding.root : nil
  }

  private func controllers(where matches: (ScriptCaller) -> Bool) -> Set<UInt64> {
    var found = Set<UInt64>()

    for id in sessions.keys {
      guard let connection = findConnection(id), !connection.isClosed,
        let caller = caller(for: connection), matches(caller)
      else { continue }

      found.insert(id)
    }

    return found
  }

  /// Ends the control of each connection. Its calls are refused from now on, including calls it
  /// sent that the host has not read or that wait in a directory check. Its grant ends, and it is
  /// not asked about again. The window layer is told, so the groups it owns lose their owner.
  public func revokeControllers(_ ids: Set<UInt64>) {
    controllerRunsRevoked(ids)

    for id in ids {
      revokedControllers.insert(id)
      endGrants { $0.connection == id }
      declined.insert(id)
      authorityEnded(id)
    }
  }

  /// What pane chrome calls a connection: its script's name and its program's PID. Nil for a
  /// connection that is gone.
  public func controllerName(_ id: UInt64) -> String? {
    guard let connection = findConnection(id), !connection.isClosed else { return nil }

    let name = sessions[id]?.name ?? "script"

    if let run = controllerRuns[id] {
      let kind = run.identity.artifact == .file ? "declared file" : "controller"

      return "\(name), \(kind) \(run.identity.controllerID) (PID \(connection.peer.pid))"
    }

    return "\(name) (PID \(connection.peer.pid))"
  }

  private func requireWindows() throws -> any ScriptWindowAPI {
    guard let windows else { throw ScriptCallError.refused("uniterm has no windows to script") }

    return windows
  }

  /// Validates the peer's ancestry and binds the connection to a session root when found. A
  /// connection that cannot be bound remains unbound, and its calls are refused.
  func bindConnection(_ connection: ScriptConnection) {
    let peerIdentity = ProcessIdentity(
      pid: connection.peer.pid, started: connection.peerStartTime)

    guard peerIdentity.isRunning else { return }

    guard let root = ProcessAncestry.findRoot(for: peerIdentity, in: sessionRoots) else {
      return
    }

    guard let generation = sessionRoots.sessionGeneration(for: root) else {
      return
    }

    connection.bind(to: root, generation: generation)
    controllersChanged()
  }

  /// Checks the pane first, so a refused send writes nothing. A file the pane did not take is
  /// removed at once.
  ///
  /// The check and the send run with no suspension between them, so the pane cannot change in
  /// between. The pane's previous file is the pane's no more once it takes this one.
  private func send(
    _ content: Data, named name: String, to target: ScriptTarget, caller: ScriptCaller
  ) throws -> ScriptValue {
    let windows = try requireWindows()

    guard let sentContent else { throw ScriptCallError.refused("uniterm cannot hold content") }

    try ScriptSentContent.checkName(name)
    let pane = try windows.prepareSend(to: target, caller: caller)

    // At most 1 MiB, a known size, so ADR-08 lets this write run on the main actor.
    let file = try sentContent.write(content, named: name)
    let reply: ScriptValue

    do {
      reply = try windows.send(to: pane, file: file, caller: caller)
    } catch {
      sentContent.discard(file, size: content.count)

      throw error
    }

    let key = PaneKey(window: pane.window, pane: pane.pane)

    if let previous = held.updateValue(Held(file: file, size: content.count), forKey: key) {
      sentContent.discard(previous.file, size: previous.size)
    }

    return reply
  }

  /// Removes the file of each pane that has closed, and gives its bytes back. A pane that is open
  /// keeps its last file, since the pane may still read it.
  private func releaseFilesOfClosedPanes() {
    guard let windows, let sentContent else { return }

    for (key, file) in held
    where !windows.isOpen(ScriptPaneReference(window: key.window, pane: key.pane)) {
      sentContent.discard(file.file, size: file.size)
      held[key] = nil
    }
  }

  /// Runs a function and turns what it returns, or throws, into the call's reply.
  private func answer(_ body: () throws -> ScriptValue) -> ScriptResult {
    do {
      return Self.result(of: try body())
    } catch {
      return Self.failure(error)
    }
  }

  /// A reply the frame cannot hold becomes a failure the script sees. For an applet command,
  /// which has already run by then, the failure says so, so the script never takes the command
  /// for one that was refused.
  static func result(of value: ScriptValue, commandRan: Bool = false) -> ScriptResult {
    let kind: ScriptFailureKind = commandRan ? .replyLost : .failed
    let lead = commandRan ? "the command ran, but its reply" : "the answer"

    do {
      let payload = try value.encoded()

      guard payload.count <= ScriptProtocol.maxReplyPayload else {
        return .failure(kind, "\(lead) is too large for one reply")
      }

      return .ok(payload)
    } catch {
      return .failure(kind, "\(lead) could not be sent: \(error)")
    }
  }

  static func failure(_ error: any Error) -> ScriptResult {
    guard let error = error as? ScriptCallError else {
      return .failure(.failed, "the call failed: \(error)")
    }

    return .failure(error.kind, error.text)
  }

  private func producer(for connection: ScriptConnection) -> ProducerRequest {
    var session = sessions[connection.id, default: Session()]

    if let producer = session.producer { return .issued(producer) }

    let request = issueProducer(session.name)

    if case .issued(let producer) = request {
      session.producer = producer
      sessions[connection.id] = session
    }

    return request
  }

  private static func level(_ level: ScriptStatusLevel) -> StatusLevel {
    switch level {
    case .info: return .info
    case .warning: return .warning
    case .error: return .error
    }
  }

  /// The script names its own label, so the label is cleaned like any text from outside.
  static func label(for name: String) -> String {
    let cleaned = StatusText.bounded(name, maximumBytes: maxLabelBytes)

    return cleaned.isEmpty ? "script" : cleaned
  }

  /// Records a terminal session root for authority checking. The identity comes from the
  /// terminal's report of the process it spawned, never from a caller.
  public func recordSessionRoot(
    _ identity: ProcessIdentity, sessionGeneration: UInt64, window: UInt64, pane: NodeID
  ) {
    sessionRoots.add(
      SessionRootRegistry.SessionRoot(identity: identity, sessionGeneration: sessionGeneration))

    let key = PaneKey(window: window, pane: pane.rawValue)

    paneRoots[key, default: []].removeAll { $0 == identity }
    paneRoots[key, default: []].append(identity)
  }

  /// Removes a terminal session root when its session closes or is replaced. Every grant to that
  /// session ends.
  public func removeSessionRoot(_ identity: ProcessIdentity, window: UInt64, pane: NodeID) {
    let acting = controllers(actingFrom: window, pane: pane).filter {
      findConnection($0)?.binding?.root == identity && grants[$0] == nil
    }

    let generation = sessionRoots.sessionGeneration(for: identity)

    sessionRoots.remove(identity)

    let key = PaneKey(window: window, pane: pane.rawValue)

    paneRoots[key]?.removeAll { $0 == identity }

    if paneRoots[key]?.isEmpty == true { paneRoots[key] = nil }

    endGrants { $0.root == identity }
    endOpenGrants { $0.root == identity }
    acting.forEach(authorityEnded)
    endForms(ofSession: identity, generation: generation, window: window)
  }

  /// Forgets every session root in a closed window, and ends every grant to one of its panes. The
  /// applets report their own sessions ending as the window closes. This also covers a session
  /// whose end was never reported.
  public func windowClosed(_ window: UInt64) {
    for (key, roots) in paneRoots where key.window == window {
      roots.forEach(sessionRoots.remove)
      paneRoots[key] = nil
      endOpenGrants { grant in roots.contains(grant.root) }
    }

    endGrants { $0.window == window }
  }

  /// The session root a grant to the pane binds to, or nil when the pane runs no recorded session.
  /// A pane with several tabs runs several sessions, and the newest one that still runs is chosen.
  public func sessionRoot(window: UInt64, pane: NodeID) -> ProcessIdentity? {
    paneRoots[PaneKey(window: window, pane: pane.rawValue)]?.last(where: sessionRoots.contains)
  }

  /// Records the request of an unbound connection. A connection asks once, however many calls it
  /// makes. A peer that has exited cannot ask, so a socket it handed on never reaches the user.
  private func recordPendingRequest(for connection: ScriptConnection) {
    guard !pendingRequests.contains(where: { $0.id == connection.id }),
      pendingRequests.count < Self.maxPendingRequests,
      ProcessInspection.isRunning(pid: connection.peer.pid, started: connection.peerStartTime)
    else { return }

    pendingRequests.append(
      PendingRequest(
        id: connection.id, pid: connection.peer.pid,
        executablePath: ProcessInspection.executablePath(of: connection.peer.pid),
        name: sessions[connection.id]?.name ?? "script", timestamp: Date()))

    notifyPendingRequestsChanged()
  }

  /// The requests the user has not answered, oldest first.
  public func allPendingRequests() -> [PendingRequest] {
    pendingRequests
  }

  /// Grants a waiting connection the session of one pane. The pane's root is read and checked now,
  /// so a pane whose session has ended cannot be granted.
  public func grantAccess(connection id: UInt64, window: UInt64, pane: NodeID) -> GrantResult {
    guard pendingRequests.contains(where: { $0.id == id }) else {
      return .failed("This program has no request waiting.")
    }

    guard let connection = findConnection(id), !connection.isClosed,
      ProcessInspection.isRunning(pid: connection.peer.pid, started: connection.peerStartTime)
    else {
      forget(connection: id)

      return .connectionClosed
    }

    guard !connection.isBound else {
      pendingRequests.removeAll { $0.id == id }
      notifyPendingRequestsChanged()

      return .failed("This program already acts for a pane, so it cannot be granted another.")
    }

    guard let root = sessionRoot(window: window, pane: pane),
      let generation = sessionRoots.sessionGeneration(for: root)
    else {
      return .failed("The pane has no running session to grant.")
    }

    connection.bind(to: root, generation: generation)

    grants[id] = ExplicitGrant(
      connection: id, pid: connection.peer.pid,
      executablePath: pendingRequests.first { $0.id == id }?.executablePath, window: window,
      pane: pane, root: root, generation: generation, grantedAt: Date())

    pendingRequests.removeAll { $0.id == id }
    notifyPendingRequestsChanged()
    controllersChanged()

    return .granted
  }

  /// Denies a request. The connection's calls stay refused, and it is not asked about again.
  public func denyRequest(connection id: UInt64) {
    guard pendingRequests.contains(where: { $0.id == id }) else { return }

    pendingRequests.removeAll { $0.id == id }
    declined.insert(id)
    notifyPendingRequestsChanged()
  }

  /// Ends a grant. The connection's calls are refused again, and it is not asked about again.
  public func revokeGrant(connection id: UInt64) {
    guard grants[id] != nil else { return }

    endGrants { $0.connection == id }
    declined.insert(id)
  }

  /// The grants that still hold, oldest first. A grant whose program exited, or whose session
  /// closed, has ended and is dropped here.
  public func allGrants() -> [ExplicitGrant] {
    endGrants { grant in
      guard let connection = findConnection(grant.connection) else { return true }

      return !connection.validateBinding(registry: sessionRoots)
    }

    return grants.values.sorted { ($0.grantedAt, $0.connection) < ($1.grantedAt, $1.connection) }
  }

  /// Ends each grant that matches. Its connection loses its binding, so its calls are refused
  /// again, and a connection whose program still runs may ask again.
  private func endGrants(where ends: (ExplicitGrant) -> Bool) {
    let ended = grants.values.filter(ends)

    guard !ended.isEmpty else { return }

    for grant in ended {
      grants[grant.connection] = nil
      findConnection(grant.connection)?.unbind()
      authorityEnded(grant.connection)
    }

    notifyPendingRequestsChanged()
  }

  /// Drops a connection's request and grant once the connection has gone, or once it is bound to
  /// its own pane and has nothing left to ask.
  func forget(connection id: UInt64) {
    let hadRequest = pendingRequests.contains { $0.id == id }
    let hadGrant = grants.removeValue(forKey: id) != nil

    pendingRequests.removeAll { $0.id == id }

    guard hadRequest || hadGrant else { return }

    notifyPendingRequestsChanged()
  }

  private func findConnection(_ id: UInt64) -> ScriptConnection? {
    listener.findConnection(id)
  }

  private func notifyPendingRequestsChanged() {
    pendingChanged()
  }
}
