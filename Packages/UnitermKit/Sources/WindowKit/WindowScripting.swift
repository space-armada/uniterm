import AppKit
import AppletKit
import ControllerPackage
import Foundation
import PaneModel
import QuestionForm
import ScriptHost
import ScriptWire
import SourceAccess
import StatusKit

/// The window side of the host API. It answers a script's calls about windows, panes, and tabs
/// from the live windows of one `WindowSet`.
///
/// Every function runs on the main actor, starts nothing that waits, and checks each argument
/// before it touches a window. A reference is looked up by its IDs in this launch. An ID that is
/// not open names nothing, so it can never name a different window, pane, or tab.
///
/// Every target is checked against the caller's authority when the call runs. The rules are the
/// ones `ScriptWindowAPI` states.
@MainActor
public final class WindowScripting: ScriptWindowAPI {
  /// The applets a script may start, by the kind name it passes.
  nonisolated static let kinds: [(name: String, choice: AppletChoice)] = [
    ("terminal", .terminalShell),
    ("data-viewer", .dataViewer),
    ("map-viewer", .mapViewer(region: nil)),
    ("image-viewer", .imageViewer),
    ("text-viewer", .textViewer),
    ("browser", .browser),
  ]

  /// The longest title or directory reported for a pane, in UTF-8 bytes. Both come from programs.
  static let maxReportedBytes = 256

  /// What opens one path inside a scope. A test replaces it with one that blocks.
  public typealias ScopedOpener =
    @Sendable (String, ReadScope) -> Result<OpenedPath, ScopedOpenError>

  /// The most path walks one caller may have running at once. The walk opens a program-chosen path,
  /// which does not return on a dead network mount, and each stuck walk parks a thread. A walk past
  /// the bound is refused as any path outside the scope is, so the answer tells nothing.
  public static let defaultMaxWalksPerCaller = 4

  private let windows: WindowSet
  private let directoryExists: @Sendable (String) -> Bool
  private let scopedOpener: ScopedOpener
  private let maxWalksPerCaller: Int
  private var walksRunning: [UInt64: Int] = [:]

  /// `directoryExists` decides whether a directory a script names is a folder here. It defaults to
  /// a stat that follows links, and a test replaces it. It runs off the main actor, since a stat
  /// on a hung network mount does not return.
  public init(
    windows: WindowSet,
    directoryExists: @escaping @Sendable (String) -> Bool = WindowScripting.isDirectory,
    scopedOpener: @escaping ScopedOpener = { ScopedOpen.open(path: $0, in: $1) },
    maxWalksPerCaller: Int = WindowScripting.defaultMaxWalksPerCaller
  ) {
    self.windows = windows
    self.directoryExists = directoryExists
    self.scopedOpener = scopedOpener
    self.maxWalksPerCaller = maxWalksPerCaller
  }

  public nonisolated static func isDirectory(_ path: String) -> Bool {
    var info = stat()

    return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
  }

  // MARK: Forms

  public func openForm(
    _ spec: FormSpec, requester: FormRequester, caller: ScriptCaller,
    resolved: @escaping @MainActor (FormOutcome) -> Void
  ) throws {
    let controller = try window(of: caller)

    guard controller.paneActionsEnabled else { throw Self.waitingForAnAnswer }

    try controller.openForm(spec, requester: requester, asker: caller.pane, resolved: resolved)
  }

  public func discardForm(requester key: String, window: UInt64) {
    windows.controller(forScriptWindow: window)?.discardForm(requester: key)
  }

  public func endForms(requester key: String, window: UInt64) {
    windows.controller(forScriptWindow: window)?.endForm(requester: key)
  }

  // MARK: Lists

  /// The caller's own window, and nothing about any other. A caller whose pane is disconnected
  /// learns only its binding: the window, the pane, and the pane's control.
  public func listWindows(caller: ScriptCaller) throws -> ScriptValue {
    let controller = try window(of: caller)
    let access = controller.control(of: caller.pane).access

    var fields: [String: ScriptValue] = [
      "window": .integer(controller.scriptWindowID),
      "pane": .integer(caller.pane.rawValue),
      "control": .string(access.rawValue),
    ]

    if access == .remoteControlled {
      fields["title"] = .string(Self.reported(controller.window?.title ?? ""))
      fields["key"] = .bool(controller.window?.isKeyWindow == true)
    }

    return .array([.record(fields)])
  }

  public func listPanes(
    window: UInt64, caller: ScriptCaller, access: ReadAccess = .none
  ) throws
    -> ScriptValue
  {
    guard window == caller.window, let controller = windows.controller(forScriptWindow: window)
    else { return .null }

    try requireSomeAuthority(caller, in: controller)

    var panes: [ScriptValue] = []

    for pane in controller.paneIDs where isAuthorized(pane, for: caller, in: controller) {
      guard let applet = controller.paneArea.applet(for: pane) else { continue }

      let shown = access.mayShow(source: (applet as? any UserFileSourcing)?.userFileSource)

      var fields: [String: ScriptValue] = [
        "window": .integer(window),
        "pane": .integer(pane.rawValue),
        "applet": .string(applet.typeID),
        "control": .string(controller.control(of: pane).access.rawValue),
        "title": .string(shown ? Self.reported(applet.title) : ""),
        "focused": .bool(pane == controller.focusedPane),
        "tabs": .array(tabs(of: applet, pane: pane, in: controller, shown: shown)),
      ]

      if shown, let directory = applet.currentDirectory {
        fields["directory"] = .string(Self.reported(directory))
      }

      panes.append(.record(fields))
    }

    return .array(panes)
  }

  private func tabs(
    of applet: any Applet, pane: NodeID, in controller: MainWindowController, shown: Bool
  ) -> [ScriptValue] {
    let tabs = applet.publishedTabs

    return tabs.all.map { tab in
      .record([
        "window": .integer(controller.scriptWindowID),
        "pane": .integer(pane.rawValue),
        "tab": .integer(controller.scriptTabNumbers.number(for: tab.id, in: pane)),
        "title": .string(shown ? Self.reported(tab.title) : ""),
        "selected": .bool(tab.id == tabs.selected),
      ])
    }
  }

  // MARK: Opening

  /// The access is checked against the applet type before anything waits or opens. The target is
  /// resolved after the directory check, so a pane disconnected or a controller revoked meanwhile
  /// stops the call.
  public func openPane(
    kind: String, beside: ScriptTarget, axis: ScriptAxis?, directory: String?,
    access: ScriptPaneAccess, caller: ScriptCaller,
    stillAllowed: @MainActor () throws -> Void = {}
  ) async throws -> ScriptValue {
    guard let choice = Self.kinds.first(where: { $0.name == kind })?.choice else {
      let names = Self.kinds.map { ":\($0.name)" }.joined(separator: ", ")

      throw ScriptCallError.badArgument("the applet kind is not known. The kinds are \(names)")
    }

    let mode: PaneAccessMode = access == .remoteControlled ? .remoteControlled : .disconnected
    let combination = ControlCombination(access: mode, driver: .none)

    let declarations = try window(of: caller).appletTypes

    guard
      AppletTypeDeclaration.supportedControl(forType: kind, in: declarations).contains(combination)
    else {
      throw ScriptCallError.refused("a \(kind) pane does not support \(combination) control")
    }

    if let directory {
      guard choice != .browser else {
        throw ScriptCallError.badArgument("a browser has no directory")
      }

      try await checkDirectory(directory)
    }

    try stillAllowed()

    let (controller, pane, _) = try resolve(beside, for: caller)

    guard controller.paneActionsEnabled else { throw Self.waitingForAnAnswer }

    let requested: Axis? = axis.map { $0 == .row ? .row : .column }

    guard let split = controller.splitAxis(for: pane, requested: requested) else {
      throw ScriptCallError.refused("the pane has no room to split")
    }

    let start = directory ?? controller.directory(of: pane)

    guard
      let created = controller.openPane(
        choice, typeID: kind, axis: split, from: pane, directory: start,
        owner: GroupOwner(connection: caller.connection), access: mode)
    else { throw ScriptCallError.refused("the pane did not open. The status bar says why") }

    return .record([
      "window": .integer(controller.scriptWindowID),
      "pane": .integer(created.rawValue),
    ])
  }

  public func openTab(
    pane target: ScriptTarget, directory: String?, caller: ScriptCaller,
    stillAllowed: @MainActor () throws -> Void = {}
  ) async throws -> ScriptValue {
    if let directory { try await checkDirectory(directory) }

    try stillAllowed()

    let (controller, pane, applet) = try resolve(target, for: caller)

    guard controller.paneActionsEnabled else { throw Self.waitingForAnAnswer }

    guard let opener = applet as? any TabOpening else {
      throw ScriptCallError.refused("the pane's applet has no tabs to open")
    }

    guard opener.canOpenTab else {
      throw ScriptCallError.refused("the pane's applet cannot open another tab")
    }

    if let refusal = opener.programOpenRefusal { throw ScriptCallError.refused(refusal) }

    if directory != nil, !opener.tabsStartInDirectory {
      throw ScriptCallError.badArgument("the pane's tabs have no directory")
    }

    guard let tab = opener.openTab(startingIn: directory ?? applet.currentDirectory) else {
      throw ScriptCallError.refused("the tab did not open")
    }

    return .record([
      "window": .integer(controller.scriptWindowID),
      "pane": .integer(pane.rawValue),
      "tab": .integer(controller.scriptTabNumbers.number(for: tab, in: pane)),
    ])
  }

  /// True while the reference names an open window and pane, and tab when it has one. It checks no
  /// authority, since the host asks it only about panes it holds files for.
  public func isOpen(_ pane: ScriptPaneReference) -> Bool {
    (try? locate(pane)) != nil
  }

  // MARK: Sending

  public func prepareSend(to target: ScriptTarget, caller: ScriptCaller) throws
    -> ScriptPaneReference
  {
    let (controller, pane, _, _) = try sendTarget(target, caller: caller)

    var reference = ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)

    if case .pane(let named) = target { reference.tab = named.tab }

    return reference
  }

  public func send(to pane: ScriptPaneReference, file: URL, caller: ScriptCaller) throws
    -> ScriptValue
  {
    let (_, _, applet, target) = try sendTarget(.pane(pane), caller: caller)

    do {
      try target.replaceSource(
        withSent: file, startDirectory: applet.currentDirectory ?? NSHomeDirectory())
    } catch {
      throw ScriptCallError.failed(
        "the pane could not open the content: \(error.localizedDescription)")
    }

    return .null
  }

  /// The pane's applet and the way it takes content. An applet that owns its input is refused
  /// before anything else, even when it could also take a source.
  private func sendTarget(_ reference: ScriptTarget, caller: ScriptCaller) throws -> (
    MainWindowController, NodeID, any Applet, any SourceReplacing
  ) {
    let (controller, pane, applet) = try resolve(reference, for: caller)

    guard controller.paneActionsEnabled else { throw Self.waitingForAnAnswer }

    guard !(applet is any InputOwning) else {
      throw ScriptCallError.refused(
        "a program owns this pane's input, so content cannot be sent to it")
    }

    guard let target = applet as? any SourceReplacing else {
      throw ScriptCallError.refused("this pane's applet cannot show sent content")
    }

    return (controller, pane, applet, target)
  }

  // MARK: Applet commands

  /// Arguments that are not JSON are refused before anything else, since they say nothing about
  /// any pane. Then the caller's authority over the target is checked, and the window's shared
  /// dispatch checks the applet type, the schema version, the command, and its arguments.
  /// Delivery checks the caller's authority again, that the target still names the same pane and
  /// applet, and that the pane's control generation has not changed.
  ///
  /// An applet may answer later, with a pending reply. The call then waits without holding the
  /// main thread, and the same authority check runs before the reply reaches the script. The
  /// window fails the call when a revocation, the run's end, a disconnect, or the pane's close
  /// takes the authority away.
  public func sendCommand(
    to target: ScriptTarget, appletType: String, schemaVersion: ScriptSchemaVersion,
    command: String,
    arguments: String, caller: ScriptCaller,
    access: @escaping @MainActor () -> ReadAccess = { .none },
    powers: @escaping @MainActor () -> Set<ControllerPermission> = { [] },
    stillAllowed: @escaping @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    let parsed: JSONValue

    do {
      parsed = try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))
    } catch {
      throw ScriptCallError.badArgument("the arguments are not a JSON object")
    }

    let (controller, pane, applet) = try resolve(target, for: caller)

    // A disconnect followed by a new enable issues new generations, so work queued under the
    // first grant of control never runs under the second.
    let generation = controller.control(of: pane).generation

    let submission = AppletCommandSubmission(
      appletType: appletType,
      schemaVersion: AppletSchemaVersion(Int(schemaVersion.major), Int(schemaVersion.minor)),
      name: command, arguments: parsed)

    let paths = controller.dispatcher.pathArguments(of: submission, for: applet)
    let opened = await walk(paths, for: caller.connection, in: access())
    let grant = Self.grant(of: caller)
    let tab = Self.targetTab(of: target, in: controller)

    let result = await withCheckedContinuation { continuation in
      controller.dispatcher.submit(
        submission, to: applet,
        authority: { [weak self] in
          guard let self else { return AppletCommandError(.refused, "uniterm is quitting") }

          do {
            try stillAllowed()

            let (now, nowPane, nowApplet) = try resolve(target, for: caller)

            guard now === controller, nowPane == pane, nowApplet === applet else {
              return AppletCommandError(.notFound, "the pane is not open in that window")
            }

            guard controller.control(of: pane).generation == generation else {
              return AppletCommandError(
                .refused, "the pane's control changed after the command was sent")
            }

            return nil
          } catch let error as ScriptCallError {
            return AppletCommandError(error.kind == .notFound ? .notFound : .refused, error.text)
          } catch {
            return AppletCommandError(.refused, "\(error)")
          }
        },
        reads: CommandReads(opened: opened, access: access),
        caller: { CommandCaller(identity: grant, permissions: Self.appletPermissions(powers())) },
        tab: tab,
        reply: { continuation.resume(returning: $0) })
    }

    switch result {
    case .success(let value):
      return try Self.scriptValue(
        Self.referencingTab(in: value, pane: pane, controller: controller, applet: applet),
        depth: 0)

    case .failure(let error):
      throw ScriptCallError(Self.kind(of: error.code), error.message)
    }
  }

  // MARK: Layout requests

  /// Runs the window's layout request for a script. `MainWindowController.requestLayout` holds the
  /// staging and publication rules.
  ///
  /// The anchor and every placed pane must be ones the caller may address. Each authority check
  /// runs the host's `stillAllowed` and resolves them again. The group is the caller connection's,
  /// and the reply has one reference for each leaf of the layout, in order.
  public func requestLayout(
    anchor target: ScriptTarget, layout: String, caller: ScriptCaller,
    powers: @escaping @MainActor () -> Set<ControllerPermission> = { [] },
    stillAllowed: @escaping @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    let controller = try window(of: caller)
    let request = try LayoutRequest.parse(
      layout, window: caller.window, declarations: controller.appletTypes)
    let (_, anchor, _) = try resolve(target, for: caller)

    let panes = try await controller.requestLayout(
      request, anchor: anchor, owner: GroupOwner(connection: caller.connection),
      authorize: { [self] in
        try stillAllowed()

        if request.needsBrowserNavigation, !powers().contains(.browserNavigation) {
          throw ScriptCallError.refused(LayoutRequest.navigationRefusal)
        }

        let (now, nowAnchor, _) = try resolve(target, for: caller)

        guard now === controller, nowAnchor == anchor else { throw Self.outOfScope }

        try controller.checkPlacedPanes(of: request) { pane in
          pane == caller.pane || owns(pane, caller, in: controller)
        }
      },
      directoryExists: directoryExists)

    return .record([
      "window": .integer(controller.scriptWindowID),
      "panes": .array(
        panes.map {
          .record(["window": .integer(controller.scriptWindowID), "pane": .integer($0.rawValue)])
        }),
    ])
  }

  /// Opens the paths a command names for one connection, unless that connection already has its
  /// share of walks running. The slot is held until the walk returns, so a walk that never returns
  /// keeps its slot, and the connection cannot park more threads than the bound.
  private func walk(
    _ paths: [(name: String, path: String)], for connection: UInt64, in access: ReadAccess
  ) async -> [String: Result<OpenedPath, ScopedOpenError>] {
    guard !paths.isEmpty else { return [:] }

    guard walksRunning[connection, default: 0] < maxWalksPerCaller else {
      return Dictionary(uniqueKeysWithValues: paths.map { ($0.name, .failure(.unavailable)) })
    }

    walksRunning[connection, default: 0] += 1

    let opened = await Self.open(paths, in: access, using: scopedOpener)

    walksRunning[connection, default: 1] -= 1

    if walksRunning[connection] == 0 { walksRunning[connection] = nil }

    return opened
  }

  /// Opens each path a command names, inside `scope`, off the main actor. A caller with no scope
  /// opens nothing and touches no disk. Every path then fails the same way, whatever it names.
  @concurrent
  private nonisolated static func open(
    _ paths: [(name: String, path: String)], in access: ReadAccess, using opener: ScopedOpener
  ) async -> [String: Result<OpenedPath, ScopedOpenError>] {
    var opened: [String: Result<OpenedPath, ScopedOpenError>] = [:]

    for (name, path) in paths {
      guard let scope = access.scope else {
        opened[name] = .failure(access.isDeclaredButNotGranted ? .notGranted : .unavailable)
        continue
      }

      opened[name] = opener(path, scope)
    }

    return opened
  }

  private static func kind(of code: AppletCommandError.Code) -> ScriptFailureKind {
    switch code {
    case .unsupportedApplet, .unsupportedVersion: return .unsupported
    case .unknownCommand, .badArgument: return .badArgument
    case .refused, .permissionMissing, .notOwned: return .refused
    case .busy: return .busy
    case .notFound: return .notFound
    case .failed: return .failed
    }
  }

  /// The grant a connection's commands act under. Ownership an applet keeps for a caller keys on
  /// it. A group the connection owns carries the same description as its owner, so an applet told
  /// of the grant's end by owner finds the same value.
  static func grant(of caller: ScriptCaller) -> AppletCaller {
    AppletCaller(grant: GroupOwner(connection: caller.connection).description)
  }

  /// The browser powers among the permissions a caller holds, by the permission's name.
  static func appletPermissions(_ held: Set<ControllerPermission>) -> Set<AppletCommandPermission> {
    Set(held.compactMap { AppletCommandPermission(rawValue: $0.kindName) })
  }

  /// The controller permission that grants a command's power.
  static func controllerPermission(for power: AppletCommandPermission) -> ControllerPermission {
    switch power {
    case .browserNavigation: return .browserNavigation
    case .browserRead: return .browserRead
    }
  }

  /// The tab a target names, when it names one.
  private static func targetTab(of target: ScriptTarget, in controller: MainWindowController)
    -> AppletTabID?
  {
    guard case .pane(let reference) = target, let number = reference.tab else { return nil }

    return controller.scriptTabNumbers.tab(for: number)
  }

  /// A reply that names a tab by its applet-side ID becomes a full reference, since a script
  /// addresses a tab by its number in the window. Any other reply passes as it is.
  private static func referencingTab(
    in value: JSONValue, pane: NodeID, controller: MainWindowController, applet: any Applet
  ) -> JSONValue {
    guard case .object(var fields) = value, case .string(let text)? = fields["tab"],
      let id = AppletTabID(reply: text), applet.publishedTabs.contains(id)
    else { return value }

    fields["tab"] = .number(Double(controller.scriptTabNumbers.number(for: id, in: pane)))
    fields["window"] = .number(Double(controller.scriptWindowID))
    fields["pane"] = .number(Double(pane.rawValue))

    return .object(fields)
  }

  public func extraPower(for call: ScriptCall, caller: ScriptCaller) -> ControllerPermission? {
    switch call {
    case .sendCommand(let target, _, _, let command, _):
      guard let (_, _, applet) = try? resolve(target, for: caller),
        let handler = applet as? any AppletCommandHandling,
        let power = handler.commandSchema.command(named: command)?.permission
      else { return nil }

      return Self.controllerPermission(for: power)

    case .requestLayout(_, let layout):
      guard let controller = try? window(of: caller),
        let request = try? LayoutRequest.parse(
          layout, window: caller.window, declarations: controller.appletTypes),
        request.needsBrowserNavigation
      else { return nil }

      return .browserNavigation

    default:
      return nil
    }
  }

  /// An applet's reply as a script value. A whole number that a Janet number holds exactly stays
  /// an integer, and any other finite number is a double. The command has run by now, so a reply
  /// a script cannot hold is reported as a lost reply, never as a refusal.
  static func scriptValue(_ value: JSONValue, depth: Int) throws -> ScriptValue {
    guard depth <= ScriptValue.maxDepth else {
      throw ScriptCallError(
        .replyLost, "the command ran, but its reply nests too deeply for a script")
    }

    switch value {
    case .null: return .null
    case .bool(let flag): return .bool(flag)
    case .string(let text): return .string(text)

    case .number(let number):
      guard number.isFinite else {
        throw ScriptCallError(.replyLost, "the command ran, but its reply holds a bad number")
      }

      if number >= 0, number == number.rounded(), number <= Double(ScriptProtocol.maxID) {
        return .integer(UInt64(number))
      }

      return .number(number)

    case .array(let values):
      return .array(try values.map { try scriptValue($0, depth: depth + 1) })

    case .object(let fields):
      guard fields.count <= ScriptValue.maxRecordFields else {
        throw ScriptCallError(
          .replyLost, "the command ran, but its reply has too many fields for a script")
      }

      return .record(try fields.mapValues { try scriptValue($0, depth: depth + 1) })
    }
  }

  // MARK: Authority

  /// What a caller whose own pane is disconnected is told. It names the local action, so the user
  /// knows what to do, and opens nothing.
  static let disconnectedSource = ScriptCallError.refused(
    "This program's pane is disconnected, so it cannot control panes. To allow it, choose "
      + "Enable Remote Control from the pane's control badge or the File menu.")

  /// The answer for a pane the caller may not reach. It is the same as for a pane that is not
  /// open, so it tells the caller nothing about the pane.
  private static let outOfScope = ScriptCallError.notFound("the pane is not open in that window")

  private func window(of caller: ScriptCaller) throws -> MainWindowController {
    guard let controller = windows.controller(forScriptWindow: caller.window),
      controller.contains(pane: caller.pane)
    else { throw ScriptCallError.notFound("the window is not open") }

    return controller
  }

  /// True when the caller's own pane is remote-controlled.
  private func sourceEnabled(_ caller: ScriptCaller, in controller: MainWindowController) -> Bool {
    controller.control(of: caller.pane).access == .remoteControlled
  }

  /// True when the pane is a member of a group the caller owns. Nesting grants nothing: the group
  /// must hold the pane as its own member.
  private func owns(_ pane: NodeID, _ caller: ScriptCaller, in controller: MainWindowController)
    -> Bool
  {
    controller.isMember(pane, ofGroupOwnedBy: GroupOwner(connection: caller.connection))
  }

  /// The caller may address the pane: it is remote-controlled, and it is the caller's own pane or
  /// a member of a group the caller owns. Position in the tree grants nothing.
  private func isAuthorized(
    _ pane: NodeID, for caller: ScriptCaller, in controller: MainWindowController
  ) -> Bool {
    controller.connectionMayAddress(
      pane, from: caller.pane, as: GroupOwner(connection: caller.connection))
  }

  /// A caller whose pane is disconnected keeps the groups it already owns. With none, it may do
  /// nothing but learn its binding.
  private func requireSomeAuthority(_ caller: ScriptCaller, in controller: MainWindowController)
    throws
  {
    guard !sourceEnabled(caller, in: controller) else { return }

    let owner = GroupOwner(connection: caller.connection)

    guard controller.paneArea.tree.groups.contains(where: { $0.owner == owner }) else {
      throw Self.disconnectedSource
    }
  }

  /// Finds the window, pane, and applet a target names, and checks the caller may address it. A
  /// reference that names a tab must name one the pane's applet still lists.
  private func resolve(_ target: ScriptTarget, for caller: ScriptCaller) throws -> (
    MainWindowController, NodeID, any Applet
  ) {
    let controller = try window(of: caller)

    switch target {
    case .pane(let reference):
      guard reference.window == caller.window else {
        throw ScriptCallError.notFound("the window is not open")
      }

      let pane = NodeID(rawValue: reference.pane)

      guard isAuthorized(pane, for: caller, in: controller) else {
        try requireSomeAuthority(caller, in: controller)

        if controller.contains(pane: pane),
          pane == caller.pane || owns(pane, caller, in: controller)
        {
          throw ScriptCallError.refused(
            "The pane is disconnected. The user must enable remote control on it.")
        }

        throw Self.outOfScope
      }

      return try locate(reference)

    case .nearest(let kind):
      guard controller.appletTypes.contains(where: { $0.typeID == kind }) else {
        throw ScriptCallError.badArgument("the applet kind \(kind) is not known")
      }

      try requireSomeAuthority(caller, in: controller)

      guard let pane = nearest(kind, to: caller, in: controller),
        let applet = controller.paneArea.applet(for: pane)
      else {
        throw ScriptCallError.notFound(
          "no \(kind) pane that this program may control is open in its window")
      }

      return (controller, pane, applet)
    }
  }

  /// The nearest pane of the applet type among those the caller may address. Proximity counts only
  /// after that filter, so it never grants anything. The rank is edge distance from the caller's
  /// pane in the tree, with groups transparent, then reading order, then pane ID. It is resolved
  /// each time a call runs, and never opens a pane.
  func nearest(_ kind: String, to caller: ScriptCaller, in controller: MainWindowController)
    -> NodeID?
  {
    let order = controller.paneIDs
    let distances = controller.paneArea.tree.edgeDistances(from: caller.pane)

    let candidates = order.enumerated().filter { _, pane in
      controller.paneArea.applet(for: pane)?.typeID == kind
        && isAuthorized(pane, for: caller, in: controller)
    }

    return candidates.min { lhs, rhs in
      let left = (distances[lhs.element] ?? Int.max, lhs.offset, lhs.element.rawValue)
      let right = (distances[rhs.element] ?? Int.max, rhs.offset, rhs.element.rawValue)

      return left < right
    }?.element
  }

  // MARK: Arguments

  /// A directory a script names must be an absolute path to a folder that exists. The helper checks
  /// the same, but the app trusts nothing a helper sends.
  private func checkDirectory(_ directory: String) async throws {
    let bytes = Array(directory.utf8)

    guard !bytes.isEmpty, bytes.count <= ScriptProtocol.maxDirectoryBytes, !bytes.contains(0),
      bytes[0] == UInt8(ascii: "/")
    else { throw ScriptCallError.badArgument("the directory must be an absolute path") }

    guard await Self.exists(directory, by: directoryExists) else {
      throw ScriptCallError.badArgument("the directory does not exist")
    }
  }

  /// Runs off the main actor. Callers resolve the pane again afterwards, since it may have closed
  /// while the check ran.
  @concurrent
  private nonisolated static func exists(
    _ path: String, by check: @Sendable (String) -> Bool
  ) async -> Bool {
    check(path)
  }

  /// A sheet holds the window's attention, and a pane's source must not change under it.
  private static let waitingForAnAnswer = ScriptCallError.refused(
    "the window is waiting for an answer to a question")

  /// Finds the window, pane, and applet a reference names, with no check of authority. A
  /// reference that names a tab must name one the pane's applet still lists.
  private func locate(_ reference: ScriptPaneReference) throws -> (
    MainWindowController, NodeID, any Applet
  ) {
    guard let controller = windows.controller(forScriptWindow: reference.window) else {
      throw ScriptCallError.notFound("the window is not open")
    }

    let pane = NodeID(rawValue: reference.pane)

    guard let applet = controller.paneArea.applet(for: pane), controller.contains(pane: pane)
    else { throw ScriptCallError.notFound("the pane is not open in that window") }

    if let number = reference.tab {
      guard let tab = controller.scriptTabNumbers.tab(for: number),
        applet.publishedTabs.contains(tab)
      else { throw ScriptCallError.notFound("the tab is not open in that pane") }
    }

    return (controller, pane, applet)
  }

  /// Text from a program, cleaned and cut by the sanitizer the status bar uses.
  static func reported(_ text: String) -> String {
    StatusText.bounded(text, maximumBytes: maxReportedBytes)
  }
}
