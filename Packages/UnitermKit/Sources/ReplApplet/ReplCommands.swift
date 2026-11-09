import AppKit
import AppletKit

extension ReplApplet {
  /// The REPL declares no content type. A user opens it from the launcher.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: ReplDescription.typeID, displayName: "REPL", symbolName: "curlybraces", opens: [])

  /// Restart is the REPL's one command. It shows only while the helper has gone, and it is the same
  /// action as the pane's button, so it is always the user's.
  public static let commandSet = AppletCommandSet(
    typeID: ReplDescription.typeID, menuTitle: "REPL",
    commands: [
      AppletCommand(
        name: "restart", title: "Restart REPL", home: .applet,
        isAvailable: { ($0 as? ReplApplet)?.isEnded == true },
        run: { ($0 as? ReplApplet)?.restart() })
    ])
}
