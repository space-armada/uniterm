import Darwin
import Foundation
import ScriptWire
import XCTest

@testable import ScriptHost

/// A stand-in for the window layer, with fixed answers keyed by the IDs a fixture script passes.
/// Window 7 is open, pane 404 is closed, and pane 403 is one that refuses.
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
  private(set) var prepared: [ScriptPaneReference] = []

  /// False for a test that sends many large files and only needs to count them.
  var keepsContent = true

  /// Panes that closed. Pane 6 closes as soon as it takes a file.
  private(set) var closedPanes: Set<UInt64> = []

  /// How many windows `listWindows` reports.
  var windowCount = 2

  func listWindows() throws -> ScriptValue {
    calls.append(.listWindows)

    return .array(
      (0..<windowCount).map { index in
        .record([
          "window": .integer(ScriptProtocol.maxID - UInt64(index)),
          "title": .string("Synthetic \(index)"),
          "key": .bool(index == 0),
        ])
      })
  }

  func listPanes(window: UInt64) throws -> ScriptValue {
    calls.append(.listPanes(window: window))

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

  func openPane(
    kind: String, beside: ScriptPaneReference, axis: ScriptAxis?, directory: String?
  ) async throws -> ScriptValue {
    calls.append(.openPane(kind: kind, beside: beside, axis: axis, directory: directory))

    guard kind != "bogus" else { throw ScriptCallError.badArgument("the applet kind is not known") }

    try check(beside)

    return .record(["window": .integer(beside.window), "pane": .integer(99)])
  }

  func openTab(pane: ScriptPaneReference, directory: String?) async throws -> ScriptValue {
    calls.append(.openTab(pane: pane, directory: directory))

    guard pane.pane != 403 else {
      throw ScriptCallError.refused("the pane's applet has no tabs to open")
    }

    try check(pane)

    return .record([
      "window": .integer(pane.window), "pane": .integer(pane.pane), "tab": .integer(5),
    ])
  }

  func isOpen(_ pane: ScriptPaneReference) -> Bool {
    pane.window == 7 && pane.pane != 404 && !closedPanes.contains(pane.pane)
  }

  func prepareSend(to pane: ScriptPaneReference) throws {
    prepared.append(pane)

    guard pane.pane != 403 else {
      throw ScriptCallError.refused(
        "a program owns this pane's input, so content cannot be sent to it")
    }

    try check(pane)
  }

  func send(to pane: ScriptPaneReference, file: URL) throws -> ScriptValue {
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

  private func check(_ pane: ScriptPaneReference) throws {
    guard pane.window == 7 else { throw ScriptCallError.notFound("the window is not open") }

    switch pane.pane {
    case 404: throw ScriptCallError.notFound("the pane is not open in that window")
    case 403: throw ScriptCallError.refused("the pane has no room to split")
    default: break
    }
  }
}
