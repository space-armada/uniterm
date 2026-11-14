import AppKit
import AppletKit
import BrowserModel

extension BrowserApplet {
  /// The browser opens no file. `file:` never loads, and the text viewer owns local files, so the
  /// router sends nothing here and the app declares no document type for it.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: BrowserDescription.typeID, displayName: "Browser", symbolName: "safari", opens: [])

  /// The browser's own commands. Back and Forward sit in the applet menu with no key, since Cmd-[
  /// and Cmd-] are uniterm's pane keys. The tab commands carry the terminal's titles, so a user's
  /// App Shortcuts remap of an item matches both applets.
  public static let commandSet = AppletCommandSet(
    typeID: BrowserDescription.typeID, menuTitle: "Browser",
    commands: tabCommands() + [
      AppletCommand(
        name: "open-location", title: "Open Location", key: KeyChord("l"), home: .file,
        isAvailable: { $0 is BrowserApplet },
        run: { ($0 as? BrowserApplet)?.openLocation() }),
      AppletCommand(
        name: "reload", title: "Reload", key: KeyChord("r"), home: .view,
        isAvailable: { $0 is BrowserApplet },
        run: { ($0 as? BrowserApplet)?.reload() }),
      AppletCommand(
        name: "reveal-latest-download", title: "Reveal Latest Download", home: .applet,
        isAvailable: { ($0 as? BrowserApplet)?.hasFinishedDownload ?? false },
        run: { ($0 as? BrowserApplet)?.revealLatestDownload() }),
      AppletCommand(
        name: "back", title: "Back", home: .applet,
        isAvailable: { ($0 as? BrowserApplet)?.canGoBack ?? false },
        run: { ($0 as? BrowserApplet)?.goBack() }),
      AppletCommand(
        name: "forward", title: "Forward", home: .applet,
        isAvailable: { ($0 as? BrowserApplet)?.canGoForward ?? false },
        run: { ($0 as? BrowserApplet)?.goForward() }),
    ])

  private static func tabCommands() -> [AppletCommand] {
    var commands = [
      AppletCommand(
        name: "new-tab", title: "New Tab", key: KeyChord("t"), home: .file, section: 1,
        isAvailable: { $0 is BrowserApplet },
        run: { ($0 as? BrowserApplet)?.openTab() }),
      AppletCommand(
        name: "next-tab", title: "Select Next Tab", key: KeyChord("\t", .control),
        home: .window, section: 1,
        isAvailable: hasSeveralTabs,
        run: { ($0 as? BrowserApplet)?.step(by: 1) }),
      AppletCommand(
        name: "previous-tab", title: "Select Previous Tab",
        key: KeyChord("\t", [.control, .shift]), home: .window, section: 1,
        isAvailable: hasSeveralTabs,
        run: { ($0 as? BrowserApplet)?.step(by: -1) }),
    ]

    for number in 1...9 {
      commands.append(
        AppletCommand(
          name: number == 9 ? "last-tab" : "tab-\(number)",
          title: number == 9 ? "Select Last Tab" : "Select Tab \(number)",
          key: KeyChord(String(number)), home: .window, section: 1, listedInPalette: false,
          isAvailable: hasSeveralTabs,
          run: { ($0 as? BrowserApplet)?.selectTab(number: number) }))
    }

    return commands
  }

  private static func hasSeveralTabs(_ applet: any Applet) -> Bool {
    ((applet as? BrowserApplet)?.tabCount ?? 1) > 1
  }
}
