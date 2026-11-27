import ControllerPackage
import ControllerTrust
import Foundation
import ScriptWire
import SourceAccess
import StatusKit

/// A controller run that the app verified and that waits for the user's review of its powers. Its
/// snapshot is kept until the run is admitted or refused.
struct WaitingAdmission {
  let connection: ScriptConnection
  let artifact: RunArtifact
  let entryHash: Data?
  let entryPath: String?
  let requested: Set<ControllerPermission>
}

/// One startup review: the powers a controller version asks for, shown to the user once. Runs of
/// the same version that ask for the same powers share it.
public struct ControllerReview: Identifiable, Equatable, Sendable {
  public let id: UInt64

  /// The descriptor's display name, or a script file's declared name or file name. It proves
  /// nothing.
  public let name: String

  public let identity: ControllerIdentity

  /// Every requested power, sorted.
  public let requested: [ControllerPermission]

  /// The powers a remembered policy for this controller does not cover yet, when one exists. The
  /// review shows them as what is new.
  public let added: [ControllerPermission]

  /// The policy the request goes beyond, when one exists.
  public let revises: ControllerSelector?

  /// What the artifact is a version of: a package's ID, or a file's declared ID or absolute path.
  /// A version approval stores it, so a later version finds this one to offer to replace.
  public let versionOf: String

  /// The version approvals of the same thing at other versions. Trust This Version offers to
  /// replace them, which ends a live run of each.
  public let older: [ControllerPolicy]

  /// False when the policy file cannot take a new policy, so only Allow once and Allow for this
  /// session are offered.
  public let canRemember: Bool

  /// Why nothing can be remembered, or why the policy file grants nothing.
  public let notice: String?

  /// The connections waiting, oldest first, with each one's process ID.
  public internal(set) var waiting: [(connection: UInt64, pid: pid_t)]

  /// The read-scope directories the request names, with their links resolved, by the directory as
  /// written. The review fills it in off the main thread after it is queued, so the panel can name
  /// the protected places a link leads into. It is empty until then.
  public var resolvedReadDirectories: [String: String] = [:]

  public var isSigned: Bool { identity.keyFingerprint != nil }

  public init(
    id: UInt64, name: String, identity: ControllerIdentity, requested: [ControllerPermission],
    added: [ControllerPermission], revises: ControllerSelector?, canRemember: Bool,
    notice: String?, waiting: [(connection: UInt64, pid: pid_t)], versionOf: String? = nil,
    older: [ControllerPolicy] = []
  ) {
    self.id = id
    self.name = name
    self.identity = identity
    self.requested = requested
    self.added = added
    self.revises = revises
    self.versionOf = versionOf ?? identity.controllerID
    self.older = older
    self.canRemember = canRemember
    self.notice = notice
    self.waiting = waiting
  }

  public static func == (lhs: ControllerReview, rhs: ControllerReview) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.identity == rhs.identity
      && lhs.requested == rhs.requested && lhs.added == rhs.added
      && lhs.waiting.map(\.connection) == rhs.waiting.map(\.connection)
  }
}

/// The user's answer to a startup review.
public enum ControllerReviewChoice: Sendable, Equatable {
  /// The oldest waiting run starts. Each later use of a power asks on its own.
  case allowOnce

  /// The oldest waiting run gets every requested power for its session.
  case allowForSession

  /// Every run of this exact verified version gets the requested powers, now and later. The older
  /// version approvals of the same thing are replaced, which ends a live run of each.
  case trustVersion

  /// The same, and every older version approval of the same thing stays.
  case trustVersionKeepingOlder

  /// Every correctly signed version of this controller ID, under this key, gets them.
  case trustIdentity

  case deny
}

/// What came of a call's power check.
enum PowerCheck {
  case allowed
  case refused(ScriptResult)

  /// The power is declared and not standing, so the operation asks the user.
  case needsApproval(ControllerPermission)
}

// MARK: Startup review

extension ScriptHost {
  /// The key of a controller version's startup denial.
  static func startupKey(_ identity: ControllerIdentity) -> PermissionRequests.Key {
    PermissionRequests.Key(
      requester: .controllerVersion(
        controllerID: identity.controllerID, version: identity.version),
      power: "startup")
  }

  /// Puts a verified run before the user. A review of the same version and powers that already
  /// waits takes the run too, so a run started again joins the first question.
  func queueReview(_ waiting: WaitingAdmission, trust: TrustLookup) {
    let identity = waiting.artifact.identity
    let requested = waiting.requested.sorted()
    let peer = (waiting.connection.id, waiting.connection.peer.pid)

    waitingAdmissions[waiting.connection.id] = waiting

    if let index = controllerReviews.firstIndex(where: {
      $0.identity == identity && $0.requested == requested
    }) {
      controllerReviews[index].waiting.append(peer)
    } else {
      lastReviewID += 1
      controllerReviews.append(
        ControllerReview(
          id: lastReviewID, name: waiting.artifact.name,
          identity: identity, requested: requested,
          added: trust.nearest.map { $0.uncovered(waiting.requested) } ?? requested,
          revises: trust.nearest?.selector,
          canRemember: trust.writable && controllerSettings?.trust != nil,
          notice: trust.notice, waiting: [peer], versionOf: waiting.artifact.versionOf,
          older: trust.older))
      resolveReads(ofReview: lastReviewID, requested: requested)
    }

    waiting.connection.send(
      .controllerReviewing(
        "\(identity.controllerID) waits for your approval. Choose Window > Pending Requests in "
          + "uniterm to review what it asks for."))
    pendingChanged()
  }

  /// Resolves the links of a review's read-scope directories off the main thread, then lets the
  /// panel name the protected places a link leads into.
  private func resolveReads(ofReview id: UInt64, requested: [ControllerPermission]) {
    var directories: [String] = []

    for case .pathRead(let scope) in requested.map(\.kind) { directories += scope.directories }

    guard !directories.isEmpty, let scope = try? ReadScope(directories: Array(Set(directories)))
    else { return }

    Task { @MainActor [weak self] in
      let resolved = await Task.detached { scope.resolvedDirectories() }.value

      guard let self, let index = controllerReviews.firstIndex(where: { $0.id == id }) else {
        return
      }

      controllerReviews[index].resolvedReadDirectories = resolved
      pendingChanged()
    }
  }

  /// Answers a startup review. Allow once and Allow for this run admit the oldest waiting
  /// run alone. A trust choice saves the policy first, then admits every run the review holds,
  /// since the new policy covers each of them. Returns why nothing happened, for the user.
  @discardableResult
  public func decideReview(_ id: UInt64, _ choice: ControllerReviewChoice) async -> String? {
    guard let review = controllerReviews.first(where: { $0.id == id }) else {
      return "The review is no longer waiting."
    }

    switch choice {
    case .allowOnce, .allowForSession:
      guard let first = review.waiting.first else { return nil }

      removeFromReviews([first.connection])

      guard let waiting = waitingAdmissions.removeValue(forKey: first.connection) else {
        return nil
      }

      let standing =
        choice == .allowOnce
        ? waiting.requested.filter { $0.capabilityName != nil } : waiting.requested

      admitRun(waiting, approval: choice == .allowOnce ? .once : .session, standing: standing)

    case .trustVersion, .trustVersionKeepingOlder, .trustIdentity:
      let selector: ControllerSelector

      let isFile = review.identity.artifact == .file

      if choice == .trustIdentity {
        guard let fingerprint = review.identity.keyFingerprint else {
          return "This \(isFile ? "file" : "controller") is not signed, so only its version can "
            + "be trusted."
        }

        selector =
          isFile
          ? .fileIdentity(fileID: review.identity.controllerID, keyFingerprint: fingerprint)
          : .identity(controllerID: review.identity.controllerID, keyFingerprint: fingerprint)
      } else {
        selector =
          isFile
          ? .fileVersion(version: review.identity.version)
          : .version(controllerID: review.identity.controllerID, version: review.identity.version)
      }

      guard review.canRemember, let store = controllerSettings?.trust else {
        return review.notice ?? "uniterm cannot save the trust now."
      }

      let policy = ControllerPolicy(
        selector: selector, name: review.name, scopes: Set(review.requested),
        approved: ISO8601DateFormatter().string(from: Date()),
        versionOf: choice == .trustIdentity ? nil : review.versionOf)
      // Only the approvals the review named go. A review that named none replaces nothing, so a
      // version trusted after another one asked cannot remove what its own prompt never showed.
      let named =
        choice == .trustVersion && selector.kindName == "version"
        ? Set(review.older.map(\.selector)) : []
      let replacing = !named.isEmpty

      let revision = trustRemovals

      // A replacement is a revoke of each older version, so its removal counts as one while it is
      // saved, and a run that a replaced approval admitted ends.
      if replacing {
        trustRemovals += 1
        trustRemovalsUnderWay += 1
      }

      let outcome = await Task.detached { () -> (String?, [ControllerSelector]) in
        do {
          let change = try store.update { policies in
            Self.trusting(policy, replacing: named, in: policies)
          }

          return (nil, change.removedSelectors)
        } catch {
          return ("uniterm could not save the trust: \(error)", [])
        }
      }.value

      if replacing {
        trustRemovalsUnderWay -= 1
        trustRemovals += 1
      }

      if let saved = outcome.0 { return saved }

      for replaced in outcome.1 { endRuns(admittedBy: replaced) }

      // The review may have changed while the policy was saved. Only runs still in it start.
      guard let current = controllerReviews.first(where: { $0.id == id }) else { return nil }

      let connections = current.waiting.map(\.connection)

      removeFromReviews(connections)
      trustChanged()

      // A removal that overlapped the save may have taken the policy away again. The user still
      // approved these runs here, so they start for this run, under no policy.
      // The replacement's own two counts are not such a removal.
      let overlapped =
        trustRemovalsUnderWay > 0 || trustRemovals != revision + (replacing ? 2 : 0)
      let approval: ControllerApproval = overlapped ? .session : .remembered(selector)

      for connection in connections {
        guard let waiting = waitingAdmissions.removeValue(forKey: connection) else { continue }

        admitRun(waiting, approval: approval, standing: waiting.requested)
      }

    case .deny:
      let connections = review.waiting.map(\.connection)

      removeFromReviews(connections)
      permissionRequests.recordDenial(
        Self.startupKey(review.identity),
        subject: "\(review.name) (\(review.identity.controllerID))",
        title: "Start this version")

      for connection in connections {
        guard let waiting = waitingAdmissions.removeValue(forKey: connection) else { continue }

        let subject = waiting.artifact.identity.artifact == .file ? "script file" : "controller"

        waiting.artifact.remove()
        refuseController(
          waiting.connection,
          "You denied this \(subject). To be asked again, choose Ask Again in Window > Pending "
            + "Requests, then run it again.")
      }
    }

    return nil
  }

  /// Takes connections out of every review, and drops reviews left with none.
  private func removeFromReviews(_ connections: [UInt64]) {
    for index in controllerReviews.indices {
      controllerReviews[index].waiting.removeAll { connections.contains($0.connection) }
    }

    controllerReviews.removeAll { $0.waiting.isEmpty }
    pendingChanged()
  }

  /// Ends a run that waits for review: its connection closed, its peer changed, or the user
  /// revoked it. Its snapshot goes.
  func dropWaitingAdmission(_ id: UInt64, refusal: String? = nil) {
    guard let waiting = waitingAdmissions.removeValue(forKey: id) else { return }

    removeFromReviews([id])
    waiting.artifact.remove()

    if let refusal, !waiting.connection.isClosed { refuseController(waiting.connection, refusal) }
  }
}

// MARK: Remembered trust

extension ScriptHost {
  /// The policy file as it is now. It is read off the main actor.
  public func rememberedTrust() async -> ControllerTrustState {
    guard let store = controllerSettings?.trust else {
      return ControllerTrustState(
        policies: [], writable: false, notice: "This uniterm remembers no controller trust.")
    }

    return await Task.detached { store.read() }.value
  }

  /// The approvals after the user trusts `policy`. Every readable entry for its selector folds into
  /// one, so no readable scope is dropped, and the new approval names the thing it is a version of.
  /// The entries for `replacing`, the selectors the prompt named, go too. An entry added after the
  /// prompt was built, or one the prompt never named, stays. A named entry that is already gone is
  /// simply absent.
  nonisolated static func trusting(
    _ policy: ControllerPolicy, replacing: Set<ControllerSelector>, in policies: [ControllerPolicy]
  ) -> [ControllerPolicy] {
    let same = policies.filter { $0.selector == policy.selector }
    let scopes = same.reduce(into: Set<ControllerPermission>()) {
      $0 = PermissionContainment.merged($0, with: $1.scopes)
    }
    let kept = policies.filter { entry in
      entry.selector != policy.selector && !replacing.contains(entry.selector)
    }

    return kept + [
      ControllerPolicy(
        selector: policy.selector, name: policy.name,
        scopes: PermissionContainment.merged(scopes, with: policy.scopes),
        approved: policy.approved, versionOf: policy.versionOf)
    ]
  }

  /// Removes a remembered policy, then ends the authority of every live run it admitted, with the
  /// work those runs have waiting. Returns why it failed, for the user. A policy that cannot be
  /// removed leaves the runs as they were, so the window never shows a revoke that did not happen.
  /// Every entry for the selector that this build reads goes. An entry it cannot read stays.
  @discardableResult
  public func forgetPolicy(_ selector: ControllerSelector) async -> String? {
    guard let store = controllerSettings?.trust else {
      return "No trust is remembered."
    }

    trustRemovals += 1
    trustRemovalsUnderWay += 1

    defer {
      trustRemovalsUnderWay -= 1
      trustRemovals += 1
    }

    let failure = await Task.detached { () -> String? in
      do {
        try store.update { $0.filter { $0.selector != selector } }

        return nil
      } catch {
        return "uniterm could not remove the policy: \(error)"
      }
    }.value

    if let failure { return failure }

    endRuns(admittedBy: selector)
    trustChanged()

    return nil
  }

  /// Ends every live run a remembered approval admitted, with the work it has waiting.
  func endRuns(admittedBy selector: ControllerSelector) {
    let admitted = controllerRuns.values.filter { $0.approval == .remembered(selector) }

    revokeControllers(Set(admitted.map(\.connection)))

    for (pid, launch) in nativeLaunches where launch.approval == .remembered(selector) {
      nativeLaunches[pid] = nil
      endNativeLaunch(launch, pid: pid)
    }
  }

  /// True when a live controller run may have uniterm start this program in a pane of a group it
  /// owns, without asking. The run's own standing approval must hold a host launch that covers the
  /// executable, the directory, and every environment key. A run allowed once has none, so its
  /// launches ask one at a time.
  ///
  /// Both folders are compared with every link resolved, so a link inside the approved folder
  /// that leads out of it is not covered. A folder that does not exist is not covered. The links
  /// are resolved off the main actor, and the run is checked again once they are.
  public func coversLaunch(
    connection id: UInt64, executable: String, directory: String, environmentKeys: [String]
  ) async -> Bool {
    guard let run = liveRun(id) else { return false }

    let folders = run.standing.compactMap { permission -> String? in
      guard case .hostLaunch(let approved) = permission.kind else { return nil }

      return approved.directory
    }

    let resolved = await Task.detached { () -> (wanted: String?, approved: [String: String]) in
      var approved: [String: String] = [:]

      for folder in folders { approved[folder] = HostLaunchScope.resolved(folder) }

      return (HostLaunchScope.resolved(directory), approved)
    }.value

    // The run may have ended, or its standing changed, while the links were resolved.
    guard let current = liveRun(id), let folder = resolved.wanted,
      let scope = try? HostLaunchScope(
        executable: executable, directory: folder, environmentKeys: environmentKeys)
    else { return false }

    let standing = Set(
      current.standing.compactMap { permission -> ControllerPermission? in
        guard case .hostLaunch(let approved) = permission.kind else { return permission }

        guard let folder = resolved.approved[approved.directory],
          let scope = try? HostLaunchScope(
            executable: approved.executable, directory: folder,
            environmentKeys: approved.environmentKeys)
        else { return nil }

        return ControllerPermission(.hostLaunch(scope), edition: permission.edition)
      })

    return PermissionContainment.uncovered([.hostLaunch(scope)], by: standing).isEmpty
  }

  /// What a connection may read and be told. A live controller run holds the directories of the
  /// path-reading powers that stand for it. Anything else holds none, so it sees no user's file.
  /// An Allow once answer does not stand, so a run that wants to read starts under a choice that
  /// lasts for the run.
  func readAccess(for id: UInt64) -> ReadAccess {
    let sent = sentContentRoot

    guard let run = liveRun(id) else { return ReadAccess(scope: nil, controllerSentRoot: sent) }

    let scope = Self.readScope(of: run.standing)
    let declared = run.scopes.contains { permission in
      if case .pathRead = permission.kind { return true }

      return false
    }

    return ReadAccess(
      scope: scope, controllerSentRoot: sent, isDeclaredButNotGranted: scope == nil && declared,
      resolvedDirectories: resolvedReadDirectories)
  }

  /// Resolves the links in every read-scope directory a live run holds, off the main actor, and
  /// drops the resolutions no run needs. A reply that comes before the answer arrives compares the
  /// directories as written, which hides paths and never shows extra ones.
  func refreshReadResolutions() {
    let wanted = Set(
      controllerRuns.values.flatMap { Self.readScope(of: $0.standing)?.directories ?? [] })

    resolvedReadDirectories = resolvedReadDirectories.filter { wanted.contains($0.key) }
    resolvingReadDirectories.formIntersection(wanted)

    let missing = wanted.subtracting(resolvedReadDirectories.keys)
      .subtracting(resolvingReadDirectories)

    guard !missing.isEmpty else { return }

    resolvingReadDirectories.formUnion(missing)

    Task { [weak self] in
      let resolved = await Task.detached { ReadScope.resolve(missing) }.value

      guard let self else { return }

      for directory in missing where self.resolvingReadDirectories.contains(directory) {
        self.resolvedReadDirectories[directory] = resolved[directory] ?? directory
        self.resolvingReadDirectories.remove(directory)
      }
    }
  }

  /// The directories every path-reading power in `standing` covers together, or nil when none
  /// stands.
  static func readScope(of standing: Set<ControllerPermission>) -> ReadScope? {
    let scopes = standing.compactMap { permission -> ReadScope? in
      guard case .pathRead(let scope) = permission.kind else { return nil }

      return scope
    }

    guard let first = scopes.first else { return nil }

    return scopes.dropFirst().reduce(first) { $0.union($1) }
  }

  /// The run a connection is bound to, while its authority holds.
  private func liveRun(_ id: UInt64) -> ControllerRun? {
    guard let run = controllerRuns[id], !isRevoked(id),
      let connection = listener.findConnection(id), !connection.isClosed,
      connection.peerGenerationHolds, run.generation == connection.peer.token?.pidVersion
    else { return nil }

    return run
  }

  func trustChanged() {
    changes.notify()
  }

  func pendingChanged() {
    onPendingRequestsChanged?()
    onPendingRequestsActiveChanged?(hasPendingWork)
    changes.notify()
  }

  /// True while anything waits for the user: a program's pane request, a startup review, or a
  /// permission question.
  public var hasPendingWork: Bool {
    !allPendingRequests().isEmpty || !controllerReviews.isEmpty || !undeclaredReviews.isEmpty
      || permissionRequests.isWaiting
  }
}

// MARK: Powers at the call boundary

extension ScriptHost {
  /// The power a call uses, or nil for a call that needs none, such as posting status.
  static func power(for call: ScriptCall) -> ControllerPermission? {
    switch call.kind.power {
    case nil: return nil
    case .clipboardRead: return .clipboardRead
    case .clipboardWrite: return .clipboardWrite
    case .paneControl: return .paneControl
    case .askUser: return .askUser
    }
  }

  /// Checks a call's power against the live grant. `once` holds the powers an Allow once answer
  /// granted for this operation alone.
  ///
  /// A controller run may use only what it declared, and without asking only what stands. An
  /// ordinary script's pane calls follow the pane rules alone, and its clipboard calls need the
  /// user's answer each time, unless the user allowed them for the connection.
  func checkPower(
    _ call: ScriptCall, on connection: ScriptConnection, once: Set<ControllerPermission> = []
  ) -> PowerCheck {
    if controllerAdmissions.contains(connection.id) || waitingAdmissions[connection.id] != nil
      || waitingUndeclared[connection.id] != nil
    {
      let subject = sessions[connection.id]?.kind == .controllerRun ? "controller" : "script"

      return .refused(.failure(.refused, "uniterm has not admitted this \(subject) yet."))
    }

    let power = Self.power(for: call)

    guard let run = controllerRuns[connection.id] else {
      guard let power, power != .paneControl, power != .askUser else { return .allowed }

      if once.contains(power) || clipboardGrants[connection.id]?.contains(power) == true {
        return .allowed
      }

      return .needsApproval(power)
    }

    guard run.generation == connection.peer.token?.pidVersion, connection.peerGenerationHolds
    else {
      return .refused(.failure(.refused, "This controller run has ended."))
    }

    guard let power else { return .allowed }

    guard run.scopes.contains(power) else {
      let isFile = run.identity.artifact == .file
      let subject = isFile ? "script" : "controller"
      let place = isFile ? "its (declare-permissions ...) form" : "its controller.json"

      return .refused(
        .failure(
          .refused,
          "This \(subject) did not declare \(power.kindName) in \(place), so it "
            + "cannot \(Self.verb(for: power))."))
    }

    guard once.contains(power) || run.standing.contains(power) else { return .needsApproval(power) }

    return checkExtraPower(call, on: connection, run: run, once: once)
  }

  /// The power a command or layout needs beyond control of panes, such as a browser's. A power the
  /// run declared and does not yet hold is asked about, as pane control is. A power it never
  /// declared passes through, and the window refuses the call with a structured error, since the
  /// run holds nothing that names the power.
  private func checkExtraPower(
    _ call: ScriptCall, on connection: ScriptConnection, run: ControllerRun,
    once: Set<ControllerPermission>
  ) -> PowerCheck {
    guard let caller = caller(for: connection),
      let extra = windows?.extraPower(for: call, caller: caller), run.scopes.contains(extra)
    else { return .allowed }

    return once.contains(extra) || run.standing.contains(extra) ? .allowed : .needsApproval(extra)
  }

  /// The permissions a live run holds for a command or layout now: the ones that stand, and the
  /// ones the user allowed once for this call. A script that is not a controller run holds none.
  func heldPowers(
    for id: UInt64, once: Set<ControllerPermission>
  ) -> Set<ControllerPermission> {
    guard let run = liveRun(id) else { return [] }

    return run.standing.union(once.intersection(run.scopes))
  }

  /// Checks a call's powers and runs it, asks the user, or refuses it. Each answer of Allow once
  /// comes back here with the power added, so a call that needs two powers asks about each in
  /// turn and runs only when every one holds.
  func routeRequest(
    _ call: ScriptCall, id: UInt32, on connection: ScriptConnection,
    once: Set<ControllerPermission>
  ) {
    guard !connection.isClosed else { return }

    switch checkPower(call, on: connection, once: once) {
    case .allowed:
      dispatch(call, id: id, on: connection, once: once)

    case .refused(let result):
      connection.reply(id: id, result: result)

    case .needsApproval(let power):
      askForOperation(call, id: id, on: connection, power: power, once: once)
    }
  }

  private static func verb(for power: ControllerPermission) -> String {
    switch power.kind {
    case .paneControl: return "act on panes"
    case .askUser: return "ask you questions"
    case .clipboardRead: return "read the clipboard"
    default: return "replace the clipboard"
    }
  }

  /// Puts an operation that needs the user's answer in the Pending Requests panel. The call is
  /// answered when the user answers: Allow once runs this call alone, Allow for This Run or Allow
  /// for This Connection also keeps the power for the run or the connection, and Deny refuses it.
  func askForOperation(
    _ call: ScriptCall, id: UInt32, on connection: ScriptConnection, power: ControllerPermission,
    once: Set<ControllerPermission> = []
  ) {
    let key = PermissionRequests.Key(requester: .connection(connection.id), power: power.kindName)
    let run = controllerRuns[connection.id]
    let isRun = run != nil || sessions[connection.id]?.kind.lastsOneRun == true
    let subject = controllerName(connection.id) ?? "a script"

    var detail = "\(subject) asks to \(power.displayText.lowercased())."

    if case .writeClipboard(let text) = call {
      detail +=
        " It would write: \u{201C}\(StatusText.bounded(text, maximumBytes: 160))\u{201D}"
    }

    detail +=
      isRun
      ? " Allow for This Run lets this run do it again without asking, until it ends."
      : " Allow for This Connection lets this program do it again without asking, until it "
        + "disconnects."

    let outcome = permissionRequests.ask(
      key, deniedAs: denialKey(for: connection, run: run, power: power), subject: subject,
      pid: connection.peer.pid, title: power.displayText, detail: detail,
      sessionTitle: isRun ? "Allow for This Run" : "Allow for This Connection"
    ) { [weak self, weak connection] answer in
      guard let self, let connection else { return }

      switch answer {
      case .deny:
        connection.reply(id: id, result: .failure(.refused, "You denied this request."))

      case .withdrawn:
        connection.reply(
          id: id,
          result: .failure(
            .refused,
            "The request ended before you answered it, since this program lost the authority it "
              + "asked under."))

      case .allowOnce:
        routeRequest(call, id: id, on: connection, once: once.union([power]))

      case .allowForSession:
        grantStanding(power, to: connection.id)
        routeRequest(call, id: id, on: connection, once: once)
      }
    }

    switch outcome {
    case .waiting:
      pendingChanged()

    case .denied:
      connection.reply(
        id: id,
        result: .failure(
          .refused,
          "You denied this earlier. To be asked again, choose Ask Again in Window > Pending "
            + "Requests."))

    case .busy:
      connection.reply(
        id: id,
        result: .failure(
          .busy, "Too many of this program's requests wait for the user. Try again later."))
    }
  }

  /// What a denial of a connection's request is kept under, so that the program cannot ask
  /// again by reconnecting. A controller run's denial covers its verified version, as a denied
  /// startup review does. An ordinary script names nothing a reconnect could not, so its denial
  /// covers the scripts acting for its pane. Nil keeps the denial under the connection.
  private func denialKey(
    for connection: ScriptConnection, run: ControllerRun?, power: ControllerPermission
  ) -> PermissionRequests.Key? {
    if let run {
      return PermissionRequests.Key(
        requester: .controllerVersion(
          controllerID: run.identity.controllerID, version: run.identity.version),
        power: power.kindName)
    }

    guard let caller = caller(for: connection) else { return nil }

    return PermissionRequests.Key(
      requester: .paneScripts(window: caller.window, pane: caller.pane.rawValue),
      power: power.kindName)
  }

  /// Keeps a power the user allowed for the session.
  private func grantStanding(_ power: ControllerPermission, to id: UInt64) {
    if controllerRuns[id] != nil {
      controllerRuns[id]?.standing.insert(power)
      controllersChanged()
    } else if !(listener.findConnection(id)?.isClosed ?? true) {
      clipboardGrants[id, default: []].insert(power)
    }
  }

  /// Reads or writes the clipboard. This is the access boundary: the live grant is checked here,
  /// with nothing suspended before the clipboard is touched. A read waits off the main actor for
  /// the text, so the grant is checked again before any text goes to the program.
  func performClipboard(
    _ call: ScriptCall, on connection: ScriptConnection, once: Set<ControllerPermission>
  ) async -> ScriptResult {
    if let refusal = clipboardRefusal(call, on: connection, once: once) { return refusal }

    guard let clipboard else {
      return .failure(.refused, "uniterm has no clipboard to offer.")
    }

    switch call {
    case .readClipboard:
      let text = await clipboard.readText()

      if let refusal = clipboardRefusal(call, on: connection, once: once) { return refusal }

      guard let text else { return .ok(Data([0])) }

      let bytes = Data(text.utf8)

      guard bytes.count <= ScriptProtocol.maxClipboardBytes else {
        return .failure(
          .failed,
          "The clipboard holds \(bytes.count) bytes of text, more than the "
            + "\(ScriptProtocol.maxClipboardBytes) a script may read.")
      }

      return .ok(Data([1]) + bytes)

    case .writeClipboard(let text):
      clipboard.writeText(text)

      return .ok(Data())

    default:
      return .failure(.failed, "the call does not use the clipboard")
    }
  }

  /// Why a clipboard call may not touch the clipboard now, or nil when it may.
  private func clipboardRefusal(
    _ call: ScriptCall, on connection: ScriptConnection, once: Set<ControllerPermission>
  ) -> ScriptResult? {
    if connection.isClosed { return .failure(.refused, "The program has gone.") }

    if let refusal = authorize(connection) { return refusal }

    switch checkPower(call, on: connection, once: once) {
    case .allowed: return nil
    case .refused(let result): return result
    case .needsApproval: return .failure(.refused, "The permission for this request has ended.")
    }
  }
}
