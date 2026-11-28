import AppKit
import AppletFixtures
import XCTest

@testable import AppletKit
@testable import SourceAccess

/// A path argument through shared dispatch. The host opens each path inside the caller's scope
/// before the command is queued, and the dispatcher checks the grant again as it delivers the
/// command. The fixture reads what the host opened and never sees a path.
@MainActor
final class ControlDispatcherPathTests: XCTestCase {
  private var turns: [@MainActor () -> Void] = []
  private var base: URL!
  private var scope: ReadScope!

  override func setUpWithError() throws {
    base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-paths-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()

    let manager = FileManager.default

    for name in ["scope", "outside"] {
      try manager.createDirectory(
        at: base.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    try Data("inside".utf8).write(to: base.appendingPathComponent("scope/a.txt"))
    try Data("second".utf8).write(to: base.appendingPathComponent("scope/b.txt"))
    try Data("secret".utf8).write(to: base.appendingPathComponent("outside/s.txt"))
    try manager.createSymbolicLink(
      atPath: base.appendingPathComponent("scope/escape.txt").path,
      withDestinationPath: base.appendingPathComponent("outside/s.txt").path)

    scope = try ReadScope(directories: [base.appendingPathComponent("scope").path])

    let folder = base!

    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
  }

  private func path(_ name: String) -> String { base.appendingPathComponent(name).path }

  private func dispatcher() -> ControlDispatcher {
    ControlDispatcher { [weak self] body in self?.turns.append(body) }
  }

  private func turn() {
    let bodies = turns
    turns = []
    for body in bodies { body() }
  }

  private func submission(_ name: String, _ arguments: JSONValue) -> AppletCommandSubmission {
    AppletCommandSubmission(
      appletType: PathsFixture.typeID, schemaVersion: AppletSchemaVersion(0, 0), name: name,
      arguments: arguments)
  }

  /// Opens like the window does: each path named by the dispatcher, inside the scope.
  private func reads(
    _ dispatch: ControlDispatcher, _ submitted: AppletCommandSubmission, _ applet: PathsFixture,
    scope: ReadScope?, access: (@MainActor () -> ReadAccess)? = nil
  ) -> CommandReads {
    var opened: [String: Result<OpenedPath, ScopedOpenError>] = [:]

    for (name, path) in dispatch.pathArguments(of: submitted, for: applet) {
      opened[name] =
        scope.map { ScopedOpen.open(path: path, in: $0) } ?? .failure(.unavailable)
    }

    return CommandReads(opened: opened, access: access ?? { ReadAccess(scope: scope) })
  }

  private func run(
    _ name: String, _ arguments: JSONValue, on applet: PathsFixture, scope: ReadScope?,
    authority: @escaping ControlDispatcher.Authority = { nil },
    access: (@MainActor () -> ReadAccess)? = nil, beforeTurn: () -> Void = {}
  ) -> Result<JSONValue, AppletCommandError>? {
    let dispatch = dispatcher()
    let submitted = submission(name, arguments)
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(
      submitted, to: applet, authority: authority,
      reads: reads(dispatch, submitted, applet, scope: scope, access: access),
      reply: { result = $0 })

    beforeTurn()
    turn()

    return result
  }

  private func fileArgs(_ name: String) -> JSONValue { .object(["path": .string(path(name))]) }

  /// Catches a path the applet reads without the host: a file in the scope reads, and the applet is
  /// handed the contents through a descriptor with the argument itself read as null.
  func testAFileInTheScopeReadsAndTheAppletNeverSeesThePath() {
    let applet = PathsFixture()
    let result = run("read-file", fileArgs("scope/a.txt"), on: applet, scope: scope)

    XCTAssertEqual(result, .success(.object(["text": .string("inside")])))
    XCTAssertEqual(applet.lastArguments, ["path": .null])
  }

  /// Catches a path nested in an array reaching the applet raw, or out of order.
  func testPathsInAnArrayAreOpenedInOrder() {
    let applet = PathsFixture()
    let arguments = JSONValue.object([
      "paths": .array([.string(path("scope/b.txt")), .string(path("scope/a.txt"))])
    ])

    let result = run("read-files", arguments, on: applet, scope: scope)

    XCTAssertEqual(
      result,
      .success(.object(["texts": .array([.string("second"), .string("inside")])])))
    XCTAssertEqual(applet.lastArguments, ["paths": .array([.null, .null])])
  }

  /// Catches a command with a path that runs for a caller with no power, and a path outside the
  /// scope that tells what it was: a file that exists, a missing one, a link out, and the
  /// protected-by-absence case of no scope at all must all give one refusal.
  func testNoPowerAndOutOfScopePathsAreRefusedAlike() {
    let applet = PathsFixture()
    var refusals: [Result<JSONValue, AppletCommandError>?] = []

    for name in ["outside/s.txt", "outside/missing.txt", "scope/escape.txt", "/etc/hosts"] {
      refusals.append(
        run(
          "read-file", .object(["path": .string(name.hasPrefix("/") ? name : path(name))]),
          on: applet, scope: scope))
    }

    refusals.append(run("read-file", fileArgs("scope/a.txt"), on: applet, scope: nil))

    for refusal in refusals {
      XCTAssertEqual(refusal, .failure(ControlDispatcher.unreadable))
    }

    XCTAssertEqual(applet.lastArguments, [:], "no refused command reached the applet")
  }

  /// Catches a caller that supplies no opens at all, as an exec driver does: a command that names
  /// a path is refused, and one that names none is not affected.
  func testACallerWithoutOpensCannotNameAPath() {
    let dispatch = dispatcher()
    let applet = PathsFixture()
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(
      submission("read-file", fileArgs("scope/a.txt")), to: applet, authority: { nil },
      reply: { result = $0 })

    XCTAssertEqual(result, .failure(ControlDispatcher.unreadable))

    dispatch.submit(
      submission("seen", .object([:])), to: applet, authority: { nil }, reply: { result = $0 })
    turn()

    XCTAssertEqual(result, .success(.object(["arguments": .object([:])])))
  }

  /// Catches a revoked grant that still reads what was queued. The authority is asked again at
  /// delivery, so a command queued before the revocation reads nothing.
  func testRevokingTheGrantStopsAQueuedRead() {
    let applet = PathsFixture()
    let granted = Toggle(true)

    let result = run(
      "read-file", fileArgs("scope/a.txt"), on: applet, scope: scope,
      authority: { granted.on ? nil : AppletCommandError(.refused, "revoked") },
      beforeTurn: { granted.on = false })

    XCTAssertEqual(result, .failure(AppletCommandError(.refused, "revoked")))
    XCTAssertEqual(applet.lastArguments, [:])
  }

  /// Catches a scope that narrowed while the command waited and still reads under the old one.
  func testANarrowedScopeStopsAQueuedRead() throws {
    let applet = PathsFixture()
    let narrowed = Toggle(false)
    let elsewhere = try ReadScope(directories: [path("outside")])

    let result = run(
      "read-file", fileArgs("scope/a.txt"), on: applet, scope: scope,
      access: { ReadAccess(scope: narrowed.on ? elsewhere : self.scope) },
      beforeTurn: { narrowed.on = true })

    XCTAssertEqual(result, .failure(ControlDispatcher.unreadable))
    XCTAssertEqual(applet.lastArguments, [:])
  }

  /// Catches a malformed path argument reaching the host's open: a relative path, a number, and a
  /// string over the limit all fail validation first.
  func testAPathArgumentMustBeAnAbsoluteString() {
    let applet = PathsFixture()
    let tooLong = "/" + String(repeating: "a", count: 1100)

    for value in [JSONValue.string("relative.txt"), .number(3), .string(tooLong), .null] {
      let result = run("read-file", .object(["path": value]), on: applet, scope: scope)

      guard case .failure(let error)? = result else { return XCTFail("\(value) was not refused") }

      XCTAssertEqual(error.code, .badArgument)
    }
  }
}

private final class Toggle {
  var on: Bool

  init(_ on: Bool) {
    self.on = on
  }
}
