import ControllerPackage
import ControllerTrust
import Darwin
import FileRouting
import Foundation
import PaneModel
import ProcessInspection
import ScriptWire

/// A native controller's launch, between the command's request and the entry's own connection.
///
/// The command asks for the run, the app verifies and snapshots the package, and the command then
/// execs the snapshot's entry in the same process. The entry's connection is bound to the run only
/// when it comes from that process, with the same start time, after an exec, running the very code
/// the snapshot holds at the snapshot's path.
struct NativeLaunch {
  let snapshot: ControllerSnapshot
  let scopes: Set<ControllerPermission>
  let approval: ControllerApproval
  let standing: Set<ControllerPermission>
  let started: Int

  /// The command's process ID version. The entry's must differ, since an exec changes it.
  let launcherGeneration: Int32

  /// The entry's code directory hash and path, read from the snapshot.
  let entryHash: Data
  let entryPath: String

  let sourceRoot: ProcessIdentity?
  let window: UInt64?
  let pane: NodeID?

  /// The entry's process ID version, once its first connection is bound.
  var generation: Int32?

  let watch: any DispatchSourceProcess
}

extension ScriptHost {
  /// The most native launches the host tracks at once. Each one waits on a process that the
  /// listener already counts as a connection, so the bound matches the listener's.
  static let maxNativeLaunches = ScriptListener.maxConnections

  /// The run a connection is bound to, or nil when it is no controller run.
  public func controllerRun(connection id: UInt64) -> ControllerRun? {
    controllerRuns[id]
  }

  /// Every live controller run, oldest connection first.
  public func allControllerRuns() -> [ControllerRun] {
    controllerRuns.values.sorted { $0.connection < $1.connection }
  }

  /// Starts the admission of a controller run. Nothing the connection sends is answered until the
  /// app has authenticated the command, verified the package, and made its snapshot, all off the
  /// main actor.
  func beginController(_ connection: ScriptConnection, _ request: ControllerBegin) {
    guard let settings = controllerSettings else {
      return refuseController(connection, "This uniterm does not run controller packages.")
    }

    guard let token = connection.peer.token else {
      return refuseController(connection, "uniterm cannot tell which program asked.")
    }

    guard request.package.hasPrefix("/") else {
      return refuseController(connection, "The package must be named by an absolute path.")
    }

    if request.entry == .native, nativeLaunches.count >= Self.maxNativeLaunches {
      return refuseController(connection, "Too many native controllers are starting at once.")
    }

    controllerAdmissions.insert(connection.id)

    let revision = trustRemovals

    Task { @MainActor [weak self] in
      let outcome = await Task.detached {
        Self.admit(request, token: token, settings: settings)
      }.value

      self?.finishController(connection, request, outcome: outcome, trustRevision: revision)
    }
  }

  /// What admission found, off the main actor.
  enum Admission: Sendable {
    case admitted(ControllerSnapshot, entryHash: Data?, entryPath: String?, trust: TrustLookup)
    case refused(String)
  }

  /// What the remembered policies say of a run, read when the run was admitted.
  struct TrustLookup: Sendable {
    /// The policy that covers the request, when one does. A version policy wins over an identity.
    var covering: ControllerSelector?

    /// The policy for this controller that leaves the least uncovered, to show what is new.
    var nearest: ControllerPolicy?

    /// The version approvals of the same thing at other versions, which trusting this version
    /// offers to replace.
    var older: [ControllerPolicy] = []

    /// False when the user cannot be offered a remembered choice.
    var writable: Bool

    var notice: String?

    /// How many entries the policy file holds that this build cannot read.
    var unreadable = 0

    static let none = TrustLookup(covering: nil, nearest: nil, writable: false, notice: nil)
  }

  /// The powers a run asks for: what its descriptor declares beyond capabilities, and the
  /// capabilities named with `--allow`.
  nonisolated static func requested(
    _ descriptor: ControllerDescriptor, capabilities: [String]
  ) -> Set<ControllerPermission> {
    requested(descriptor.permissions, capabilities: capabilities)
  }

  /// The powers a run asks for out of the permissions its artifact declares.
  nonisolated static func requested(
    _ permissions: Set<ControllerPermission>, capabilities: [String]
  ) -> Set<ControllerPermission> {
    // A capability is requested at the version the artifact declares it.
    var scopes = Set(
      capabilities.compactMap { name in
        permissions.first { $0.capabilityName == name }
      })

    for permission in permissions where permission.capabilityName == nil {
      scopes.insert(permission)
    }

    return scopes
  }

  /// Reads the policy file, and finds the policy that covers the request. Only an approval this
  /// build reads in full is ever covering, or the nearest to what a run asks for. `versionOf` is
  /// what the run is a version of, and only finds the older versions to offer to replace.
  nonisolated static func lookUp(
    _ requested: Set<ControllerPermission>, for identity: ControllerIdentity,
    versionOf: String? = nil, in store: ControllerTrustStore?
  ) -> TrustLookup {
    guard let store, !requested.isEmpty else { return .none }

    let state = store.read()
    let matching = state.policies.filter { $0.selector.matches(identity) }
    let covering = matching.filter { $0.uncovered(requested).isEmpty }.min { first, _ in
      first.selector.kindName == "version"
    }
    let nearest = matching.min { $0.uncovered(requested).count < $1.uncovered(requested).count }

    let older =
      versionOf.map { thing in
        state.policies.filter {
          $0.versionOf == thing && $0.selector.kindName == "version"
            && $0.selector.artifact == identity.artifact && $0.selector.value != identity.version
        }
      } ?? []

    return TrustLookup(
      covering: covering?.selector, nearest: nearest, older: older, writable: state.writable,
      notice: state.notice, unreadable: state.unreadable)
  }

  nonisolated static func admit(
    _ request: ControllerBegin, token: AuditToken, settings: ControllerSettings
  ) -> Admission {
    if let refusal = settings.helper.refusal(forPeer: token) { return .refused(refusal) }

    let snapshot: ControllerSnapshot

    do {
      snapshot = try ControllerSnapshot.create(from: request.package, in: settings.runsRoot)
    } catch {
      return .refused("uniterm refused the controller: \(error)")
    }

    let descriptor = snapshot.controller.descriptor
    let wanted: ControllerEntryKind = request.entry == .janet ? .janet : .native

    guard descriptor.entryKind == wanted else {
      snapshot.remove()

      return .refused(
        wanted == .janet
          ? "This package's entry is native. Run it with uniterm controller run."
          : "This package's entry is Janet. Run it with uniterm run.")
    }

    if let undeclared = request.capabilities.first(where: { !descriptor.capabilities.contains($0) })
    {
      snapshot.remove()

      return .refused(
        "--allow \(undeclared) is not a capability the controller declares, so it cannot be "
          + "granted.")
    }

    let trust = lookUp(
      requested(descriptor, capabilities: request.capabilities),
      for: snapshot.controller.identity, versionOf: snapshot.controller.identity.controllerID,
      in: settings.trust)

    guard wanted == .native else {
      return .admitted(snapshot, entryHash: nil, entryPath: nil, trust: trust)
    }

    guard let entry = CodeIdentity.ofFile(at: snapshot.entryURL),
      let path = realpath(snapshot.entryURL.path)
    else {
      snapshot.remove()

      return .refused(
        "The native entry has no valid code signature, so uniterm cannot tell it runs.")
    }

    return .admitted(snapshot, entryHash: entry.codeDirectoryHash, entryPath: path, trust: trust)
  }

  private func finishController(
    _ connection: ScriptConnection, _ request: ControllerBegin, outcome: Admission,
    trustRevision: UInt64
  ) {
    controllerAdmissions.remove(connection.id)

    switch outcome {
    case .refused(let text):
      return refuseController(connection, text)

    case .admitted(let made, let hash, let path, let lookup):
      guard claimAfterFullCheck(connection) else {
        made.remove()
        onRefusal(.secondSession)

        return refuseController(connection, Self.secondSessionText)
      }

      proceed(
        WaitingAdmission(
          connection: connection, artifact: .package(made), entryHash: hash, entryPath: path,
          requested: Self.requested(
            made.controller.descriptor, capabilities: request.capabilities)),
        trust: lookup, trustRevision: trustRevision)
    }
  }

  /// Admits a verified run, refuses it, or puts it before the user. A package and a declared file
  /// reach this point alike, with their powers read and their remembered trust looked up.
  func proceed(_ waiting: WaitingAdmission, trust: TrustLookup, trustRevision: UInt64) {
    var trust = trust
    let connection = waiting.connection

    // The command may have exited, started another executable, or been revoked while the package
    // was read. Its run then never starts.
    guard admissionStillWanted(connection) else {
      waiting.artifact.remove()

      return refuseController(connection, "The program that asked for the run is gone.")
    }

    let identity = waiting.artifact.identity

    if waiting.requested.isEmpty {
      return admitRun(waiting, approval: .nothingRequested, standing: [])
    }

    if permissionRequests.isDenied(Self.startupKey(identity)) {
      waiting.artifact.remove()

      return refuseController(
        connection,
        "You denied this version of \(identity.controllerID). To be asked again, choose Ask "
          + "Again in Window > Pending Requests, then run it again.")
    }

    if let selector = trust.covering {
      guard !trustRemoved(since: trustRevision) else {
        // The policy that covered the run may be gone, so the user reviews the run instead.
        trust.covering = nil
        trust.nearest = nil
        trust.older = []

        return queueReview(waiting, trust: trust)
      }

      return admitRun(waiting, approval: .remembered(selector), standing: waiting.requested)
    }

    queueReview(waiting, trust: trust)
  }

  /// True when a removal of a remembered policy began or ended after `revision` was taken, or is
  /// under way now. What the policy file said before then may cover nothing any more.
  func trustRemoved(since revision: UInt64) -> Bool {
    trustRemovalsUnderWay > 0 || trustRemovals != revision
  }

  /// True while a connection that asked for a run may still be admitted.
  func admissionStillWanted(_ connection: ScriptConnection) -> Bool {
    !connection.isClosed && connection.peerGenerationHolds && !isRevoked(connection.id)
      && connection.peer.token != nil
  }

  /// Starts an admitted run: a Janet run at once, or a native launch that waits for its entry.
  func admitRun(
    _ waiting: WaitingAdmission, approval: ControllerApproval,
    standing: Set<ControllerPermission>
  ) {
    let connection = waiting.connection
    let artifact = waiting.artifact

    guard admissionStillWanted(connection), let token = connection.peer.token else {
      artifact.remove()

      return refuseController(connection, "The program that asked for the run is gone.")
    }

    let caller = caller(for: connection)

    switch artifact {
    case .package(let snapshot):
      let descriptor = snapshot.controller.descriptor

      if let hash = waiting.entryHash, let path = waiting.entryPath {
        startNativeLaunch(
          NativeLaunch(
            snapshot: snapshot, scopes: waiting.requested, approval: approval, standing: standing,
            started: connection.peerStartTime, launcherGeneration: token.pidVersion,
            entryHash: hash, entryPath: path, sourceRoot: connection.binding?.root,
            window: caller?.window, pane: caller?.pane, generation: nil,
            watch: watchNative(connection.peer.pid)),
          pid: connection.peer.pid)
      } else {
        controllerRuns[connection.id] = ControllerRun(
          identity: snapshot.controller.identity, name: descriptor.name,
          entryKind: descriptor.entryKind, entryPath: descriptor.entryPath,
          scopes: waiting.requested, approval: approval, standing: standing,
          pid: connection.peer.pid, generation: token.pidVersion, connection: connection.id,
          sourceRoot: connection.binding?.root, window: caller?.window, pane: caller?.pane,
          snapshot: snapshot.directory)
        controllerSnapshots[connection.id] = snapshot.directory
        sessions[connection.id, default: Session()].name = Self.label(for: descriptor.name)
      }

      connection.send(
        .controllerAdmitted(
          snapshot: snapshot.directory.path, version: descriptor.versionDigest))

    case .file(let file):
      controllerRuns[connection.id] = ControllerRun(
        identity: file.identity, name: file.name, entryKind: .janet,
        entryPath: file.snapshot.sourceName, scopes: waiting.requested, approval: approval,
        standing: standing, pid: connection.peer.pid, generation: token.pidVersion,
        connection: connection.id, sourceRoot: connection.binding?.root, window: caller?.window,
        pane: caller?.pane, snapshot: file.snapshot.directory)
      controllerSnapshots[connection.id] = file.snapshot.directory
      sessions[connection.id, default: Session()].name = Self.label(for: file.name)

      connection.send(
        .controllerAdmitted(snapshot: file.snapshot.file.path, version: file.snapshot.version))
    }

    controllersChanged()
  }

  /// Sends the refusal and closes the connection after it. The close is queued behind the refusal,
  /// so the connection is marked refused here. A request that is already on the wire is dropped
  /// until the close lands.
  func refuseController(_ connection: ScriptConnection, _ text: String) {
    if !connection.isClosed { sessions[connection.id, default: Session()].refused = true }

    connection.send(.controllerRefused(text))
    connection.closeAfterSending()
  }

  private func startNativeLaunch(_ launch: NativeLaunch, pid: pid_t) {
    if let earlier = nativeLaunches.removeValue(forKey: pid) { endNativeLaunch(earlier, pid: pid) }

    nativeLaunches[pid] = launch
    launch.watch.activate()
  }

  /// Watches a native controller's process. Its first exec is the command starting the entry.
  /// Any later one, or its exit, ends the run and removes the snapshot.
  private func watchNative(_ pid: pid_t) -> any DispatchSourceProcess {
    let watch = DispatchSource.makeProcessSource(
      identifier: pid, eventMask: [.exec, .exit], queue: .main)

    watch.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.nativeProcessChanged(pid) }
    }

    return watch
  }

  private func nativeProcessChanged(_ pid: pid_t) {
    guard let launch = nativeLaunches[pid] else { return }

    let running = ProcessInspection.isRunning(pid: pid, started: launch.started)

    if running, launch.generation == nil { return }

    // An exec notice can arrive after the entry's connection was bound. Its connections then
    // still hold their generation, and the notice is the one that started the entry.
    let connections = controllerRuns.values.filter { $0.pid == pid }.compactMap {
      listener.findConnection($0.connection)
    }

    if running, connections.contains(where: { $0.peerGenerationHolds }) { return }

    nativeLaunches[pid] = nil
    endNativeLaunch(launch, pid: pid)
  }

  func endNativeLaunch(_ launch: NativeLaunch, pid: pid_t) {
    launch.watch.cancel()

    for run in controllerRuns.values
    where run.pid == pid && run.snapshot == launch.snapshot.directory {
      controllerRuns[run.connection] = nil
      authorityEnded(run.connection)
    }

    launch.snapshot.remove()
  }

  /// Tells the bundled command running a plain script from any other program that begins a
  /// session.
  ///
  /// It runs on the main actor, before the connection's first call, so that call's question is
  /// already worded for the right kind. The command's file was validated once, and only the
  /// running code's dynamic signing information is read here. A native controller's process is
  /// never the command, so it skips the check. A missing setting or token leaves a generic peer.
  func plainPeerKind(of connection: ScriptConnection) -> SessionKind {
    guard let settings = controllerSettings, let token = connection.peer.token,
      nativeLaunches[connection.peer.pid] == nil,
      settings.helper.isRunningCommand(token)
    else { return .genericPeer }

    return .bundledRun
  }

  /// Binds a new connection to the native launch it comes from, when it does. A connection from
  /// the command itself, from another process at a reused ID, or from code that is not the
  /// snapshot's entry gets no run.
  ///
  /// It runs on the main actor, before the connection's first call, so that call already has its
  /// run. The code check asks only for the running code's dynamic signing information, and no
  /// check of the file on disk. The entry's hash was read off the main actor at admission.
  func adoptNativeRun(_ connection: ScriptConnection) {
    let pid = connection.peer.pid

    guard var launch = nativeLaunches[pid], let token = connection.peer.token,
      connection.peerStartTime == launch.started,
      token.pidVersion != launch.launcherGeneration,
      launch.generation == nil || launch.generation == token.pidVersion,
      let running = CodeIdentity.ofProcess(token: token, dynamicOnly: true),
      running.codeDirectoryHash == launch.entryHash,
      let path = running.path.flatMap(realpath), path == launch.entryPath,
      connection.peerGenerationHolds
    else { return }

    launch.generation = token.pidVersion
    nativeLaunches[pid] = launch

    let descriptor = launch.snapshot.controller.descriptor

    controllerRuns[connection.id] = ControllerRun(
      identity: launch.snapshot.controller.identity, name: descriptor.name,
      entryKind: .native, entryPath: descriptor.entryPath, scopes: launch.scopes,
      approval: launch.approval, standing: launch.standing, pid: pid,
      generation: token.pidVersion, connection: connection.id, sourceRoot: launch.sourceRoot,
      window: launch.window, pane: launch.pane, snapshot: launch.snapshot.directory)
    sessions[connection.id, default: Session()].name = Self.label(for: descriptor.name)
    sessions[connection.id, default: Session()].kind = .controllerRun
    controllersChanged()
  }

  /// Ends a connection's run when the connection goes, and removes a Janet run's snapshot. A
  /// native run's snapshot stays while its process runs from it.
  func controllerConnectionClosed(_ id: UInt64) {
    controllerAdmissions.remove(id)
    controllerRuns[id] = nil
    dropWaitingAdmission(id)
    dropPendingDeclaration(id)

    if let snapshot = controllerSnapshots.removeValue(forKey: id) {
      ControllerSnapshot.remove(directory: snapshot)
    }
  }

  /// Ends the runs of revoked connections, and refuses the runs still waiting for review. A Janet
  /// run's snapshot stays until its connection closes. Remembered policies are not touched: only
  /// the Controllers & Permissions window removes them.
  func controllerRunsRevoked(_ ids: Set<UInt64>) {
    for id in ids {
      controllerRuns[id] = nil
      dropWaitingAdmission(id, refusal: "You revoked this run before it started.")
      dropPendingDeclaration(id, refusal: "You revoked this program before it started.")
      dropUndeclared(id, refusal: "You revoked this run before it started.")
    }
  }

  /// Ends every run and removes every snapshot, as the host stops.
  func stopControllers() {
    for (pid, launch) in nativeLaunches { endNativeLaunch(launch, pid: pid) }

    nativeLaunches = [:]

    for snapshot in controllerSnapshots.values { ControllerSnapshot.remove(directory: snapshot) }

    controllerSnapshots = [:]
    controllerRuns = [:]
    controllerAdmissions = []

    for waiting in waitingAdmissions.values { waiting.artifact.remove() }

    waitingAdmissions = [:]

    for pending in pendingDeclarations.values {
      pending.deadline.cancel()
      pending.snapshot.remove()
    }

    pendingDeclarations = [:]
    controllerReviews = []
  }
}

private func realpath(_ path: String) -> String? {
  guard let resolved = Darwin.realpath(path, nil) else { return nil }

  defer { free(resolved) }

  return String(cString: resolved)
}
