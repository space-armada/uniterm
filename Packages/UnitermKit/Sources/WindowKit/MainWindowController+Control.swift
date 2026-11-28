import AppKit
import AppletKit
import LayoutKit
import PaneModel

// MARK: Pane control

extension MainWindowController {
  /// The pane's control as the window holds it.
  func control(of pane: NodeID) -> PaneControl {
    paneControls.control(of: pane)
  }

  /// The combinations the pane's applet type supports. A pane with no applet, or one whose type
  /// declares nothing, supports only disconnected access.
  func supportedControl(of pane: NodeID) -> Set<ControlCombination> {
    guard let applet = paneArea.applet(for: pane) else { return [.disconnected] }

    return AppletTypeDeclaration.supportedControl(forType: applet.typeID, in: appletTypes)
  }

  /// True when the user can enable remote control on the pane: it is disconnected now, and its
  /// applet type supports remote control with the driver the pane has now.
  func canEnableRemoteControl(_ pane: NodeID?) -> Bool {
    guard let pane, contains(pane: pane) else { return false }

    let control = control(of: pane)

    return control.access == .disconnected
      && supportedControl(of: pane).contains(
        ControlCombination(access: .remoteControlled, driver: control.driver))
  }

  func canDisconnect(_ pane: NodeID?) -> Bool {
    guard let pane, contains(pane: pane) else { return false }

    return control(of: pane).access == .remoteControlled
  }

  func canRevokeController(_ pane: NodeID?) -> Bool {
    guard let pane, contains(pane: pane) else { return false }

    return !controllers(of: pane).isEmpty
  }

  /// The controllers that have authority over the pane: the owners of the groups that hold it as
  /// a member or as their source, and the connections that act for it. An owner is a connection
  /// or a running driver. A driver running in the pane counts while its run holds a clipboard
  /// grant, so a driver that owns no group can still be revoked from its own pane.
  func controllers(of pane: NodeID) -> Set<GroupOwner> {
    var found = Set<GroupOwner>()

    for group in paneArea.tree.enclosingGroups(of: pane) {
      guard let owner = group.owner, group.members.contains(pane) || group.source == pane
      else { continue }

      found.insert(owner)
    }

    if let controllerAuthority {
      for id in controllerAuthority.controllers(actingFrom: scriptWindowID, pane: pane) {
        found.insert(GroupOwner(connection: id))
      }
    }

    if let attachment = execAttachments[pane], let owner = attachment.owner, !attachment.revoked,
      !attachment.clipboardGrants.isEmpty || !attachment.browserGrants.isEmpty
    {
      found.insert(owner)
    }

    return found
  }

  /// True when the pane is a member of a group `owner` owns. Nesting grants nothing: the group
  /// must hold the pane as its own member. A group's source is not a member.
  func isMember(_ pane: NodeID, ofGroupOwnedBy owner: GroupOwner) -> Bool {
    paneArea.tree.enclosingGroups(of: pane).contains {
      $0.owner == owner && $0.members.contains(pane)
    }
  }

  /// True when a command from a connection, acting from `callerPane`, is accepted on the pane now.
  /// The pane is remote-controlled, and it is the caller's own pane or a member of a group the
  /// connection owns. The command path and the authority marker both ask this.
  func connectionMayAddress(_ pane: NodeID, from callerPane: NodeID?, as owner: GroupOwner) -> Bool
  {
    guard control(of: pane).access == .remoteControlled else { return false }

    return pane == callerPane || isMember(pane, ofGroupOwnedBy: owner)
  }

  /// Why an exec driver's run may not act beyond its own pane, or nil when it may. The run must
  /// still drive its pane, and the user must not have revoked it.
  enum DriverStanding {
    case ended
    case revoked
  }

  func driverStanding(of owner: GroupOwner) -> DriverStanding? {
    guard
      let (home, attachment) = execAttachments.first(where: { $0.value.owner == owner }),
      contains(pane: home)
    else { return .ended }

    return attachment.revoked ? .revoked : nil
  }

  /// Why a driver's command to a pane is refused once its standing allows it, or nil when the pane
  /// takes it: a member of a group the run owns, and remote-controlled.
  enum DriverMemberRefusal {
    case notMember
    case disconnected
  }

  func driverMemberRefusal(_ pane: NodeID, as owner: GroupOwner) -> DriverMemberRefusal? {
    guard contains(pane: pane), isMember(pane, ofGroupOwnedBy: owner) else { return .notMember }

    return control(of: pane).access == .remoteControlled ? nil : .disconnected
  }

  /// True when a command from the exec driver owning `owner` is accepted on the pane now, beyond
  /// the driver's own pane. The command path asks the two steps itself, to word each refusal. The
  /// marker asks them through this.
  func driverMayAddress(_ pane: NodeID, as owner: GroupOwner) -> Bool {
    driverStanding(of: owner) == nil && driverMemberRefusal(pane, as: owner) == nil
  }

  /// Who can act on the pane's tabs now, for the applet to mark them by. Each granted owner is
  /// asked the command path's own questions, so the marker never states authority a command would
  /// refuse. The pane's access mode, a controller's pending request, and a window question never
  /// enter it. An applet that takes neither commands nor sent content gets no owners. A driver's
  /// own pane gets none for the driver, since it commands the pane through its attached channel.
  func paneAuthority(for pane: NodeID, applet placed: (any Applet)? = nil) -> PaneAuthority {
    guard control(of: pane).access == .remoteControlled,
      let applet = placed ?? paneArea.applet(for: pane), Self.takesCommandsOrContent(applet)
    else { return .none }

    var owners = Set<GroupOwner>()

    for group in paneArea.tree.enclosingGroups(of: pane) {
      guard let owner = group.owner, group.members.contains(pane) else { continue }

      switch owner.kind {
      case .connection:
        if connectionMayAddress(pane, from: nil, as: owner) { owners.insert(owner) }

      case .driver:
        if driverMayAddress(pane, as: owner) { owners.insert(owner) }
      }
    }

    if let controllerAuthority {
      for id in controllerAuthority.controllers(actingFrom: scriptWindowID, pane: pane) {
        let owner = GroupOwner(connection: id)

        if connectionMayAddress(pane, from: pane, as: owner) { owners.insert(owner) }
      }
    }

    return PaneAuthority(owners: Set(owners.map { AppletCaller(grant: $0.description) }))
  }

  /// True when the applet accepts a controller's command or content for its tab. It handles
  /// applet commands, or it replaces its source and does not own its input, the test `send` runs.
  static func takesCommandsOrContent(_ applet: any Applet) -> Bool {
    if applet is any AppletCommandHandling { return true }

    return applet is any SourceReplacing && !(applet is any InputOwning)
  }

  /// The live owner of the innermost group the pane is a member of, when there is one.
  func owner(of pane: NodeID) -> GroupOwner? {
    paneArea.tree.enclosingGroups(of: pane).last { $0.members.contains(pane) }?.owner
  }

  /// Lets programs the trust rules allow drive the pane. Only the user does this, and only on a
  /// pane whose applet type supports it.
  ///
  /// The applet takes its new control before the window records the mode, so its clipboard policy
  /// is in place before any call can reach the pane. Both happen on the main actor with nothing
  /// suspended between them.
  func enableRemoteControl(_ pane: NodeID?) {
    guard let pane, canEnableRemoteControl(pane), let applet = paneArea.applet(for: pane) else {
      return
    }

    var table = paneControls
    let control = table.set(.remoteControlled, for: pane)

    applet.controlDidChange(control)
    paneControls = table
    dispatcher.revalidatePending()

    refreshControlMarks()
    onLayoutChange?()
  }

  /// Refuses every other program's call to the pane from now on. A call that waits for the pane,
  /// or that the app has not read yet, checks again when it runs, so it is refused too. The
  /// pane's own outbound calls to panes its controller owns are not affected.
  func disconnect(_ pane: NodeID?) {
    guard let pane, contains(pane: pane) else { return }

    let control = paneControls.set(.disconnected, for: pane)

    pushControl(control, to: pane)
    refreshControlMarks()
    onLayoutChange?()
  }

  /// Ends the authority of every controller over the pane: its live grant, its calls still
  /// waiting, and the groups it owns, in every window. The groups and their panes stay, with no
  /// owner. The pane's own mode stays as it is.
  ///
  /// A driver that owns a group loses it, and its run is marked revoked. It keeps the channel the
  /// user attached to its own pane.
  func revokeController(_ pane: NodeID?) {
    guard let pane, contains(pane: pane) else { return }

    let owners = controllers(of: pane)

    guard !owners.isEmpty else { return }

    let connections = Set(owners.compactMap(\.connection))

    controllerAuthority?.revokeControllers(connections)

    for attachment in execAttachments.values {
      if let owner = attachment.owner, owners.contains(owner) {
        attachment.revoked = true
        endDriverClipboard(of: attachment)
      }
    }

    for owner in owners { ownerEnded(owner) }

    pushControl(paneControls.bump(pane), to: pane)
    refreshControlMarks()
  }

  /// A connection's authority ended. Its groups in this window lose their owner.
  func controllerEnded(_ id: UInt64) {
    ownerEnded(GroupOwner(connection: id))
  }

  /// An owner's authority ended. Its groups in this window lose their owner, and each pane that
  /// was a member gets a new generation, so a permission asked under the owner is stale. A launch
  /// that waits for approval in such a pane is withdrawn, since the controller that staged it no
  /// longer stands behind it.
  func ownerEnded(_ owner: GroupOwner) {
    let released = paneArea.releaseOwner(owner)
    let grant = AppletCaller(grant: owner.description)

    for pane in paneIDs {
      (paneArea.applet(for: pane) as? any CallerOwning)?.grantDidEnd(grant)
    }

    for pane in released where contains(pane: pane) {
      pushControl(paneControls.bump(pane), to: pane)
      launchAuthority.withdraw(
        target: ExecLaunchAuthority.Target(window: scriptWindowID, pane: pane))
    }

    dispatcher.revalidatePending()
    refreshControlMarks()
  }

  /// Hands the pane's applet its new control. Every change of an existing pane's control issues a
  /// new generation, so this is also where waiting replies are checked again. A path that changes
  /// control cannot forget to.
  ///
  /// Two kinds of path do not call it. `enableRemoteControl` must hand the applet its control
  /// before the window records the mode, so it checks waiting replies itself once the mode is
  /// recorded. A pane being created has no waiting reply yet, since no call can name a pane that
  /// is not in the tree, so those paths hand the applet its first control directly.
  func pushControl(_ control: PaneControl, to pane: NodeID) {
    paneArea.applet(for: pane)?.controlDidChange(control)
    dispatcher.revalidatePending()
  }

  func runControlAction(_ action: PaneControlAction, on pane: NodeID) {
    switch action {
    case .enable: enableRemoteControl(pane)
    case .disconnect: disconnect(pane)
    case .revoke: revokeController(pane)
    case .suspend(let target): suspend(target)
    case .resume(let target): resume(target)
    case .adopt(let owner): adoptGroup(of: pane, by: owner)
    }
  }

  /// What a saved layout keeps of the pane's control: the mode it has now, or the intent it was
  /// restored with while the user has left it disconnected, and its exec declaration with no
  /// environment value.
  func savedControl(of pane: NodeID) -> SavedPaneControl {
    let control = control(of: pane)
    let access =
      control.access == .disconnected
      ? paneControls.intent(of: pane)?.access ?? .disconnected : control.access

    return SavedPaneControl(
      access: access, driver: .none, exec: execAttachments[pane]?.declaration)
  }

  private func savedIntent(of pane: NodeID) -> PaneAccessMode? {
    guard let access = paneControls.intent(of: pane)?.access, access != .disconnected else {
      return nil
    }

    return access
  }

  /// Tells every pane's badge what to show.
  func refreshControlMarks() {
    for pane in paneArea.tree.paneIDs {
      paneArea.paneView(for: pane)?.controlMark = controlMark(for: pane)
      paneArea.paneView(for: pane)?.askingMark = askingMark(for: pane)
      paneArea.applet(for: pane)?.authorityDidChange(paneAuthority(for: pane))
    }

    onSuspensionChange?()
  }

  /// The badge's mark for a pane, from the control table, the tree, and the live controllers.
  func controlMark(for pane: NodeID) -> PaneControlMark {
    let control = control(of: pane)
    let memberships = paneArea.tree.enclosingGroups(of: pane).filter { $0.members.contains(pane) }
    let owner = memberships.last?.owner

    var mark = PaneControlMark(
      access: control.access, driver: control.driver,
      owner: owner.map(controllerName),
      inUnownedGroup: !memberships.isEmpty && owner == nil,
      savedIntent: control.access == .disconnected ? savedIntent(of: pane) : nil,
      enableAvailable: canEnableRemoteControl(pane), revokeAvailable: canRevokeController(pane))

    mark.controllers = controllers(of: pane).sorted().map(controllerName)
    mark.controllerLines = controllerLines(for: pane)

    if unownedGroup(of: pane) != nil {
      mark.adoptions = adoptionCandidates().map {
        PaneControlMark.Adoption(owner: $0, name: controllerName($0))
      }
    }

    return mark
  }

  /// What pane chrome calls an owner: a connection's script and PID, or a driver's program.
  func controllerName(_ owner: GroupOwner) -> String {
    switch owner.kind {
    case .connection:
      return controllerAuthority?.controllerName(owner.id) ?? "\(owner)"

    case .driver:
      let attachment = execAttachments.values.first { $0.owner == owner }

      return attachment.map { "\($0.program) (driver)" } ?? "\(owner)"
    }
  }
}
