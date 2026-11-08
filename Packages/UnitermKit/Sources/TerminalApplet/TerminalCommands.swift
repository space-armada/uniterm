import AppKit
import AppletKit
import TerminalSurface

/// The commands the terminal owns: its tabs, its text size, and clearing the screen. The terminal
/// declares their keys, and uniterm only reserves the keys of its own window commands.
///
/// Titles are the ones the menu has always shown, so a user's App Shortcuts remap of an item still
/// matches it.
extension TerminalApplet {
  public static let commandSet = AppletCommandSet(
    typeID: TerminalDescription.typeID, menuTitle: "Terminal",
    commands: tabCommands() + textCommands())

  private static func tabCommands() -> [AppletCommand] {
    var commands = [
      AppletCommand(
        name: "new-tab", title: "New Tab", key: KeyChord("t"), home: .file, section: 1,
        isAvailable: { ($0 as? TerminalApplet)?.canOpenTab == true },
        run: { ($0 as? TerminalApplet)?.openTab() }),
      AppletCommand(
        name: "next-tab", title: "Select Next Tab", key: KeyChord("\t", .control),
        home: .window, section: 1,
        isAvailable: hasSeveralTabs,
        run: { ($0 as? TerminalApplet)?.step(by: 1) }),
      AppletCommand(
        name: "previous-tab", title: "Select Previous Tab",
        key: KeyChord("\t", [.control, .shift]), home: .window, section: 1,
        isAvailable: hasSeveralTabs,
        run: { ($0 as? TerminalApplet)?.step(by: -1) }),
    ]

    for number in 1...9 {
      commands.append(
        AppletCommand(
          name: number == 9 ? "last-tab" : "tab-\(number)",
          title: number == 9 ? "Select Last Tab" : "Select Tab \(number)",
          key: KeyChord(String(number)), home: .window, section: 1, listedInPalette: false,
          isAvailable: hasSeveralTabs,
          run: { ($0 as? TerminalApplet)?.selectTab(number: number) }))
    }

    return commands
  }

  private static func textCommands() -> [AppletCommand] {
    [
      text("bigger-text", "Bigger Text", KeyChord("+"), .increaseFontSize),
      text("smaller-text", "Smaller Text", KeyChord("-"), .decreaseFontSize),
      text("actual-size", "Actual Size", KeyChord("0"), .resetFontSize),
      AppletCommand(
        name: "clear", title: "Clear Screen", home: .applet,
        isAvailable: hasSession,
        run: { ($0 as? TerminalApplet)?.perform(.clearScreen) }),
    ]
  }

  private static func text(
    _ name: String, _ title: String, _ key: KeyChord, _ action: TerminalAction
  ) -> AppletCommand {
    AppletCommand(
      name: name, title: title, key: key, home: .view, isAvailable: hasSession,
      run: { ($0 as? TerminalApplet)?.perform(action) })
  }

  private static func hasSeveralTabs(_ applet: any Applet) -> Bool {
    ((applet as? TerminalApplet)?.tabCount ?? 1) > 1
  }

  private static func hasSession(_ applet: any Applet) -> Bool {
    (applet as? TerminalApplet)?.hasSession == true
  }

  /// Selects the tab numbered `number`, counting from 1. Number 9 selects the last tab, as Terminal
  /// does.
  func selectTab(number: Int) {
    selectTab(at: number == 9 ? tabCount - 1 : number - 1)
  }

  func step(by step: Int) {
    guard tabCount > 1 else { return }

    selectTab(at: (selectedTabIndex + step + tabCount) % tabCount)
  }
}
