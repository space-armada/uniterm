import AppKit
import AppletKit
import PaneModel
import QuestionsApplet
import ScriptHost
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptWire
@testable import WindowKit

/// The form calls through the real host and real windows: a raw peer sends the calls over the
/// socket, and the form opens in a Questions pane beside the pane the peer runs in.
///
/// These prove that the wire, the host, and the window layer agree. They cannot prove the keys or
/// the look of the pane in the running app, which `QuestionsUITests` drives.
@MainActor
final class QuestionsWireWindowTests: XCTestCase {
  private var fixture: ScriptingFixture!
  private var host: ScriptHost!
  private var directory: URL!
  private var peer: FramedSocket?

  override func setUp() async throws {
    fixture = ScriptingFixture()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)

    let center = StatusCenter()

    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) }, windows: fixture.scripting
    )
    host.start()
  }

  override func tearDown() async throws {
    peer?.shutdownAndClose()
    host.stop()
    fixture.cleanUp()
    try? FileManager.default.removeItem(at: directory)
  }

  private func read() async throws -> ScriptAppMessage {
    let socket = try XCTUnwrap(peer)

    return try await Task.detached {
      let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
    }.value
  }

  private func reply(_ id: UInt32) async throws -> ScriptResult {
    while true {
      if case .reply(let answered, let result) = try await read(), answered == id { return result }
    }
  }

  /// Catches a form that reaches the host and never the screen, and a wait that the pane's close
  /// leaves hanging. The peer opens a form from the pane it runs in. The form opens beside that
  /// pane, the asker is badged, and the pane's close answers the wait with `dismissed`.
  func testAFormOpensBesideTheCallersPaneAndAClosedPaneDismissesIt() async throws {
    let (controller, pane) = try fixture.openWindow()
    let asker = NodeID(rawValue: pane.pane)

    TestSessionRoot.record(in: host, window: controller.scriptWindowID, pane: asker)

    let socket = try UnixSocket.connect(path: host.instanceAddress)

    peer = socket

    try socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await read()

    try socket.send(ScriptHelperMessage.begin(name: "bash").frame())

    let spec = #"{"items": [{"id": "ok", "text": "Sure?", "type": "boolean"}]}"#

    try socket.send(
      ScriptHelperMessage.request(id: 1, call: .openForm(spec: spec)).frame())

    guard case .ok(let payload) = try await reply(1),
      case .integer(let handle) = try ScriptValue.decode(payload)
    else { return XCTFail("the form did not open") }

    let found = try XCTUnwrap(controller.questionsPane())

    XCTAssertNotEqual(found.pane, asker)
    XCTAssertEqual(controller.paneArea.focusedPane, found.pane)
    XCTAssertEqual(found.applet.requesterKeys.count, 1)
    XCTAssertNotNil(controller.paneArea.paneView(for: asker)?.askingMark)

    try socket.send(ScriptHelperMessage.request(id: 2, call: .waitForm(form: handle)).frame())

    for _ in 0..<50 { await Task.yield() }

    controller.closePane(found.pane, appletEnded: false)

    guard case .ok(let answer) = try await reply(2),
      case .record(let fields) = try ScriptValue.decode(answer)
    else { return XCTFail("the wait did not answer") }

    XCTAssertEqual(fields["outcome"], .string("dismissed"))
    XCTAssertEqual(fields["form"], .integer(handle))
    XCTAssertNil(controller.paneArea.paneView(for: asker)?.askingMark)
  }
}
