import Darwin
import FileRouting
import Foundation
import ProcessInspection
import ScriptWire
import XCTest

@testable import ScriptHost

/// A command identity whose path and kept hash a test chooses.
private struct FixedCommand: ControllerHelperIdentity {
  var path: String?
  var kept: Data?

  func refusal(forPeer token: AuditToken) -> String? { nil }

  var commandPath: String? { path }

  func keptCodeDirectoryHash() -> Data? { kept }
}

private final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  private var refusal: ScriptRefusal?

  func note(_ item: String) {
    lock.lock()
    items.append(item)
    lock.unlock()
  }

  func refuse(_ value: ScriptRefusal) {
    lock.lock()
    refusal = value
    lock.unlock()
  }

  var all: [String] {
    lock.lock()
    defer { lock.unlock() }

    return items
  }

  var refused: ScriptRefusal? {
    lock.lock()
    defer { lock.unlock() }

    return refusal
  }
}

/// The bundled command proves it comes from the same build as the running app. These tests drive
/// raw peers against a listener that holds a command identity. The test process stands in for the
/// command, since the identity check keys on the peer's executable path. They prove the refusals,
/// their texts, and their order. `ControllerRunTests` and the declared file tests run the real
/// command against the same check. Nothing here swaps a bundle on disk, which
/// `BundleHelperIdentityTests` covers apart from any peer.
final class CommandIdentityTests: XCTestCase {
  private var directory: URL!
  private let kept = Data(repeating: 0xAA, count: 20)
  private let other = Data(repeating: 0xBB, count: 20)

  private var ownPath: String { ProcessInspection.executablePath(of: getpid()) ?? "" }

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// A peer that has said hello and read the app's answer.
  private func open(_ listener: ScriptListener) throws -> FramedSocket {
    let socket = try ScriptFixtures.connectPeer(path: listener.path)

    try socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    return socket
  }

  private func read(_ socket: FramedSocket) throws -> ScriptAppMessage {
    let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
  }

  /// Drives the listener until a refusal or a begin, and returns what it saw.
  private func outcome(of listener: ScriptListener) async -> Seen {
    let seen = Seen()

    _ = await listener.drive(timeout: .seconds(15)) { event in
      switch event {
      case .refused(_, let refusal):
        seen.refuse(refusal)

        return true

      case .begun(_, let name):
        seen.note("begun \(name)")

        return true

      case .controllerBegun:
        seen.note("controller begun")

        return true

      case .attached:
        seen.note("attached")

        return true

      default:
        return false
      }
    }

    return seen
  }

  /// Catches a swapped command from this bundle that is admitted, or one that is told to do
  /// anything but relaunch. The peer runs from the app's own command path and presents an identity
  /// the app did not keep. It never reaches `begin`, and it reads the refusal.
  func testASwappedCommandFromThisBundleIsRefusedWithTheRelaunchText() async throws {
    let listener = try ScriptListener.start(
      directory: directory, commandIdentity: FixedCommand(path: ownPath, kept: kept))

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.identity(codeDirectoryHash: other).frame())
    try peer.send(
      ScriptHelperMessage.controllerBegin(ControllerBegin(entry: .janet, package: "/p")).frame())

    guard case .controllerRefused(let text) = try read(peer) else {
      return XCTFail("the app did not refuse the swapped command")
    }

    XCTAssertTrue(text.contains("Relaunch uniterm"), text)
    XCTAssertTrue(text.contains(ownPath), text)

    let seen = await outcome(of: listener)

    XCTAssertEqual(seen.refused, .commandIdentity(text))
    XCTAssertEqual(seen.all, [], "a call ran before the refusal")
  }

  /// Catches a command from another install that is told to relaunch, which cannot fix it, or one
  /// that is not told where this app's own command is.
  func testACommandFromAnotherInstallIsToldWhereTheAppsOwnCommandIs() async throws {
    let own = "/Applications/Uniterm.app/Contents/Helpers/uniterm"
    let listener = try ScriptListener.start(
      directory: directory, commandIdentity: FixedCommand(path: own, kept: kept))

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.identity(codeDirectoryHash: other).frame())
    try peer.send(ScriptHelperMessage.questionBegin.frame())

    guard case .controllerRefused(let text) = try read(peer) else {
      return XCTFail("the app did not refuse the command of another install")
    }

    XCTAssertTrue(text.contains(own), text)
    XCTAssertFalse(text.contains("Relaunch"), text)
  }

  /// Catches a REPL that waits for an attach answer and gets another kind of message, which its
  /// reader would call unexpected, hiding the reason.
  func testAnAttachIsRefusedWithAnAttachRefusal() async throws {
    let listener = try ScriptListener.start(
      directory: directory, commandIdentity: FixedCommand(path: ownPath, kept: kept))

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.identity(codeDirectoryHash: other).frame())
    try peer.send(
      ScriptHelperMessage.attach(token: Data(repeating: 1, count: ScriptProtocol.tokenBytes))
        .frame())

    guard case .attachRefused(let text) = try read(peer) else {
      return XCTFail("the REPL was not refused as a REPL")
    }

    XCTAssertTrue(text.contains("Relaunch uniterm"), text)
  }

  /// Catches a command that is admitted with the hash the app kept, whatever path it runs from.
  func testTheCommandThatMatchesWhatTheAppKeptIsAdmitted() async throws {
    let listener = try ScriptListener.start(
      directory: directory, commandIdentity: FixedCommand(path: ownPath, kept: kept))

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.identity(codeDirectoryHash: kept).frame())
    try peer.send(ScriptHelperMessage.begin(name: "synthetic").frame())

    let seen = await outcome(of: listener)

    XCTAssertEqual(seen.all, ["begun synthetic"])
    XCTAssertNil(seen.refused)
  }

  /// Catches a command at the app's own path that skips the identity, such as a command built
  /// before the identity existed. The app cannot tell it from a swapped one, so it must refuse.
  func testACommandAtTheAppsOwnPathThatSendsNoIdentityIsRefused() async throws {
    let listener = try ScriptListener.start(
      directory: directory, commandIdentity: FixedCommand(path: ownPath, kept: kept))

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.questionBegin.frame())

    guard case .controllerRefused(let text) = try read(peer) else {
      return XCTFail("the app admitted a command that presented no identity")
    }

    XCTAssertTrue(text.contains("did not present its code identity"), text)
    XCTAssertTrue(text.contains("Relaunch uniterm"), text)
  }

  /// Catches a native controller that is refused for sending no identity. A program built against
  /// the ScriptWire library runs from its own path and never sends one, and is admitted as before.
  func testAProgramFromAnotherPathThatSendsNoIdentityIsAdmitted() async throws {
    let listener = try ScriptListener.start(
      directory: directory,
      commandIdentity: FixedCommand(
        path: "/Applications/Uniterm.app/Contents/Helpers/uniterm",
        kept: kept))

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.begin(name: "native").frame())

    let seen = await outcome(of: listener)

    XCTAssertEqual(seen.all, ["begun native"])
    XCTAssertNil(seen.refused)
  }

  /// Catches an app that admits a command it cannot compare. When the app could not read its own
  /// command, no identity can match, so a program that presents one is refused with that reason.
  func testAnIdentityIsRefusedWhenTheAppCouldNotReadItsOwnCommand() async throws {
    let listener = try ScriptListener.start(
      directory: directory, commandIdentity: FixedCommand(path: ownPath, kept: nil))

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.identity(codeDirectoryHash: kept).frame())
    try peer.send(ScriptHelperMessage.questionBegin.frame())

    guard case .controllerRefused(let text) = try read(peer) else {
      return XCTFail("the app admitted a command it could not compare")
    }

    XCTAssertTrue(text.contains("cannot read the signature of its own command"), text)
  }

  /// Catches an identity that may come after the declaration, or twice. It has one fixed place:
  /// right after the hello. The other order is a violation that names it, and nothing runs.
  func testTheIdentityAfterTheDeclarationOrTwiceIsRefusedByName() async throws {
    // A command at the app's own path that begins first is refused for sending no identity before
    // it, so the late identity is shown with a program from another path.
    for (order, path) in [("after", "/elsewhere/uniterm"), ("twice", ownPath)] {
      let listener = try ScriptListener.start(
        directory: directory, commandIdentity: FixedCommand(path: path, kept: kept))

      defer { listener.stop() }

      let peer = try open(listener)
      let identity = ScriptHelperMessage.identity(codeDirectoryHash: kept).frame()

      if order == "after" {
        try peer.send(ScriptHelperMessage.begin(name: "late").frame())
        try peer.send(identity)
      } else {
        try peer.send(identity)
        try peer.send(identity)
      }

      let seen = Seen()

      _ = await listener.drive(timeout: .seconds(15)) { event in
        if case .refused(_, let refusal) = event {
          seen.refuse(refusal)

          return true
        }

        return false
      }

      guard case .protocolViolation(let text)? = seen.refused else {
        XCTFail("\(order): refused as \(String(describing: seen.refused))")
        continue
      }

      XCTAssertTrue(text.contains("code identity"), "\(order): \(text)")
      XCTAssertTrue(text.contains("right after the hello"), "\(order): \(text)")
    }
  }

  /// Catches an app that admits every program when its own command has no path. That only comes
  /// from a broken bundle, so the listener refuses, with a reason that names the cause.
  func testAnIdentityThatNamesNoPathRefusesEveryProgram() async throws {
    let listener = try ScriptListener.start(
      directory: directory, commandIdentity: FixedCommand(path: nil, kept: kept))

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.questionBegin.frame())

    guard case .controllerRefused(let text) = try read(peer) else {
      return XCTFail("the app admitted a program with no known command path")
    }

    XCTAssertTrue(text.contains("does not know where its own command is"), text)
  }

  /// Catches a peer whose executable the kernel cannot name being taken for a native controller.
  /// A stale command at the app's own path sends no identity, and it would pass if an unknown
  /// path counted as another path. A peer with an identity is still compared.
  func testAPeerWhosePathIsUnknownAndSendsNoIdentityIsRefused() {
    let check = CommandIdentityCheck(helper: FixedCommand(path: "/app/Helpers/uniterm", kept: kept))

    let unknown = check.refusal(presented: nil, peerPath: nil)

    XCTAssertTrue(unknown?.contains("could not tell where the program") == true, "\(unknown ?? "")")
    XCTAssertNil(check.refusal(presented: nil, peerPath: "/elsewhere/native"))
    XCTAssertNil(check.refusal(presented: kept, peerPath: nil))
    XCTAssertNotNil(check.refusal(presented: other, peerPath: nil))
  }

  /// Catches a listener with no command identity that refuses a program for sending one. The
  /// package's own tests start listeners without one, and the real command sends it.
  func testAListenerWithNoCommandIdentityAdmitsAnyIdentity() async throws {
    let listener = try ScriptListener.startWithoutCommandIdentityForTests(directory: directory)

    defer { listener.stop() }

    let peer = try open(listener)

    try peer.send(ScriptHelperMessage.identity(codeDirectoryHash: other).frame())
    try peer.send(ScriptHelperMessage.begin(name: "plain").frame())

    let seen = await outcome(of: listener)

    XCTAssertEqual(seen.all, ["begun plain"])
  }

  /// Catches a refusal that picks its remedy from the numbers, or one that tells a program of
  /// another version to relaunch. Both directions say the same: name both versions, then rebuild
  /// the program against this uniterm or update uniterm.
  func testTheVersionRefusalNamesBothVersionsAndNeverSaysRelaunch() {
    for found: UInt16 in [14, 1, 0] {
      let text = ScriptRefusal.versionMismatch(found: found).text

      XCTAssertTrue(text.contains("version \(found)"), text)
      XCTAssertTrue(text.contains("version \(ScriptProtocol.version)"), text)
      XCTAssertTrue(text.contains("Rebuild the program against this uniterm"), text)
      XCTAssertTrue(text.contains("update uniterm"), text)
      XCTAssertFalse(text.contains("Relaunch"), text)
    }
  }
}
