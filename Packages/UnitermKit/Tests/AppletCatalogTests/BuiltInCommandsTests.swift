import AppletCatalog
import AppletKit
import XCTest

@testable import WindowKit

/// The commands of every applet the app ships, checked against the keys uniterm reserves.
@MainActor
final class BuiltInCommandsTests: XCTestCase {
  /// Catches a built-in applet that takes Cmd-O from the window's File > Open, whether it asks for
  /// the key outright or loses it to the reservation and still lists it. It also catches the
  /// terminal gaining an Open of its own, since it has no source to replace. A viewer added to the
  /// catalog later is covered without a new test.
  func testNoBuiltInAppletCommandClaimsCommandO() {
    let registry = CommandRegistry()

    for set in BuiltInApplets.commandSets {
      registry.register(set)
    }

    _ = CommandMenu(registry: registry, activeController: { nil })
    let commandO = KeyChord("o")

    XCTAssertFalse(BuiltInApplets.commandSets.isEmpty)

    for set in BuiltInApplets.commandSets {
      XCTAssertFalse(set.commands.contains { $0.key == commandO }, set.typeID)
    }

    XCTAssertFalse(registry.appletKeys.values.contains(commandO))

    let terminal = BuiltInApplets.commandSets.first { $0.typeID == "terminal" }
    XCTAssertFalse(terminal?.commands.contains { $0.name == AppletCommand.openSourceName } ?? true)

    let viewer = BuiltInApplets.commandSets.first { $0.typeID == "data-viewer" }
    let open = viewer?.commands.first { $0.name == AppletCommand.openSourceName }
    XCTAssertNotNil(open)
    XCTAssertNil(open?.key)
  }

  /// Catches a data viewer find key that uniterm reserves, whether a window command, a fixed Edit
  /// key, or one a later catalog entry takes. Every find key survives the reservation pass with no
  /// warning, the commands sit in Edit > Find, and Focus Filter asks for no key.
  func testTheDataViewerFindCommandsHoldTheirKeysInEditFind() throws {
    var warnings: [String] = []
    let registry = CommandRegistry(app: AppCommandHooks(warn: { warnings.append($0) }))

    for set in BuiltInApplets.commandSets {
      registry.register(set)
    }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let viewer = try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "data-viewer" })
    let find = viewer.commands.filter { $0.home == .editFind }

    XCTAssertEqual(
      find.map(\.name), ["find", "find-next", "find-previous", "focus-filter"])
    XCTAssertEqual(
      find.map(\.key), [KeyChord("f"), KeyChord("g"), KeyChord("g", [.command, .shift]), nil])

    for command in find where command.key != nil {
      let id = CommandRegistry.commandID(typeID: "data-viewer", name: command.name)
      XCTAssertEqual(registry.appletKeys[id], command.key, command.title)
    }

    XCTAssertTrue(warnings.isEmpty, "\(warnings)")
  }

  /// Catches a text viewer command whose key uniterm reserves, one that lands outside Edit > Find or
  /// View, and a key the live menu takes from it. Find, Find Next, Find Previous, and Use Selection
  /// for Find hold Cmd-F, Cmd-G, Cmd-Shift-G, and Cmd-E in Edit > Find. Show Contents has no key.
  func testTheTextViewerFindAndContentsCommandsHoldTheirKeys() throws {
    var warnings: [String] = []
    let registry = CommandRegistry(app: AppCommandHooks(warn: { warnings.append($0) }))

    for set in BuiltInApplets.commandSets {
      registry.register(set)
    }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let viewer = try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "text-viewer" })
    let find = viewer.commands.filter { $0.home == .editFind }

    XCTAssertEqual(
      find.map(\.name), ["find", "find-next", "find-previous", "use-selection-for-find"])
    XCTAssertEqual(
      find.map(\.key),
      [KeyChord("f"), KeyChord("g"), KeyChord("g", [.command, .shift]), KeyChord("e")])

    for command in find {
      let id = CommandRegistry.commandID(typeID: "text-viewer", name: command.name)
      XCTAssertEqual(registry.appletKeys[id], command.key, command.title)
    }

    let contents = try XCTUnwrap(viewer.commands.first { $0.name == "show-contents" })

    XCTAssertEqual(contents.home, .view)
    XCTAssertNil(contents.key)

    for name in ["reload", AppletCommand.openSourceName] {
      XCTAssertNotNil(viewer.commands.first { $0.name == name }, name)
    }

    XCTAssertTrue(warnings.isEmpty, "\(warnings)")
  }

  /// Catches a map command that gains or loses a key, lands in the wrong menu, or loses its name.
  /// The commands are the registry's contract with the menu and the palette. Open and Clear File
  /// Pins sit in File with no key, so Cmd-O stays with the window's File > Open. The three styles
  /// sit in View on Cmd-1 to Cmd-3, which the terminal's tab keys leave free while a map is focused.
  /// The camera commands sit in View too, and none loses its key to a reservation.
  func testTheMapCommandsSitInTheirMenusWithTheirKeys() throws {
    var warnings: [String] = []
    let registry = CommandRegistry(app: AppCommandHooks(warn: { warnings.append($0) }))

    for set in BuiltInApplets.commandSets {
      registry.register(set)
    }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let map = try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "map-viewer" })
    let keys: [String: KeyChord] = [
      "style-standard": KeyChord("1"), "style-satellite": KeyChord("2"),
      "style-hybrid": KeyChord("3"), "zoom-in": KeyChord("+"), "zoom-out": KeyChord("-"),
      "zoom-to-pins": KeyChord("0"), "face-north": KeyChord("n", [.command, .shift]),
      "go-to-place": KeyChord("l"), "save": KeyChord("s"),
      "save-as": KeyChord("s", [.command, .shift]), "remove-pin": KeyChord("\u{8}"),
      "pin-list": KeyChord("l", [.command, .shift]),
    ]
    let homes: [String: AppletMenuHome] = [
      "open": .file, "save": .file, "save-as": .file, "clear-file": .file, "edit-pin": .applet,
      "remove-pin": .applet,
    ]

    XCTAssertEqual(
      map.commands.map(\.name),
      [
        "open", "save", "save-as", "clear-file", "style-standard", "style-satellite",
        "style-hybrid", "zoom-in", "zoom-out", "zoom-to-pins", "face-north", "go-to-place",
        "edit-pin", "remove-pin", "pin-list",
      ])
    XCTAssertEqual(
      map.commands.map(\.title),
      [
        "Open\u{2026}", "Save", "Save As\u{2026}", "Clear File Pins", "Standard Map",
        "Satellite Map", "Hybrid Map", "Zoom In", "Zoom Out", "Zoom to Fit Pins", "Face North",
        "Go to Place\u{2026}", "Edit Pin\u{2026}", "Remove Pin", "Show or Hide Pin List",
      ])

    for command in map.commands {
      XCTAssertEqual(command.key, keys[command.name], command.title)
      XCTAssertEqual(command.home, homes[command.name] ?? .view, command.title)

      let id = CommandRegistry.commandID(typeID: "map-viewer", name: command.name)
      XCTAssertEqual(registry.appletKeys[id], keys[command.name], command.title)
    }

    XCTAssertTrue(warnings.isEmpty, "\(warnings)")
  }

  /// Catches an image viewer command that gains a key it should not have, loses one it should, or
  /// lands in the wrong menu. The stepping, slideshow, sort, and reload commands sit in the viewer's
  /// own menu with no chord, because a text-editing chord such as Cmd-Left would reach the menu
  /// before the palette's search field and the palette would close and run it. Open stays in File
  /// with no key. The four zoom commands sit in View on Cmd-+, Cmd--, Cmd-0, and Cmd-9, and none
  /// loses its key to a reservation or draws a warning.
  func testTheImageViewerCommandsSitInTheirMenusWithTheirKeys() throws {
    var warnings: [String] = []
    let registry = CommandRegistry(app: AppCommandHooks(warn: { warnings.append($0) }))

    for set in BuiltInApplets.commandSets {
      registry.register(set)
    }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let viewer = try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "image-viewer" })

    XCTAssertEqual(viewer.menuTitle, "Image Viewer")
    XCTAssertEqual(
      viewer.commands.map(\.name),
      [
        "open", "next", "previous", "first", "last", "play-pause", "sort-by-name", "sort-by-date",
        "reload", "zoom-in", "zoom-out", "actual-size", "zoom-to-fit",
      ])
    XCTAssertEqual(
      viewer.commands.map(\.title),
      [
        "Open\u{2026}", "Next Image", "Previous Image", "First Image", "Last Image",
        "Play or Pause Slideshow", "Sort by Name", "Sort by Date Modified", "Reload Folder",
        "Zoom In", "Zoom Out", "Actual Size", "Zoom to Fit",
      ])

    let keys: [String: KeyChord] = [
      "zoom-in": KeyChord("+"), "zoom-out": KeyChord("-"), "actual-size": KeyChord("0"),
      "zoom-to-fit": KeyChord("9"),
    ]

    for command in viewer.commands {
      let isZoom = keys[command.name] != nil
      let home: AppletMenuHome = isZoom ? .view : (command.name == "open" ? .file : .applet)

      XCTAssertEqual(command.key, keys[command.name], command.title)
      XCTAssertEqual(command.home, home, command.title)

      let id = CommandRegistry.commandID(typeID: "image-viewer", name: command.name)
      XCTAssertEqual(registry.appletKeys[id], keys[command.name], command.title)
    }

    XCTAssertTrue(warnings.isEmpty, "\(warnings)")
  }

  /// Catches a zoom key that uniterm reserves for a window command, whether now or after a later
  /// window key is added. The menu is built from the registry, so a new window key joins the
  /// reserved set and fails here. Cmd-9 is the terminal's last tab and Cmd-0 its Actual Size. Both
  /// stay out of the reserved set, since each applet's keys apply only while its pane has focus.
  func testNoImageViewerZoomKeyIsReserved() throws {
    let registry = CommandRegistry()

    for set in BuiltInApplets.commandSets { registry.register(set) }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    let reserved = menu.reservedKeys()
    let viewer = try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "image-viewer" })

    for command in viewer.commands {
      guard let key = command.key else { continue }

      XCTAssertFalse(reserved.contains(key), command.title)
    }

    XCTAssertEqual(viewer.commands.compactMap(\.key).count, 4)
  }
}
