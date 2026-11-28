import AppKit
import AppletKit
import ControllerPackage
import ExecDriver
import PaneModel
import ScriptHost
import StatusKit

/// Asks the user for the values of a driver's environment keys before a run. Nil means the user
/// cancelled. The values live in memory for the pane's life and are never saved.
typealias ExecValuesAsker =
  @MainActor (_ keys: [String], _ program: String, _ window: NSWindow?) async -> [String: String]?

/// One pane's exec driver: what it declares, the values the user gave it, and where it stands.
///
/// The declaration is inert. Nothing runs until the user chooses Run in the pane, and a launch
/// then needs execution authority from the Pending Requests panel or a grant made there.
@MainActor
final class ExecAttachment {
  enum State {
    /// Not running. The note says why, and Run starts it.
    case idle(String)

    case waitingForValues
    case waitingForApproval

    case running(ExecDriverChannel)

    /// The driver stopped. The reason is shown, and Restart starts it again. Nothing restarts it
    /// by itself.
    case ended(String)
  }

  let declaration: ExecDeclaration
  var values: [String: String] = [:]
  var state: State

  /// Counts runs, so the end of an earlier run never changes a later one.
  var run: UInt64 = 0

  /// The owner the running driver's groups have. Each run gets its own, and loses it when it ends,
  /// so a later run never inherits an earlier run's groups.
  var owner: GroupOwner?

  /// True once the user revoked this run's control of other panes. It holds for the rest of the
  /// run, as a revoke holds for a connection, so the run lays out and commands nothing beyond its
  /// own pane again, layouts still in preparation included. A new run starts clear.
  var revoked = false

  /// The clipboard powers the user allowed for this run. A new run starts with none.
  var clipboardGrants: Set<ControllerPermission> = []

  /// The browser powers the user allowed for this run. A new run starts with none.
  var browserGrants: Set<ControllerPermission> = []

  /// The pane the attachment drives.
  let pane: NodeID?

  init(declaration: ExecDeclaration, note: String, pane: NodeID? = nil) {
    self.declaration = declaration
    self.pane = pane
    state = .idle(note)
  }

  var program: String { (declaration.executable as NSString).lastPathComponent }

  var isBusy: Bool {
    switch state {
    case .idle, .ended: return false
    case .waitingForValues, .waitingForApproval, .running: return true
    }
  }

  var channel: ExecDriverChannel? {
    if case .running(let channel) = state { return channel }

    return nil
  }
}

// MARK: Exec drivers

extension MainWindowController {
  /// Gives the pane an exec driver declaration. It runs nothing. The pane's applet must take
  /// commands and its type must support an exec driver. A declaration already there is replaced,
  /// and a driver it was running is stopped.
  func declareExecDriver(_ declaration: ExecDeclaration, for pane: NodeID, restored: Bool = false)
    throws
  {
    guard let applet = paneArea.applet(for: pane), contains(pane: pane) else {
      throw ExecPaneError.notOpen
    }

    guard applet is any AppletCommandHandling,
      supportedControl(of: pane).contains(where: { $0.driver == .exec })
    else { throw ExecPaneError.unsupported(applet.typeID) }

    execAttachments[pane]?.channel?.close()

    let note =
      restored
      ? "Restored. Nothing runs until you choose Run."
      : "Not running. Choose Run to start it."

    execAttachments[pane] = ExecAttachment(declaration: declaration, note: note, pane: pane)
    refreshExecStatus(of: pane)
    onLayoutChange?()
  }

  /// The user's Run or Restart. It is a local action only: no script call and no driver command
  /// reaches it. A driver that needs environment values asks for them first, then the launch
  /// needs execution authority.
  func runExecDriver(_ pane: NodeID) {
    guard let attachment = execAttachments[pane], !attachment.isBusy else { return }

    let combination = ControlCombination(access: control(of: pane).access, driver: .exec)

    guard supportedControl(of: pane).contains(combination) else {
      attachment.state = .idle(
        "This pane does not support an exec driver while it is \(combination.access.rawValue).")
      refreshExecStatus(of: pane)
      return
    }

    let missing = attachment.declaration.environmentKeys.filter { attachment.values[$0] == nil }

    guard missing.isEmpty else {
      attachment.state = .waitingForValues
      refreshExecStatus(of: pane)

      Task { @MainActor [weak self, weak attachment] in
        guard let self, let attachment else { return }

        let values = await execValuesAsker(
          attachment.declaration.environmentKeys, attachment.program, window)

        guard execAttachments[pane] === attachment, case .waitingForValues = attachment.state
        else { return }

        guard let values else {
          attachment.state = .idle("Not running. Choose Run to start it.")
          refreshExecStatus(of: pane)
          return
        }

        attachment.values = values
        attachment.state = .idle("Not running.")
        runExecDriver(pane)
      }

      return
    }

    let launch: ExecLaunch

    do {
      launch = try ExecLaunch(
        declaration: attachment.declaration, environment: attachment.values,
        home: execEnvironment?.home ?? NSHomeDirectory())
    } catch {
      attachment.state = .ended("The driver cannot run: \(error).")
      refreshExecStatus(of: pane)
      return
    }

    let target = ExecLaunchAuthority.Target(window: scriptWindowID, pane: pane)

    if launchAuthority.grant(covering: launch, in: target) != nil {
      start(launch, for: attachment, in: pane)
      return
    }

    attachment.state = .waitingForApproval
    refreshExecStatus(of: pane)

    guard let connection = owner(of: pane)?.connection, let controllerAuthority else {
      return askToLaunch(launch, for: attachment, in: pane)
    }

    Task { @MainActor [weak self, weak attachment] in
      let covered = await Self.covered(launch, by: connection, authority: controllerAuthority)

      guard let self, let attachment, execAttachments[pane] === attachment,
        case .waitingForApproval = attachment.state
      else { return }

      if let covered, owner(of: pane)?.connection == connection {
        start(covered, for: attachment, in: pane)
      } else {
        askToLaunch(launch, for: attachment, in: pane)
      }
    }
  }

  /// Puts a launch that nothing covers before the user in the Pending Requests panel.
  private func askToLaunch(_ launch: ExecLaunch, for attachment: ExecAttachment, in pane: NodeID) {
    let target = ExecLaunchAuthority.Target(window: scriptWindowID, pane: pane)
    let requested = launchAuthority.request(
      launch, in: target, paneTitle: paneArea.applet(for: pane)?.title ?? "Pane"
    ) { [weak self, weak attachment] decision in
      guard let self, let attachment, execAttachments[pane] === attachment,
        case .waitingForApproval = attachment.state
      else { return }

      switch decision {
      case .allowOnce, .allowInPane:
        start(launch, for: attachment, in: pane)

      case .deny:
        attachment.state = .idle("Not allowed. Choose Run to ask again.")
        refreshExecStatus(of: pane)
      }
    }

    if requested == nil {
      attachment.state = .idle("Too many launches wait for approval. Answer some, then try again.")
      refreshExecStatus(of: pane)
    }
  }

  /// The launch that the live controller run owning the pane's group may start without asking,
  /// under its own approval, or nil. A remembered policy reaches a pane only this way: through a
  /// live run that owns it now, never through a path or a saved pane.
  ///
  /// The launch comes back with its folder resolved, and the driver starts there. A link inside
  /// the approved folder then cannot lead the driver out of it, at the check or after it. The
  /// folder is resolved off the main actor, since the disk may be slow.
  private static func covered(
    _ launch: ExecLaunch, by connection: UInt64, authority: any ControllerAuthority
  ) async -> ExecLaunch? {
    let directory = launch.directory

    guard
      let folder = await Task.detached(operation: { HostLaunchScope.resolved(directory) }).value,
      let declaration = try? ExecDeclaration(
        arguments: launch.arguments, directory: folder,
        environmentKeys: launch.declaration.environmentKeys),
      let resolved = try? ExecLaunch(
        declaration: declaration, environment: launch.environment, home: folder),
      await authority.coversLaunch(
        connection: connection, executable: declaration.executable, directory: folder,
        environmentKeys: declaration.environmentKeys)
    else { return nil }

    return resolved
  }

  /// Starts exactly the launch that was approved. The applet learns of the driver before the
  /// driver can reach it, so its clipboard policy tightens first.
  private func start(_ launch: ExecLaunch, for attachment: ExecAttachment, in pane: NodeID) {
    guard let applet = paneArea.applet(for: pane) as? any AppletCommandHandling,
      let environment = execEnvironment
    else {
      attachment.state = .ended("The driver cannot run in this pane.")
      refreshExecStatus(of: pane)
      return
    }

    attachment.run += 1
    lastDriverOwner += 1

    let run = attachment.run
    let owner = GroupOwner(driver: lastDriverOwner)

    attachment.owner = owner
    attachment.revoked = false
    attachment.clipboardGrants = []
    attachment.browserGrants = []
    pushControl(paneControls.set(driver: .exec, for: pane), to: pane)

    let drives: @MainActor () -> Bool = { [weak self, weak attachment] in
      guard let self, let attachment else { return false }

      return execAttachments[pane] === attachment && attachment.run == run
        && contains(pane: pane)
    }

    let beyond: @MainActor () -> ScriptCallError? = { [weak self] in
      guard let self else { return .refused("the driver no longer drives this pane") }

      switch driverStanding(of: owner) {
      case .ended:
        return .refused("the driver no longer drives this pane")

      case .revoked:
        return .refused(
          "You revoked this driver's control of other panes. It keeps its own pane, and needs a "
            + "new run to act beyond it.")

      case nil:
        return nil
      }
    }

    let channel = ExecDriverChannel(
      launch: launch, environment: environment, applet: applet, dispatcher: dispatcher,
      authority: {
        drives() ? nil : AppletCommandError(.refused, "the driver no longer drives this pane")
      },
      producer: statusCenter.issueProducer(kind: .applet, name: "\(attachment.program) (driver)"),
      killGrace: execKillGrace,
      host: { [weak self] request, reply in
        guard let self else {
          return reply(.failure(AppletCommandError(.refused, "uniterm is quitting")))
        }

        switch request {
        case .clipboardRead, .clipboardWrite:
          return driverAskedClipboard(
            request, attachment: attachment, run: run, pane: pane, drives: drives, reply: reply)

        case .layout, .command:
          break
        }

        if let refusal = beyond() ?? driverRefusal(for: request, from: pane, as: owner) {
          return reply(.failure(Self.driverFailure(refusal)))
        }

        driverAsked(request, from: pane, as: owner, beyond: beyond, reply: reply)
      },
      onEnd: { [weak self, weak attachment] end in
        guard let self, let attachment else { return }

        driverEnded(end, attachment: attachment, run: run, pane: pane)
      })

    channel.onSuspensionChange = { [weak self, weak attachment] _ in
      guard let self, let attachment, execAttachments[pane] === attachment, attachment.run == run
      else { return }

      suspensionDidChange(of: pane)
    }

    attachment.state = .running(channel)

    do {
      try channel.start()
    } catch {
      attachment.state = .ended("The driver did not start: \(error).")
      attachment.owner = nil
      pushControl(paneControls.set(driver: .none, for: pane), to: pane)
      statusCenter.post(level: .warning, text: "The driver did not start: \(error).")
    }

    refreshExecStatus(of: pane)
    refreshControlMarks()
  }

  private func driverEnded(
    _ end: ExecDriverChannel.End, attachment: ExecAttachment, run: UInt64, pane: NodeID
  ) {
    guard execAttachments[pane] === attachment, attachment.run == run, contains(pane: pane) else {
      return
    }

    attachment.state = .ended(end.description)
    releaseDriverOwner(of: attachment)
    pushControl(paneControls.set(driver: .none, for: pane), to: pane)
    refreshExecStatus(of: pane)
    refreshControlMarks()
  }

  /// A run's groups lose their owner when the run ends, however it ends. Its clipboard questions
  /// and the clipboard powers it was allowed go with it.
  private func releaseDriverOwner(of attachment: ExecAttachment) {
    endDriverClipboard(of: attachment)

    guard let owner = attachment.owner else { return }

    attachment.owner = nil
    ownerEnded(owner)
  }

  /// Ends a driver run's clipboard questions and powers. A revoke does this too.
  func endDriverClipboard(of attachment: ExecAttachment) {
    attachment.clipboardGrants = []
    attachment.browserGrants = []

    guard let pane = attachment.pane else { return }

    permissionRequests.end(
      .driver(window: scriptWindowID, pane: pane.rawValue, run: attachment.run))
  }

  /// A pane left the window. Its driver's authority ends at once, since nothing names the
  /// attachment any more, and so does its authority over the groups it owns. The applet's own
  /// close shuts the child down.
  func execPaneClosed(_ pane: NodeID) {
    if let attachment = execAttachments.removeValue(forKey: pane) {
      releaseDriverOwner(of: attachment)
    }

    permissionRequests.end(.terminal(window: scriptWindowID, pane: pane.rawValue))
    permissionRequests.end(.paneScripts(window: scriptWindowID, pane: pane.rawValue))

    launchAuthority.paneClosed(ExecLaunchAuthority.Target(window: scriptWindowID, pane: pane))
    dispatcher.revalidatePending()
  }

  // MARK: What a driver asks of the window

  /// Answers a driver's layout request or its command to another pane. `beyond` says why the run
  /// may no longer act beyond its own pane, and is asked again at every authority check. It holds
  /// for every request. A layout also needs the driver's own pane remote-controlled. A command
  /// needs that only while the run owns no group, and then reaches only a remote-controlled
  /// member of a group this run owns. Its authority is checked again when it is delivered.
  private func driverAsked(
    _ request: ExecDriverChannel.HostRequest, from pane: NodeID, as owner: GroupOwner,
    beyond: @escaping @MainActor () -> ScriptCallError?, reply: @escaping ControlDispatcher.Reply
  ) {
    switch request {
    case .layout(let layout):
      let parsed: LayoutRequest

      do {
        parsed = try LayoutRequest.parse(layout, window: scriptWindowID, declarations: appletTypes)
      } catch {
        return reply(.failure(Self.driverFailure(error)))
      }

      let power = ControllerPermission.browserNavigation

      guard parsed.needsBrowserNavigation, let attachment = execAttachments[pane],
        !attachment.browserGrants.contains(power)
      else {
        return driverLayout(
          parsed, from: pane, as: owner, beyond: beyond, once: false, reply: reply)
      }

      let run = attachment.run

      askDriver(
        power: power,
        detail: "The driver \(attachment.program) asks to \(power.displayText.lowercased()).",
        attachment: attachment, run: run, pane: pane,
        drives: { [weak self, weak attachment] in
          guard let self, let attachment else { return false }

          return execAttachments[pane] === attachment && attachment.run == run
            && attachment.owner == owner
        },
        grant: { $0.browserGrants.insert(power) },
        proceed: { [weak self] once in
          self?.driverLayout(
            parsed, from: pane, as: owner, beyond: beyond, once: once, reply: reply)
        }, reply: reply)

    case .clipboardRead, .clipboardWrite:
      reply(.failure(AppletCommandError(.failed, "the clipboard is answered elsewhere")))

    case .command(let target, let submission):
      let member = NodeID(rawValue: target)

      let authority: ControlDispatcher.Authority = { [weak self] in
        guard let self else { return AppletCommandError(.refused, "uniterm is quitting") }

        if let refusal = beyond() ?? driverRefusal(for: request, from: pane, as: owner) {
          return Self.driverFailure(refusal)
        }

        switch driverMemberRefusal(member, as: owner) {
        case .notMember:
          return AppletCommandError(.notFound, "the pane is not open in that window")

        case .disconnected:
          return AppletCommandError(
            .refused, "The pane is disconnected. The user must enable remote control on it.")

        case nil:
          return nil
        }
      }

      guard authority() == nil, let applet = paneArea.applet(for: member) else {
        return reply(
          .failure(
            authority() ?? AppletCommandError(.notFound, "the pane is not open in that window")))
      }

      let generation = control(of: member).generation
      let grant = AppletCaller(grant: owner.description)

      let submit: @MainActor (_ once: Set<ControllerPermission>) -> Void = {
        [weak self, weak applet] once in
        guard let self, let applet else { return reply(.failure(Self.gone)) }

        dispatcher.submit(
          submission, to: applet,
          authority: { [weak self, weak applet] in
            if let refusal = authority() { return refusal }

            guard let self, let applet, paneArea.applet(for: member) === applet,
              control(of: member).generation == generation
            else {
              return AppletCommandError(
                .refused, "the pane's control changed after the command was sent")
            }

            return nil
          },
          caller: { [weak self] in
            let held = self?.execAttachments[pane]?.browserGrants ?? []

            return CommandCaller(
              identity: grant,
              permissions: WindowScripting.appletPermissions(held.union(once)))
          },
          reply: reply)
      }

      guard
        let needed = (applet as? any AppletCommandHandling)?.commandSchema
          .command(named: submission.name)?.permission,
        let attachment = execAttachments[pane]
      else { return submit([]) }

      let power = WindowScripting.controllerPermission(for: needed)

      guard !attachment.browserGrants.contains(power) else { return submit([]) }

      let run = attachment.run

      askDriver(
        power: power,
        detail: "The driver \(attachment.program) asks to \(power.displayText.lowercased()).",
        attachment: attachment, run: run, pane: pane,
        drives: { [weak self, weak attachment] in
          guard let self, let attachment else { return false }

          return execAttachments[pane] === attachment && attachment.run == run
            && attachment.owner == owner
        },
        grant: { $0.browserGrants.insert(power) },
        proceed: { once in submit(once ? [power] : []) }, reply: reply)
    }
  }

  private static let gone = AppletCommandError(.notFound, "the pane closed")

  /// Lays out a driver's request and answers with the panes it made. A layout that seeds a
  /// browser page needs browser navigation: the run holds it, or the user allowed it once for
  /// this request.
  private func driverLayout(
    _ parsed: LayoutRequest, from pane: NodeID, as owner: GroupOwner,
    beyond: @escaping @MainActor () -> ScriptCallError?, once: Bool,
    reply: @escaping ControlDispatcher.Reply
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        let panes = try await requestLayout(
          parsed, anchor: pane, owner: owner,
          authorize: { [self] in
            if let refusal = beyond() ?? sourceRefusal(pane, doing: "lay out other panes") {
              throw refusal
            }

            if parsed.needsBrowserNavigation, !once,
              execAttachments[pane]?.browserGrants.contains(.browserNavigation) != true
            {
              throw ScriptCallError.refused(LayoutRequest.navigationRefusal)
            }

            try checkPlacedPanes(of: parsed) { $0 == pane || owns($0, owner) }
          },
          directoryExists: directoryExists)

        reply(
          .success(
            .object([
              "window": .number(Double(scriptWindowID)),
              "panes": .array(panes.map { .number(Double($0.rawValue)) }),
            ])))
      } catch {
        reply(.failure(Self.driverFailure(error)))
      }
    }
  }

  /// Answers a driver's typed clipboard request. Reads and writes are separate powers. Each one
  /// asks the user in the Pending Requests panel unless the user allowed that power for this run.
  /// The grant is checked again at the clipboard itself: the run must still drive the pane, and
  /// a revoke ends the run's clipboard powers for the rest of the run.
  private func driverAskedClipboard(
    _ request: ExecDriverChannel.HostRequest, attachment: ExecAttachment, run: UInt64,
    pane: NodeID, drives: @escaping @MainActor () -> Bool,
    reply: @escaping ControlDispatcher.Reply
  ) {
    let power: ControllerPermission = request == .clipboardRead ? .clipboardRead : .clipboardWrite

    let allowed: @MainActor (Bool) -> Bool = { [weak attachment] once in
      guard let attachment else { return false }

      return drives() && !attachment.revoked
        && (once || attachment.clipboardGrants.contains(power))
    }

    let ended = AppletCommandError(.refused, "The permission for this request has ended.")

    let access: @MainActor (Bool) -> Void = { [weak self] once in
      guard let self, allowed(once) else { return reply(.failure(ended)) }

      guard let clipboard else {
        return reply(.failure(AppletCommandError(.refused, "uniterm has no clipboard to offer.")))
      }

      switch request {
      case .clipboardRead:
        // The read can wait on another app, so it runs off the main actor. The grant is checked
        // again before the text goes to the driver.
        Task { @MainActor in
          let text = await clipboard.readText()

          guard allowed(once) else { return reply(.failure(ended)) }

          guard let text else { return reply(.success(.object(["text": .null]))) }

          guard text.utf8.count <= ExecProtocol.maxClipboardBytes else {
            return reply(
              .failure(
                AppletCommandError(
                  .failed,
                  "The clipboard holds more than the \(ExecProtocol.maxClipboardBytes) bytes a "
                    + "driver may read.")))
          }

          reply(.success(.object(["text": .string(text)])))
        }

      case .clipboardWrite(let text):
        clipboard.writeText(text)
        reply(.success(.object([:])))

      case .layout, .command:
        reply(.failure(AppletCommandError(.failed, "not a clipboard request")))
      }
    }

    guard !attachment.revoked else {
      return reply(
        .failure(
          AppletCommandError(
            .refused, "You revoked this driver. It needs a new run to use the clipboard.")))
    }

    if attachment.clipboardGrants.contains(power) { return access(false) }

    var detail = "The driver \(attachment.program) asks to \(power.displayText.lowercased())."

    if case .clipboardWrite(let text) = request {
      detail += " It would write: \u{201C}\(StatusText.bounded(text, maximumBytes: 160))\u{201D}"
    }

    askDriver(
      power: power, detail: detail, attachment: attachment, run: run, pane: pane, drives: drives,
      grant: { $0.clipboardGrants.insert(power) }, proceed: access, reply: reply)
  }

  /// Asks the user about one power a driver wants, in the Pending Requests panel. Allow once lets
  /// `proceed` run for this request alone. Allow for This Run keeps the power through `grant`,
  /// and `proceed` then runs. Any other answer fails the request.
  private func askDriver(
    power: ControllerPermission, detail: String, attachment: ExecAttachment, run: UInt64,
    pane: NodeID, drives: @escaping @MainActor () -> Bool,
    grant: @escaping @MainActor (ExecAttachment) -> Void,
    proceed: @escaping @MainActor (_ once: Bool) -> Void,
    reply: @escaping ControlDispatcher.Reply
  ) {
    let detail =
      detail + " Allow for This Run lets this run do it again without asking, until it ends."

    let outcome = permissionRequests.ask(
      PermissionRequests.Key(
        requester: .driver(window: scriptWindowID, pane: pane.rawValue, run: run),
        power: power.kindName),
      subject: "\(attachment.program) (driver)", title: power.displayText, detail: detail,
      sessionTitle: "Allow for This Run"
    ) { [weak attachment] answer in
      switch answer {
      case .deny:
        reply(.failure(AppletCommandError(.refused, "You denied this request.")))

      case .withdrawn:
        reply(
          .failure(
            AppletCommandError(.refused, "The request ended before you answered it.")))

      case .allowOnce:
        proceed(true)

      case .allowForSession:
        if let attachment, drives(), !attachment.revoked { grant(attachment) }

        proceed(false)
      }
    }

    switch outcome {
    case .waiting:
      break

    case .denied:
      reply(
        .failure(
          AppletCommandError(
            .refused,
            "You denied this earlier. To be asked again, choose Ask Again in Window > Pending "
              + "Requests.")))

    case .busy:
      reply(.failure(AppletCommandError(.busy, "Too many of this driver's requests wait.")))
    }
  }

  /// Why a driver's pane keeps this request from running, once `beyond` allows it. A layout needs
  /// the driver's own pane remote-controlled. A command rests on the groups the run owns, so it
  /// needs that only while the run owns none.
  private func driverRefusal(
    for request: ExecDriverChannel.HostRequest, from pane: NodeID, as owner: GroupOwner
  ) -> ScriptCallError? {
    switch request {
    case .layout:
      return sourceRefusal(pane, doing: "lay out other panes")

    case .command:
      guard !paneArea.tree.groups.contains(where: { $0.owner == owner }) else { return nil }

      return sourceRefusal(pane, doing: "command other panes")

    case .clipboardRead, .clipboardWrite:
      return nil
    }
  }

  /// A driver lays out, or commands without a group, only while the user has its own pane
  /// remote-controlled.
  private func sourceRefusal(_ pane: NodeID, doing action: String) -> ScriptCallError? {
    guard contains(pane: pane) else { return .notFound("the driver's pane is closed") }

    guard control(of: pane).access == .remoteControlled else {
      return .refused(
        "This driver's pane is disconnected, so it cannot \(action). To allow it, choose Enable "
          + "Remote Control from the pane's control badge or the File menu.")
    }

    return nil
  }

  private func owns(_ pane: NodeID, _ owner: GroupOwner) -> Bool {
    isMember(pane, ofGroupOwnedBy: owner)
  }

  private static func driverFailure(_ error: any Error) -> AppletCommandError {
    guard let error = error as? ScriptCallError else {
      return AppletCommandError(.failed, "\(error)")
    }

    switch error.kind {
    case .badArgument: return AppletCommandError(.badArgument, error.text)
    case .notFound: return AppletCommandError(.notFound, error.text)
    case .unsupported: return AppletCommandError(.unsupportedApplet, error.text)
    case .refused: return AppletCommandError(.refused, error.text)
    case .busy: return AppletCommandError(.busy, error.text)
    case .failed, .replyLost, .ended: return AppletCommandError(.failed, error.text)
    }
  }

  /// What the pane's exec strip shows now.
  func execStatus(of pane: NodeID) -> PaneExecStatus? {
    guard let attachment = execAttachments[pane] else { return nil }

    let program = attachment.program

    switch attachment.state {
    case .idle(let note):
      return PaneExecStatus(text: "Driver \(program): \(note)", action: "Run")

    case .waitingForValues:
      return PaneExecStatus(text: "Driver \(program) needs its environment values.", action: nil)

    case .waitingForApproval:
      return PaneExecStatus(
        text: "Driver \(program) waits for approval in Window > Pending Requests.", action: nil)

    case .running(let channel):
      guard channel.suspension.isSuspended else {
        return PaneExecStatus(text: "Driver \(program) is running.", action: nil)
      }

      return PaneExecStatus(
        text: SuspensionWording.suspended("Driver \(program)"), action: "Resume",
        isSuspended: true)

    case .ended(let reason):
      return PaneExecStatus(text: "Driver \(program): \(reason)", action: "Restart")
    }
  }

  func refreshExecStatus(of pane: NodeID) {
    paneArea.paneView(for: pane)?.execStatus = execStatus(of: pane)
  }
}

/// Why a pane cannot take an exec driver.
enum ExecPaneError: Error, Equatable {
  case notOpen
  case unsupported(String)
}

/// Asks for the values of a driver's environment keys in a sheet. Each field is secure, since a
/// value is often a token.
@MainActor
enum ExecValuesSheet {
  static func present(keys: [String], program: String, window: NSWindow?) async -> [String: String]?
  {
    guard let window else { return nil }

    let alert = NSAlert()
    let stack = NSStackView()
    var fields: [(String, NSSecureTextField)] = []

    stack.orientation = .vertical
    stack.alignment = .leading

    for key in keys {
      let label = NSTextField(labelWithString: key)
      let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))

      field.setAccessibilityIdentifier("exec-value-\(key)")
      field.widthAnchor.constraint(equalToConstant: 260).isActive = true
      stack.addArrangedSubview(label)
      stack.addArrangedSubview(field)
      fields.append((key, field))
    }

    stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(keys.count) * 48)

    alert.messageText = "Values for \(program)"
    alert.informativeText =
      "The driver needs these environment variables. They are kept only while this pane is open, "
      + "and never saved."
    alert.accessoryView = stack
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")

    let response = await alert.beginSheetModal(for: window)

    guard response == .alertFirstButtonReturn else { return nil }

    return Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.stringValue) })
  }
}
