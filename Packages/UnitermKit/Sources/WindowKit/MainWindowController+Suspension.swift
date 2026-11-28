import AppKit
import AppletKit
import ExecDriver
import PaneModel
import ProcessInspection
import ScriptHost

/// What a Suspend or Resume acts on. Each case reaches one controller process uniterm started.
enum SuspendTarget: Hashable {
  /// The REPL helper that runs in this pane.
  case repl(NodeID)

  /// The exec driver running in this pane.
  case driver(NodeID)

  /// The REPL helper behind this connection. A badge lists a helper by its connection.
  case connection(UInt64)
}

/// A controller uniterm started, as the window lists it for Suspend All and the slot's menu.
struct SpawnedController: Equatable {
  let target: SuspendTarget
  let name: String
  let suspension: SuspensionState
}

extension MainWindowController {
  /// The REPL helpers and exec drivers of this window, with what each process is doing. A REPL
  /// that has not attached, and a driver that has not finished its hellos, are not listed. They
  /// are still inside their declaration window, and a suspend would only make the listener drop
  /// them.
  func spawnedControllers() -> [SpawnedController] {
    var found: [SpawnedController] = []

    for pane in paneIDs {
      if let repl = paneArea.applet(for: pane) as? any ControllerSuspending,
        let state = repl.controllerSuspension
      {
        found.append(
          SpawnedController(target: .repl(pane), name: repl.controllerName, suspension: state))
      }

      if let attachment = execAttachments[pane], let channel = attachment.channel,
        channel.isConnected || channel.suspension.canResume
      {
        found.append(
          SpawnedController(
            target: .driver(pane), name: "\(attachment.program) (driver)",
            suspension: channel.suspension))
      }
    }

    return found
  }

  /// What the target's process is doing, or nil when it has none to suspend.
  func suspension(of target: SuspendTarget) -> SuspensionState? {
    switch target {
    case .repl(let pane):
      return (paneArea.applet(for: pane) as? any ControllerSuspending)?.controllerSuspension

    case .driver(let pane):
      // A driver that has not finished its hellos is still inside its declaration window. The
      // palette must not offer a suspend that would do nothing.
      guard let channel = execAttachments[pane]?.channel,
        channel.isConnected || channel.suspension.canResume
      else { return nil }

      return channel.suspension

    case .connection(let id):
      guard case .spawned(let state)? = controllerAuthority?.controllerProcessState(id) else {
        return nil
      }

      return state
    }
  }

  func suspend(_ target: SuspendTarget) {
    switch target {
    case .repl(let pane):
      (paneArea.applet(for: pane) as? any ControllerSuspending)?.suspendController()

    case .driver(let pane):
      execAttachments[pane]?.channel?.suspend()

    case .connection(let id):
      controllerAuthority?.suspendController(id)
    }
  }

  func resume(_ target: SuspendTarget) {
    switch target {
    case .repl(let pane):
      (paneArea.applet(for: pane) as? any ControllerSuspending)?.resumeController()

    case .driver(let pane):
      execAttachments[pane]?.channel?.resume()

    case .connection(let id):
      controllerAuthority?.resumeController(id)
    }
  }

  /// The targets a pane's Suspend and Resume reach: the controller that runs in the pane, and each
  /// one uniterm started that has authority over it. They are the same controllers the badge
  /// lists.
  func suspendTargets(of pane: NodeID) -> [SuspendTarget] {
    var targets: [SuspendTarget] = []

    if (paneArea.applet(for: pane) as? any ControllerSuspending)?.controllerSuspension != nil {
      targets.append(.repl(pane))
    }

    if suspension(of: .driver(pane)) != nil { targets.append(.driver(pane)) }

    for owner in controllers(of: pane).sorted() {
      switch owner.kind {
      case .connection:
        if case .spawned? = controllerAuthority?.controllerProcessState(owner.id) {
          targets.append(.connection(owner.id))
        }

      case .driver:
        if let attachment = execAttachments.values.first(where: { $0.owner == owner }),
          let driverPane = attachment.pane, suspension(of: .driver(driverPane)) != nil
        {
          targets.append(.driver(driverPane))
        }
      }
    }

    var seen = Set<SuspendTarget>()

    return targets.filter { seen.insert($0).inserted }
  }

  func canSuspendControllers(of pane: NodeID?) -> Bool {
    guard let pane, contains(pane: pane) else { return false }

    return suspendTargets(of: pane).contains { target in
      guard let state = suspension(of: target) else { return false }

      return !state.isSuspended
    }
  }

  func canResumeControllers(of pane: NodeID?) -> Bool {
    guard let pane, contains(pane: pane) else { return false }

    return suspendTargets(of: pane).contains { suspension(of: $0)?.canResume == true }
  }

  /// Suspends each controller the pane's badge lists that uniterm started and that runs now.
  func suspendControllers(of pane: NodeID?) {
    guard let pane, contains(pane: pane) else { return }

    for target in suspendTargets(of: pane) where suspension(of: target)?.isSuspended == false {
      suspend(target)
    }
  }

  /// Resumes each such controller that is stopped, uniterm's own stop or another's.
  func resumeControllers(of pane: NodeID?) {
    guard let pane, contains(pane: pane) else { return }

    for target in suspendTargets(of: pane) where suspension(of: target)?.canResume == true {
      resume(target)
    }
  }

  /// Suspends every controller of this window that runs. One that something outside uniterm
  /// stopped is left alone, so Resume All has no stop to take for uniterm's own.
  func suspendAllControllers() {
    for controller in spawnedControllers() where !controller.suspension.isSuspended {
      suspend(controller.target)
    }
  }

  /// Continues only what uniterm suspended.
  func resumeAllControllers() {
    for controller in spawnedControllers() where controller.suspension.madeByUniterm {
      resume(controller.target)
    }
  }

  /// The controllers of this window that uniterm has suspended now.
  func controllersSuspendedByUniterm() -> [SpawnedController] {
    spawnedControllers().filter { $0.suspension.isSuspendedByUniterm }
  }

  /// A change in a controller's state shows on its badge, its strip, and the window slot.
  func suspensionDidChange(of pane: NodeID? = nil) {
    if let pane { refreshExecStatus(of: pane) }

    refreshControlMarks()
  }

  /// What the badge lists for each controller that has authority over the pane, with how to
  /// suspend or resume it.
  func controllerLines(for pane: NodeID) -> [PaneControlMark.ControllerLine] {
    var lines: [PaneControlMark.ControllerLine] = []
    var seen = Set<SuspendTarget>()

    func add(_ name: String, _ target: SuspendTarget) {
      guard let state = suspension(of: target), seen.insert(target).inserted else { return }

      lines.append(
        PaneControlMark.ControllerLine(
          name: name, target: target, state: state.isSuspended ? .suspended : .running,
          canResume: state.canResume))
    }

    if let attachment = execAttachments[pane], attachment.channel != nil {
      add("\(attachment.program) (driver)", .driver(pane))
    }

    for owner in controllers(of: pane).sorted() {
      switch owner.kind {
      case .connection:
        guard let authority = controllerAuthority else { continue }

        let name = controllerName(owner)

        switch authority.controllerProcessState(owner.id) {
        case .spawned:
          add(name, .connection(owner.id))

        case .other(let stopped):
          if stopped {
            lines.append(
              PaneControlMark.ControllerLine(
                name: name, target: nil, state: .stoppedByShell, canResume: false))
          }
        }

      case .driver:
        if let attachment = execAttachments.values.first(where: { $0.owner == owner }),
          let driverPane = attachment.pane
        {
          add(controllerName(owner), .driver(driverPane))
        }
      }
    }

    return lines
  }

  /// The menu the window slot opens: each controller uniterm suspended with its Resume, and
  /// Resume All.
  func suspendedMenuEntries() -> [(title: String, target: SuspendTarget)] {
    controllersSuspendedByUniterm().map { ("Resume \($0.name)", $0.target) }
  }
}
