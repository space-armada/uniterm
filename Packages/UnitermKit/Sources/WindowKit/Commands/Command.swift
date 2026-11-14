import AppKit
import AppletKit
import PaneModel

/// A command's stable name. It is namespaced by its owner, such as `uniterm.split-right`, and it
/// is never reused for a different action. A title can change. An ID cannot.
public struct CommandID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    rawValue = value
  }

  public var description: String { rawValue }
}

extension CommandID {
  public static let newWindow: CommandID = "uniterm.new-window"
  public static let openFile: CommandID = "uniterm.open"
  public static let openFileWith: CommandID = "uniterm.open-with"
  public static let showSettings: CommandID = "uniterm.settings"
  public static let installCommandLineTool: CommandID = "uniterm.install-command-line-tool"
  public static let hideApp: CommandID = "uniterm.hide"
  public static let quit: CommandID = "uniterm.quit"
  public static let minimizeWindow: CommandID = "uniterm.minimize"
  public static let splitRight: CommandID = "uniterm.split-right"
  public static let splitDown: CommandID = "uniterm.split-down"
  public static let close: CommandID = "uniterm.close"
  public static let reopenClosed: CommandID = "uniterm.reopen-closed"
  public static let focusNextPane: CommandID = "uniterm.focus-next-pane"
  public static let focusPreviousPane: CommandID = "uniterm.focus-previous-pane"
  public static let focusPaneLeft: CommandID = "uniterm.focus-pane-left"
  public static let focusPaneRight: CommandID = "uniterm.focus-pane-right"
  public static let focusPaneUp: CommandID = "uniterm.focus-pane-up"
  public static let focusPaneDown: CommandID = "uniterm.focus-pane-down"
  public static let toggleMessageHistory: CommandID = "uniterm.toggle-message-history"
  public static let focusMessageHistory: CommandID = "uniterm.focus-message-history"
  public static let dismissMessage: CommandID = "uniterm.dismiss-message"
  public static let showCommandPalette: CommandID = "uniterm.show-command-palette"
}

/// Who owns a command. uniterm owns the window commands, and an applet type owns its own.
enum CommandOwner: Equatable {
  case uniterm
  case applet(typeID: String)
}

/// The menu a command's item lives in.
enum MenuHome {
  case app
  case file
  case view
  case window

  /// The Find submenu of Edit.
  case editFind

  /// The menu named for the owning applet type.
  case applet
}

/// Where a command's menu item goes. Items of one menu with different sections are set apart by a
/// separator. The title overrides the command's own, for an item whose menu title differs from the
/// palette's.
struct MenuPlacement {
  let home: MenuHome
  let section: Int
  let title: String?

  init(_ home: MenuHome, section: Int = 0, title: String? = nil) {
    self.home = home
    self.section = section
    self.title = title
  }
}

/// What a command acts on. It decides whether the command needs a pane that still exists.
enum CommandScope: Sendable {
  /// The app, with or without a window.
  case app

  /// The window, whatever its panes are doing.
  case window

  /// One pane of the window. A pane that is gone makes the command report that and do nothing.
  case pane
}

/// What a command runs against. The target pane is explicit and fixed when the caller built the
/// context. A run action never asks the window which pane has focus, since the palette has focus
/// while it shows.
@MainActor
struct CommandContext {
  weak var controller: MainWindowController?
  var pane: NodeID?

  /// The pane a request came from, when there is one. A file opened from it lands beside it.
  var anchor: RouteAnchor? {
    guard let controller, let pane else { return nil }

    return RouteAnchor(controller: controller, pane: pane)
  }

  /// The applet of this type in the target pane, nil when the pane holds another kind.
  func applet(ofType typeID: String) -> (any Applet)? {
    guard let controller, let pane, let applet = controller.paneArea.applet(for: pane),
      applet.typeID == typeID
    else { return nil }

    return applet
  }
}

/// One thing the user can ask uniterm to do. A key binding, a menu item, and the palette run the
/// same action.
///
/// A run action is synchronous and runs on the main thread. It may start UI, such as the applet
/// chooser or a close question, and return before the user answers.
@MainActor
struct Command {
  let id: CommandID
  let title: String
  let scope: CommandScope
  let owner: CommandOwner

  /// The key the command asks for. It is a default. A user's remap replaces it, and a reserved key
  /// drops it for an applet's command.
  let key: KeyChord?

  /// Nil for a command with no menu item.
  let menu: MenuPlacement?

  /// False for a command that the palette must not list, such as the palette's own toggle or a
  /// binding that the palette's other entries already cover.
  let listedInPalette: Bool

  let isAvailable: @MainActor (CommandContext) -> Bool
  let run: @MainActor (CommandContext) -> Void

  init(
    _ id: CommandID, _ title: String, scope: CommandScope, owner: CommandOwner = .uniterm,
    key: KeyChord? = nil, menu: MenuPlacement? = nil, listedInPalette: Bool = true,
    isAvailable: @escaping @MainActor (CommandContext) -> Bool = { _ in true },
    run: @escaping @MainActor (CommandContext) -> Void
  ) {
    self.id = id
    self.title = title
    self.scope = scope
    self.owner = owner
    self.key = key
    self.menu = menu
    self.listedInPalette = listedInPalette
    self.isAvailable = isAvailable
    self.run = run
  }
}

extension AppletMenuHome {
  var menuHome: MenuHome {
    switch self {
    case .file: return .file
    case .view: return .view
    case .window: return .window
    case .editFind: return .editFind
    case .applet: return .applet
    }
  }
}
