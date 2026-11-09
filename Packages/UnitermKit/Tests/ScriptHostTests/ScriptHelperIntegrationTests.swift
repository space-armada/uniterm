import Darwin
import Foundation
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// Runs the unsandboxed helper against a real listener in this process. The helper links Janet and
/// the listener does not, which is the split the app ships.
///
/// These prove the handshake and its refusal in both directions, a script's status post reaching
/// the status center as a script-sourced message, and each kind of script error reaching the user
/// with its name, line, and message while the listener keeps serving. They cannot prove the shipped
/// helper's signing. `make test-helper-sandbox` checks the built copy.
@MainActor
final class ScriptHelperIntegrationTests: XCTestCase {
  private var directory: URL!
  private var center: StatusCenter!
  private var host: ScriptHost!
  private var refusals: [ScriptRefusal] = []
  private var refused: XCTestExpectation?

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    center = StatusCenter()
    refusals = []

    let center = center!
    let listener = try ScriptListener.start(directory: directory)

    host = ScriptHost(
      listener: listener,
      issueProducer: { center.issueProducer(kind: .script, name: $0) },
      onRefusal: { [weak self] in
        self?.refusals.append($0)
        self?.refused?.fulfill()
      })
    host.start()
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  /// Catches a helper whose host functions do not reach the app, a status post that arrives as
  /// uniterm instead of as the script, or a script label that is not the script's name.
  func testAScriptPostsAStatusThatArrivesAsTheScript() async throws {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("post-status"))

    XCTAssertEqual(run.status, 0, run.standardError)
    XCTAssertEqual(center.history.count, 1)

    let message = try XCTUnwrap(center.history.first)

    XCTAssertEqual(message.text, "synthetic status from a script")
    XCTAssertEqual(message.level, .warning)
    XCTAssertEqual(message.source.label, "post-status.janet")

    guard case .script = message.source else {
      return XCTFail("the status arrived as \(message.source), not as a script")
    }
  }

  /// Catches an error path that loses the script name, the line, or the message, or that stops the
  /// listener from serving the next script. Each kind of error is a different path in the shim.
  func testEachKindOfScriptErrorNamesTheScriptLineAndMessageAndTheAppKeepsServing() async throws {
    let cases: [(fixture: String, expected: [String])] = [
      ("runtime-error", ["runtime-error.janet:4", "runtime error", "synthetic failure"]),
      ("compile-error", ["compile-error.janet:4", "compile error", "missing-function"]),
      ("parse-error", ["parse-error.janet", "parse error"]),
    ]

    for (fixture, expected) in cases {
      let run = try await ScriptFixtures.run(
        socket: host.instanceAddress, script: ScriptFixtures.script(fixture))

      XCTAssertEqual(run.status, 1, "\(fixture): \(run.standardError)")

      for fragment in expected {
        XCTAssertTrue(
          run.standardError.contains(fragment),
          "\(fixture) did not report \(fragment): \(run.standardError)")
      }
    }

    let after = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("post-status"))

    XCTAssertEqual(after.status, 0, after.standardError)
    XCTAssertEqual(center.history.last?.text, "synthetic status from a script")
  }

  /// Catches a host function that passes bad arguments through to the app. The script gets a Janet
  /// error, and nothing is posted.
  func testABadArgumentFailsTheScriptAndPostsNothing() async throws {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("bad-argument"))

    XCTAssertEqual(run.status, 1)
    XCTAssertTrue(run.standardError.contains("the level must be"), run.standardError)
    XCTAssertTrue(center.history.isEmpty)
  }

  /// Catches a helper that starts with Janet's full power. A script may read no file unless the
  /// command line grants it, so a plain read fails.
  func testAScriptCannotReadAFileByDefault() async throws {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("denied-read"))

    XCTAssertEqual(run.status, 1)
    XCTAssertTrue(run.standardError.contains("sandbox"), run.standardError)
  }

  /// Catches an app that accepts a helper of another protocol version. The app answers with its
  /// own hello first, so the helper can tell the user, then closes. It reports the refusal.
  func testTheAppRefusesAHelperOfAnotherProtocolVersion() async throws {
    let refused = expectation(description: "the app reports the refusal")

    self.refused = refused

    let socket = try ScriptFixtures.connectPeer(path: host.instanceAddress)
    let other = ScriptProtocol.version + 1

    try socket.send(ScriptHelperMessage.hello(version: other).frame())

    let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    XCTAssertEqual(
      try ScriptAppMessage.decode(type: frame.type, body: frame.body),
      .hello(version: ScriptProtocol.version))

    XCTAssertThrowsError(try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))) { error in
      XCTAssertEqual(error as? WireError, .closed)
    }

    await fulfillment(of: [refused], timeout: 30)

    XCTAssertEqual(refusals, [.versionMismatch(found: other)])
    XCTAssertEqual(refusals.first?.text, ScriptProtocol.mismatchText)
  }

  /// Catches a peer that renames its session or floods the app with begin messages. One begin is
  /// allowed, and a second is a protocol violation that ends the connection.
  func testASecondBeginIsAProtocolViolation() async throws {
    let refused = expectation(description: "the app reports the violation")

    self.refused = refused

    let socket = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    try socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try socket.send(ScriptHelperMessage.begin(name: "first").frame())
    try socket.send(ScriptHelperMessage.begin(name: "second").frame())

    let outcome = await XCTWaiter.fulfillment(of: [refused], timeout: 30)

    guard outcome == .completed else {
      return XCTFail("the app never reported the second begin")
    }

    guard case .protocolViolation = refusals.first else {
      return XCTFail("the second begin was not refused as a violation: \(refusals)")
    }

    XCTAssertThrowsError(try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))) { error in
      XCTAssertEqual(error as? WireError, .closed)
    }
  }

  /// Catches a stop that returns before the socket file is gone. The app quits right after it
  /// stops the listener, so a file removed later by the accept thread can outlive the process.
  func testStopRemovesTheSocketFileBeforeItReturns() throws {
    let listener = try ScriptListener.start(
      directory: directory.appendingPathComponent("stop", isDirectory: true))

    XCTAssertTrue(FileManager.default.fileExists(atPath: listener.path))

    listener.stop()

    XCTAssertFalse(FileManager.default.fileExists(atPath: listener.path))
  }

  /// Catches a status text that reaches the bar with its control characters. Newlines and escapes
  /// become spaces and the text is bounded, whatever a script sends.
  func testStatusTextFromAScriptIsNeutralized() async throws {
    let socket = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    try socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    try socket.send(ScriptHelperMessage.begin(name: "raw\u{1B}[31m\nname").frame())
    try socket.send(
      ScriptHelperMessage.request(
        id: 1, call: .postStatus(level: .info, text: "line one\nline\u{1B}[2J two")
      ).frame())

    let frame = try await Task.detached {
      try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    }.value

    XCTAssertEqual(
      try ScriptAppMessage.decode(type: frame.type, body: frame.body),
      .reply(id: 1, result: .ok(Data())))

    let message = try XCTUnwrap(center.history.first)

    XCTAssertEqual(message.text, "line one line [2J two")
    XCTAssertEqual(message.source.label, "raw[31mname")
  }

  /// Catches a helper that runs against an app of another protocol version. It must refuse with
  /// the relaunch message and a distinct exit status, before it runs any of the script.
  func testTheHelperRefusesAnAppOfAnotherProtocolVersion() async throws {
    let path = directory.appendingPathComponent("other.sock").path
    let server = try FakeApp.listen(path: path)

    defer { Darwin.close(server) }

    let process = try ScriptFixtures.start(
      socket: path, script: ScriptFixtures.script("post-status"))

    let peer = Darwin.accept(server, nil, nil)

    XCTAssertGreaterThanOrEqual(peer, 0)

    let socket = FramedSocket(descriptor: peer)

    _ = try socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))
    try socket.send(ScriptAppMessage.hello(version: ScriptProtocol.version + 1).frame())

    let run = await ScriptFixtures.finish(process)

    XCTAssertEqual(run.status, 70)
    XCTAssertTrue(run.standardError.contains("Relaunch uniterm"), run.standardError)

    XCTAssertThrowsError(try socket.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))) {
      error in
      XCTAssertEqual(error as? WireError, .closed, "the helper sent more after the mismatch")
    }
  }

  /// Records what the design must stay within and what a helper costs. The numbers go to the
  /// test log. The assertions only hold the footprint under the per-helper cap, which is 1 GiB.
  ///
  /// The footprint is read while the script waits for an answer, so the VM is built, the script is
  /// loaded, and nothing is running. Startup runs from the process launch to the helper's first
  /// message after its hello.
  func testTheHelperRestingFootprintAndStartupTime() async throws {
    let listener = try ScriptListener.start(
      directory: directory.appendingPathComponent("measure", isDirectory: true))

    defer { listener.stop() }

    let clock = ContinuousClock()
    let launch = clock.now
    let process = try ScriptFixtures.start(
      socket: listener.path, script: ScriptFixtures.script("post-status"),
      onExit: { listener.stop() })

    let measured = MeasureBox()
    let finished = await listener.drive(timeout: .seconds(60)) { event in
      switch event {
      case .begun(_, _):
        measured.startup = clock.now - launch

      case .request(let connection, let id, _):
        measured.footprint = ScriptFixtures.footprint(of: connection.peer.pid)
        measured.peer = connection.peer
        connection.reply(id: id, result: .ok(Data()))

      case .closed:
        return true

      case .attached, .replLine, .replEvaluating:
        XCTFail("a script helper acted as a REPL")

      case .refused(_, let refusal):
        XCTFail("the helper was refused: \(refusal)")
      }

      return false
    }

    XCTAssertTrue(finished, "the helper never finished")

    let peer = try XCTUnwrap(measured.peer)

    XCTAssertEqual(peer.pid, process.processIdentifier)
    XCTAssertEqual(peer.uid, getuid())
    XCTAssertEqual(peer.token?.pid, process.processIdentifier)

    let run = await ScriptFixtures.finish(process)

    XCTAssertEqual(run.status, 0, run.standardError)

    let footprint = try XCTUnwrap(measured.footprint)

    print(
      "script helper \(ScriptFixtures.helper().lastPathComponent): resting footprint "
        + "\(footprint) bytes (\(footprint / 1024) KiB), startup to the first message "
        + "\(try XCTUnwrap(measured.startup))")

    XCTAssertGreaterThan(footprint, 0)
    XCTAssertLessThan(footprint, 1 << 30)
  }
}

/// What the footprint test reads from the listener's events, which arrive on another thread.
private final class MeasureBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storedStartup: Duration?
  private var storedFootprint: Int?
  private var storedPeer: ScriptPeer?

  var startup: Duration? {
    get { lock.withLock { storedStartup } }
    set { lock.withLock { storedStartup = newValue } }
  }

  var footprint: Int? {
    get { lock.withLock { storedFootprint } }
    set { lock.withLock { storedFootprint = newValue } }
  }

  var peer: ScriptPeer? {
    get { lock.withLock { storedPeer } }
    set { lock.withLock { storedPeer = newValue } }
  }
}

/// A listener that speaks no protocol, for a test that plays the app by hand.
enum FakeApp {
  static func listen(path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)

    try UnixSocket.withAddress(path: path) { address, length in
      guard Darwin.bind(descriptor, address, length) == 0, Darwin.listen(descriptor, 1) == 0 else {
        throw WireError.io(errno)
      }
    }

    return descriptor
  }
}
