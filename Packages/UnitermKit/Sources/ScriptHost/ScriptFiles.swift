import ControllerPackage
import ControllerTrust
import Darwin
import FileRouting
import Foundation
import ProcessInspection
import ScriptWire

/// A command process, told apart from another that reused its ID. The process ID version changes
/// when a process starts another executable, so the entry a command execs is a new key.
struct ProcessSessionKey: Hashable, Sendable {
  let pid: pid_t
  let started: Int
  let version: Int32
}

/// What a script file's copy and a declaration make together: the thing the user reviews and the
/// run is bound to.
struct FileRunArtifact: Sendable {
  let snapshot: DeclaredFileSnapshot
  let declaration: FileDeclaration
  let identity: ControllerIdentity

  /// The name the review shows: the declared name, else the file's name.
  let name: String

  /// What the file is a version of: its declared ID, or else its absolute path. A version
  /// approval stores it to find the file's older versions. It decides no coverage.
  let versionOf: String
}

/// What an admitted run was verified from. A package is the descriptor and its files. A script
/// file is its one copy and the declaration the command read from it.
enum RunArtifact: Sendable {
  case package(ControllerSnapshot)
  case file(FileRunArtifact)

  var identity: ControllerIdentity {
    switch self {
    case .package(let snapshot): return snapshot.controller.identity
    case .file(let file): return file.identity
    }
  }

  var name: String {
    switch self {
    case .package(let snapshot): return snapshot.controller.descriptor.name
    case .file(let file): return file.name
    }
  }

  /// What the artifact is a version of: a package's ID, or a file's declared ID or path.
  var versionOf: String {
    switch self {
    case .package(let snapshot): return snapshot.controller.identity.controllerID
    case .file(let file): return file.versionOf
    }
  }

  /// The run's private folder.
  var directory: URL {
    switch self {
    case .package(let snapshot): return snapshot.directory
    case .file(let file): return file.snapshot.directory
    }
  }

  func remove() {
    switch self {
    case .package(let snapshot): snapshot.remove()
    case .file(let file): file.snapshot.remove()
    }
  }
}

/// A declared file the app copied and is waiting to hear about. The deadline refuses a command
/// that never reports.
struct PendingDeclaration {
  let request: FileBegin
  let snapshot: DeclaredFileSnapshot
  let deadline: Task<Void, Never>
}

extension ScriptHost {
  static let secondSessionText =
    "This program already has a script or a REPL connected to uniterm, so it cannot begin "
    + "another."

  /// Records the process behind a connection as having begun a session. Returns false when it
  /// already has, or when the table is full of processes that still run.
  func claimProcessSession(_ connection: ScriptConnection) -> Bool {
    guard let token = connection.peer.token else { return false }

    let key = ProcessSessionKey(
      pid: connection.peer.pid, started: connection.peerStartTime, version: token.pidVersion)

    guard processSessions[key] == nil else { return false }

    if processSessions.count >= Self.maxProcessSessions {
      processSessions = processSessions.filter { processIsLive($0.key.pid, $0.key.started) }

      guard processSessions.count < Self.maxProcessSessions else { return false }
    }

    processSessions[key] = connection.id

    return true
  }

  /// Claims the process's place when it is the bundled command, and does nothing for any other
  /// program. The check is the cheap one the host runs on the main actor for a plain begin, and
  /// it runs before the admission starts, so a second begin from the command is refused even while
  /// the first still authenticates. A program that is not the command takes no place, so it cannot
  /// fill the table. The admission refuses it with the full check.
  ///
  /// The cheap check can fail for the command itself, when the command was replaced on disk under a
  /// running app. A peer it does not take for the command is marked, and claims its place once the
  /// admission's full check passes. The full check is what refuses a program that is not the
  /// command.
  func claimIfBundledCommand(_ connection: ScriptConnection) -> Bool {
    guard let settings = controllerSettings, let token = connection.peer.token else { return true }

    guard settings.helper.isRunningCommand(token) else {
      lateClaims.insert(connection.id)

      return true
    }

    return claimProcessSession(connection)
  }

  /// Claims the place of a begin that the cheap check did not take for the command, now that the
  /// full check has. Returns false when the process already has a session.
  func claimAfterFullCheck(_ connection: ScriptConnection) -> Bool {
    guard lateClaims.remove(connection.id) != nil else { return true }

    return claimProcessSession(connection)
  }

  func refuseSecondAttach(_ connection: ScriptConnection) {
    sessions[connection.id, default: Session()].refused = true

    connection.send(.attachRefused(Self.secondSessionText))
    connection.closeAfterSending()

    onRefusal(.secondSession)
  }

  // MARK: Admission

  /// Starts the admission of a declared file. The app authenticates the command, and only then
  /// reads the file. Nothing the connection sends is answered until the run is admitted.
  func beginFile(_ connection: ScriptConnection, _ request: FileBegin) {
    guard let settings = controllerSettings else {
      return refuseController(connection, "This uniterm does not run declared script files.")
    }

    guard let token = connection.peer.token else {
      return refuseController(connection, "uniterm cannot tell which program asked.")
    }

    guard request.path.hasPrefix("/") else {
      return refuseController(connection, "The script file must be named by an absolute path.")
    }

    controllerAdmissions.insert(connection.id)

    Task { @MainActor [weak self] in
      let outcome = await Task.detached {
        Self.snapshotFile(request, token: token, settings: settings)
      }.value

      self?.fileSnapshotted(connection, request, outcome: outcome)
    }
  }

  /// Reads the file off the main actor. The peer is authenticated first, so a program that is not
  /// the bundled command never has a file read or copied for it.
  nonisolated static func snapshotFile(
    _ request: FileBegin, token: AuditToken, settings: ControllerSettings
  ) -> Result<DeclaredFileSnapshot, FileRefusal> {
    if let refusal = settings.helper.refusal(forPeer: token) { return .failure(.init(refusal)) }

    do {
      return .success(
        try DeclaredFileSnapshot.create(from: request.path, in: settings.runsRoot))
    } catch {
      return .failure(.init("uniterm refused the script file: \(error)"))
    }
  }

  struct FileRefusal: Error, Sendable {
    let text: String

    init(_ text: String) {
      self.text = text
    }
  }

  private func fileSnapshotted(
    _ connection: ScriptConnection, _ request: FileBegin,
    outcome: Result<DeclaredFileSnapshot, FileRefusal>
  ) {
    let snapshot: DeclaredFileSnapshot

    switch outcome {
    case .failure(let refusal):
      controllerAdmissions.remove(connection.id)

      return refuseController(connection, refusal.text)

    case .success(let made):
      snapshot = made
    }

    guard admissionStillWanted(connection) else {
      controllerAdmissions.remove(connection.id)
      snapshot.remove()

      return refuseController(connection, "The program that asked for the run is gone.")
    }

    guard claimAfterFullCheck(connection) else {
      controllerAdmissions.remove(connection.id)
      snapshot.remove()
      onRefusal(.secondSession)

      return refuseController(connection, Self.secondSessionText)
    }

    let wait = fileDeclarationTimeout
    let deadline = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(wait))

      guard !Task.isCancelled else { return }

      self?.declarationTimedOut(connection.id)
    }

    pendingDeclarations[connection.id] = PendingDeclaration(
      request: request, snapshot: snapshot, deadline: deadline)
    connection.send(.fileAdmitted(snapshot: snapshot.file.path, version: snapshot.version))
  }

  private func declarationTimedOut(_ id: UInt64) {
    guard let connection = listener.findConnection(id), !connection.isClosed else {
      return dropPendingDeclaration(id)
    }

    dropPendingDeclaration(
      id, refusal: "The uniterm command did not report what the script file declares in time.")
  }

  /// Ends a file that waits for its declaration, and removes its copy.
  func dropPendingDeclaration(_ id: UInt64, refusal: String? = nil) {
    guard let pending = pendingDeclarations.removeValue(forKey: id) else { return }

    pending.deadline.cancel()
    pending.snapshot.remove()
    controllerAdmissions.remove(id)

    if let refusal, let connection = listener.findConnection(id), !connection.isClosed {
      refuseController(connection, refusal)
    }
  }

  /// Reads the declaration the command reported, with the strict reader, and goes on to trust and
  /// review. The command's claim is believed no further than that reading.
  func receiveDeclaration(_ connection: ScriptConnection, json: String) {
    guard let settings = controllerSettings,
      let pending = pendingDeclarations.removeValue(forKey: connection.id)
    else { return connection.close() }

    pending.deadline.cancel()

    let declaration: FileDeclaration

    do {
      declaration = try FileDeclaration.parse(json)
    } catch {
      controllerAdmissions.remove(connection.id)
      pending.snapshot.remove()

      return refuseController(connection, "uniterm refused the script file: \(error)")
    }

    if let undeclared = pending.request.capabilities.first(where: {
      !declaration.capabilities.contains($0)
    }) {
      controllerAdmissions.remove(connection.id)
      pending.snapshot.remove()

      return refuseController(
        connection,
        "--allow \(undeclared) is not a capability the file declares, so it cannot be granted.")
    }

    let snapshot = pending.snapshot

    if snapshot.signature != nil, declaration.id == nil {
      controllerAdmissions.remove(connection.id)
      snapshot.remove()

      return refuseController(
        connection,
        "uniterm refused the script file: it has a .sig beside it, so its (declare-permissions ...) "
          + "form must name an :id. A signature with no ID would match nothing it could be trusted "
          + "by.")
    }

    // A file name can hold any character, and the review prints the ID as it prints a validated
    // one, so the name is cleaned before it stands in for an ID.
    let title = Self.fileTitle(snapshot.sourceName)
    let identity = ControllerIdentity(
      controllerID: declaration.id ?? title, version: snapshot.versionHex,
      keyFingerprint: snapshot.signature?.keyFingerprint, artifact: .file)
    let artifact = FileRunArtifact(
      snapshot: snapshot, declaration: declaration, identity: identity,
      name: declaration.name ?? title, versionOf: declaration.id ?? pending.request.path)
    let requested = Self.requested(
      declaration.permissions, capabilities: pending.request.capabilities)
    let revision = trustRemovals
    let store = settings.trust
    let versionOf = artifact.versionOf

    Task { @MainActor [weak self] in
      let trust = await Task.detached {
        Self.lookUp(requested, for: identity, versionOf: versionOf, in: store)
      }.value

      self?.fileDeclared(
        connection, artifact: artifact, requested: requested, trust: trust,
        trustRevision: revision)
    }
  }

  private func fileDeclared(
    _ connection: ScriptConnection, artifact: FileRunArtifact, requested: Set<ControllerPermission>,
    trust: TrustLookup, trustRevision: UInt64
  ) {
    controllerAdmissions.remove(connection.id)

    proceed(
      WaitingAdmission(
        connection: connection, artifact: .file(artifact), entryHash: nil, entryPath: nil,
        requested: requested),
      trust: trust, trustRevision: trustRevision)
  }

  /// The longest cleaned file name, in bytes. It is a descriptor name's limit.
  static let maxTitleBytes = ControllerDescriptor.maxNameBytes

  /// A file's name as a review title: bounded like a descriptor name, since a file name can hold
  /// anything. A name that is too long keeps its start and its end, which holds the extension, and
  /// shows an ellipsis between, so a cut name reads as cut. A name that cannot pass the descriptor
  /// name rules is shown as "script file".
  static func fileTitle(_ fileName: String) -> String {
    var title = fileName.trimmingCharacters(in: .whitespaces)

    if title.utf8.count > maxTitleBytes {
      let ellipsis = "\u{2026}"
      let tailBytes = 24
      let scalars = Array(title.unicodeScalars)
      var tail = ""
      var head = ""

      for scalar in scalars.reversed() {
        let next = String(scalar) + tail

        guard next.utf8.count <= tailBytes else { break }

        tail = next
      }

      for scalar in scalars {
        let next = head + String(scalar)

        guard next.utf8.count + ellipsis.utf8.count + tail.utf8.count <= maxTitleBytes else {
          break
        }

        head = next
      }

      title = head + ellipsis + tail
    }

    return ControllerDescriptor.isValidName(title) ? title : "script file"
  }
}
