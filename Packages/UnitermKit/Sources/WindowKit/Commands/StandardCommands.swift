import AppKit
import AppletKit
import PaneModel

/// The commands that uniterm itself owns: the ones that act on the app, a window, or the pane tree.
/// An applet's commands are registered by the applet type.
///
/// The standard edit actions are not here. Cut, copy, paste, select all, undo, and redo stay
/// responder-chain menu items, since a command would act on the pane and not on a text field
/// inside it.
@MainActor
enum StandardCommands {
  private static let commandShift: NSEvent.ModifierFlags = [.command, .shift]
  private static let commandOption: NSEvent.ModifierFlags = [.command, .option]

  static func make(app: AppCommandHooks) -> [Command] {
    appCommands(app) + paneCommands() + windowCommands()
  }

  private static func appCommands(_ app: AppCommandHooks) -> [Command] {
    [
      Command(
        .showSettings, "Settings", scope: .app, key: KeyChord(","),
        menu: MenuPlacement(.app, section: 0, title: "Settings\u{2026}")
      ) { _ in app.showSettings() },
      Command(
        .installCommandLineTool, "Install Command Line Tool", scope: .app,
        menu: MenuPlacement(.app, section: 0, title: "Install Command Line Tool\u{2026}")
      ) { _ in app.installCommandLineTool() },
      Command(
        .hideApp, "Hide uniterm", scope: .app, key: KeyChord("h"),
        menu: MenuPlacement(.app, section: 1)
      ) { _ in NSApp.hide(nil) },
      Command(
        .quit, "Quit uniterm", scope: .app, key: KeyChord("q"),
        menu: MenuPlacement(.app, section: 2),
        isAvailable: { _ in app.canQuit() },
        run: { _ in NSApp.terminate(nil) }
      ),
      Command(
        .newWindow, "New Window", scope: .app, key: KeyChord("n"),
        menu: MenuPlacement(.file, section: 0)
      ) { _ in app.newWindow() },
      Command(
        .openFile, "Open File or Folder", scope: .app, key: KeyChord("o"),
        menu: MenuPlacement(.file, section: 0, title: "Open\u{2026}"),
        isAvailable: canOpen
      ) { context in app.openFile(context.anchor) },
      Command(
        .openFileWith, "Open File or Folder With", scope: .app,
        menu: MenuPlacement(.file, section: 0, title: "Open With\u{2026}"),
        isAvailable: canOpen
      ) { context in app.openFileWith(context.anchor) },
    ]
  }

  /// Opening works with no window, and waits while a sheet holds the window's attention.
  private static func canOpen(_ context: CommandContext) -> Bool {
    context.controller == nil || context.actionsEnabled
  }

  private static func paneCommands() -> [Command] {
    [
      pane(.splitRight, "Split Right", KeyChord("d"), .file, 1) { context in
        context.controller?.requestSplit(.row, from: context.pane)
      },
      pane(.splitDown, "Split Down", KeyChord("d", commandShift), .file, 1) { context in
        context.controller?.requestSplit(.column, from: context.pane)
      },
      Command(
        .close, "Close Tab or Pane", scope: .pane, key: KeyChord("w"),
        menu: MenuPlacement(.file, section: 2, title: "Close"),
        isAvailable: { $0.actionsEnabled },
        run: { context in
          context.controller?.closeTabOrPane(context.pane)
        }
      ),
      Command(
        .reopenClosed, "Reopen Closed Tab or Pane", scope: .window,
        key: KeyChord("t", commandShift), menu: MenuPlacement(.file, section: 2),
        isAvailable: { context in
          context.actionsEnabled && context.controller?.hasReopenableClose == true
        },
        run: { context in
          context.controller?.reopenClosed()
        }
      ),
      focus(.focusNextPane, "Focus Next Pane", KeyChord("]"), .next, 2),
      focus(.focusPreviousPane, "Focus Previous Pane", KeyChord("["), .previous, 2),
      focus(.focusPaneLeft, "Focus Pane Left", arrow(NSLeftArrowFunctionKey), .toward(.left), 3),
      focus(
        .focusPaneRight, "Focus Pane Right", arrow(NSRightArrowFunctionKey), .toward(.right), 3),
      focus(.focusPaneUp, "Focus Pane Up", arrow(NSUpArrowFunctionKey), .toward(.up), 3),
      focus(.focusPaneDown, "Focus Pane Down", arrow(NSDownArrowFunctionKey), .toward(.down), 3),
    ]
  }

  private static func arrow(_ code: Int) -> KeyChord {
    KeyChord(String(UnicodeScalar(UInt32(code)).map(Character.init) ?? " "), commandOption)
  }

  private static func pane(
    _ id: CommandID, _ title: String, _ key: KeyChord, _ home: MenuHome, _ section: Int,
    run: @escaping @MainActor (CommandContext) -> Void
  ) -> Command {
    Command(
      id, title, scope: .pane, key: key, menu: MenuPlacement(home, section: section),
      isAvailable: { $0.actionsEnabled }, run: run)
  }

  private static func focus(
    _ id: CommandID, _ title: String, _ key: KeyChord, _ move: PaneFocusMove, _ section: Int
  ) -> Command {
    pane(id, title, key, .window, section) { context in
      context.controller?.moveFocus(move, from: context.pane)
    }
  }

  private static func windowCommands() -> [Command] {
    [
      Command(
        .minimizeWindow, "Minimize", scope: .window, key: KeyChord("m"),
        menu: MenuPlacement(.window, section: 0)
      ) { context in
        context.controller?.window?.performMiniaturize(nil)
      },
      Command(
        .showCommandPalette, "Show Command Palette", scope: .window,
        key: KeyChord("k"), menu: MenuPlacement(.view, section: 1),
        listedInPalette: false,
        isAvailable: { $0.actionsEnabled },
        run: { context in
          context.controller?.showCommandPalette()
        }
      ),
      Command(
        .toggleMessageHistory, "Toggle Message History", scope: .window,
        key: KeyChord("m", commandShift),
        menu: MenuPlacement(.view, section: 1, title: "Show Message History")
      ) { context in
        context.controller?.toggleHistory()
      },
      Command(
        .focusMessageHistory, "Focus Message History", scope: .window,
        menu: MenuPlacement(.view, section: 1)
      ) { context in
        context.controller?.focusHistory()
      },
      Command(
        .dismissMessage, "Dismiss Message", scope: .window,
        key: KeyChord("\u{8}", commandOption), menu: MenuPlacement(.view, section: 1),
        isAvailable: { $0.controller?.statusCenter.display?.message.level == .error },
        run: { context in
          context.controller?.statusCenter.dismissCurrent()
        }
      ),
    ]
  }
}

extension CommandContext {
  /// False while a sheet holds the window's attention. Pane actions wait until it is answered.
  var actionsEnabled: Bool {
    controller?.paneActionsEnabled ?? false
  }
}
