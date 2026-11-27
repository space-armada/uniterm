import ControllerPackage
import ControllerTestSupport
import CryptoKit
import Darwin
import FileRouting
import Foundation
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// The declared file protocol and the one-session rule, with raw peers that play the command and
/// a fake app that plays the app.
@MainActor
final class DeclaredFileProtocolTests: XCTestCase {
  private var directory: URL!
  private var work: URL!
  private var runs: URL!
  private var host: ScriptHost!
  private var refusals: [ScriptRefusal] = []

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    runs = work.appendingPathComponent("runs")
  }

  override func tearDown() async throws {
    host?.stop()
    try? FileManager.default.removeItem(at: directory)
    ControllerSnapshot.removeStale(in: runs)
    try? FileManager.default.removeItem(at: work)
  }

  private func startHost(helper: any ControllerHelperIdentity) throws {
    host = try ScriptFixtures.makeFileHost(
      directory: directory, work: work, helper: helper,
      onRefusal: { [weak self] in self?.refusals.append($0) })
  }

  private func connect() async throws -> FramedSocket {
    try await ScriptFixtures.openPeer(host: host)
  }

  private func read(_ peer: FramedSocket) async throws -> ScriptAppMessage {
    try await ScriptFixtures.readMessage(peer)
  }

  /// True when the next read finds the connection closed.
  private func isClosed(_ peer: FramedSocket) async -> Bool {
    do {
      _ = try await read(peer)

      return false
    } catch WireError.closed {
      return true
    } catch {
      return false
    }
  }

  private func declaredFile(_ body: String = "(print :ran)") throws -> URL {
    let file = work.appendingPathComponent("f-\(UUID().uuidString.prefix(6)).janet")

    try Data("(declare-permissions {:kind :pane-control})\n\(body)\n".utf8)
      .write(to: file)

    return file
  }

  private var runFolders: [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
  }

  // MARK: Authentication

  /// Catches a file that is read for a program that is not the bundle's command. A raw peer's file
  /// begin is refused before the app opens the file, so no run folder is ever made.
  func testAPeerThatIsNotTheBundleCommandIsRefusedBeforeAnySnapshot() async throws {
    try startHost(helper: BundleHelperIdentity(helperURL: try HardenedHelper.url()))

    let peer = try await connect()

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.fileBegin(FileBegin(path: try declaredFile().path)).frame())

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("a raw peer was answered with something other than a refusal")
    }

    XCTAssertTrue(text.contains("Only the uniterm command"), text)
    XCTAssertTrue(runFolders.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: runs.path), "a snapshot folder was made")
  }

  // MARK: Reading the file

  /// Catches a snapshot refusal that never reaches the peer, or that leaves a run folder. The
  /// snapshot tests hold every kind of file the copy refuses. This holds that the app turns one
  /// refusal into a wire refusal and removes what it made.
  func testASnapshotRefusalReachesThePeerAndLeavesNoRunFolder() async throws {
    try startHost(helper: AcceptingHelper())

    let fifo = work.appendingPathComponent("p.fifo")

    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

    let peer = try await connect()

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.fileBegin(FileBegin(path: fifo.path)).frame())

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("a pipe was not refused")
    }

    XCTAssertTrue(text.contains("is not a regular file"), text)
    XCTAssertTrue(runFolders.isEmpty, "a refused file left a snapshot: \(runFolders)")
  }

  // MARK: The declaration

  /// Catches a file begin whose declaration never comes holding the connection and a snapshot for
  /// ever. After the bound the run is refused and the copy is removed.
  func testAFileBeginWhoseDeclarationNeverArrivesIsRefusedAfterABound() async throws {
    try startHost(helper: AcceptingHelper())

    host.fileDeclarationTimeout = 0.3

    let peer = try await connect()

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.fileBegin(FileBegin(path: try declaredFile().path)).frame())

    guard case .fileAdmitted = try await read(peer) else {
      return XCTFail("the file was not admitted to the declaration stage")
    }

    XCTAssertEqual(runFolders.count, 1)

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("a missing declaration was not refused")
    }

    XCTAssertTrue(text.contains("did not report"), text)
    expect(await waitUntil { self.runFolders.isEmpty }, "the copy outlived the refusal")
    XCTAssertTrue(host.pendingDeclarations.isEmpty)
  }

  /// Catches a call that is answered before the run is admitted, while the copy waits for its
  /// declaration and while the declaration waits for review.
  func testACallBeforeAdmissionIsRefused() async throws {
    try startHost(helper: AcceptingHelper())

    let peer = try await connect()

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.fileBegin(FileBegin(path: try declaredFile().path)).frame())

    guard case .fileAdmitted = try await read(peer) else { return XCTFail("not admitted") }

    try peer.send(
      ScriptHelperMessage.request(id: 1, call: .postStatus(level: .info, text: "early")).frame())

    guard case .reply(1, .failure(.refused, let text)) = try await read(peer) else {
      return XCTFail("an early call was not refused")
    }

    XCTAssertTrue(text.contains("has not admitted this script yet"), text)
  }

  /// Catches a second declaration on one connection being believed, and a declaration from a
  /// connection that began no file. Either ends the connection.
  func testASecondOrUnsolicitedDeclarationEndsTheConnection() async throws {
    try startHost(helper: AcceptingHelper())

    let json = #"{"permissions":[]}"#
    let stray = try await connect()

    defer { stray.shutdownAndClose() }

    try stray.send(ScriptHelperMessage.fileDeclaration(json).frame())
    expect(await isClosed(stray), "a stray declaration was accepted")

    host.processSessions = [:]

    let peer = try await connect()

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.fileBegin(FileBegin(path: try declaredFile().path)).frame())

    guard case .fileAdmitted = try await read(peer) else { return XCTFail("not admitted") }

    try peer.send(ScriptHelperMessage.fileDeclaration(json).frame())

    guard case .controllerAdmitted = try await read(peer) else {
      return XCTFail("an empty declaration was not admitted")
    }

    try peer.send(ScriptHelperMessage.fileDeclaration(json).frame())
    expect(await isClosed(peer), "a second declaration was accepted")
  }

  /// Catches an app that believes a declaration it cannot read: a repeated kind, an unknown
  /// field, and text that is not JSON are each refused by the app itself, whatever the command
  /// checked.
  func testTheAppReadsTheDeclarationItself() async throws {
    try startHost(helper: AcceptingHelper())

    let bad = [
      (
        #"{"permissions":[{"kind":"pane-control"},{"kind":"pane-control"}]}"#,
        "pane-control is listed twice"
      ),
      (#"{"permissions":[],"extra":1}"#, "unknown field"),
      ("not json", "declaration"),
    ]

    for (json, fragment) in bad {
      host.processSessions = [:]

      let peer = try await connect()

      defer { peer.shutdownAndClose() }

      try peer.send(
        ScriptHelperMessage.fileBegin(FileBegin(path: try declaredFile().path)).frame())

      guard case .fileAdmitted = try await read(peer) else { return XCTFail("not admitted") }

      try peer.send(ScriptHelperMessage.fileDeclaration(json).frame())

      guard case .controllerRefused(let text) = try await read(peer) else {
        return XCTFail("\(json) was not refused")
      }

      XCTAssertTrue(text.contains(fragment), "\(json): \(text)")
    }

    expect(await waitUntil { self.runFolders.isEmpty }, "a refused declaration left a copy")
  }

  // MARK: One session per command process

  /// Catches a second begin from a process that already has a session, for each way to begin one.
  /// The raw peers here share this process, so they stand for script code that opens a second
  /// connection from a command process.
  func testASecondBeginFromOneProcessIsRefusedForEveryKindOfSession() async throws {
    try startHost(helper: AcceptingHelper())

    let first = try await connect()

    defer { first.shutdownAndClose() }

    try first.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "first")).frame())

    guard case .controllerRefused(let strictText) = try await read(first) else {
      return XCTFail("the first begin was not answered")
    }

    XCTAssertTrue(strictText.contains("strict mode"), strictText)

    let plain = try await connect()

    defer { plain.shutdownAndClose() }

    try plain.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "second")).frame())

    guard case .controllerRefused(let plainText) = try await read(plain) else {
      return XCTFail("a second undeclared begin was not refused")
    }

    XCTAssertEqual(plainText, ScriptHost.secondSessionText)

    let controller = try await connect()

    defer { controller.shutdownAndClose() }

    try controller.send(
      ScriptHelperMessage.controllerBegin(ControllerBegin(entry: .janet, package: "/tmp/none"))
        .frame())

    guard case .controllerRefused(let controllerText) = try await read(controller) else {
      return XCTFail("a second controller begin was not refused")
    }

    XCTAssertEqual(controllerText, ScriptHost.secondSessionText)

    let file = try await connect()

    defer { file.shutdownAndClose() }

    try file.send(ScriptHelperMessage.fileBegin(FileBegin(path: try declaredFile().path)).frame())

    guard case .controllerRefused(let fileText) = try await read(file) else {
      return XCTFail("a second file begin was not refused")
    }

    XCTAssertEqual(fileText, ScriptHost.secondSessionText)

    let repl = try await connect()

    defer { repl.shutdownAndClose() }

    let channel = openTestRepl(host: host, history: [])
    let token = try XCTUnwrap(ReplEnvironmentHex.decode(channel.launch.token))

    try repl.send(ScriptHelperMessage.attach(token: token).frame())

    guard case .attachRefused(let replText) = try await read(repl) else {
      return XCTFail("a second attach was not refused")
    }

    XCTAssertEqual(replText, ScriptHost.secondSessionText)
    XCTAssertTrue(runFolders.isEmpty)
    XCTAssertEqual(refusals.filter { $0 == .secondSession }.count, 4)
  }

  /// Catches a refused or finished session being forgotten. A process whose run was refused, and
  /// one whose connection has closed, still cannot begin another.
  func testTheTableOutlivesTheConnectionAndCountsRefusedSessions() async throws {
    try startHost(helper: AcceptingHelper())

    let refused = try await connect()

    try refused.send(
      ScriptHelperMessage.fileBegin(FileBegin(path: work.appendingPathComponent("none").path))
        .frame())

    guard case .controllerRefused = try await read(refused) else {
      return XCTFail("a missing file was not refused")
    }

    refused.shutdownAndClose()

    let again = try await connect()

    defer { again.shutdownAndClose() }

    try again.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "later")).frame())

    guard case .controllerRefused(let text) = try await read(again) else {
      return XCTFail("a refused session freed its process")
    }

    XCTAssertEqual(text, ScriptHost.secondSessionText)
  }

  /// Catches the rule being applied to a program that is not the command. A generic peer keeps
  /// the admission any program on the socket gets and may open as many plain sessions as it likes.
  func testAGenericPeerKeepsItsPlainSessions() async throws {
    try startHost(helper: RejectingHelper())

    var peers: [FramedSocket] = []

    defer {
      for peer in peers { peer.shutdownAndClose() }
    }

    for index in 0..<3 {
      let peer = try await connect()

      peers.append(peer)
      try peer.send(ScriptHelperMessage.begin(name: "generic-\(index)").frame())
      try peer.send(
        ScriptHelperMessage.request(id: 1, call: .postStatus(level: .info, text: "hi")).frame())

      guard case .reply(1, .ok) = try await read(peer) else {
        return XCTFail("generic session \(index) was not served")
      }
    }

    XCTAssertTrue(refusals.isEmpty, "\(refusals)")
  }

  /// Catches a table that never prunes, or that prunes a process that still runs. It holds 1024
  /// entries, 600 of them for processes that have exited. A new begin drops exactly those.
  func testTheTableIsBoundedAndPrunesOnlyDeadProcesses() async throws {
    try startHost(helper: AcceptingHelper())

    let dead = 600
    let first = 1_000_000

    for index in 0..<ScriptHost.maxProcessSessions {
      host.processSessions[
        ProcessSessionKey(pid: pid_t(first + index), started: index, version: 1)
      ] = 0
    }

    host.processIsLive = { pid, _ in Int(pid) >= first + dead }

    let peer = try await connect()

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "late")).frame())

    let expected = ScriptHost.maxProcessSessions - dead + 1

    expect(
      await waitUntil { self.host.processSessions.count == expected },
      "pruning left \(host.processSessions.count) entries, not \(expected)")
    XCTAssertFalse(refusals.contains(.secondSession), "dead entries were not dropped")
    XCTAssertTrue(
      host.processSessions.keys.allSatisfy { Int($0.pid) >= first + dead || $0.pid == getpid() })
  }

  /// Catches a table full of live processes taking one more. A begin that finds no room is
  /// refused, and the table does not grow.
  func testATableFullOfLiveProcessesRefusesANewBegin() async throws {
    try startHost(helper: AcceptingHelper())

    for index in 0..<ScriptHost.maxProcessSessions {
      host.processSessions[
        ProcessSessionKey(pid: pid_t(1_000_000 + index), started: index, version: 1)
      ] = 0
    }

    host.processIsLive = { _, _ in true }

    let plain = try await connect()

    defer { plain.shutdownAndClose() }

    try plain.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "late")).frame())

    guard case .controllerRefused(let plainText) = try await read(plain) else {
      return XCTFail("a begin was taken with no room")
    }

    XCTAssertEqual(plainText, ScriptHost.secondSessionText)

    let file = try await connect()

    defer { file.shutdownAndClose() }

    try file.send(ScriptHelperMessage.fileBegin(FileBegin(path: try declaredFile().path)).frame())

    guard case .controllerRefused(let text) = try await read(file) else {
      return XCTFail("a file begin was taken with no room")
    }

    XCTAssertEqual(text, ScriptHost.secondSessionText)
    XCTAssertEqual(host.processSessions.count, ScriptHost.maxProcessSessions)
    XCTAssertTrue(runFolders.isEmpty)
  }

  /// Catches a program that is not the bundled command taking a place in the table. Its begins are
  /// refused by the admission, and the table stays empty, so such a peer cannot lock the command
  /// out by filling it.
  func testAPeerThatIsNotTheCommandTakesNoPlaceInTheTable() async throws {
    try startHost(helper: RejectingHelper())

    for index in 0..<5 {
      let peer = try await connect()

      defer { peer.shutdownAndClose() }

      if index.isMultiple(of: 2) {
        try peer.send(
          ScriptHelperMessage.fileBegin(FileBegin(path: try declaredFile().path)).frame())
      } else {
        try peer.send(
          ScriptHelperMessage.controllerBegin(ControllerBegin(entry: .janet, package: "/tmp/none"))
            .frame())
      }

      guard case .controllerRefused(let text) = try await read(peer) else {
        return XCTFail("a begin from a program that is not the command was not refused")
      }

      XCTAssertEqual(text, "not the command")
    }

    XCTAssertTrue(host.processSessions.isEmpty, "\(host.processSessions)")
    XCTAssertTrue(runFolders.isEmpty)
  }

  // MARK: The command's checks of the app's copy

  /// Runs the command on a declared file against a fake app that answers the file begin with
  /// `copy`, under the version `claimed`. The fake app never admits the run. It reports whether
  /// the command went on to send a declaration.
  ///
  /// With `thenSwapping`, the fake app overwrites the copy once the declaration arrives, and then
  /// admits the run, so a command that reads the copy again would run the swapped bytes.
  private func runAgainstFakeApp(
    copy: String, claimed: Data?, thenSwapping swapped: String? = nil
  ) async throws -> (result: HelperRun, declared: Bool) {
    let socketPath = directory.appendingPathComponent("fake-\(UUID().uuidString.prefix(4)).sock")
      .path
    let listening = try ScriptSocketFiles.bindListening(path: socketPath)
    let file = try declaredFile("(print :ran)")
    let snapshot = work.appendingPathComponent("copy-\(UUID().uuidString.prefix(4)).janet")
    let version = claimed ?? Data(SHA256.hash(data: Data(copy.utf8)))

    try Data(copy.utf8).write(to: snapshot)

    let sawDeclaration = DeclarationFlag()
    let server = Thread {
      let accepted = accept(listening, nil, nil)

      guard accepted >= 0 else { return }

      let peer = FramedSocket(descriptor: accepted)

      defer { peer.shutdownAndClose() }

      do {
        _ = try peer.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))
        try peer.send(ScriptAppMessage.hello(version: ScriptProtocol.version).frame())
        _ = try peer.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))
        try peer.send(
          ScriptAppMessage.fileAdmitted(snapshot: snapshot.path, version: version).frame())

        while true {
          let frame = try peer.readFrame(limit: ScriptHelperMessage.bodyLimit(type:))

          if frame.type == 12 {
            sawDeclaration.set()

            if let swapped {
              try? FileManager.default.removeItem(at: snapshot)
              try Data(swapped.utf8).write(to: snapshot)
              try peer.send(
                ScriptAppMessage.controllerAdmitted(snapshot: snapshot.path, version: version)
                  .frame())
            } else {
              try peer.send(ScriptAppMessage.controllerRefused("fake app stop").frame())
            }
          }
        }
      } catch {}
    }

    server.start()

    defer { close(listening) }

    let run = try await ScriptFixtures.finish(
      try HelperHandle.spawn(
        executable: try HardenedHelper.url(),
        arguments: ["run", "--socket", socketPath, file.path],
        environment: ProcessInfo.processInfo.environment.filter {
          !$0.key.hasPrefix("DYLD_") && $0.key != "UNITERM_SOCKET"
        },
        deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)]))

    return (run, sawDeclaration.isSet)
  }

  /// Catches a command that parses or runs bytes whose hash differs from the version the app
  /// sent. A fake app answers a file begin with a copy that is not the file it hashed, and the
  /// command refuses it without reading the copy's declaration, which would be its own error.
  func testTheCommandRefusesACopyWhoseHashDiffersBeforeParsingIt() async throws {
    // A second declaration is an error the reader names, so seeing "did not verify" instead proves
    // the command never parsed these bytes.
    let outcome = try await runAgainstFakeApp(
      copy: "(declare-permissions)\n(declare-permissions)\n(print :tampered)\n",
      claimed: Data(repeating: 0xAB, count: 32))

    XCTAssertNotEqual(outcome.result.status, 0)
    XCTAssertEqual(outcome.result.standardOutput, "")
    XCTAssertTrue(
      outcome.result.standardError.contains("did not verify"), outcome.result.standardError)
    XCTAssertFalse(outcome.result.standardError.contains("appears again"))
    XCTAssertFalse(outcome.declared, "the command reported a declaration for a bad copy")
  }

  /// Catches a command that reads the copy again after the app admits the run, which would run
  /// bytes the hash never covered. The copy is swapped before the admission arrives, and the run
  /// prints what was hashed.
  func testTheCommandRunsTheBytesItHashedAndNotASecondReadOfTheCopy() async throws {
    let outcome = try await runAgainstFakeApp(
      copy: "(declare-permissions)\n(print :hashed)\n", claimed: nil,
      thenSwapping: "(declare-permissions)\n(print :swapped)\n")

    XCTAssertEqual(outcome.result.status, 0, outcome.result.standardError)
    XCTAssertEqual(outcome.result.standardOutput, "hashed\n")
    XCTAssertTrue(outcome.declared)
  }

  /// Catches a command that runs the app's copy as an undeclared script when its first form is
  /// not a declaration, which a file changed after the command's own read would otherwise get. The
  /// copy's hash is right, so only the first form is wrong.
  func testACopyWhoseFirstFormIsNotADeclarationIsRefusedNotRunUndeclared() async throws {
    let outcome = try await runAgainstFakeApp(copy: "(print :undeclared)\n", claimed: nil)

    XCTAssertNotEqual(outcome.result.status, 0)
    XCTAssertEqual(outcome.result.standardOutput, "")
    XCTAssertTrue(
      outcome.result.standardError.contains("first form is not (declare-permissions ...)"),
      outcome.result.standardError)
    XCTAssertFalse(outcome.declared)
  }

  /// Catches a copy whose declaration is invalid reaching the app. The command reads it from the
  /// copy, names the problem, and sends nothing.
  func testACopyWithAnInvalidDeclarationIsRefusedByTheCommandItself() async throws {
    let outcome = try await runAgainstFakeApp(
      copy: "(declare-permissions {:kind :pane-control :kind :pane-control})\n",
      claimed: nil)

    XCTAssertNotEqual(outcome.result.status, 0)
    XCTAssertTrue(
      outcome.result.standardError.contains("repeats a key"), outcome.result.standardError)
    XCTAssertFalse(outcome.declared)
  }

  /// Catches an older command and a newer app that go on to talk. Version 9 knows no file begin,
  /// so the app answers its hello and refuses it before any effect.
  func testACommandOfAnotherVersionIsRefusedAtTheHello() async throws {
    try startHost(helper: AcceptingHelper())

    let peer = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version + 1).frame())

    guard case .hello(let version) = try await read(peer) else {
      return XCTFail("the app did not answer the hello")
    }

    XCTAssertEqual(version, ScriptProtocol.version)
    expect(await isClosed(peer), "the app went on after a version mismatch")
    expect(
      await waitUntil {
        self.refusals.contains(.versionMismatch(found: ScriptProtocol.version + 1))
      },
      "the mismatch was not reported")
  }
}

private final class DeclarationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }

    return value
  }
}
