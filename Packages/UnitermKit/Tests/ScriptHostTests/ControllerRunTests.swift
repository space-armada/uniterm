import ControllerPackage
import ControllerTestSupport
import Darwin
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// Controller runs end to end: the real command, the real Janet loader, a real native entry, and
/// the app's own admission, against a host whose window layer is a fake.
///
/// The app accepts only the bundle's command. Here that is a copy of the SwiftPM helper signed with
/// the hardened runtime, which the tests name as the bundle's command, the way the app names the
/// one in its bundle. The unsigned SwiftPM helper itself then stands for any other interpreter.
@MainActor
final class ControllerRunTests: XCTestCase {
  private var directory: URL!
  private var runs: URL!
  private var work: URL!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!

  /// What each change of the host's controllers showed, so a test sees a run that has ended.
  private var seenRuns: [ControllerRun] = []

  /// How the tests answer each startup review, as the user would in the panel. A test that looks
  /// at reviews itself sets it to nil.
  private var reviewAnswer: ControllerReviewChoice? = .allowForSession

  /// The reviews each change showed.
  private var seenReviews: [ControllerReview] = []
  private var reviewWatch: ChangeObservers.Token?

  /// The plain scripts here run in unsafe mode, and each undeclared review is answered to ask on
  /// each use.
  private var settings: TestScriptSettings!
  private var undeclaredWatch: ChangeObservers.Token?

  override func setUp() async throws {
    settings = TestScriptSettings(mode: .unsafe)
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    runs = work.appendingPathComponent("runs")
    windows = FakeWindowAPI()

    let center = StatusCenter()
    let command = BundleHelperIdentity(helperURL: try HardenedHelper.url())

    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory, commandIdentity: command),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows,
      controllers: ControllerSettings(
        runsRoot: runs, helper: command, trustDirectory: work.appendingPathComponent("trust")),
      settings: settings.store)
    host.start()
    undeclaredWatch = host.answerUndeclaredReviews(with: .askEachUse)
    reviewWatch = host.changes.add { [weak self] in
      guard let self else { return }

      for review in host.controllerReviews where !seenReviews.contains(review) {
        seenReviews.append(review)

        if let answer = reviewAnswer {
          Task { @MainActor in await self.host.decideReview(review.id, answer) }
        }
      }
    }
    host.onControllersChanged = { [weak self] in
      guard let self else { return }

      for run in self.host.allControllerRuns() where !self.seenRuns.contains(run) {
        self.seenRuns.append(run)
      }
    }

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    host.stop()
    settings.remove()
    try? FileManager.default.removeItem(at: directory)
    ControllerSnapshot.removeStale(in: runs)
    try? FileManager.default.removeItem(at: work)
  }

  // MARK: Helpers

  /// Runs `executable` with `arguments` and the test's environment plus `environment`, in
  /// `folder`, and collects what it wrote.
  private func run(
    _ executable: URL, _ arguments: [String], environment: [String: String] = [:],
    in folder: URL? = nil
  ) async throws -> HelperRun {
    // The test runner sets dyld variables of its own, which a controller run refuses. A test
    // that wants one passes it in `environment`.
    var inherited = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }

    inherited["UNITERM_SOCKET"] = nil

    return try await ScriptFixtures.finish(
      try HelperHandle.spawn(
        executable: executable, arguments: arguments,
        environment: inherited.merging(environment) { _, new in new }, directory: folder,
        deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)]))
  }

  private func runJanet(
    _ package: URL, allow: [String] = [], arguments: [String] = [],
    using executable: URL? = nil, environment: [String: String] = [:], in folder: URL? = nil
  ) async throws -> HelperRun {
    try await run(
      executable ?? HardenedHelper.url(),
      ["run", "--socket", host.instanceAddress] + allow.flatMap { ["--allow", $0] }
        + [package.path] + arguments,
      environment: environment, in: folder)
  }

  private func janetPackage(
    _ files: [String: String], permissions: [String] = [#"{"kind": "pane-control"}"#]
  ) throws -> URL {
    var builder = ControllerPackageBuilder(files: files.mapValues { Data($0.utf8) })

    builder.permissions = permissions

    return try builder.write(
      to: work.appendingPathComponent("package-\(UUID().uuidString.prefix(6))"))
  }

  private var runFolders: [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
  }

  // MARK: Janet

  /// Catches a Janet run that is admitted without its package verified, that runs something other
  /// than the shared fixture as the app read it, or that keeps its snapshot after it ends. The
  /// command keeps its own output and exit status.
  func testTheBundleCommandRunsTheSharedJanetFixtureFromAVerifiedSnapshot() async throws {
    let result = try await runJanet(
      try ControllerFixtures.copy("janet-hello"), allow: ["fs-read"])

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, ControllerFixtures.Hello.output)

    let admitted = try XCTUnwrap(seenRuns.first)

    XCTAssertEqual(
      admitted.identity,
      ControllerIdentity(
        controllerID: ControllerFixtures.Hello.id, version: ControllerFixtures.Hello.version,
        keyFingerprint: ControllerFixtures.Hello.keyFingerprint))
    XCTAssertEqual(admitted.scopes, ControllerFixtures.Hello.permissions)
    XCTAssertEqual(admitted.entryKind, .janet)
    XCTAssertEqual(admitted.window, 1)
    XCTAssertEqual(admitted.pane, NodeID(rawValue: 1))
    XCTAssertEqual(admitted.sourceRoot, TestSessionRoot.identity)

    expect(await waitUntil { self.runFolders.isEmpty }, "the snapshot outlived its run")
    XCTAssertTrue(host.allControllerRuns().isEmpty)
  }

  /// Catches a script digest or path that a peer claims standing in for verification. A program
  /// that is not the bundle's command gets no controller run, whether it is another interpreter
  /// running the same package or a raw peer naming it. The other interpreter is the unsigned
  /// SwiftPM helper, which presents the identity of its own code. The listener refuses it for not
  /// being the app's command, before it begins a run.
  func testAnInterpreterThatIsNotTheBundleCommandGetsNoControllerRun() async throws {
    let package = try ControllerFixtures.copy("janet-hello")
    let other = try await runJanet(package, allow: ["fs-read"], using: ScriptFixtures.helper())

    XCTAssertNotEqual(other.status, 0)
    XCTAssertEqual(other.standardOutput, "", "another interpreter ran the package")
    XCTAssertTrue(
      other.standardError.contains("comes from another build than this running uniterm"),
      other.standardError)

    let peer = try ScriptFixtures.connectPeer(path: host.instanceAddress)

    defer { peer.shutdownAndClose() }

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await read(peer)
    try peer.send(
      ScriptHelperMessage.controllerBegin(ControllerBegin(entry: .janet, package: package.path))
        .frame())

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("a raw peer was answered with something other than a refusal")
    }

    XCTAssertTrue(text.contains("Only the uniterm command"), text)
    XCTAssertTrue(seenRuns.isEmpty)
    XCTAssertTrue(runFolders.isEmpty)
  }

  private func read(_ peer: FramedSocket) async throws -> ScriptAppMessage {
    try await Task.detached {
      let frame = try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

      return try ScriptAppMessage.decode(type: frame.type, body: frame.body)
    }.value
  }

  /// Catches a command that evaluates any of a package's code before the app admits it, or before
  /// the sandbox the run was granted is in place. The refused runs print nothing, and the admitted
  /// one reaches a file only through the capability it declared and was granted.
  func testNoUserCodeRunsBeforeAdmissionAndTheGrantedSandbox() async throws {
    let printer = try janetPackage(["main.janet": "(print \"ran\")\n"])

    try Data("(print \"changed\")\n".utf8).write(to: printer.appendingPathComponent("main.janet"))

    let changed = try await runJanet(printer)

    XCTAssertNotEqual(changed.status, 0)
    XCTAssertEqual(changed.standardOutput, "")
    XCTAssertTrue(
      changed.standardError.contains("does not match the digest"), changed.standardError)

    let undeclared = try await runJanet(
      try janetPackage(["main.janet": "(print \"ran\")\n"]), allow: ["net"])

    XCTAssertNotEqual(undeclared.status, 0)
    XCTAssertEqual(undeclared.standardOutput, "")
    XCTAssertTrue(
      undeclared.standardError.contains("--allow net is not a capability the controller declares"),
      undeclared.standardError)

    let reader = try janetPackage(
      ["main.janet": "(print (length (slurp (get (dyn :args) 1))))\n"],
      permissions: [#"{"kind": "pane-control"}"#, #"{"kind": "capability", "name": "fs-read"}"#])
    let file = work.appendingPathComponent("synthetic.txt")

    try Data("12345".utf8).write(to: file)

    let denied = try await runJanet(reader, arguments: [file.path])

    XCTAssertNotEqual(denied.status, 0)
    XCTAssertTrue(denied.standardError.contains("forbidden by sandbox"), denied.standardError)

    let granted = try await runJanet(reader, allow: ["fs-read"], arguments: [file.path])

    XCTAssertEqual(granted.status, 0, granted.standardError)
    XCTAssertEqual(granted.standardOutput, "5\n")
  }

  /// Catches a loader that finds a module outside the package: one beside the working folder, one
  /// on a JANET_PATH, an absolute one, a native module, or one imported late by a function that
  /// runs after startup. The run holds fs-read, so a refusal comes from the loader and not the
  /// sandbox. The same folder serves an ordinary script, which does load the ambient module, so
  /// the fixture would catch a loader that falls back to Janet's own.
  func testTheJanetLoaderRefusesAmbientDelayedAndStartupImports() async throws {
    let ambient = work.appendingPathComponent("ambient", isDirectory: true)
    let system = work.appendingPathComponent("syspath", isDirectory: true)

    for folder in [ambient, system] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    let marker = "(print \"AMBIENT CODE RAN\")\n"

    try Data(marker.utf8).write(to: ambient.appendingPathComponent("outside.janet"))
    try Data(marker.utf8).write(to: system.appendingPathComponent("outside.janet"))
    try Data(marker.utf8).write(to: system.appendingPathComponent("profile.janet"))
    try Data("not a library".utf8).write(to: ambient.appendingPathComponent("native.so"))
    try Data("not an image".utf8).write(to: ambient.appendingPathComponent("image.jimage"))

    let entry = """
      (import ./lib/inside)

      (defn later [] (require "./outside"))

      (print (inside/value))
      (each attempt [(fn [] (require "./outside")) (fn [] (require "outside"))
                     (fn [] (require "\(ambient.path)/outside")) (fn [] (require "./native"))
                     (fn [] (require "./image"))
                     (fn [] (native "\(ambient.path)/native.so")) later]
        (print (get (protect (attempt)) 0)))

      """
    let package = try janetPackage(
      ["main.janet": entry, "lib/inside.janet": "(defn value [] \"inside\")\n"],
      permissions: [#"{"kind": "pane-control"}"#, #"{"kind": "capability", "name": "fs-read"}"#])
    let environment = [
      "JANET_PATH": system.path,
      "JANET_PROFILE": system.appendingPathComponent("profile.janet").path,
    ]
    let result = try await runJanet(
      package, allow: ["fs-read"], environment: environment, in: ambient)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(
      result.standardOutput, "inside\nfalse\nfalse\nfalse\nfalse\nfalse\nfalse\nfalse\n")
    XCTAssertFalse(result.standardOutput.contains("AMBIENT"))

    let script = ambient.appendingPathComponent("ordinary.janet")

    try Data("(import ./outside)\n".utf8).write(to: script)

    let ordinary = try await run(
      try HardenedHelper.url(),
      ["run", "--socket", host.instanceAddress, "--allow", "fs-read", script.path],
      environment: environment, in: ambient)

    XCTAssertEqual(ordinary.status, 0, ordinary.standardError)
    XCTAssertEqual(ordinary.standardOutput, "AMBIENT CODE RAN\n", "the fixture proves nothing")
  }

  /// The library dyld loads for `DYLD_INSERT_LIBRARIES` here. It prints a GuardMalloc banner
  /// once loaded, so a run shows whether substitute code was injected.
  private let inject = ["DYLD_INSERT_LIBRARIES": "/usr/lib/libgmalloc.dylib"]

  /// Catches a loader variable that injects code into the command before the app admits it. The
  /// SwiftPM helper, which has no hardened runtime, shows the marker loading. The bundle's command
  /// has the hardened runtime, so dyld drops the variable before any code runs, and the run is the
  /// same run it would be without it.
  func testALoaderVariableRunsNoSubstituteCodeBeforeAdmission() async throws {
    let package = try ControllerFixtures.copy("janet-hello")
    let control = try await run(ScriptFixtures.helper(), ["--help"], environment: inject)

    XCTAssertTrue(control.standardError.contains("GuardMalloc"), "the marker never loads")

    try skipUnlessSystemIntegrityIsOn()

    // Xcode sets __XPC_DYLD_ variables for an app under test, and a terminal in it passes them on.
    // dyld never reads them, so they stop nothing.
    let result = try await runJanet(
      package, allow: ["fs-read"],
      environment: inject.merging(["__XPC_DYLD_FRAMEWORK_PATH": "/tmp"]) { a, _ in a })

    XCTAssertFalse(result.standardError.contains("GuardMalloc"), result.standardError)
    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, ControllerFixtures.Hello.output)
  }

  /// Catches an admitted run whose later loads read the package's original path. The entry
  /// imports a module only after the test has rewritten the source and swapped the folder, and the
  /// run still gets the snapshot's copy.
  func testAnAdmittedRunsLaterImportsComeFromItsSnapshot() async throws {
    let package = try janetPackage([
      "main.janet": """
      (print "ready")
      (flush)
      (file/read stdin :line)
      (print (get-in (require "./lib/later") ['value :value]))

      """,
      "lib/later.janet": "(def value :original)\n",
    ])
    let input = Pipe()
    let (process, lines) = try start(
      ["run", "--socket", host.instanceAddress, package.path], input: input)

    defer { process.signal(SIGTERM) }

    expect(await waitUntil { lines.text.contains("ready\n") }, "the entry never started")

    try Data("(def value :substituted)\n".utf8).write(
      to: package.appendingPathComponent("lib/later.janet"))

    let moved = package.deletingLastPathComponent().appendingPathComponent("moved")

    try FileManager.default.moveItem(at: package, to: moved)
    try ControllerPackageBuilder(files: ["main.janet": Data("(print :replaced)\n".utf8)])
      .write(to: package)
    try input.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))

    expect(await waitUntil { !process.isRunning }, "the run never ended")
    XCTAssertEqual(try process.exitStatus(), .exited(0))
    XCTAssertEqual(lines.text, "ready\noriginal\n")
  }

  /// Starts the bundle command on `arguments` with its output collected as it arrives. A command
  /// that never ends is killed after 60 seconds.
  private func start(_ arguments: [String], input: Pipe? = nil) throws -> (
    process: HelperHandle, output: LineCollector
  ) {
    let output = Pipe()

    let process = try HelperHandle.spawn(
      executable: try HardenedHelper.url(), arguments: arguments,
      environment: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") },
      standardInput: input.map { .file($0.fileHandleForReading) } ?? .null,
      standardOutput: .file(output.fileHandleForWriting), standardError: .null,
      deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)])

    let lines = LineCollector(output.fileHandleForReading, retaining: output)

    try? input?.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()

    return (process, lines)
  }

  /// Catches a revoke that leaves a Janet run's authority, or that strands its snapshot. The run's
  /// calls are refused from the revoke on, and its snapshot goes once the command ends.
  func testRevokingAJanetRunEndsItsAuthorityAndItsSnapshotGoesAtClose() async throws {
    let package = try janetPackage([
      "main.janet": """
      (import uniterm)
      (print "ready")
      (flush)
      (file/read stdin :line)
      (print (get (protect (uniterm/list-windows)) 0))

      """
    ])
    let input = Pipe()
    let (process, lines) = try start(
      ["run", "--socket", host.instanceAddress, package.path], input: input)

    defer { process.signal(SIGTERM) }

    expect(await waitUntil { lines.text.contains("ready\n") }, "the entry never started")

    let run = try XCTUnwrap(host.allControllerRuns().first)

    host.revokeControllers([run.connection])

    XCTAssertNil(host.controllerRun(connection: run.connection))
    XCTAssertEqual(runFolders.count, 1, "the revoke took the snapshot from a live helper")

    try input.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))

    expect(await waitUntil { !process.isRunning }, "the run never ended")
    XCTAssertEqual(lines.text, "ready\nfalse\n")
    XCTAssertFalse(windows.calls.contains(.listWindows))
    expect(await waitUntil { self.runFolders.isEmpty }, "the revoked run's snapshot stayed")
  }

  /// Catches a command that relays signals or loses them in the package loader. Ctrl-C's SIGINT,
  /// sent to the command's own process, stops a Janet entry that spins, and one stuck in a module
  /// it imports, with the status a script that Ctrl-C stopped gets.
  func testSIGINTStopsAJanetPackageInItsEntryAndInAModuleLoad() async throws {
    let cases: [[String: String]] = [
      ["main.janet": "(print \"ready\")\n(flush)\n(while true)\n"],
      [
        "main.janet": "(import ./lib/spin)\n",
        "lib/spin.janet": "(print \"ready\")\n(flush)\n(while true)\n",
      ],
    ]

    for files in cases {
      let package = try janetPackage(files)
      let (process, lines) = try start(["run", "--socket", host.instanceAddress, package.path])

      defer { process.signal(SIGKILL) }

      expect(await waitUntil { lines.text.contains("ready\n") }, "\(files.keys) never started")

      XCTAssertEqual(process.signal(SIGINT), .sent)

      expect(await waitUntil { !process.isRunning }, "SIGINT did not stop \(files.keys)")
      XCTAssertEqual(try process.exitStatus(), .exited(130), "\(files.keys)")
    }
  }

  // MARK: Native

  private func nativePackage(_ entry: Data, permissions: [String] = [#"{"kind": "pane-control"}"#])
    throws -> URL
  {
    var builder = ControllerPackageBuilder(files: ["bin/fixture": entry])

    builder.entryKind = "native"
    builder.entry = "bin/fixture"
    builder.permissions = permissions

    let package = try builder.write(
      to: work.appendingPathComponent("native-\(UUID().uuidString.prefix(6))"))

    XCTAssertEqual(chmod(package.appendingPathComponent("bin/fixture").path, 0o755), 0)

    return package
  }

  private var nativeFixture: URL {
    ScriptFixtures.helper().deletingLastPathComponent().appendingPathComponent(
      "ControllerNativeFixture")
  }

  /// Catches a native entry that runs from anywhere but the verified snapshot, one whose run is
  /// bound before its exec or to the command's own generation, and a command that relays its
  /// streams, its working folder, or its exit status instead of handing over its process.
  func testANativeEntryRunsFromTheSnapshotInTheCommandsOwnProcess() async throws {
    let package = try nativePackage(try Data(contentsOf: nativeFixture))
    let result = try await run(
      try HardenedHelper.url(),
      ["controller", "run", "--socket", host.instanceAddress, package.path, "one", "two", "7"],
      in: work)

    XCTAssertEqual(result.status, 7, result.standardError)
    XCTAssertTrue(result.standardOutput.contains("args: one two 7\n"), result.standardOutput)
    XCTAssertTrue(result.standardOutput.contains("loader: none\n"), result.standardOutput)
    XCTAssertTrue(
      result.standardOutput.contains("directory: /private\(work.path)\n")
        || result.standardOutput.contains("directory: \(work.path)\n"), result.standardOutput)
    XCTAssertTrue(result.standardOutput.contains("call: ok\n"), result.standardOutput)

    let admitted = try XCTUnwrap(seenRuns.first)

    XCTAssertEqual(admitted.entryKind, .native)
    XCTAssertEqual(admitted.entryPath, "bin/fixture")
    XCTAssertEqual(admitted.sourceRoot, TestSessionRoot.identity)
    XCTAssertTrue(admitted.snapshot.path.hasPrefix(runs.path), admitted.snapshot.path)

    expect(await waitUntil { self.runFolders.isEmpty }, "the snapshot outlived its process")
  }

  /// Catches the one-session rule turning away a native entry's later connections. Once the command
  /// execs the entry, the whole process is the controller, so every connection it opens is its own
  /// and is adopted, where a command process would be held to one.
  func testEveryConnectionANativeEntryOpensAfterTheExecIsAdopted() async throws {
    let package = try nativePackage(try Data(contentsOf: nativeFixture))
    let result = try await run(
      try HardenedHelper.url(),
      ["controller", "run", "--socket", host.instanceAddress, package.path, "second"], in: work)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertTrue(result.standardOutput.contains("call: ok\n"), result.standardOutput)
    XCTAssertTrue(result.standardOutput.contains("second: ok\n"), result.standardOutput)
    XCTAssertEqual(seenRuns.filter { $0.entryKind == .native }.count, 2)
    expect(await waitUntil { self.runFolders.isEmpty }, "the snapshot outlived its process")
  }

  /// Catches a command that stays between the terminal and the native entry. A signal sent to the
  /// command's process reaches the entry, because the entry is that process.
  func testASignalToTheCommandsProcessReachesTheNativeEntry() async throws {
    let package = try nativePackage(try Data(contentsOf: nativeFixture))
    let (process, lines) = try start(
      ["controller", "run", "--socket", host.instanceAddress, package.path, "wait"])

    defer { process.signal(SIGKILL) }

    expect(await waitUntil { lines.text.contains("waiting\n") }, "the entry never started")

    let admitted = try XCTUnwrap(seenRuns.first)

    XCTAssertEqual(admitted.pid, process.pid)
    XCTAssertEqual(process.signal(SIGINT), .sent)

    expect(await waitUntil { !process.isRunning }, "SIGINT did not reach the entry")
    XCTAssertEqual(try process.exitStatus(), .signalled(SIGINT))
    expect(await waitUntil { self.runFolders.isEmpty }, "the snapshot outlived its process")
    XCTAssertTrue(host.allControllerRuns().isEmpty)
  }

  /// Catches a native run that outlives a second exec. The entry keeps its connection open and
  /// execs another program, which then holds the socket. The run and its snapshot end while the
  /// process still runs, so the new program has neither.
  func testANativeRunEndsWhenItsEntryExecsAnotherProgram() async throws {
    let package = try nativePackage(try Data(contentsOf: nativeFixture))
    let (process, lines) = try start(
      ["controller", "run", "--socket", host.instanceAddress, package.path, "exec"])

    defer { process.signal(SIGKILL) }

    expect(await waitUntil { lines.text.contains("execing\n") }, "the entry never started")

    let admitted = try XCTUnwrap(seenRuns.first)

    expect(
      await waitUntil { self.host.controllerRun(connection: admitted.connection) == nil },
      "the run outlived the exec")
    expect(await waitUntil { self.runFolders.isEmpty }, "the snapshot outlived the exec")
    XCTAssertTrue(process.isRunning, "the process ended, so the exec was not what ended the run")
    XCTAssertNotNil(host.listener.findConnection(admitted.connection), "the connection closed")
  }

  /// Catches a native entry whose load commands reach outside the package, which would run with
  /// the run's authority and code the descriptor does not cover. Nothing is executed.
  func testANativeEntryThatLoadsOutsideCodeIsRefusedBeforeItRuns() async throws {
    var outside = try Data(contentsOf: nativeFixture)
    let original = "/usr/lib/libSystem.B.dylib"
    let replacement = "/opt/evil/libSystem.dylib\0"

    guard let range = outside.range(of: Data(original.utf8)) else {
      return XCTFail("the fixture does not load libSystem by its path")
    }

    outside.replaceSubrange(range, with: Data(replacement.prefix(original.count).utf8))

    let package = try nativePackage(outside)
    let result = try await run(
      try HardenedHelper.url(),
      ["controller", "run", "--socket", host.instanceAddress, package.path])

    XCTAssertNotEqual(result.status, 0)
    XCTAssertFalse(result.standardOutput.contains("args:"), "the entry ran")
    XCTAssertTrue(result.standardError.contains("outside the package"), result.standardError)
    XCTAssertTrue(seenRuns.isEmpty)
    XCTAssertTrue(runFolders.isEmpty)
  }

  /// Catches a loader variable that reaches the native entry through the command's exec, where
  /// it would load code the package does not hold into a process that has the run's authority.
  func testALoaderVariableNeverReachesTheNativeEntry() async throws {
    try skipUnlessSystemIntegrityIsOn()

    let package = try nativePackage(try Data(contentsOf: nativeFixture))
    let result = try await run(
      try HardenedHelper.url(),
      ["controller", "run", "--socket", host.instanceAddress, package.path],
      environment: inject)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertFalse(result.standardError.contains("GuardMalloc"), result.standardError)
    XCTAssertTrue(result.standardOutput.contains("loader: none\n"), result.standardOutput)
    XCTAssertTrue(result.standardOutput.contains("call: ok\n"), result.standardOutput)
  }

  /// Catches an app that trusts a bundle command dyld can inject code into: one built without the
  /// hardened runtime, or one that holds get-task-allow, as Xcode gives a debug build by default.
  /// Either refusal comes before the peer is looked at.
  func testTheAppRefusesABundleCommandThatLoaderVariablesCanReach() throws {
    let (one, other) = try FramedSocket.pair()

    defer { withExtendedLifetime(other) {} }

    let token = try XCTUnwrap(ScriptPeer.liveToken(descriptor: one.rawDescriptor))
    let unhardened = BundleHelperIdentity(helperURL: ScriptFixtures.helper())
    let debuggable = BundleHelperIdentity(helperURL: try HardenedHelper.url(debuggable: true))

    for identity in [unhardened, debuggable] {
      let refusal = try XCTUnwrap(identity.refusal(forPeer: token), "\(identity.helperURL.path)")

      XCTAssertTrue(refusal.contains("dyld variables can load code"), refusal)
    }

    let accepted = BundleHelperIdentity(helperURL: try HardenedHelper.url())

    XCTAssertTrue(
      try XCTUnwrap(accepted.refusal(forPeer: token)).contains("Only the uniterm command"),
      "the test process passed as the bundle's command")
  }

  /// Catches a launch that removes another running instance's snapshots, which a native run may be
  /// executing from, or that keeps an ended instance's. Each instance gets a folder of its own.
  func testALaunchRemovesOnlyTheRunsOfInstancesThatEnded() throws {
    let root = work.appendingPathComponent("instances")
    let other = try HelperHandle.spawn(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], environment: [:],
      standardOutput: .null, standardError: .null,
      deadlines: [HelperDeadline(after: .seconds(90), signal: SIGKILL)])
    let gone = Process()

    gone.executableURL = URL(fileURLWithPath: "/bin/sleep")
    gone.arguments = ["0.3"]
    try gone.run()

    defer { other.signal(SIGKILL) }

    let running = ProcessIdentity(
      pid: other.pid, started: try XCTUnwrap(ProcessInspection.startTime(of: other.pid)))
    let ended = ProcessIdentity(
      pid: gone.processIdentifier,
      started: try XCTUnwrap(ProcessInspection.startTime(of: gone.processIdentifier)))

    gone.waitUntilExit()

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var made: [String: URL] = [:]

    for instance in [running, ended] {
      let snapshot = try ControllerSnapshot.create(
        from: ControllerFixtures.package("janet-hello").path,
        in: root.appendingPathComponent(instance.folderName))

      made[instance.folderName] = snapshot.directory
    }

    let settings = try ControllerSettings.atLaunch(
      root: root, trustDirectory: nil, process: TestSessionRoot.identity,
      helper: BundleHelperIdentity(helperURL: try HardenedHelper.url()))

    XCTAssertEqual(
      settings.runsRoot.path, root.appendingPathComponent(TestSessionRoot.identity.folderName).path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: made[running.folderName]!.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(ended.folderName).path))

    ControllerSnapshot.removeStale(in: root.appendingPathComponent(running.folderName))
  }

  // MARK: Signatures

  /// Catches a run admitted with a signature that does not verify, and a re-signed package whose
  /// new key keeps the old identity, either of which would let trust in one key cover another's
  /// code.
  func testABadSignatureIsRefusedAndAnotherKeyIsAnotherIdentity() async throws {
    let tampered = try ControllerFixtures.copy("janet-hello")
    let signature = tampered.appendingPathComponent("controller.sig")
    let other = try ControllerSignature.sign(
      descriptor: Data("{}".utf8), with: try ControllerFixtures.signingKey())

    try other.encoded().write(to: signature)

    let refused = try await runJanet(tampered, allow: ["fs-read"])

    XCTAssertNotEqual(refused.status, 0)
    XCTAssertEqual(refused.standardOutput, "")
    XCTAssertTrue(refused.standardError.contains("signature does not match"), refused.standardError)
    XCTAssertTrue(seenRuns.isEmpty)

    let descriptor = try Data(contentsOf: tampered.appendingPathComponent("controller.json"))

    try ControllerSignature.sign(descriptor: descriptor, with: InMemorySigningKey()).encoded()
      .write(to: signature)

    let resigned = try await runJanet(tampered, allow: ["fs-read"])

    XCTAssertEqual(resigned.status, 0, resigned.standardError)

    let identity = try XCTUnwrap(seenRuns.first).identity

    XCTAssertEqual(identity.controllerID, ControllerFixtures.Hello.id)
    XCTAssertEqual(identity.version, ControllerFixtures.Hello.version)
    XCTAssertNotEqual(identity.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)
  }

  /// Catches a controller that acts on panes without declaring pane control, which would be an
  /// effect its descriptor never asked for.
  func testAControllerThatDeclaresNoPaneControlCannotActOnPanes() async throws {
    let package = try janetPackage(
      [
        "main.janet": """
        (import uniterm)
        (print (get (protect (uniterm/list-windows)) 1))
        (uniterm/post-status :info "synthetic status")

        """
      ], permissions: [])
    let result = try await runJanet(package)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertTrue(
      result.standardOutput.contains("did not declare pane-control"), result.standardOutput)
    XCTAssertFalse(windows.calls.contains(.listWindows))
  }

  /// Catches a collector that keeps its handler once the pipe ends. A handler left on an ended pipe
  /// is called again and again for as long as the test process lives, and each one holds a core.
  func testALineCollectorLetsGoOfItsPipeAtTheEnd() async throws {
    let pipe = Pipe()
    let collector = LineCollector(pipe.fileHandleForReading)

    pipe.fileHandleForWriting.write(Data("one\n".utf8))
    try pipe.fileHandleForWriting.close()

    expect(
      await waitUntil(timeout: .seconds(5)) { pipe.fileHandleForReading.readabilityHandler == nil },
      "the collector kept reading an ended pipe")
    XCTAssertEqual(collector.text, "one\n")
  }
}

/// Collects a pipe's text as it arrives, and lets go of the pipe at its end.
final class LineCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var collected = ""

  /// What owns the handle, such as its pipe. A pipe closes its read end when it is released, and
  /// a helper that still writes would then die of SIGPIPE.
  private let owner: AnyObject?

  init(_ handle: FileHandle, retaining owner: AnyObject? = nil) {
    self.owner = owner

    handle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData

      guard !data.isEmpty else {
        handle.readabilityHandler = nil

        return
      }

      guard let self else { return }

      self.lock.lock()
      self.collected += String(decoding: data, as: UTF8.self)
      self.lock.unlock()
    }
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }

    return collected
  }
}

/// Copies of the SwiftPM helper signed as the bundle's command is, with the hardened runtime and the
/// one entitlement for unsigned executable memory, which the tests treat as the bundle's command.
/// Each is made once per test run. The debuggable one also holds get-task-allow, as a debug build
/// would without the project's setting.
enum HardenedHelper {
  private static let made = Result { try sign(entitlements: jitMemory) }

  private static let debuggable = Result {
    try sign(entitlements: jitMemory + "<key>com.apple.security.get-task-allow</key><true/>")
  }

  private static let jitMemory =
    "<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>"

  static func url(debuggable wantsDebuggable: Bool = false) throws -> URL {
    try (wantsDebuggable ? debuggable : made).get()
  }

  /// Signs a copy of the helper with `entitlements`, the keys and values of a plist's dictionary.
  private static func sign(entitlements: String) throws -> URL {
    let folder = try ControllerFixtures.temporaryFolder()
    let copy = folder.appendingPathComponent("uniterm")
    let plist = folder.appendingPathComponent("entitlements.plist")
    let document = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>\(entitlements)</dict></plist>
      """

    try FileManager.default.copyItem(at: ScriptFixtures.helper(), to: copy)
    try Data(document.utf8).write(to: plist)

    let sign = Process()

    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = [
      "--force", "--sign", "-", "--options", "runtime", "--entitlements", plist.path, copy.path,
    ]
    sign.standardOutput = FileHandle.nullDevice
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()

    guard sign.terminationStatus == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: copy.path])
    }

    return copy
  }
}
