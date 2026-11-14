import AppKit
import AppletKit
import Preferences
import StatusKit
import XCTest

@testable import TerminalApplet
@testable import WindowKit

/// An applet that is not a terminal and reports a directory, as an editor or a file browser would.
@MainActor
private final class DirectoryApplet: Applet {
  let typeID = "directory"
  let view = NSView()
  let title = "Directory"
  let segments: [AppletSegment] = []
  let publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: "Directory"))
  let isRunningSomething = false
  weak var host: (any AppletHost)?
  let currentDirectory: String?

  init(directory: String?) { currentDirectory = directory }

  func start(origin: StartOrigin) {}
  func close() {}
  func detach() {}
  func reattach() {}
  func focus() {}

  func describe() -> AppletDescription {
    AppletDescription(type: typeID, version: 1, payload: .null)
  }
}

/// A split in a real window with the terminal applet behind the factory, the way the app wires it.
@MainActor
final class SplitDirectoryTests: XCTestCase {
  private var suite = ""

  override func tearDown() async throws {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  }

  /// Builds a window whose first pane is a `DirectoryApplet`. Later panes are terminals on `engine`.
  private func window(
    reporting reported: String?, engine: FakeEngine
  ) throws -> MainWindowController {
    suite = "uniterm-split-directory-\(UUID().uuidString)"
    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    var first = true

    let controller = try MainWindowController(
      appearance: AppearanceController(store: store), settings: store
    ) { choice, requested in
      if first {
        first = false
        return DirectoryApplet(directory: reported)
      }

      switch choice {
      case .terminalShell:
        return TerminalApplet(engine: engine, workingDirectory: requested)

      case .terminalProgram(let command):
        return try TerminalApplet(engine: engine, program: command, workingDirectory: requested)

      case .dataViewer, .mapViewer, .browser, .imageViewer, .textViewer:
        throw AppletRestoreError.unsupported("this fixture builds terminals only")
      }
    }

    controller.window?.contentView?.layoutSubtreeIfNeeded()
    controller.window?.orderFrontRegardless()

    return controller
  }

  private func chooseTerminal(in controller: MainWindowController) throws {
    let pane = try XCTUnwrap(controller.openLauncher(axis: .row, from: controller.focusedPane))
    let launcher = try XCTUnwrap(controller.paneArea.applet(for: pane) as? LauncherApplet)
    launcher.launcher.open()
  }

  /// Catches a split that depends on libghostty's own record of the last terminal. The focused
  /// pane is not a terminal and reports /tmp, so only the applet contract can carry the directory
  /// to the engine.
  func testASplitFromAnyAppletStartsTheTerminalInItsDirectory() throws {
    let engine = FakeEngine()
    let controller = try window(reporting: "/tmp", engine: engine)
    defer { controller.window?.close() }

    try chooseTerminal(in: controller)

    XCTAssertEqual(engine.sessions.map { $0.launch.workingDirectory }, ["/tmp"])
  }

  /// Catches a split from a pane with no directory that starts wherever the app was launched.
  func testASplitFromAPaneWithNoDirectoryStartsInHome() throws {
    let engine = FakeEngine()
    let controller = try window(reporting: nil, engine: engine)
    defer { controller.window?.close() }

    try chooseTerminal(in: controller)

    XCTAssertEqual(engine.sessions.map { $0.launch.workingDirectory }, [NSHomeDirectory()])
  }

  /// Catches program mode that skips the directory the shell gets.
  func testProgramModeStartsInTheDirectoryToo() throws {
    let engine = FakeEngine()
    let controller = try window(reporting: "/tmp", engine: engine)
    defer { controller.window?.close() }

    let pane = try XCTUnwrap(controller.openLauncher(axis: .row, from: controller.focusedPane))
    let launcher = try XCTUnwrap(controller.paneArea.applet(for: pane) as? LauncherApplet)
    launcher.launcher.choose(.program)
    launcher.launcher.setCommand("htop")
    launcher.launcher.open()

    XCTAssertEqual(engine.sessions.map { $0.launch.workingDirectory }, ["/tmp"])
    XCTAssertEqual(engine.sessions.first?.launch.program, ["htop"])
  }
}
