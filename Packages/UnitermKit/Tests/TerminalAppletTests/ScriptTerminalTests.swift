import AppKit
import AppletKit
import Preferences
import ScriptHost
import ScriptWire
import XCTest

@testable import TerminalApplet
@testable import WindowKit

/// A script's calls against real terminal applets on a fake engine, behind a real window set. These
/// prove what the window layer's own fakes cannot: that a terminal in shell mode takes a tab in the
/// named directory, that a terminal running one program refuses, and that a terminal owns its
/// input, so a script cannot send to it. They cannot prove a real shell starts.
@MainActor
final class ScriptTerminalTests: XCTestCase {
  private var suite = ""
  private var windows: WindowSet?

  override func tearDown() async throws {
    for controller in windows?.controllers ?? [] {
      controller.window?.close()
    }

    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  }

  private func scripting(engine: FakeEngine) throws
    -> (WindowScripting, ScriptPaneReference, TerminalApplet)
  {
    suite = "uniterm-script-terminal-\(UUID().uuidString)"

    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    let appearance = AppearanceController(store: store)
    var first: TerminalApplet?

    let makeApplet: AppletFactory = { choice, directory in
      let applet: TerminalApplet

      switch choice {
      case .terminalShell:
        applet = TerminalApplet(
          engine: engine, workingDirectory: directory, directoryExists: { _ in true })

      case .terminalProgram(let command):
        applet = try TerminalApplet(
          engine: engine, program: command, workingDirectory: directory,
          directoryExists: { _ in true })

      default:
        throw AppletRestoreError.unsupported("this fixture builds terminals only")
      }

      if first == nil { first = applet }

      return applet
    }

    let set = WindowSet(
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          makeApplet: makeApplet)
      })

    windows = set

    let controller = try set.open()
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    let pane = ScriptPaneReference(
      window: controller.scriptWindowID, pane: controller.focusedPane.rawValue)

    return (
      WindowScripting(windows: set, directoryExists: { _ in true }), pane, try XCTUnwrap(first)
    )
  }

  /// Catches a tab that starts in the neighbour's directory when the call names another, and a tab
  /// reference that does not name the tab the terminal opened.
  func testAShellTerminalOpensATabInTheNamedDirectory() async throws {
    let engine = FakeEngine()
    let (scripting, pane, applet) = try scripting(engine: engine)

    let reply = try await scripting.openTab(pane: pane, directory: "/synthetic/tab")

    XCTAssertEqual(
      engine.sessions.map { $0.launch.workingDirectory }, [NSHomeDirectory(), "/synthetic/tab"])
    XCTAssertEqual(applet.tabCount, 2)

    guard case .record(let fields) = reply, case .integer(let number)? = fields["tab"] else {
      return XCTFail("the reply is not a tab reference: \(reply)")
    }

    let controller = try XCTUnwrap(windows?.controller(forScriptWindow: pane.window))

    XCTAssertEqual(controller.scriptTabNumbers.tab(for: number), applet.publishedTabs.selected)
  }

  /// Catches a tab that starts in the working directory of whatever runs the script. With no
  /// directory named, the tab starts where the terminal's selected tab reports, through the applet
  /// contract.
  func testATabWithNoDirectoryStartsWhereTheTerminalReports() async throws {
    let engine = FakeEngine()
    let (scripting, pane, applet) = try scripting(engine: engine)

    engine.sessions[0].onEvent?(.workingDirectoryChanged("/synthetic/reported"))

    XCTAssertEqual(applet.currentDirectory, "/synthetic/reported")

    _ = try await scripting.openTab(pane: pane, directory: nil)

    XCTAssertEqual(engine.sessions.last?.launch.workingDirectory, "/synthetic/reported")
    XCTAssertNotEqual(
      engine.sessions.last?.launch.workingDirectory, FileManager.default.currentDirectoryPath)
  }

  /// Catches a terminal that runs one program being given a second shell. Program mode never opens
  /// another tab, and the refusal starts nothing.
  func testAProgramTerminalRefusesATab() async throws {
    let engine = FakeEngine()
    let (scripting, pane, applet) = try scripting(engine: engine)
    let controller = try XCTUnwrap(windows?.controllers.first)

    let program = try XCTUnwrap(
      controller.openPane(
        .terminalProgram(command: "tail -f log"), axis: .row, from: controller.focusedPane))
    let programPane = ScriptPaneReference(window: pane.window, pane: program.rawValue)
    let sessions = engine.sessions.count

    XCTAssertEqual(applet.tabCount, 1)

    do {
      _ = try await scripting.openTab(pane: programPane, directory: nil)
      XCTFail("a program terminal opened a tab")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
      XCTAssertTrue(error.text.contains("cannot open another tab"), error.text)
    }

    XCTAssertEqual(engine.sessions.count, sessions)
  }

  /// Catches a terminal that a script can type into. A terminal owns its input, so a send is
  /// refused before any content is written.
  func testATerminalRefusesSentContent() async throws {
    let engine = FakeEngine()
    let (scripting, pane, applet) = try scripting(engine: engine)

    let owner: any Applet = applet

    XCTAssertTrue(owner is any InputOwning)

    do {
      try scripting.prepareSend(to: pane)
      XCTFail("a send to a terminal was prepared")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
      XCTAssertTrue(error.text.contains("owns this pane's input"), error.text)
    }
  }

  /// Catches a script that opens a terminal beside a terminal and gets the neighbour's directory
  /// through anything but the applet contract. The new terminal starts in the directory the first
  /// one reports.
  func testANewTerminalStartsWhereItsNeighbourReports() async throws {
    let engine = FakeEngine()
    let (scripting, pane, _) = try scripting(engine: engine)

    engine.sessions[0].onEvent?(.workingDirectoryChanged("/synthetic/reported"))

    _ = try await scripting.openPane(kind: "terminal", beside: pane, axis: nil, directory: nil)

    XCTAssertEqual(engine.sessions.last?.launch.workingDirectory, "/synthetic/reported")
  }
}
