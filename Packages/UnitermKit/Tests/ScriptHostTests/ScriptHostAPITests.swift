import Foundation
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// Runs each host function's fixtures through a real helper process, the wire, and the real host,
/// with a stand-in for the window layer. A script is the only caller the API has, so the fixtures
/// are the contract: each one asserts what the script sees, and a bad argument must fail before
/// the app hears of the call.
///
/// They prove the helper's argument checks, the encoding both sides share, the replies that become
/// Janet values, and that an app failure reaches the script as an error. They cannot prove what a
/// call does to a window. `WindowScriptingTests` proves that against real windows.
@MainActor
final class ScriptHostAPITests: XCTestCase {
  private var directory: URL!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!
  private var sentRoot: URL!

  private let pane = ScriptPaneReference(window: 7, pane: 1)

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    sentRoot = directory.appendingPathComponent("sent", isDirectory: true)
    windows = FakeWindowAPI()

    let center = StatusCenter()
    let listener = try ScriptListener.startWithoutCommandIdentityForTests(directory: directory)

    host = ScriptHost(
      listener: listener, issueProducer: { center.requestProducer(kind: .script, name: $0) },
      windows: windows, sentContent: try ScriptSentContent(root: sentRoot))
    host.start()

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  private func run(_ fixture: String, file: StaticString = #filePath, line: UInt = #line)
    async throws
  {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script(fixture))

    XCTAssertEqual(run.status, 0, "\(fixture): \(run.standardError)", file: file, line: line)
  }

  /// Catches an ID that loses precision on its way out, a reply value that the shim builds wrongly,
  /// or a reference that a script cannot pass back as the shape it received.
  func testScriptsListWindowsAndPanes() async throws {
    try await run("list-windows")
    try await run("list-panes")

    XCTAssertEqual(
      windows.calls,
      [
        .listWindows,
        .listPanes(window: 7), .listPanes(window: 7), .listPanes(window: 7),
        .listPanes(window: 8), .listPanes(window: 9_007_199_254_740_991),
      ])
  }

  /// Catches an open-pane that drops the kind, the axis, the directory, the control, or the tab of
  /// a reference, that turns a directory the script left out into one it did not name, or that
  /// loses a nearest target's kind.
  func testOpenPaneCarriesItsArgumentsToTheApp() async throws {
    try await run("open-pane")

    XCTAssertEqual(
      windows.calls,
      [
        .openPane(
          kind: "terminal", beside: .pane(pane), axis: nil, directory: nil, access: .disconnected),
        .openPane(
          kind: "data-viewer", beside: .pane(ScriptPaneReference(window: 7, pane: 1, tab: 2)),
          axis: .column, directory: "/synthetic/work", access: .disconnected),
        .openPane(
          kind: "browser", beside: .pane(pane), axis: .row, directory: nil, access: .disconnected),
        .openPane(
          kind: "map-viewer", beside: .nearest(kind: "data-viewer"), axis: nil, directory: nil,
          access: .remoteControlled),
        .openPane(
          kind: "text-viewer", beside: .pane(pane), axis: nil, directory: nil,
          access: .disconnected),
      ])
  }

  /// Catches an open-tab that loses its directory or returns a tab without its pane.
  func testOpenTabCarriesItsArgumentsToTheApp() async throws {
    try await run("open-tab")

    XCTAssertEqual(
      windows.calls,
      [
        .openTab(pane: .pane(pane), directory: nil),
        .openTab(pane: .pane(pane), directory: "/synthetic/tab"),
      ])
  }

  /// Catches a send that reaches the viewer with the wrong bytes or name, or in a file or folder
  /// that another user could read. The script sends bytes and a name, and the app writes the file.
  func testSendWritesAPrivateFileTheViewerReads() async throws {
    try await run("send")

    XCTAssertEqual(
      windows.sent.map(\.name), ["report.csv", "notes.txt", "empty.txt"])
    XCTAssertEqual(
      windows.sent.map(\.content),
      [Data("a,b\n1,2\n".utf8), Data("buffer content".utf8), Data()])

    for sent in windows.sent {
      XCTAssertEqual(sent.fileMode, 0o600, sent.name)
      XCTAssertEqual(sent.folderMode, 0o700, sent.name)
    }
  }

  /// Catches a spool whose budget never frees. A pane keeps only its last file, so 300 sends of
  /// 1 MiB to one viewer all succeed under a budget of 256 MiB, and one file remains.
  func testRepeatedSendsToOnePaneKeepOnlyTheLastFile() async throws {
    windows.keepsContent = false

    try await run("send-many")

    XCTAssertEqual(windows.sent.count, 300)
    XCTAssertEqual(windows.sent.last?.name, "part-299.bin")

    XCTAssertEqual(try sentFiles(), ["part-299.bin"])
  }

  /// Catches a file kept for a pane that closed. The pane takes its file, closes, and the next
  /// call from any script removes the file, while the open pane keeps its own.
  func testTheFileOfAClosedPaneIsRemoved() async throws {
    try await run("send-closing")

    XCTAssertEqual(windows.sent.map(\.name), ["gone.txt", "kept.txt"])
    XCTAssertEqual(try sentFiles(), ["kept.txt"])
  }

  /// The names of every file the instance holds now, in any folder.
  private func sentFiles() throws -> [String] {
    let instance = sentRoot.appendingPathComponent(ProcessIdentity.current.folderName)
    let folders = try FileManager.default.contentsOfDirectory(atPath: instance.path)

    return try folders.flatMap {
      try FileManager.default.contentsOfDirectory(atPath: instance.appendingPathComponent($0).path)
    }.sorted()
  }

  /// Catches a limit in the shim that is larger than the wire's, which would drop the connection
  /// instead of delivering the largest allowed send.
  func testTheLargestSendIsDelivered() async throws {
    try await run("send-largest")

    XCTAssertEqual(windows.sent.first?.content.count, ScriptProtocol.maxSendBytes)
  }

  /// Catches a form call whose spec, handle, or failure kind is lost on the way. The script opens
  /// a form, sees a second one refused as busy, a bad spec refused as a bad argument, a handle
  /// that is not open as not found, and a discard that frees the handle.
  func testFormCallsCarryTheSpecAndTheHandleAndRaiseStructuredErrors() async throws {
    try await run("forms")

    XCTAssertEqual(windows.askedForms.count, 2)
    XCTAssertEqual(windows.askedForms.first?.spec.title, "T")
    XCTAssertEqual(windows.discardedForms.count, 2, "the script's discard, then the run's end")
  }

  /// Catches a send-command that loses its target, applet type, schema version, or command, that
  /// writes arguments the app reads as other JSON, or a refusal that reaches the script as plain
  /// text in place of a struct naming its kind.
  func testSendCommandCarriesItsCallAndRaisesStructuredErrors() async throws {
    try await run("send-command")

    let sent = windows.calls.compactMap {
      call -> (ScriptTarget, String, ScriptSchemaVersion, String, String)? in
      guard case .sendCommand(let pane, let type, let version, let command, let arguments) = call
      else { return nil }

      return (pane, type, version, command, arguments)
    }

    XCTAssertEqual(sent.count, 11)
    XCTAssertEqual(sent.map(\.0).first, .pane(pane))
    XCTAssertEqual(
      sent.map(\.1),
      [
        "fixture-slides", "fixture-slides", "fixture-slides", "fixture-slides", "fixture-slides",
        "fixture-chart", "fixture-slides", "fixture-slides", "fixture-slides", "fixture-slides",
        "fixture-slides",
      ])
    XCTAssertEqual(
      sent.map(\.2),
      [
        ScriptSchemaVersion(major: 0), ScriptSchemaVersion(major: 0), ScriptSchemaVersion(major: 0),
        ScriptSchemaVersion(major: 0), ScriptSchemaVersion(major: 0), ScriptSchemaVersion(major: 0),
        ScriptSchemaVersion(major: 2), ScriptSchemaVersion(major: 0, minor: 1),
        ScriptSchemaVersion(major: 0), ScriptSchemaVersion(major: 0), ScriptSchemaVersion(major: 0),
      ])
    XCTAssertEqual(sent[1].0, .nearest(kind: "fixture-slides"))
    XCTAssertEqual(sent[1].3, "status")
    XCTAssertEqual(sent[1].4, "{}")
    XCTAssertEqual(sent[2].4, "{}")

    let arguments = try JSONSerialization.jsonObject(with: Data(sent[0].4.utf8)) as? NSDictionary
    let expected: NSDictionary = [
      "index": 2, "label": "two\n\"quoted\"", "ratio": 0.5, "below": -3,
      "flags": [true, false, NSNull()], "nested": ["inner": [1, 2]], "mode": "row",
    ]

    XCTAssertEqual(arguments, expected)
  }

  /// Catches a request-layout that loses its anchor or a nearest anchor's kind, that writes a
  /// layout the app reads as other JSON, or a refusal that reaches the script as plain text.
  func testRequestLayoutCarriesItsLayoutAndRaisesStructuredErrors() async throws {
    try await run("request-layout")

    let sent = windows.calls.compactMap { call -> (ScriptTarget, String)? in
      guard case .requestLayout(let pane, let layout) = call else { return nil }

      return (pane, layout)
    }

    XCTAssertEqual(
      sent.map(\.0),
      [
        .pane(pane), .nearest(kind: "fixture-slides"), .pane(pane), .pane(pane),
        .pane(ScriptPaneReference(window: 7, pane: 404)),
      ])
    XCTAssertEqual(sent[1].1, #"{"pane":2}"#)

    let layout = try JSONSerialization.jsonObject(with: Data(sent[0].1.utf8)) as? NSDictionary
    let expected: NSDictionary = [
      "split": "row",
      "children": [
        ["pane": 1, "weight": 2],
        [
          "split": "column",
          "children": [
            ["open": "fixture-notes", "control": "remote-controlled"],
            [
              "open": "fixture-chart", "directory": "/synthetic/charts",
              "exec": ["argv": ["/usr/bin/perl", "chart.pl"], "environment-keys": ["TOKEN"]],
            ],
          ],
        ],
      ],
    ]

    XCTAssertEqual(layout, expected)
  }

  /// Catches a function that passes a bad argument on to the app. Each fixture holds the error
  /// cases of one function, and no call may reach the app.
  func testEveryFunctionRejectsBadArgumentsBeforeTheAppHearsOfThem() async throws {
    for fixture in [
      "bad-list-panes", "bad-open-pane", "bad-open-tab", "bad-send", "bad-send-command",
      "bad-request-layout",
    ] {
      try await run(fixture)
    }

    XCTAssertEqual(windows.calls, [])
    XCTAssertEqual(windows.sent, [])
  }

  /// Catches an app failure that the script never sees, or one that stops the script from going
  /// on. A refused send must leave no file behind.
  func testAppFailuresReachTheScriptAsErrors() async throws {
    try await run("app-errors")

    XCTAssertEqual(windows.sent, [])

    let instance = sentRoot.appendingPathComponent(ProcessIdentity.current.folderName)
    let left = try FileManager.default.contentsOfDirectory(atPath: instance.path)

    XCTAssertEqual(left, [], "a refused send left a file")
  }

  /// Catches an answer that does not fit the frame being sent anyway, which would end the
  /// connection and the script with it.
  func testAnAnswerTooLargeForOneReplyIsAFailureTheScriptSees() async throws {
    windows.windowCount = 3000

    try await run("big-reply")
  }

  /// Catches a host built without a window layer that crashes, or answers a call it cannot serve.
  func testAHostWithoutWindowsRefusesTheCalls() async throws {
    let center = StatusCenter()
    let other = try ScriptListener.startForTests(
      directory: directory.appendingPathComponent("bare", isDirectory: true))
    let bare = ScriptHost(
      listener: other, issueProducer: { center.requestProducer(kind: .script, name: $0) })

    bare.start()
    recordTestProcessAsSessionRoot(bare)
    defer { bare.stop() }

    let run = try await ScriptFixtures.run(
      socket: bare.instanceAddress, script: ScriptFixtures.script("list-windows"))

    XCTAssertEqual(run.status, 1)
    XCTAssertTrue(run.standardError.contains("no windows to script"), run.standardError)
  }
}
