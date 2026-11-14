import AppKit
import AppletKit
import GeoData
import LayoutKit
import PaneModel
import Preferences
import StatusKit
import Theme
import XCTest

@testable import PlaceSearch
@testable import WindowKit

/// A view that can hold the keyboard, as a terminal does.
@MainActor
private final class KeyboardTarget: NSView {
  override var acceptsFirstResponder: Bool { true }
}

private struct ProgramRefused: LocalizedError {
  var errorDescription: String? { "the program was refused" }
}

/// The launcher's rules, apart from any view.
final class LauncherModelTests: XCTestCase {
  /// Catches a filter that is case sensitive or keeps stray space, so typing "RUNNING" or "term "
  /// would show nothing.
  func testTheFilterMatchesNamesIgnoringCaseAndSpace() {
    var model = LauncherModel()
    XCTAssertEqual(
      model.visible.map(\.kind),
      [.terminal, .program, .dataViewer, .mapViewer, .browser, .imageViewer, .textViewer])

    model.filter = "RUNNING"
    XCTAssertEqual(model.visible.map(\.kind), [.program])

    model.filter = "  term "
    XCTAssertEqual(model.visible.map(\.kind), [.terminal, .program])

    model.filter = "zzz"
    XCTAssertTrue(model.visible.isEmpty)
    XCTAssertNil(model.selection)
  }

  /// Catches a selection that stays on a hidden row, so Return would open an applet the list does
  /// not show.
  func testAFilteredOutSelectionFallsToTheFirstVisibleRow() {
    var model = LauncherModel()
    model.select(.terminal)
    model.filter = "running"
    XCTAssertEqual(model.selection?.kind, .program)

    model.filter = ""
    XCTAssertEqual(model.selection?.kind, .terminal)

    model.select(.program)
    model.backToTerminal()
    XCTAssertEqual(model.selection?.kind, .terminal)
  }

  /// Catches arrows that stop at the ends or step off the list. The selection wraps, as a menu
  /// does, and an empty list has no selection to move.
  func testTheSelectionWrapsAtBothEnds() {
    var model = LauncherModel()
    XCTAssertEqual(model.selection?.kind, .terminal)

    model.move(by: 1)
    XCTAssertEqual(model.selection?.kind, .program)

    model.move(by: 1)
    XCTAssertEqual(model.selection?.kind, .dataViewer)

    model.move(by: 1)
    XCTAssertEqual(model.selection?.kind, .mapViewer)

    model.move(by: 1)
    XCTAssertEqual(model.selection?.kind, .browser)

    model.move(by: 1)
    XCTAssertEqual(model.selection?.kind, .imageViewer)

    model.move(by: 1)
    XCTAssertEqual(model.selection?.kind, .textViewer)

    model.move(by: 1)
    XCTAssertEqual(model.selection?.kind, .terminal)

    model.move(by: -1)
    XCTAssertEqual(model.selection?.kind, .textViewer)

    model.filter = "zzz"
    model.move(by: 1)
    XCTAssertNil(model.selection)
  }

  /// Catches a number key that counts all entries and not the visible ones, or that picks past
  /// the end.
  func testANumberPicksTheNthVisibleRow() {
    var model = LauncherModel()
    XCTAssertTrue(model.pick(number: 2))
    XCTAssertEqual(model.selection?.kind, .program)

    XCTAssertTrue(model.pick(number: 1))
    XCTAssertEqual(model.selection?.kind, .terminal)

    model.filter = "running"
    XCTAssertTrue(model.pick(number: 1))
    XCTAssertEqual(model.selection?.kind, .program)
    XCTAssertFalse(model.pick(number: 2))
    XCTAssertFalse(model.pick(number: 0))
  }

  /// Catches a command field that shows for the terminal, or a keyboard that stays in the filter
  /// while a command is wanted.
  func testTheProgramRowOwnsTheCommandFieldAndTheKeyboard() {
    var model = LauncherModel()
    XCTAssertEqual(model.focus, .filter)
    XCTAssertFalse(model.showsCommand)

    model.select(.program)
    XCTAssertEqual(model.focus, .command)
    XCTAssertTrue(model.showsCommand)
  }

  /// Catches a data viewer row that opens a terminal, or one that asks for a command.
  func testTheDataViewerEntryChoosesTheDataViewerWithoutACommand() throws {
    var model = LauncherModel()
    model.select(.dataViewer)

    XCTAssertEqual(try model.choice().get(), .dataViewer)
    XCTAssertFalse(model.showsCommand)
    XCTAssertEqual(model.focus, .filter)
  }

  /// Catches a map viewer row that opens a terminal, or one that asks for a command.
  func testTheMapViewerEntryChoosesTheMapViewerWithoutACommand() throws {
    var model = LauncherModel()
    model.select(.mapViewer)

    XCTAssertEqual(try model.choice().get(), .mapViewer(region: nil))
    XCTAssertFalse(model.showsCommand)
    XCTAssertEqual(model.focus, .filter)
    XCTAssertEqual(model.selection?.kind.accessibilityIdentifier, "launcher-map-viewer")
  }

  /// Catches a browser row that opens a terminal, or one that asks for a command or a place.
  func testTheBrowserEntryChoosesTheBrowserWithoutAnyField() throws {
    var model = LauncherModel()
    model.offersPlace = true
    model.select(.browser)

    XCTAssertEqual(try model.choice().get(), .browser)
    XCTAssertFalse(model.showsCommand)
    XCTAssertFalse(model.showsPlace)
    XCTAssertEqual(model.focus, .filter)
    XCTAssertEqual(model.selection?.kind.accessibilityIdentifier, "launcher-browser")
  }

  /// Catches an empty program that opens, and a command that keeps stray space.
  func testAProgramNeedsATrimmedCommand() throws {
    var model = LauncherModel()
    XCTAssertEqual(try model.choice().get(), .terminalShell)

    model.select(.program)
    model.command = " \n "
    XCTAssertThrowsError(try model.choice().get()) { error in
      XCTAssertEqual(error as? LauncherRefusal, LauncherRefusal(reason: "The command is empty."))
    }

    model.command = "  tail -f log \n"
    XCTAssertEqual(try model.choice().get(), .terminalProgram(command: "tail -f log"))
  }
}

/// The launcher in a window.
@MainActor
final class LauncherTests: XCTestCase {
  private var controller: MainWindowController!
  private var made: [FakeApplet] = []
  private var suite = ""
  private var layoutChanges = 0

  /// The choice and directory each new applet was asked for, oldest first.
  private var requests: [(choice: AppletChoice, directory: String?)] = []

  override func setUp() async throws {
    suite = "uniterm-launcher-test-\(UUID().uuidString)"
    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)

    controller = try MainWindowController(
      appearance: AppearanceController(store: store), settings: store
    ) { [unowned self] choice, directory in
      requests.append((choice, directory))

      if case .terminalProgram(let command) = choice, command.hasPrefix("refuse") {
        throw ProgramRefused()
      }

      let applet = FakeApplet()
      applet.segments = [AppletSegment(text: "from the new applet")]
      made.append(applet)
      return applet
    }

    controller.onLayoutChange = { [unowned self] in layoutChanges += 1 }
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    controller.window?.orderFrontRegardless()
  }

  override func tearDown() async throws {
    controller.window?.close()
    controller = nil
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  }

  private func openLauncher() throws -> (pane: NodeID, launcher: LauncherApplet) {
    let pane = try XCTUnwrap(controller.openLauncher(axis: .row))
    let launcher = try XCTUnwrap(controller.paneArea.applet(for: pane) as? LauncherApplet)
    return (pane, launcher)
  }

  private func commandKey(_ digit: String) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: digit,
        charactersIgnoringModifiers: digit, isARepeat: false, keyCode: 0))
  }

  private func click(_ row: LauncherRowView, count: Int) throws {
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: count, pressure: 1))

    row.mouseDown(with: event)
  }

  private func send(_ selector: Selector, from field: NSTextField, in view: LauncherView) {
    XCTAssertTrue(view.control(field, textView: NSTextView(), doCommandBy: selector))
  }

  // MARK: Opening

  /// Catches a split that still waits for a dialog, or a launcher that does not take the keyboard
  /// as the pane appears.
  func testSplittingShowsALauncherThatHoldsTheKeyboardInItsFilter() throws {
    controller.dispatch(.splitRight)

    XCTAssertNil(controller.window?.attachedSheet)
    XCTAssertEqual(controller.paneIDs.count, 2)

    let launcher = try XCTUnwrap(
      controller.paneArea.applet(for: controller.focusedPane) as? LauncherApplet)
    XCTAssertTrue(launcher.launcher.isFocused(launcher.launcher.filterField))
    XCTAssertFalse(launcher.isRunningSomething)
  }

  /// Catches a launcher that makes a new pane, so the pane's ID changes when an applet is chosen
  /// and anything that named the pane loses it.
  func testChoosingReplacesTheLauncherInTheSamePane() throws {
    let (pane, launcher) = try openLauncher()
    let frame = controller.paneArea.paneView(for: pane)?.frame
    controller.paneArea.apply(.mocha)
    layoutChanges = 0

    send(
      #selector(NSResponder.insertNewline(_:)), from: launcher.launcher.filterField,
      in: launcher.launcher)

    XCTAssertEqual(controller.paneIDs.count, 2)
    XCTAssertEqual(controller.focusedPane, pane)
    XCTAssertTrue(controller.paneArea.applet(for: pane) === made.last)
    XCTAssertTrue(made.last?.started ?? false)
    XCTAssertEqual(controller.paneArea.paneView(for: pane)?.frame, frame)
    XCTAssertNil(launcher.launcher.superview)
    XCTAssertGreaterThan(layoutChanges, 0, "the saved layout was not told the pane changed")
    XCTAssertTrue(
      controller.contentController.statusBar.segments.contains { $0.text == "from the new applet" },
      "the status bar still shows the launcher")
    XCTAssertEqual(made.last?.palettes.last, .mocha, "the new applet never got the palette")
  }

  // MARK: Directory

  /// Catches a split that leaves the new pane's directory to a library. The pane the launcher was
  /// opened from reports /tmp, so the shell is asked to start there. Program mode gets it too.
  func testWhatTheLauncherOpensStartsInTheDirectoryOfThePaneItWasOpenedFrom() throws {
    made[0].currentDirectory = "/tmp"

    var (_, launcher) = try openLauncher()
    var view = launcher.launcher
    send(#selector(NSResponder.insertNewline(_:)), from: view.filterField, in: view)

    XCTAssertEqual(requests.last?.choice, .terminalShell)
    XCTAssertEqual(requests.last?.directory, "/tmp")

    made.last?.currentDirectory = "/tmp"
    (_, launcher) = try openLauncher()
    view = launcher.launcher
    view.choose(.program)
    view.setCommand("htop")
    send(#selector(NSResponder.insertNewline(_:)), from: view.commandField, in: view)

    XCTAssertEqual(requests.last?.choice, .terminalProgram(command: "htop"))
    XCTAssertEqual(requests.last?.directory, "/tmp")
  }

  /// Catches a launcher that invents a directory when the pane it was opened from has none.
  func testAPaneWithoutADirectoryPassesNone() throws {
    let (_, launcher) = try openLauncher()
    send(
      #selector(NSResponder.insertNewline(_:)), from: launcher.launcher.filterField,
      in: launcher.launcher)

    XCTAssertEqual(requests.last?.choice, .terminalShell)
    XCTAssertNil(requests.last?.directory)
  }

  /// Catches an Applet default that is not nil, which would make every applet claim a directory.
  func testAnAppletSaysNothingAboutDirectoriesByDefault() {
    final class Quiet: Applet {
      let typeID = "quiet"
      let view = NSView()
      let title = ""
      let segments: [AppletSegment] = []
      let publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: "Quiet"))
      let isRunningSomething = false
      weak var host: (any AppletHost)?
      func start(origin: StartOrigin) {}
      func close() {}
      func detach() {}
      func reattach() {}
      func focus() {}
      func describe() -> AppletDescription {
        AppletDescription(type: "quiet", version: 1, payload: .null)
      }
    }

    let applet: any Applet = Quiet()
    XCTAssertNil(applet.currentDirectory)
  }

  /// Catches a launcher whose saved form drops the directory, so a relaunch would open elsewhere.
  /// The launcher is saved with its directory, and the restored one asks for it again.
  func testALauncherKeepsItsDirectoryAcrossASave() throws {
    made[0].currentDirectory = "/tmp"
    let (_, launcher) = try openLauncher()

    let saved = launcher.describe()
    XCTAssertEqual(saved.payload, .object(["directory": .string("/tmp")]))

    let restored = try LauncherApplet(restoring: saved)
    XCTAssertEqual(restored.currentDirectory, "/tmp")
    XCTAssertEqual(restored.describe(), saved)

    let old = AppletDescription(type: "launcher", version: 1, payload: .object([:]))
    XCTAssertNil(try LauncherApplet(restoring: old).currentDirectory)
  }

  /// Catches a restored launcher that forgets where it was opened from.
  func testARestoredLauncherOpensInItsSavedDirectory() throws {
    let restored = try restoredController(
      launcher: AppletDescription(
        type: "launcher", version: 1, payload: .object(["directory": .string("/var")])))
    defer { restored.window?.close() }

    let launcher = try XCTUnwrap(
      restored.paneArea.applet(for: NodeID(rawValue: 2)) as? LauncherApplet)
    launcher.launcher.open()

    XCTAssertEqual(requests.last?.directory, "/var")
  }

  /// Catches a program that opens with no command, and a refusal that closes the launcher or
  /// hides its reason.
  func testAnEmptyOrRefusedCommandKeepsTheLauncherOpenWithTheReason() throws {
    let (pane, launcher) = try openLauncher()
    let view = launcher.launcher

    view.choose(.program)
    send(#selector(NSResponder.insertNewline(_:)), from: view.commandField, in: view)
    XCTAssertEqual(view.model.refusal?.reason, "The command is empty.")
    XCTAssertTrue(controller.paneArea.applet(for: pane) === launcher)

    view.setCommand("refuse this")
    XCTAssertNil(view.model.refusal)

    send(#selector(NSResponder.insertNewline(_:)), from: view.commandField, in: view)
    XCTAssertEqual(view.model.refusal?.reason, "the program was refused")
    XCTAssertTrue(controller.paneArea.applet(for: pane) === launcher)
    XCTAssertTrue(view.isFocused(view.commandField))

    view.setCommand("htop")
    send(#selector(NSResponder.insertNewline(_:)), from: view.commandField, in: view)
    XCTAssertTrue(controller.paneArea.applet(for: pane) === made.last)
  }

  /// Catches Return with nothing listed, which must not open anything.
  func testReturnWithNoMatchOpensNothing() throws {
    let (pane, launcher) = try openLauncher()
    let view = launcher.launcher

    view.setFilter("zzz")
    send(#selector(NSResponder.insertNewline(_:)), from: view.filterField, in: view)

    XCTAssertTrue(controller.paneArea.applet(for: pane) === launcher)
    XCTAssertNil(view.model.refusal)
  }

  // MARK: Keyboard

  /// Catches a program row that leaves the keyboard in the filter, and a way back that leaves it
  /// in the command field. The arrows move the selection while the keyboard stays in a field.
  func testSelectingProgramMovesTheKeyboardToTheCommandFieldAndBack() throws {
    let (_, launcher) = try openLauncher()
    let view = launcher.launcher

    send(#selector(NSResponder.moveDown(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .program)
    XCTAssertTrue(view.isFocused(view.commandField))

    send(#selector(NSResponder.moveDown(_:)), from: view.commandField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .dataViewer)
    XCTAssertTrue(view.isFocused(view.filterField))

    send(#selector(NSResponder.moveDown(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .mapViewer)

    send(#selector(NSResponder.moveDown(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .browser)

    send(#selector(NSResponder.moveDown(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .imageViewer)

    send(#selector(NSResponder.moveDown(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .textViewer)

    send(#selector(NSResponder.moveDown(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .terminal)
    XCTAssertTrue(view.isFocused(view.filterField))

    send(#selector(NSResponder.moveUp(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .textViewer)

    send(#selector(NSResponder.moveUp(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .imageViewer)

    send(#selector(NSResponder.moveUp(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .browser)

    send(#selector(NSResponder.moveUp(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .mapViewer)

    send(#selector(NSResponder.moveUp(_:)), from: view.filterField, in: view)
    XCTAssertEqual(view.model.selection?.kind, .dataViewer)

    send(#selector(NSResponder.moveUp(_:)), from: view.filterField, in: view)
    XCTAssertTrue(view.isFocused(view.commandField))
  }

  /// Catches Escape that skips a level. In the command field it goes back to the filter with the
  /// terminal selected. In the filter it closes the pane, and nothing goes on the undo stack.
  func testEscapeGoesBackThenClosesTheEmptyPane() throws {
    let (pane, launcher) = try openLauncher()
    let view = launcher.launcher

    view.choose(.program)
    send(#selector(NSResponder.cancelOperation(_:)), from: view.commandField, in: view)

    XCTAssertEqual(view.model.selection?.kind, .terminal)
    XCTAssertTrue(view.isFocused(view.filterField))
    XCTAssertEqual(controller.paneIDs.count, 2)

    send(#selector(NSResponder.cancelOperation(_:)), from: view.filterField, in: view)

    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertFalse(controller.paneIDs.contains(pane))
    XCTAssertTrue(controller.ledger.entries.isEmpty)
  }

  /// Catches Cmd-W on a launcher that records an undo entry for a pane with nothing to restore.
  func testClosingALauncherAddsNoUndoEntry() throws {
    _ = try openLauncher()

    controller.dispatch(.close)

    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertTrue(controller.ledger.entries.isEmpty)
  }

  /// Catches Command-digit reaching the Window menu's tab items instead of the launcher. The
  /// window asks its views before the menu, so the launcher must take the key there. It takes it
  /// only while the keyboard is in the launcher.
  func testCommandDigitsGoToTheLauncherBeforeTheMenu() throws {
    let (_, launcher) = try openLauncher()
    let view = launcher.launcher
    let window = try XCTUnwrap(controller.window)

    XCTAssertTrue(window.performKeyEquivalent(with: try commandKey("2")))
    XCTAssertEqual(view.model.selection?.kind, .program)
    XCTAssertTrue(view.isFocused(view.commandField))

    XCTAssertTrue(window.performKeyEquivalent(with: try commandKey("1")))
    XCTAssertEqual(view.model.selection?.kind, .terminal)

    XCTAssertTrue(window.performKeyEquivalent(with: try commandKey("8")))
    XCTAssertEqual(view.model.selection?.kind, .terminal)

    window.makeFirstResponder(nil)
    XCTAssertFalse(view.performKeyEquivalent(with: try commandKey("2")))
    XCTAssertEqual(view.model.selection?.kind, .terminal)
  }

  /// Catches a launcher that takes Command-digit while the keyboard is in another pane. A terminal
  /// pane beside it must keep its tab keys, so the launcher must leave the key to the menu.
  func testCommandDigitsAreLeftAloneWhileAnotherPaneHasTheKeyboard() throws {
    let (_, launcher) = try openLauncher()
    let view = launcher.launcher
    let window = try XCTUnwrap(controller.window)

    let other = try XCTUnwrap(controller.paneArea.applet(for: controller.paneIDs[0]) as? FakeApplet)
    let field = KeyboardTarget()
    other.view.addSubview(field)
    XCTAssertTrue(window.makeFirstResponder(field))
    XCTAssertFalse(view.hasKeyboard)

    XCTAssertFalse(window.performKeyEquivalent(with: try commandKey("2")))
    XCTAssertEqual(view.model.selection?.kind, .terminal)
  }

  // MARK: Mouse

  /// Catches a click that opens at once, and a double click that only selects.
  func testClickSelectsAndDoubleClickOpens() throws {
    let (pane, launcher) = try openLauncher()
    let view = launcher.launcher
    let program = try XCTUnwrap(view.rows.first { $0.kind == .program })

    try click(program, count: 1)
    XCTAssertEqual(view.model.selection?.kind, .program)
    XCTAssertTrue(view.isFocused(view.commandField))
    XCTAssertTrue(controller.paneArea.applet(for: pane) === launcher)

    view.setCommand("htop")
    try click(program, count: 2)

    XCTAssertTrue(controller.paneArea.applet(for: pane) === made.last)
  }

  // MARK: Layout

  /// Catches parts that start or end at different x positions. The title, the subtitle, the
  /// filter box, and every row share one left edge and one right edge. The command box indents
  /// to the row text and ends where the list ends.
  func testTheLauncherPartsShareOneLeftEdge() throws {
    let (_, launcher) = try openLauncher()
    let view = launcher.launcher
    view.choose(.program)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()

    // A label's frame reaches 2 points past its text on each side. Auto Layout lines up the
    // alignment rect, which is the text's own edge and the one the eye sees.
    func frame(_ part: NSView) -> NSRect {
      let rect = part.alignmentRect(forFrame: part.bounds)
      return view.convert(rect, from: part)
    }

    let rows = view.rows.map(frame)
    XCTAssertEqual(rows.count, LauncherEntry.all.count)
    XCTAssertGreaterThan(rows[0].width, 200)

    let filter = frame(view.filterBox)
    for (name, part) in [
      ("title", frame(view.titleLabel)), ("subtitle", frame(view.subtitleLabel)),
      ("first row", rows[0]), ("second row", rows[1]),
    ] {
      XCTAssertEqual(part.minX, filter.minX, accuracy: 0.5, "\(name) starts off the filter's edge")
      XCTAssertEqual(part.maxX, filter.maxX, accuracy: 0.5, "\(name) ends off the filter's edge")
    }

    let command = frame(view.commandBox)
    XCTAssertEqual(command.minX, filter.minX + LauncherRowView.textLeading, accuracy: 0.5)
    XCTAssertEqual(command.maxX, filter.maxX, accuracy: 0.5)
  }

  /// Catches a launcher whose constraints cannot all hold in a pane that is tiny or has no size
  /// yet. AppKit logs each unsatisfiable set and breaks one constraint. The test checks that every
  /// required constraint holds after layout, and first proves the check sees a deliberate conflict.
  /// At the minimum pane size the card is taller than the pane. It must stay top-aligned with its title in view, and the stage must clip it so it never draws
  /// over the hint bar.
  func testTinyAndEmptyPanesLayOutWithoutConflictsAndClipTheCard() throws {
    let view = LauncherView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.choose(.program)

    func lay(out size: NSSize) {
      window.setContentSize(size)
      view.frame = NSRect(origin: .zero, size: size)
      view.layoutSubtreeIfNeeded()
    }

    let probe = NSView()
    probe.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(probe)
    probe.widthAnchor.constraint(equalToConstant: 10).isActive = true
    probe.widthAnchor.constraint(equalToConstant: 20).isActive = true
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(
      unsatisfiedRequiredConstraints(under: view).isEmpty, "the check cannot see a conflict")
    probe.removeFromSuperview()

    for size in [NSSize.zero, NSSize(width: 200, height: 100), NSSize(width: 380, height: 60)] {
      lay(out: size)
      let broken = unsatisfiedRequiredConstraints(under: view)
      XCTAssertTrue(broken.isEmpty, "\(size): \(broken)")
    }

    lay(out: NSSize(width: 200, height: 100))

    let title = view.convert(view.titleLabel.bounds, from: view.titleLabel)
    XCTAssertGreaterThanOrEqual(title.minY, 0, "the title is pushed out of the pane")
    XCTAssertEqual(view.stage.layer?.masksToBounds, true, "the card is not clipped to its stage")
  }

  // MARK: Restored windows

  /// Builds a window that restores `launcher` beside a fake pane, as a relaunch does.
  private func restoredController(launcher: AppletDescription) throws -> MainWindowController {
    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)

    let saved = savedWindow(
      tree: savedSplit(
        3, .row,
        [(savedPane(1), 0.5), (.pane(id: NodeID(rawValue: 2), applet: launcher), 0.5)]),
      focus: 1, mark: 3)

    let restorer: AppletRestorer = { _ in FakeApplet() }
    let factory: AppletFactory = { [unowned self] choice, directory in
      requests.append((choice, directory))

      let applet = FakeApplet()
      made.append(applet)
      return applet
    }

    return try MainWindowController(
      appearance: AppearanceController(store: store), settings: store,
      restoring: RestoredWindow(saved: saved), restoreApplet: restorer, makeApplet: factory)
  }

  /// Catches a restored launcher that nobody wired, so choosing in it does nothing. Only the
  /// window's own hosting step connects a launcher to the pane.
  func testARestoredLauncherReplacesItselfWhenChosen() throws {
    let restored = try restoredController(
      launcher: AppletDescription(type: "launcher", version: 1, payload: .object([:])))
    defer { restored.window?.close() }

    let pane = NodeID(rawValue: 2)
    let launcher = try XCTUnwrap(restored.paneArea.applet(for: pane) as? LauncherApplet)

    launcher.launcher.open()

    XCTAssertTrue(restored.paneArea.applet(for: pane) === made.last)
    XCTAssertEqual(restored.paneIDs.count, 2)
  }

  /// Catches a launcher saved by a newer build that is read anyway, or rewritten. The pane
  /// becomes a placeholder that names the newer version and writes back the exact bytes.
  func testANewerLauncherBecomesAPlaceholderThatKeepsItsBytes() throws {
    let raw = #"{"type":"launcher","version":2,  "payload":{"pinned":[ 1,2 ]}}"#
    let newer = AppletDescription(
      type: "launcher", version: 2, payload: .null, verbatim: Data(raw.utf8))

    let restored = try restoredController(launcher: newer)
    defer { restored.window?.close() }

    let applet = try XCTUnwrap(restored.paneArea.applet(for: NodeID(rawValue: 2)))
    XCTAssertEqual(applet.typeID, "placeholder")
    XCTAssertEqual(applet.describe().verbatim, Data(raw.utf8))

    func texts(in view: NSView) -> [String] {
      let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
      return own + view.subviews.flatMap { texts(in: $0) }
    }

    XCTAssertTrue(
      texts(in: applet.view).contains { $0.contains("newer version") },
      "\(texts(in: applet.view))")
  }

  // MARK: Saved layout

  /// Catches a launcher that restores as an unavailable pane, or a newer one that is read anyway.
  func testALauncherRestoresAsALauncher() throws {
    let (_, launcher) = try openLauncher()
    let description = launcher.describe()

    let restored = try LauncherApplet(restoring: description)
    XCTAssertEqual(restored.describe(), description)

    let newer = AppletDescription(
      type: "launcher", version: LauncherApplet.currentVersion + 1, payload: .object([:]))
    XCTAssertThrowsError(try LauncherApplet(restoring: newer))

    let result = PaneRestoration.applet(for: description) { _ in throw ProgramRefused() }
    XCTAssertFalse(result.isPlaceholder)
    XCTAssertTrue(result.applet is LauncherApplet)
  }
}

/// Every required constraint under `root` whose two sides disagree after layout, as a description.
/// A required constraint that does not hold is what AppKit logs as unsatisfiable and breaks. The
/// log goes nowhere a test can read, so this checks the frames. It skips an attribute it cannot
/// measure, such as a baseline.
@MainActor
private func unsatisfiedRequiredConstraints(under root: NSView) -> [String] {
  func rect(of item: AnyObject?) -> NSRect? {
    if let view = item as? NSView {
      return root.convert(view.alignmentRect(forFrame: view.bounds), from: view)
    }

    if let guide = item as? NSLayoutGuide, let owner = guide.owningView {
      return root.convert(guide.frame, from: owner)
    }

    return nil
  }

  func value(_ attribute: NSLayoutConstraint.Attribute, _ rect: NSRect) -> CGFloat? {
    switch attribute {
    case .leading, .left: return rect.minX
    case .trailing, .right: return rect.maxX
    case .top: return rect.minY
    case .bottom: return rect.maxY
    case .width: return rect.width
    case .height: return rect.height
    case .centerX: return rect.midX
    case .centerY: return rect.midY
    default: return nil
    }
  }

  func constraints(in view: NSView) -> [NSLayoutConstraint] {
    view.constraints + view.subviews.flatMap { constraints(in: $0) }
  }

  var broken: [String] = []

  for constraint in constraints(in: root)
  where constraint.isActive && constraint.priority == .required
    && String(describing: type(of: constraint)) != "NSContentSizeLayoutConstraint"
  {
    guard let first = rect(of: constraint.firstItem),
      let left = value(constraint.firstAttribute, first)
    else { continue }

    var right: CGFloat = 0

    if constraint.secondItem != nil {
      guard let second = rect(of: constraint.secondItem),
        let measured = value(constraint.secondAttribute, second)
      else { continue }

      right = measured
    }

    let difference = left - (constraint.multiplier * right + constraint.constant)

    let holds: Bool
    switch constraint.relation {
    case .equal: holds = abs(difference) <= 0.5
    case .greaterThanOrEqual: holds = difference >= -0.5
    case .lessThanOrEqual: holds = difference <= 0.5
    @unknown default: holds = true
    }

    if !holds {
      broken.append("\(constraint) is off by \(difference)")
    }
  }

  return broken
}

/// A place searcher that answers from the test.
@MainActor
private final class FakePlaceSearch: PlaceSearching {
  var onUpdate: ((Result<[PlaceSuggestion], PlaceSearchFailure>) -> Void)?
  var region: GeoRegion?
  private(set) var cancelled = false

  func search(_ query: String) {}

  func region(for suggestion: PlaceSuggestion) async -> Result<GeoRegion, PlaceSearchFailure> {
    region.map { .success($0) } ?? .failure(.notFound)
  }

  func cancel() { cancelled = true }
}

/// The launcher's place field: it shows only for the map viewer, a pick opens the map there, and
/// the field never traps the keys the launcher needs.
@MainActor
final class LauncherPlaceTests: XCTestCase {
  private let paris = GeoRegion(
    center: GeoCoordinate(latitude: 48.85, longitude: 2.35),
    span: GeoSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))!

  private func launcher() -> (LauncherView, FakePlaceSearch, () -> [AppletChoice]) {
    let view = LauncherView()
    let search = FakePlaceSearch()
    var chosen: [AppletChoice] = []
    view.onChoose = { chosen.append($0) }
    view.offerPlaces(PlaceServices(search: { search }))

    return (view, search, { chosen })
  }

  private func key(_ view: LauncherView, _ selector: Selector) {
    guard let field = view.placeSearch?.field else { return XCTFail("no place field") }

    _ = view.placeSearch?.control(field, textView: NSTextView(), doCommandBy: selector)
  }

  /// Catches a place field that shows for another entry, or takes the keyboard when the app gave
  /// no search. Only the map viewer, in a launcher given a search, wants a place.
  func testThePlaceFieldIsOnlyForTheMapViewer() {
    var plain = LauncherModel()
    plain.select(.mapViewer)
    XCTAssertFalse(plain.showsPlace)
    XCTAssertEqual(plain.focus, .filter)

    let (view, _, _) = launcher()
    view.choose(.dataViewer)
    XCTAssertFalse(view.model.showsPlace)
    XCTAssertEqual(view.model.focus, .filter)

    view.choose(.mapViewer)
    XCTAssertTrue(view.model.showsPlace)
    XCTAssertEqual(view.model.focus, .place)
  }

  /// Catches a pick that opens the map at its default view, or a map that cannot open without a
  /// place. A picked place opens the map there. Return on an empty field opens it with no place.
  func testAPickOpensTheMapThereAndAnEmptyFieldOpensItPlain() async throws {
    let (view, search, chosen) = launcher()
    view.choose(.mapViewer)

    key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(chosen(), [.mapViewer(region: nil)])

    let place = try XCTUnwrap(view.placeSearch)
    place.setQuery("Paris")
    search.onUpdate?(.success([PlaceSuggestion(title: "Paris", subtitle: "France", token: 0)]))
    search.region = paris

    key(view, #selector(NSResponder.insertNewline(_:)))
    await place.pendingPick?.value

    XCTAssertEqual(chosen(), [.mapViewer(region: nil), .mapViewer(region: paris)])
  }

  /// Catches a place field that traps the launcher's keys. Up and Down with no suggestions move
  /// the launcher's selection, and Escape on an empty field goes back to the filter.
  func testTheLaunchersKeysPassThroughAnEmptyField() {
    let (view, _, _) = launcher()
    view.choose(.mapViewer)

    key(view, #selector(NSResponder.moveUp(_:)))
    XCTAssertEqual(view.model.selection?.kind, .dataViewer)

    view.choose(.mapViewer)
    key(view, #selector(NSResponder.cancelOperation(_:)))
    XCTAssertEqual(view.model.selection?.kind, .terminal)
    XCTAssertEqual(view.model.focus, .filter)
  }

  /// Catches a search left running after the launcher's pane is replaced or closed.
  func testClosingTheLauncherStopsItsSearch() {
    let applet = LauncherApplet(directory: nil)
    let search = FakePlaceSearch()
    applet.launcher.offerPlaces(PlaceServices(search: { search }))

    applet.close()

    XCTAssertTrue(search.cancelled)
  }
}
