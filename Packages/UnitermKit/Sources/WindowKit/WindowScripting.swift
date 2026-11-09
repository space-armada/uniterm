import AppKit
import AppletKit
import Foundation
import PaneModel
import ScriptHost
import ScriptWire
import StatusKit

/// The window side of the host API. It answers a script's calls about windows, panes, and tabs
/// from the live windows of one `WindowSet`.
///
/// Every function runs on the main actor, starts nothing that waits, and checks each argument
/// before it touches a window. A reference is looked up by its IDs in this launch. An ID that is
/// not open names nothing, so it can never name a different window, pane, or tab.
@MainActor
public final class WindowScripting: ScriptWindowAPI {
  /// The applets a script may start, by the kind name it passes.
  static let kinds: [(name: String, choice: AppletChoice)] = [
    ("terminal", .terminalShell),
    ("data-viewer", .dataViewer),
    ("map-viewer", .mapViewer(region: nil)),
    ("image-viewer", .imageViewer),
    ("text-viewer", .textViewer),
    ("browser", .browser),
  ]

  /// The longest title or directory reported for a pane, in UTF-8 bytes. Both come from programs.
  static let maxReportedBytes = 256

  private let windows: WindowSet
  private let directoryExists: @Sendable (String) -> Bool

  /// `directoryExists` decides whether a directory a script names is a folder here. It defaults to
  /// a stat that follows links, and a test replaces it. It runs off the main actor, since a stat
  /// on a hung network mount does not return.
  public init(
    windows: WindowSet,
    directoryExists: @escaping @Sendable (String) -> Bool = WindowScripting.isDirectory
  ) {
    self.windows = windows
    self.directoryExists = directoryExists
  }

  public nonisolated static func isDirectory(_ path: String) -> Bool {
    var info = stat()

    return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
  }

  // MARK: Lists

  public func listWindows() throws -> ScriptValue {
    .array(
      windows.controllers.map { controller in
        .record([
          "window": .integer(controller.scriptWindowID),
          "title": .string(Self.reported(controller.window?.title ?? "")),
          "key": .bool(controller.window?.isKeyWindow == true),
        ])
      })
  }

  public func listPanes(window: UInt64) throws -> ScriptValue {
    guard let controller = windows.controller(forScriptWindow: window) else { return .null }

    var panes: [ScriptValue] = []

    for pane in controller.paneIDs {
      guard let applet = controller.paneArea.applet(for: pane) else { continue }

      var fields: [String: ScriptValue] = [
        "window": .integer(window),
        "pane": .integer(pane.rawValue),
        "applet": .string(applet.typeID),
        "title": .string(Self.reported(applet.title)),
        "focused": .bool(pane == controller.focusedPane),
        "tabs": .array(tabs(of: applet, pane: pane, in: controller)),
      ]

      if let directory = applet.currentDirectory {
        fields["directory"] = .string(Self.reported(directory))
      }

      panes.append(.record(fields))
    }

    return .array(panes)
  }

  private func tabs(
    of applet: any Applet, pane: NodeID, in controller: MainWindowController
  ) -> [ScriptValue] {
    let tabs = applet.publishedTabs

    return tabs.all.map { tab in
      .record([
        "window": .integer(controller.scriptWindowID),
        "pane": .integer(pane.rawValue),
        "tab": .integer(controller.scriptTabNumbers.number(for: tab.id)),
        "title": .string(Self.reported(tab.title)),
        "selected": .bool(tab.id == tabs.selected),
      ])
    }
  }

  // MARK: Opening

  public func openPane(
    kind: String, beside: ScriptPaneReference, axis: ScriptAxis?, directory: String?
  ) async throws -> ScriptValue {
    guard let choice = Self.kinds.first(where: { $0.name == kind })?.choice else {
      let names = Self.kinds.map { ":\($0.name)" }.joined(separator: ", ")

      throw ScriptCallError.badArgument("the applet kind is not known. The kinds are \(names)")
    }

    if let directory {
      guard choice != .browser else {
        throw ScriptCallError.badArgument("a browser has no directory")
      }

      try await checkDirectory(directory)
    }

    let (controller, pane, _) = try resolve(beside)

    guard controller.paneActionsEnabled else { throw Self.waitingForAnAnswer }

    let requested: Axis? = axis.map { $0 == .row ? .row : .column }

    guard let split = controller.splitAxis(for: pane, requested: requested) else {
      throw ScriptCallError.refused("the pane has no room to split")
    }

    let start = directory ?? controller.directory(of: pane)

    guard let created = controller.openPane(choice, axis: split, from: pane, directory: start)
    else { throw ScriptCallError.refused("the pane did not open. The status bar says why") }

    return .record([
      "window": .integer(controller.scriptWindowID),
      "pane": .integer(created.rawValue),
    ])
  }

  public func openTab(pane reference: ScriptPaneReference, directory: String?) async throws
    -> ScriptValue
  {
    if let directory { try await checkDirectory(directory) }

    let (controller, pane, applet) = try resolve(reference)

    guard let opener = applet as? any TabOpening else {
      throw ScriptCallError.refused("the pane's applet has no tabs to open")
    }

    guard opener.canOpenTab else {
      throw ScriptCallError.refused("the pane's applet cannot open another tab")
    }

    if directory != nil, !opener.tabsStartInDirectory {
      throw ScriptCallError.badArgument("the pane's tabs have no directory")
    }

    guard let tab = opener.openTab(startingIn: directory ?? applet.currentDirectory) else {
      throw ScriptCallError.refused("the tab did not open")
    }

    return .record([
      "window": .integer(controller.scriptWindowID),
      "pane": .integer(pane.rawValue),
      "tab": .integer(controller.scriptTabNumbers.number(for: tab)),
    ])
  }

  /// True while the reference names an open window and pane, and tab when it has one.
  public func isOpen(_ pane: ScriptPaneReference) -> Bool {
    (try? resolve(pane)) != nil
  }

  // MARK: Sending

  public func prepareSend(to pane: ScriptPaneReference) throws {
    _ = try sendTarget(pane)
  }

  public func send(to pane: ScriptPaneReference, file: URL) throws -> ScriptValue {
    let (applet, target) = try sendTarget(pane)

    do {
      try target.replaceSource(
        with: file, startDirectory: applet.currentDirectory ?? NSHomeDirectory())
    } catch {
      throw ScriptCallError.failed(
        "the pane could not open the content: \(error.localizedDescription)")
    }

    return .null
  }

  /// The pane's applet and the way it takes content. An applet that owns its input is refused
  /// before anything else, even when it could also take a source.
  private func sendTarget(_ reference: ScriptPaneReference) throws -> (
    any Applet, any SourceReplacing
  ) {
    let (controller, _, applet) = try resolve(reference)

    guard controller.paneActionsEnabled else { throw Self.waitingForAnAnswer }

    guard !(applet is any InputOwning) else {
      throw ScriptCallError.refused(
        "a program owns this pane's input, so content cannot be sent to it")
    }

    guard let target = applet as? any SourceReplacing else {
      throw ScriptCallError.refused("this pane's applet cannot show sent content")
    }

    return (applet, target)
  }

  // MARK: Arguments

  /// A directory a script names must be an absolute path to a folder that exists. The helper checks
  /// the same, but the app trusts nothing a helper sends.
  private func checkDirectory(_ directory: String) async throws {
    let bytes = Array(directory.utf8)

    guard !bytes.isEmpty, bytes.count <= ScriptProtocol.maxDirectoryBytes, !bytes.contains(0),
      bytes[0] == UInt8(ascii: "/")
    else { throw ScriptCallError.badArgument("the directory must be an absolute path") }

    guard await Self.exists(directory, by: directoryExists) else {
      throw ScriptCallError.badArgument("the directory does not exist")
    }
  }

  /// Runs off the main actor. Callers resolve the pane again afterwards, since it may have closed
  /// while the check ran.
  @concurrent
  private nonisolated static func exists(
    _ path: String, by check: @Sendable (String) -> Bool
  ) async -> Bool {
    check(path)
  }

  /// A sheet holds the window's attention, and a pane's source must not change under it.
  private static let waitingForAnAnswer = ScriptCallError.refused(
    "the window is waiting for an answer to a question")

  /// Finds the window, pane, and applet a reference names. A reference that names a tab must name
  /// one the pane's applet still lists.
  private func resolve(_ reference: ScriptPaneReference) throws -> (
    MainWindowController, NodeID, any Applet
  ) {
    guard let controller = windows.controller(forScriptWindow: reference.window) else {
      throw ScriptCallError.notFound("the window is not open")
    }

    let pane = NodeID(rawValue: reference.pane)

    guard let applet = controller.paneArea.applet(for: pane), controller.contains(pane: pane)
    else { throw ScriptCallError.notFound("the pane is not open in that window") }

    if let number = reference.tab {
      guard let tab = controller.scriptTabNumbers.tab(for: number),
        applet.publishedTabs.contains(tab)
      else { throw ScriptCallError.notFound("the tab is not open in that pane") }
    }

    return (controller, pane, applet)
  }

  /// Text from a program, cleaned and cut by the sanitizer the status bar uses.
  static func reported(_ text: String) -> String {
    StatusText.bounded(text, maximumBytes: maxReportedBytes)
  }
}
