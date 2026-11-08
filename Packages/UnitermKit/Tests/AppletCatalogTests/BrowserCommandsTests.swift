import AppKit
import AppletCatalog
import AppletKit
import XCTest

@testable import WindowKit

/// The commands the browser declares, checked against the keys uniterm reserves. A new window key
/// that lands on a browser key fails here before it reaches a user.
@MainActor
final class BrowserCommandsTests: XCTestCase {
  private func browser() throws -> AppletCommandSet {
    try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "browser" })
  }

  /// Catches a browser command that claims a reserved key or a key another of its commands holds,
  /// such as Cmd-[ and Cmd-] for Back and Forward. The menu is the app's own, built from the
  /// registry, so a window key added later joins the reserved set and fails this test. AppKit adds
  /// its keys at run time, so the full-screen key is listed here. Cmd-1 to Cmd-9 stay out of the
  /// reserved set, since the browser holds them as the terminal does.
  func testNoBrowserCommandClaimsAReservedKeyOrAKeyOfItsOwn() throws {
    let set = try browser()
    let registry = CommandRegistry()
    registry.register(set)

    let menu = CommandMenu(registry: registry, activeController: { nil })
    var reserved = menu.reservedKeys()
    reserved.insert(KeyChord("f", [.command, .control]))

    let resolution = KeyReservations.resolve(sets: registry.appletSets, reserved: reserved)

    XCTAssertEqual(resolution.conflicts, [])
    XCTAssertEqual(resolution.keys.count, set.commands.compactMap(\.key).count)

    for number in 1...9 {
      XCTAssertFalse(menu.reservedKeys().contains(KeyChord(String(number))), "\(number)")
    }
  }

  /// Catches a browser tab command that moved a title, a key, or a menu. The titles are the ones the
  /// terminal uses, so one App Shortcuts remap covers both. Back and Forward take no key, since
  /// Cmd-[ and Cmd-] are uniterm's pane keys.
  func testTheBrowserHoldsItsTabKeysAndTheTerminalsTitles() throws {
    let set = try browser()
    let terminal = try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "terminal" })

    let expected: [String: (title: String, key: KeyChord?, home: AppletMenuHome)] = [
      "new-tab": ("New Tab", KeyChord("t"), .file),
      "open-location": ("Open Location", KeyChord("l"), .file),
      "reload": ("Reload", KeyChord("r"), .view),
      "next-tab": ("Select Next Tab", KeyChord("\t", .control), .window),
      "previous-tab": ("Select Previous Tab", KeyChord("\t", [.control, .shift]), .window),
      "tab-1": ("Select Tab 1", KeyChord("1"), .window),
      "tab-8": ("Select Tab 8", KeyChord("8"), .window),
      "last-tab": ("Select Last Tab", KeyChord("9"), .window),
      "back": ("Back", nil, .applet),
      "forward": ("Forward", nil, .applet),
    ]

    for (name, want) in expected {
      let command = try XCTUnwrap(set.commands.first { $0.name == name }, name)

      XCTAssertEqual(command.title, want.title, name)
      XCTAssertEqual(command.key, want.key, name)
      XCTAssertEqual(command.home, want.home, name)
    }

    for name in ["new-tab", "next-tab", "previous-tab", "tab-1", "last-tab"] {
      let mine = set.commands.first { $0.name == name }
      let theirs = terminal.commands.first { $0.name == name }

      XCTAssertEqual(mine?.title, theirs?.title, name)
      XCTAssertEqual(mine?.key, theirs?.key, name)
    }

    XCTAssertEqual(set.commands.compactMap(\.key).count, 14)
  }
}

/// What the user hears when one remap takes a key that two applets declare.
@MainActor
final class SharedKeyWarningTests: XCTestCase {
  private var warnings: [String] = []

  private func item(_ id: CommandID, in menu: CommandMenu) throws -> CommandMenuItem {
    func find(in menu: NSMenu) -> CommandMenuItem? {
      for item in menu.items {
        if let found = item as? CommandMenuItem, found.commandID == id { return found }

        if let submenu = item.submenu, let found = find(in: submenu) { return found }
      }

      return nil
    }

    return try XCTUnwrap(find(in: menu.menu), "no menu item for \(id)")
  }

  /// Catches a remap that drops a key from two applets and tells the user about one. The terminal
  /// and the browser both declare Cmd-T. The status bar shows the newest message, so two messages
  /// would hide the first. One message names both applets, the command, and the key.
  func testOneRemapOntoAKeyTwoAppletsDeclareWarnsOnceAndNamesBoth() throws {
    let registry = CommandRegistry(app: AppCommandHooks(warn: { [self] in warnings.append($0) }))

    for set in BuiltInApplets.commandSets { registry.register(set) }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    XCTAssertTrue(warnings.isEmpty, "\(warnings)")

    let palette = try item(.showCommandPalette, in: menu)
    palette.keyEquivalent = "t"
    palette.keyEquivalentModifierMask = .command
    menu.refreshKeys()

    XCTAssertEqual(warnings.count, 1, "\(warnings)")
    XCTAssertTrue(warnings[0].contains("Terminal"), warnings[0])
    XCTAssertTrue(warnings[0].contains("Browser"), warnings[0])
    XCTAssertTrue(warnings[0].contains("New Tab"), warnings[0])
    XCTAssertTrue(warnings[0].contains("\u{2318}T"), warnings[0])

    menu.refreshKeys()

    XCTAssertEqual(warnings.count, 1, "a repeated drop was announced again")
  }

  /// Catches a message that grows with every dropped command. An applet lists at most three, then
  /// counts the rest, and the next step still ends the message.
  func testALongListOfDropsEndsWithACountAndTheNextStep() {
    func drop(_ name: String) -> KeyConflict {
      KeyConflict(
        typeID: "a", commandID: CommandID("a.\(name)"), commandTitle: name,
        key: KeyChord(name), reason: .reserved)
    }

    let text = KeyReservations.warning(
      for: [("Alpha", ["1", "2", "3", "4", "5"].map(drop)), ("Beta", [drop("6")])])

    XCTAssertTrue(text.contains("Alpha:"), text)
    XCTAssertTrue(text.contains("and 2 more lose their keys too"), text)
    XCTAssertFalse(text.contains("\u{201C}5\u{201D}"), text)
    XCTAssertTrue(text.contains("Beta: \u{201C}6\u{201D}"), text)
    XCTAssertTrue(text.hasSuffix("App Shortcuts."), text)
  }
}
