import AppletKit
import PaneModel

/// What only the app can do. The app delegate supplies these, since a window has no way to open
/// another one or to show the Settings window.
public struct AppCommandHooks {
  public var newWindow: @MainActor () -> Void
  public var showSettings: @MainActor () -> Void

  /// Asks where to put the `uniterm` command, then links it into the app bundle.
  public var installCommandLineTool: @MainActor () -> Void

  /// Shows the open panel and routes the chosen files. The anchor is the focused pane of the window
  /// whose menu ran the command, and nil when no window is open.
  public var openFile: @MainActor (RouteAnchor?) -> Void

  /// Shows the open panel for one file, then the Open With chooser for it.
  public var openFileWith: @MainActor (RouteAnchor?) -> Void

  /// False while a quit waits for its answer, so a second request does not cancel the question.
  public var canQuit: @MainActor () -> Bool

  /// Tells the user something about the app's commands, such as a key an applet could not have.
  public var warn: @MainActor (String) -> Void

  public init(
    newWindow: @escaping @MainActor () -> Void = {},
    showSettings: @escaping @MainActor () -> Void = {},
    installCommandLineTool: @escaping @MainActor () -> Void = {},
    openFile: @escaping @MainActor (RouteAnchor?) -> Void = { _ in },
    openFileWith: @escaping @MainActor (RouteAnchor?) -> Void = { _ in },
    canQuit: @escaping @MainActor () -> Bool = { true },
    warn: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.newWindow = newWindow
    self.showSettings = showSettings
    self.installCommandLineTool = installCommandLineTool
    self.openFile = openFile
    self.openFileWith = openFileWith
    self.canQuit = canQuit
    self.warn = warn
  }
}

/// Every command uniterm runs, shared by its key bindings, its menus, and the palette.
///
/// One registry serves the whole app, so command recency is one list for the app. Recency lives in
/// memory only. A relaunch starts with none.
@MainActor
public final class CommandRegistry {
  /// How many recently run commands the registry remembers.
  static let recencyDepth = 8

  private(set) var commands: [Command]
  private var index: [CommandID: Int] = [:]
  private let hooks: AppCommandHooks

  /// The applet types that registered commands, in registration order.
  private(set) var appletSets: [AppletCommandSet] = []

  /// The menu built from this registry, once the app installs it.
  weak var menu: CommandMenu?

  /// The drops already announced this session, so a repeat of one is silent.
  private var announced = Set<AnnouncedDrop>()

  private struct AnnouncedDrop: Hashable {
    let command: CommandID
    let key: KeyChord
  }

  /// The key each applet command holds now. A command that lost its key, or never asked for one,
  /// has no entry.
  private(set) var appletKeys: [CommandID: KeyChord] = [:]

  /// The IDs of recently run commands, newest first.
  private(set) var recency: [CommandID] = []

  public init(app: AppCommandHooks = AppCommandHooks()) {
    hooks = app
    commands = []

    add(StandardCommands.make(app: app))
  }

  private func add(_ new: [Command]) {
    for command in new {
      precondition(index[command.id] == nil, "the command \(command.id) is registered twice")
      index[command.id] = commands.count
      commands.append(command)
    }
  }

  /// The ID of an applet type's command.
  public static func commandID(typeID: String, name: String) -> CommandID {
    CommandID("\(typeID).\(name)")
  }

  /// Adds an applet type's commands. Each is owned by the type, and its ID is namespaced by it.
  /// The command acts on the applet of its type in the pane it was aimed at. It holds no applet.
  /// Register every applet type before the menu is built.
  public func register(_ set: AppletCommandSet) {
    precondition(
      !appletSets.contains { $0.typeID == set.typeID } && set.typeID != Self.windowOwner,
      "the applet type \(set.typeID) registered its commands twice")

    appletSets.append(set)

    let typeID = set.typeID

    add(
      set.commands.map { spec in
        Command(
          Self.commandID(typeID: typeID, name: spec.name), spec.title, scope: .pane,
          owner: .applet(typeID: typeID), key: spec.key,
          menu: MenuPlacement(spec.home.menuHome, section: spec.section),
          listedInPalette: spec.listedInPalette,
          isAvailable: { context in
            guard context.actionsEnabled, let applet = context.applet(ofType: typeID) else {
              return false
            }

            return spec.isAvailable(applet)
          },
          run: { context in
            guard let applet = context.applet(ofType: typeID) else { return }

            spec.run(applet)
          })
      })
  }

  static let windowOwner = "uniterm"

  /// The registered applet type that owns a command, nil for a uniterm command.
  func appletSet(owning id: CommandID) -> AppletCommandSet? {
    guard case .applet(let typeID) = command(id)?.owner else { return nil }

    return appletSets.first { $0.typeID == typeID }
  }

  /// Settles which applet command holds which key, given the keys uniterm reserves. Keys that
  /// are dropped are returned. Each pass posts at most one warning, and it names every applet that
  /// lost a key and only the drops not announced before this session. One message covers all of
  /// them, since the status bar shows the newest message and a second one would hide the first.
  @discardableResult
  func resolveKeys(reserved: Set<KeyChord>) -> [KeyConflict] {
    let resolution = KeyReservations.resolve(sets: appletSets, reserved: reserved)
    appletKeys = resolution.keys

    var byType: [String: [KeyConflict]] = [:]

    for conflict in resolution.conflicts {
      byType[conflict.typeID, default: []].append(conflict)
    }

    var groups: [(menuTitle: String, conflicts: [KeyConflict])] = []

    for set in appletSets {
      let fresh = (byType[set.typeID] ?? []).filter {
        announced.insert(AnnouncedDrop(command: $0.commandID, key: $0.key)).inserted
      }

      if !fresh.isEmpty { groups.append((set.menuTitle, fresh)) }
    }

    if !groups.isEmpty {
      hooks.warn(KeyReservations.warning(for: groups))
    }

    return resolution.conflicts
  }

  func command(_ id: CommandID) -> Command? {
    index[id].map { commands[$0] }
  }

  /// A pane-scoped command whose pane is gone counts as available, so choosing it can say why
  /// nothing happened. Otherwise a key press would find a disabled menu item and fall through to
  /// the pane behind it.
  func isAvailable(_ id: CommandID, in context: CommandContext) -> Bool {
    guard let command = command(id) else { return false }

    if command.scope != .app, context.controller == nil { return false }

    if command.scope == .pane, !Self.paneExists(context) {
      return true
    }

    return command.isAvailable(context)
  }

  static func paneExists(_ context: CommandContext) -> Bool {
    guard let pane = context.pane, let controller = context.controller else { return false }

    return controller.paneArea.applet(for: pane) != nil
  }

  /// Runs a command when it is available. A run of a command the palette lists is recorded for
  /// ranking. Unlisted bindings, such as Cmd-1 to Cmd-9, would only push listed commands out of
  /// the short recency list.
  ///
  /// Returns whether it ran. A pane-scoped command whose pane is gone does not run, and the
  /// window says so.
  @discardableResult
  func run(_ id: CommandID, in context: CommandContext) -> Bool {
    guard let command = command(id), isAvailable(id, in: context) else { return false }

    if command.scope == .pane, !Self.paneExists(context) {
      context.controller?.postPaneGone(for: command.title)
      return false
    }

    command.run(context)

    if command.listedInPalette {
      remember(id)
    }

    return true
  }

  /// Runs an app command when there is no window to run it in. A command that needs a window or
  /// a pane does nothing.
  @discardableResult
  public func runWithoutWindow(_ id: CommandID) -> Bool {
    guard let command = command(id), command.scope == .app else { return false }

    return run(id, in: CommandContext(controller: nil, pane: nil))
  }

  private func remember(_ id: CommandID) {
    recency.removeAll { $0 == id }
    recency.insert(id, at: 0)

    if recency.count > Self.recencyDepth {
      recency.removeLast(recency.count - Self.recencyDepth)
    }
  }
}
