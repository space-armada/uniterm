import ControllerPackage
import Darwin
import Foundation
import PaneModel
import QuestionForm
import ScriptWire
import SourceAccess
import XCTest

@testable import ScriptHost

/// A stand-in for the window layer, with fixed answers keyed by the IDs a fixture script passes.
/// Window 7 is open, pane 404 is closed, and pane 403 is one that refuses. A nearest target names
/// pane 2.
///
/// It stands in for the layer only to prove how a script's call travels through the helper, the
/// wire, and the host. The window layer's own tests prove what the calls do to real windows.
@MainActor
final class FakeWindowAPI: ScriptWindowAPI {
  struct Sent: Equatable {
    var name: String
    var content: Data
    var size: Int
    var fileMode: mode_t
    var folderMode: mode_t
  }

  /// Every call that reached the app, oldest first, in the wire's own terms.
  private(set) var calls: [ScriptCall] = []
  private(set) var sent: [Sent] = []

  /// The panes a send asked about before it wrote anything.
  private(set) var prepared: [ScriptTarget] = []

  /// The caller the host named for each call, oldest first.
  private(set) var callers: [ScriptCaller] = []

  /// The permissions the host said the caller held, for each command or layout, oldest first.
  private(set) var heldPowers: [Set<ControllerPermission>] = []

  /// The extra power a command needs, by command name, as an applet's schema would name it. A
  /// layout whose text holds `"url"` needs browser navigation.
  var commandPowers: [String: ControllerPermission] = [:]

  func extraPower(for call: ScriptCall, caller: ScriptCaller) -> ControllerPermission? {
    switch call {
    case .sendCommand(_, _, _, let command, _): return commandPowers[command]
    case .requestLayout(_, let layout): return layout.contains("\"url\"") ? .browserNavigation : nil
    default: return nil
    }
  }

  /// One form the host asked this layer to show.
  struct AskedForm {
    var spec: FormSpec
    var requester: FormRequester
    var caller: ScriptCaller
  }

  /// Every form the host opened, oldest first.
  private(set) var askedForms: [AskedForm] = []

  /// The requesters whose form is open, and what each one hears when it resolves.
  private var openForms: [String: @MainActor (FormOutcome) -> Void] = [:]

  /// The requesters the host discarded, and the ones it ended, in order.
  private(set) var discardedForms: [String] = []
  private(set) var endedForms: [String] = []

  /// How many forms may be open at once. A form past it is refused as busy.
  var formCap = 8

  /// When set, `openForm` throws it.
  var formRefusal: ScriptCallError?

  func openForm(
    _ spec: FormSpec, requester: FormRequester, caller: ScriptCaller,
    resolved: @escaping @MainActor (FormOutcome) -> Void
  ) throws {
    if let formRefusal { throw formRefusal }

    guard openForms[requester.key] == nil else {
      throw ScriptCallError.busy("this requester has a form open")
    }

    guard openForms.count < formCap else { throw ScriptCallError.busy("the pane is full") }

    askedForms.append(AskedForm(spec: spec, requester: requester, caller: caller))
    openForms[requester.key] = resolved
  }

  /// The user's answer to a requester's open form.
  func resolveForm(requester key: String, with outcome: FormOutcome) {
    openForms.removeValue(forKey: key)?(outcome)
  }

  func discardForm(requester key: String, window: UInt64) {
    discardedForms.append(key)
    openForms.removeValue(forKey: key)?(.ended)
  }

  func endForms(requester key: String, window: UInt64) {
    endedForms.append(key)
    openForms.removeValue(forKey: key)?(.ended)
  }

  func hasOpenForm(requester key: String) -> Bool { openForms[key] != nil }

  /// False for a test that sends many large files and only needs to count them.
  var keepsContent = true

  /// Panes that closed. Pane 6 closes as soon as it takes a file.
  private(set) var closedPanes: Set<UInt64> = []

  /// How many windows `listWindows` reports.
  var windowCount = 2

  func listWindows(caller: ScriptCaller) throws -> ScriptValue {
    calls.append(.listWindows)
    callers.append(caller)

    return .array(
      (0..<windowCount).map { index in
        .record([
          "window": .integer(ScriptProtocol.maxID - UInt64(index)),
          "title": .string("Synthetic \(index)"),
          "key": .bool(index == 0),
        ])
      })
  }

  func listPanes(window: UInt64, caller: ScriptCaller, access: ReadAccess) throws -> ScriptValue {
    calls.append(.listPanes(window: window))
    callers.append(caller)

    guard window == 7 else { return .null }

    func tab(_ number: UInt64) -> ScriptValue {
      .record([
        "window": .integer(7), "pane": .integer(1), "tab": .integer(number),
        "title": .string("tab \(number)"), "selected": .bool(number == 1),
      ])
    }

    return .array([
      .record([
        "window": .integer(7), "pane": .integer(1), "applet": .string("terminal"),
        "title": .string("Synthetic"), "focused": .bool(true),
        "directory": .string("/synthetic/work"), "tabs": .array([tab(1), tab(2)]),
      ]),
      .record([
        "window": .integer(7), "pane": .integer(2), "applet": .string("browser"),
        "title": .string("Page"), "focused": .bool(false), "tabs": .array([tab(3)]),
      ]),
    ])
  }

  /// While true, `openPane` and `openTab` wait where the real layer checks a directory, until
  /// the test calls `releaseWait`.
  var holdsDirectoryCheck = false

  /// True while a call waits in its directory check.
  private(set) var isWaitingInDirectoryCheck = false

  /// How many panes and tabs a call went on to open.
  private(set) var opened = 0

  private var waiting: CheckedContinuation<Void, Never>?

  func releaseWait() {
    waiting?.resume()
    waiting = nil
  }

  /// Stands in for the real layer's directory check, the one wait between a call's start and its
  /// effect. The real layer asks `stillAllowed` right after it.
  private func directoryCheck(stillAllowed: @MainActor () throws -> Void) async throws {
    if holdsDirectoryCheck {
      isWaitingInDirectoryCheck = true
      await withCheckedContinuation { waiting = $0 }
      isWaitingInDirectoryCheck = false
    }

    try stillAllowed()
  }

  func openPane(
    kind: String, beside target: ScriptTarget, axis: ScriptAxis?, directory: String?,
    access: ScriptPaneAccess, caller: ScriptCaller, stillAllowed: @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    calls.append(
      .openPane(kind: kind, beside: target, axis: axis, directory: directory, access: access))
    callers.append(caller)

    guard kind != "bogus" else { throw ScriptCallError.badArgument("the applet kind is not known") }

    try await directoryCheck(stillAllowed: stillAllowed)

    let beside = Self.reference(target)
    try check(beside)

    opened += 1

    return .record(["window": .integer(beside.window), "pane": .integer(99)])
  }

  func openTab(
    pane target: ScriptTarget, directory: String?, caller: ScriptCaller,
    stillAllowed: @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    calls.append(.openTab(pane: target, directory: directory))
    callers.append(caller)

    let pane = Self.reference(target)

    guard pane.pane != 403 else {
      throw ScriptCallError.refused("the pane's applet has no tabs to open")
    }

    try await directoryCheck(stillAllowed: stillAllowed)
    try check(pane)

    opened += 1

    return .record([
      "window": .integer(pane.window), "pane": .integer(pane.pane), "tab": .integer(5),
    ])
  }

  func isOpen(_ pane: ScriptPaneReference) -> Bool {
    pane.window == 7 && pane.pane != 404 && !closedPanes.contains(pane.pane)
  }

  /// A nearest target stands for pane 2 of window 7.
  static func reference(_ target: ScriptTarget) -> ScriptPaneReference {
    switch target {
    case .pane(let reference): return reference
    case .nearest: return ScriptPaneReference(window: 7, pane: 2)
    }
  }

  func prepareSend(to target: ScriptTarget, caller: ScriptCaller) throws -> ScriptPaneReference {
    prepared.append(target)
    callers.append(caller)

    let pane = Self.reference(target)

    guard pane.pane != 403 else {
      throw ScriptCallError.refused(
        "a program owns this pane's input, so content cannot be sent to it")
    }

    try check(pane)

    return pane
  }

  func send(to pane: ScriptPaneReference, file: URL, caller: ScriptCaller) throws -> ScriptValue {
    var info = stat()
    var folder = stat()

    XCTAssertEqual(stat(file.path, &info), 0)
    XCTAssertEqual(stat(file.deletingLastPathComponent().path, &folder), 0)

    let content = try Data(contentsOf: file)

    sent.append(
      Sent(
        name: file.lastPathComponent, content: keepsContent ? content : Data(),
        size: content.count, fileMode: info.st_mode & 0o777,
        folderMode: folder.st_mode & 0o777))

    if pane.pane == 6 { closedPanes.insert(6) }

    return .null
  }

  /// Stands in for shared dispatch. A chart type or any schema version but 0.0 is unsupported,
  /// and the command `explode` is refused. Anything else echoes what arrived, with a negative and a
  /// fractional number so the reply proves both reach the script.
  func sendCommand(
    to target: ScriptTarget, appletType: String, schemaVersion: ScriptSchemaVersion,
    command: String,
    arguments: String, caller: ScriptCaller, access: @escaping @MainActor () -> ReadAccess,
    powers: @escaping @MainActor () -> Set<ControllerPermission>,
    stillAllowed: @escaping @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    heldPowers.append(powers())
    calls.append(
      .sendCommand(
        pane: target, appletType: appletType, schemaVersion: schemaVersion, command: command,
        arguments: arguments))
    callers.append(caller)

    try check(Self.reference(target))

    guard appletType == "fixture-slides" || appletType == "browser" else {
      throw ScriptCallError.unsupported("the pane runs a fixture-slides applet, not \(appletType)")
    }

    guard schemaVersion.major == 0, schemaVersion.minor == 0 else {
      throw ScriptCallError.unsupported("the applet takes command schema version 0.0")
    }

    guard command != "explode" else { throw ScriptCallError.refused("the applet refused") }

    if let needed = commandPowers[command], !powers().contains(needed) {
      throw ScriptCallError.refused(
        "the \(command) command needs the \(needed.kindName) permission")
    }

    // A reply past the reply frame's bound, as an applet that answered with too much would make.
    if command == "huge-reply" {
      return .array(Array(repeating: .string(String(repeating: "r", count: 4000)), count: 20))
    }

    try stillAllowed()

    return .record([
      "command": .string(command), "arguments": .string(arguments), "offset": .number(-1.5),
    ])
  }

  /// Stands in for the window's layout. A layout with a `refuse` key is refused, and any other
  /// answers with the anchor and two new panes, so the reply proves references reach the script.
  func requestLayout(
    anchor: ScriptTarget, layout: String, caller: ScriptCaller,
    powers: @escaping @MainActor () -> Set<ControllerPermission>,
    stillAllowed: @escaping @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    heldPowers.append(powers())
    calls.append(.requestLayout(pane: anchor, layout: layout))
    callers.append(caller)

    let pane = Self.reference(anchor)

    try check(pane)

    guard !layout.contains("\"refuse\"") else {
      throw ScriptCallError.refused("the layout places a pane more than once")
    }

    guard !layout.contains("\"busy\"") else {
      throw ScriptCallError.busy("another layout from this program is still being prepared")
    }

    try await directoryCheck(stillAllowed: stillAllowed)

    func reference(_ id: UInt64) -> ScriptValue {
      .record(["window": .integer(pane.window), "pane": .integer(id)])
    }

    return .record([
      "window": .integer(pane.window),
      "panes": .array([reference(pane.pane), reference(20), reference(21)]),
    ])
  }

  private func check(_ pane: ScriptPaneReference) throws {
    guard pane.window == 7 else { throw ScriptCallError.notFound("the window is not open") }

    switch pane.pane {
    case 404: throw ScriptCallError.notFound("the pane is not open in that window")
    case 403: throw ScriptCallError.refused("the pane has no room to split")
    default: break
    }
  }
}
