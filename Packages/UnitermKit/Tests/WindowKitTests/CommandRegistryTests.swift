import AppKit
import AppletKit
import XCTest

@testable import WindowKit

@MainActor
final class CommandRegistryTests: XCTestCase {
  /// Catches an ID that is not namespaced by its owner, which a later applet command could collide
  /// with. Duplicates trap on registration, so building the registry proves there are none.
  func testEveryCommandHasAnIDNamespacedByItsOwner() {
    let registry = CommandRegistry.testing()

    XCTAssertGreaterThan(registry.commands.count, 20)

    for command in registry.commands {
      switch command.owner {
      case .uniterm:
        XCTAssertTrue(command.id.rawValue.hasPrefix("uniterm."), "\(command.id)")
      case .applet(let typeID):
        XCTAssertTrue(command.id.rawValue.hasPrefix("\(typeID)."), "\(command.id)")
      }

      XCTAssertFalse(command.title.isEmpty)
    }
  }

  /// Catches an applet command that is registered under the wrong owner, or one that lands in the
  /// palette's recency by number.
  func testAnAppletTypeOwnsItsCommands() {
    let registry = CommandRegistry.testing()

    XCTAssertEqual(registry.command(.fakeNewTab)?.owner, .applet(typeID: "fake"))
    XCTAssertEqual(registry.command(.splitRight)?.owner, .uniterm)
    XCTAssertEqual(registry.command(.fakeTab(9))?.id.rawValue, "fake.last-tab")

    for number in 1...9 {
      XCTAssertNotNil(registry.command(.fakeTab(number)), "tab \(number)")
    }
  }

  /// Catches recency that grows without bound or keeps a command twice.
  func testRecencyKeepsEachCommandOnceAndStaysBounded() {
    let registry = CommandRegistry()

    for _ in 0..<3 {
      for id in [CommandID.newWindow, .showSettings] {
        _ = registry.runWithoutWindow(id)
      }
    }

    XCTAssertEqual(registry.recency, [.showSettings, .newWindow])
  }

  /// Catches tab-number presses that push every listed command out of the recency list.
  func testUnlistedCommandsAreNotRemembered() throws {
    let fixture = try WindowFixture()
    defer { fixture.cleanUp() }
    let controller = fixture.controller

    controller.commands.run(.splitRight, in: controller.commandContext())
    controller.commands.run(.fakeTab(1), in: controller.commandContext())
    controller.commands.run(.showCommandPalette, in: controller.commandContext())

    XCTAssertEqual(controller.commands.recency, [.splitRight])
  }

  /// Catches an app command that needs a window running without one, and a window command that
  /// runs with none.
  func testOnlyAppCommandsRunWithoutAWindow() {
    var opened = 0
    let registry = CommandRegistry(app: AppCommandHooks(newWindow: { opened += 1 }))

    XCTAssertTrue(registry.runWithoutWindow(.newWindow))
    XCTAssertFalse(registry.runWithoutWindow(.splitRight))
    XCTAssertEqual(opened, 1)
  }
}

/// The File > Open commands, as the registry and the menu hold them.
@MainActor
final class OpenCommandTests: XCTestCase {
  /// Catches an Open that loses its anchor or invents one. It gets the focused pane of the window
  /// that ran it, and nothing when no window is open.
  func testOpenHandsTheHookTheFocusedPaneOfTheWindowThatRanIt() throws {
    let fixture = try WindowFixture()
    defer { fixture.cleanUp() }

    var opened: [RouteAnchor?] = []
    var openedWith: [RouteAnchor?] = []

    let registry = CommandRegistry(
      app: AppCommandHooks(openFile: { opened.append($0) }, openFileWith: { openedWith.append($0) })
    )

    let context = fixture.controller.commandContext()

    XCTAssertTrue(registry.run(.openFile, in: context))
    XCTAssertTrue(registry.run(.openFileWith, in: context))
    XCTAssertTrue(registry.runWithoutWindow(.openFile))

    XCTAssertTrue(opened[0]?.controller === fixture.controller)
    XCTAssertEqual(opened[0]?.pane, fixture.controller.focusedPane)
    XCTAssertEqual(openedWith[0]?.pane, fixture.controller.focusedPane)
    XCTAssertNil(opened[1])
  }

  /// Catches an Open run from the palette that anchors to the pane focus returns to, or to nothing.
  /// The palette targets pane B while focus sits on pane A. The command dismisses the palette and
  /// runs on B.
  func testOpenFromThePaletteAnchorsToThePaneThePaletteTargets() throws {
    var opened: [RouteAnchor?] = []

    let registry = CommandRegistry(app: AppCommandHooks(openFile: { opened.append($0) }))
    registry.register(FakeApplet.commandSet)

    let fixture = try WindowFixture(commands: registry)
    defer { fixture.cleanUp() }
    let controller = fixture.controller

    let first = controller.focusedPane
    let second = try XCTUnwrap(controller.openPane(.terminalShell, axis: .row))

    controller.showCommandPalette()
    XCTAssertEqual(controller.paletteTarget, second)

    controller.paneArea.focus(first)
    XCTAssertEqual(controller.paneArea.focusedPane, first)
    XCTAssertNotEqual(first, second)

    controller.dispatch(.openFile)

    XCTAssertEqual(opened.count, 1)
    XCTAssertEqual(opened.first??.pane, second)
    XCTAssertFalse(controller.isPaletteVisible)
  }

  /// Catches an Open that lands outside the File menu's first section, loses Cmd-O, or gives Open
  /// With a key. Cmd-O must also join the keys uniterm reserves, so no applet can take it.
  func testOpenHoldsCommandOInTheFileMenuAndOpenWithHoldsNoKey() throws {
    let registry = CommandRegistry.testing()
    let menu = CommandMenu(registry: registry, activeController: { nil })

    XCTAssertEqual(registry.command(.openFile)?.menu?.home, .file)
    XCTAssertEqual(registry.command(.openFile)?.menu?.section, 0)
    XCTAssertEqual(registry.command(.openFileWith)?.menu?.section, 0)

    let open = try XCTUnwrap(menu.keyEquivalent(of: .openFile))
    XCTAssertEqual(open.key, "o")
    XCTAssertEqual(open.modifiers, [.command])

    XCTAssertEqual(try XCTUnwrap(menu.keyEquivalent(of: .openFileWith)).key, "")
    XCTAssertTrue(menu.reservedKeys().contains(KeyChord("o")))
  }
}

/// How a typed key is matched to a menu item's key equivalent.
@MainActor
final class MenuKeyMatchTests: XCTestCase {
  private func event(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: 0))
  }

  private func item(_ key: String, _ flags: NSEvent.ModifierFlags) -> NSMenuItem {
    let item = NSMenuItem(title: "Item", action: nil, keyEquivalent: key)
    item.keyEquivalentModifierMask = flags
    return item
  }

  /// Catches Bigger Text missing its early route. Cmd-Shift-= types "+", and the item names Cmd
  /// alone.
  func testAShiftedSymbolMatchesAnItemThatNamesOnlyTheSymbol() throws {
    XCTAssertTrue(MenuKeyMatch.triggers(item("+", .command), try event("+", [.command, .shift])))
    XCTAssertTrue(MenuKeyMatch.triggers(item("+", .command), try event("+", .command)))
  }

  /// Catches Dismiss Message missing its early route. The Delete key sends 0x7F and the item
  /// says 0x08.
  func testDeleteMatchesTheBackspaceKeyEquivalent() throws {
    XCTAssertTrue(
      MenuKeyMatch.triggers(
        item("\u{8}", [.command, .option]), try event("\u{7F}", [.command, .option])))
  }

  /// Catches Select Previous Tab never firing from Ctrl-Shift-Tab. Shift-Tab types the back-tab
  /// character 0x19, and the item says Tab with Shift.
  func testShiftTabMatchesATabKeyEquivalentWithShift() throws {
    XCTAssertTrue(
      MenuKeyMatch.triggers(
        item("\t", [.control, .shift]), try event("\u{19}", [.control, .shift])))
    XCTAssertTrue(MenuKeyMatch.triggers(item("\t", .control), try event("\t", .control)))
    XCTAssertFalse(
      MenuKeyMatch.triggers(item("\t", .control), try event("\u{19}", [.control, .shift])))
  }

  /// Catches a loosened match that fires on the wrong chord: Shift still counts for letters and
  /// digits, and a different character never matches.
  func testLettersKeepTheirModifiersAndOtherCharactersDoNotMatch() throws {
    XCTAssertFalse(MenuKeyMatch.triggers(item("d", .command), try event("d", [.command, .shift])))
    XCTAssertTrue(
      MenuKeyMatch.triggers(item("d", [.command, .shift]), try event("D", [.command, .shift])))
    XCTAssertFalse(MenuKeyMatch.triggers(item("]", .command), try event("}", [.command, .shift])))
    XCTAssertTrue(
      MenuKeyMatch.triggers(item("}", [.command, .shift]), try event("}", [.command, .shift])))
    XCTAssertFalse(MenuKeyMatch.triggers(item("t", .command), try event("t", .control)))
  }
}
