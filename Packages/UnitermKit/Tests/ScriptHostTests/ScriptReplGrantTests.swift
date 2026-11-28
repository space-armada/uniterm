import Darwin
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// What a REPL helper may do, and when its authority starts and ends: the capabilities named on
/// its command line, the attach that waits for its pane's session root, and the calls of a helper
/// whose channel has ended.
///
/// Real helpers prove the capabilities, since only the helper applies its sandbox. Raw peers from
/// the test process prove the attach and the end, so each step is in the test's hands. The REPL
/// pane's own restart is proved in `ReplAppletTests`, over the same host.
@MainActor
final class ScriptReplGrantTests: XCTestCase {
  private var directory: URL!
  private var center: StatusCenter!
  private var host: ScriptHost!
  private var peers: [FramedSocket] = []

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    center = StatusCenter()

    let center = center!

    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: FakeWindowAPI(),
      reaper: .inert)
    host.start()

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    for peer in peers { peer.shutdownAndClose() }

    peers = []
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  private var testRoot: ProcessIdentity { TestSessionRoot.identity }

  /// Connects a raw peer that says hello and presents the channel's token.
  private func attachPeer(to channel: ScriptReplChannel) async throws -> FramedSocket {
    let token = try XCTUnwrap(ReplEnvironmentHex.decode(channel.launch.token))
    let peer = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    peers.append(peer)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await read(peer)
    try peer.send(ScriptHelperMessage.attach(token: token).frame())

    return peer
  }

  private func read(_ peer: FramedSocket) async throws -> ScriptAppMessage {
    try await Task.detached {
      let frame = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
    }.value
  }

  // MARK: Capabilities

  /// Catches `--allow` that never reaches the REPL's sandbox, or one that widens it past the
  /// name. A REPL started with no flag cannot read a file. One started with `--allow fs-read`
  /// says so, reads it, and still cannot write.
  func testAllowLiftsOnlyThatDenialForTheReplItStarts() async throws {
    let file = directory.appendingPathComponent("data.txt")
    let written = directory.appendingPathComponent("out.txt")

    try Data("twelve bytes".utf8).write(to: file)

    let plain = openTestRepl(host: host)
    let plainEvents = ReplEvents(plain)
    let denied = try ReplProcess(
      address: plain.launch.address,
      environment: [ScriptProtocol.replTokenVariable: plain.launch.token])

    expect(await waitUntil { plainEvents.attachedProcess != nil })

    denied.write("(length (slurp \"\(file.path)\"))\n")

    expect(await denied.waitForError("sandbox"), denied.standardError)
    XCTAssertFalse(denied.standardOutput.contains("This REPL may use"), denied.standardOutput)

    plain.end()

    let granted = openTestRepl(host: host)
    let grantedEvents = ReplEvents(granted)
    let allowed = try ReplProcess(
      address: granted.launch.address,
      environment: [ScriptProtocol.replTokenVariable: granted.launch.token],
      arguments: ["--allow", "fs-read"])

    expect(await waitUntil { grantedEvents.attachedProcess != nil })
    expect(await allowed.waitForOutput("This REPL may use: fs-read\n"), allowed.standardOutput)

    allowed.write("(length (slurp \"\(file.path)\"))\n")

    expect(await allowed.waitForOutput("12\n"), allowed.standardOutput + allowed.standardError)

    allowed.write("(spit \"\(written.path)\" \"x\")\n")

    expect(await allowed.waitForError("sandbox"), allowed.standardError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: written.path))

    granted.end()
  }

  /// Catches a capability name the REPL accepts by mistake, or refuses only after it connected.
  /// The usage status comes back, and the token is never spent.
  func testAnUnknownCapabilityEndsTheReplBeforeItConnects() async throws {
    let channel = openTestRepl(host: host)
    let events = ReplEvents(channel)
    let repl = try ReplProcess(
      address: channel.launch.address,
      environment: [ScriptProtocol.replTokenVariable: channel.launch.token],
      arguments: ["--allow", "nonsense"])

    let status = await repl.exitStatus()

    XCTAssertEqual(status, 64, repl.standardError)
    XCTAssertTrue(repl.standardError.contains("--allow"), repl.standardError)
    XCTAssertNil(events.attachedProcess)

    channel.end()
  }

  // MARK: Attach and the session root

  /// Catches a helper turned away because it attached before the terminal reported its session.
  /// The attach waits, binds nothing, and completes once the root arrives.
  func testAnAttachBeforeTheSessionRootCompletesWhenTheRootArrives() async throws {
    let channel = host.openRepl(history: ["(+ 1 2)"])
    let peer = try await attachPeer(to: channel)

    try await Task.sleep(for: .milliseconds(200))

    XCTAssertFalse(channel.isAttached, "the helper attached with no session root")

    channel.setSessionRoot(testRoot, generation: 1)

    guard case .history(let lines, true) = try await read(peer) else {
      return XCTFail("the waiting helper never got its history")
    }

    XCTAssertEqual(lines, ["(+ 1 2)"])
    expect(await waitUntil { channel.isAttached })

    channel.end()
  }

  /// A process outside every session, which stands in for another pane's session root.
  private func standIn() throws -> HelperHandle {
    try HelperHandle.spawn(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], environment: [:],
      standardOutput: .null, standardError: .null,
      deadlines: [HelperDeadline(after: .seconds(90), signal: SIGKILL)])
  }

  /// Catches a stolen token that binds a process from another pane. The token is presented from a
  /// process outside the channel's session, both after the root arrived and before it. Either way
  /// the attach is refused, the second time once the root arrives.
  func testATokenPresentedFromOutsideTheChannelsSessionIsRefused() async throws {
    let other = try standIn()

    defer { other.signal(SIGKILL) }

    let otherRoot = ProcessIdentity(
      pid: other.pid, started: try XCTUnwrap(ProcessInspection.startTime(of: other.pid)))

    host.recordSessionRoot(otherRoot, sessionGeneration: 1, window: 1, pane: NodeID(rawValue: 2))

    for rootFirst in [true, false] {
      let channel = host.openRepl(history: [])

      if rootFirst { channel.setSessionRoot(otherRoot, generation: 1) }

      let peer = try await attachPeer(to: channel)

      if !rootFirst {
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(channel.isAttached)
        channel.setSessionRoot(otherRoot, generation: 1)
      }

      guard case .attachRefused = try await read(peer) else {
        return XCTFail("a token from outside the session bound, root first: \(rootFirst)")
      }

      XCTAssertFalse(channel.isAttached)

      channel.end()
    }
  }

  /// Catches a REPL connection whose binding a stale request could move to another pane. A real
  /// helper sends nothing before its history, but a raw peer can call while its attach waits for
  /// the session root. That call is refused without asking the user. Once the attach completes,
  /// no request waits for the connection, and a grant to another pane's session is refused.
  func testACallWhileTheAttachWaitsLeavesNoRequestThatCanMoveTheBinding() async throws {
    let other = try standIn()

    defer { other.signal(SIGKILL) }

    let otherRoot = ProcessIdentity(
      pid: other.pid, started: try XCTUnwrap(ProcessInspection.startTime(of: other.pid)))
    let otherPane = NodeID(rawValue: 2)

    host.recordSessionRoot(otherRoot, sessionGeneration: 1, window: 1, pane: otherPane)

    let channel = host.openRepl(history: [])
    let peer = try await attachPeer(to: channel)

    expect(await waitUntil { !self.host.awaitingRoot.isEmpty }, "the attach never waited")

    let connection = try XCTUnwrap(host.awaitingRoot.keys.first)

    try peer.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    guard case .reply(1, .failure(.refused, _)) = try await read(peer) else {
      return XCTFail("a call while the attach waited was not refused")
    }

    channel.setSessionRoot(testRoot, generation: 1)

    guard case .history = try await read(peer) else {
      return XCTFail("the attach never completed")
    }

    XCTAssertEqual(host.allPendingRequests(), [], "a request waits for a bound REPL connection")

    guard case .failed = host.grantAccess(connection: connection, window: 1, pane: otherPane)
    else { return XCTFail("a bound REPL connection was granted another pane") }

    XCTAssertEqual(host.listener.findConnection(connection)?.binding?.root, testRoot)

    channel.end()
  }

  /// Catches a REPL helper that attaches to a session that was replaced. The channel's root is no
  /// longer the one recorded with its generation, so the attach is refused.
  func testAnAttachToASessionThatWasReplacedIsRefused() async throws {
    let channel = host.openRepl(history: [])

    channel.setSessionRoot(testRoot, generation: 2)

    let peer = try await attachPeer(to: channel)

    guard case .attachRefused = try await read(peer) else {
      return XCTFail("a helper of a replaced session attached")
    }

    channel.end()
  }

  // MARK: A helper's end

  /// Catches an ended helper's call that still runs. The helper sends a status message, and its
  /// channel ends before the host reads the call, as a restart ends it. The message never posts,
  /// and the helper's connection closes.
  func testAnEndedChannelRunsNoCallItsHelperHadAlreadySent() async throws {
    let channel = openTestRepl(host: host)
    let peer = try await attachPeer(to: channel)

    guard case .history = try await read(peer) else { return XCTFail("the helper got no history") }

    expect(await waitUntil { channel.isAttached })

    try peer.send(
      ScriptHelperMessage.request(id: 1, call: .postStatus(level: .info, text: "late")).frame())

    // The main actor is held, so the listener's reader takes the call and queues it for the host
    // before the channel ends, and the host reads it only after.
    usleep(200_000)

    channel.end()

    do {
      let message = try await read(peer)

      XCTFail("the ended helper's call was answered: \(message)")
    } catch {}

    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(center.history.map(\.text), [], "an ended helper's call ran")
  }
}
