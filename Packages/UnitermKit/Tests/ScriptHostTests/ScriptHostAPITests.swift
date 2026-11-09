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
    let listener = try ScriptListener.start(directory: directory)

    host = ScriptHost(
      listener: listener, issueProducer: { center.issueProducer(kind: .script, name: $0) },
      windows: windows, sentContent: try ScriptSentContent(root: sentRoot))
    host.start()
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  private func run(_ fixture: String, file: StaticString = #filePath, line: UInt = #line)
    async throws
  {
    let run = try await ScriptFixtures.run(
      socket: host.socketPath, script: ScriptFixtures.script(fixture))

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

  /// Catches an open-pane that drops the kind, the axis, the directory, or the tab of a reference,
  /// or that turns a directory the script left out into one it did not name.
  func testOpenPaneCarriesItsArgumentsToTheApp() async throws {
    try await run("open-pane")

    XCTAssertEqual(
      windows.calls,
      [
        .openPane(kind: "terminal", beside: pane, axis: nil, directory: nil),
        .openPane(
          kind: "data-viewer", beside: ScriptPaneReference(window: 7, pane: 1, tab: 2),
          axis: .column, directory: "/synthetic/work"),
        .openPane(kind: "browser", beside: pane, axis: .row, directory: nil),
      ])
  }

  /// Catches an open-tab that loses its directory or returns a tab without its pane.
  func testOpenTabCarriesItsArgumentsToTheApp() async throws {
    try await run("open-tab")

    XCTAssertEqual(
      windows.calls,
      [
        .openTab(pane: pane, directory: nil),
        .openTab(pane: pane, directory: "/synthetic/tab"),
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

  /// Catches a function that passes a bad argument on to the app. Each fixture holds the error
  /// cases of one function, and no call may reach the app.
  func testEveryFunctionRejectsBadArgumentsBeforeTheAppHearsOfThem() async throws {
    for fixture in ["bad-list-panes", "bad-open-pane", "bad-open-tab", "bad-send"] {
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
    let other = try ScriptListener.start(
      directory: directory.appendingPathComponent("bare", isDirectory: true))
    let bare = ScriptHost(
      listener: other, issueProducer: { center.issueProducer(kind: .script, name: $0) })

    bare.start()
    defer { bare.stop() }

    let run = try await ScriptFixtures.run(
      socket: bare.socketPath, script: ScriptFixtures.script("list-windows"))

    XCTAssertEqual(run.status, 1)
    XCTAssertTrue(run.standardError.contains("no windows to script"), run.standardError)
  }
}
