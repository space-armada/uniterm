import ControllerPackage
import ControllerTestSupport
import ControllerTrust
import Darwin
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// Declared script files end to end: the real command, the real Janet reader and loader, and the
/// app's own admission, against a host whose window layer is a fake.
///
/// As in the controller tests, the bundle's command is a signed copy of the SwiftPM helper.
@MainActor
final class DeclaredFileRunTests: XCTestCase {
  private var directory: URL!
  private var runs: URL!
  private var work: URL!
  private var trust: URL!
  private var host: ScriptHost!

  private var seenReviews: [ControllerReview] = []
  private var seenRuns: [ControllerRun] = []
  private var reviewWatch: ChangeObservers.Token?

  /// The undeclared scripts here run in unsafe mode, and each review is answered to ask on each
  /// use. The strict mode and the unsafe review have their own tests.
  private var settings: TestScriptSettings!
  private var undeclaredWatch: ChangeObservers.Token?

  /// How the tests answer each startup review. A test that answers itself sets it to nil.
  private var reviewAnswer: ControllerReviewChoice? = .allowForSession

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    runs = work.appendingPathComponent("runs")
    trust = work.appendingPathComponent("trust")
    settings = TestScriptSettings(mode: .unsafe)

    try startHost()
  }

  override func tearDown() async throws {
    host.stop()
    settings.remove()
    try? FileManager.default.removeItem(at: directory)
    ControllerSnapshot.removeStale(in: runs)
    try? FileManager.default.removeItem(at: work)
  }

  private func startHost() throws {
    host = try ScriptFixtures.makeFileHost(
      directory: directory, work: work, helper: nil, settings: settings.store)
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

      for run in host.allControllerRuns() where !seenRuns.contains(run) {
        seenRuns.append(run)
      }
    }
  }

  // MARK: Helpers

  private var runFolders: [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
  }

  private func source(_ text: String, named name: String = "tidy") throws -> URL {
    let file = work.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).janet")

    try Data(text.utf8).write(to: file)

    return file
  }

  /// A file whose first form declares `permissions` under `header`, followed by `body`.
  private func declared(
    _ body: String, header: String = #"{:name "Tidy"}"#,
    permissions: [String] = ["{:kind :pane-control :version 1}"], named name: String = "tidy"
  ) throws -> URL {
    try source(
      "(declare-permissions \(header)\n  \(permissions.joined(separator: "\n  ")))\n\n\(body)\n",
      named: name)
  }

  private func environment() -> [String: String] {
    var inherited = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }

    inherited["UNITERM_SOCKET"] = nil

    return inherited
  }

  private func start(
    _ file: URL, allow: [String] = [], arguments: [String] = [], input: Pipe? = nil
  ) throws -> (process: HelperHandle, output: LineCollector, errors: LineCollector) {
    let output = Pipe()
    let errors = Pipe()

    let process = try HelperHandle.spawn(
      executable: try HardenedHelper.url(),
      arguments: ["run", "--socket", host.instanceAddress] + allow.flatMap { ["--allow", $0] }
        + [file.path] + arguments,
      environment: environment(),
      standardInput: input.map { .file($0.fileHandleForReading) } ?? .null,
      standardOutput: .file(output.fileHandleForWriting),
      standardError: .file(errors.fileHandleForWriting),
      deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)])

    let collected = LineCollector(output.fileHandleForReading, retaining: output)
    let failures = LineCollector(errors.fileHandleForReading, retaining: errors)

    try? output.fileHandleForWriting.close()
    try? errors.fileHandleForWriting.close()

    return (process, collected, failures)
  }

  private func run(_ file: URL, allow: [String] = [], arguments: [String] = []) async throws
    -> HelperRun
  {
    try await ScriptFixtures.finish(
      try HelperHandle.spawn(
        executable: try HardenedHelper.url(),
        arguments: ["run", "--socket", host.instanceAddress] + allow.flatMap { ["--allow", $0] }
          + [file.path] + arguments,
        environment: environment(), directory: work,
        deadlines: [HelperDeadline(after: .seconds(60), signal: SIGKILL)]))
  }

  // MARK: Review

  /// Catches a declared file that runs before the user has seen its powers. The review lists the
  /// declared powers and the declared name, the file has printed nothing while it waits, and once
  /// the user answers, the file runs.
  func testAValidDeclarationShowsAReviewListingItsPowersBeforeAnyCodeRuns() async throws {
    reviewAnswer = nil

    let file = try declared(
      #"(print "ran")"#,
      permissions: [
        "{:kind :pane-control :version 1}", "{:kind :clipboard-read :version 1}",
      ])
    let started = try start(file)

    defer { started.process.signal(SIGTERM) }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertEqual(review.name, "Tidy")
    XCTAssertEqual(review.identity.artifact, .file)
    XCTAssertEqual(review.requested, [.paneControl, .clipboardRead])
    XCTAssertEqual(started.output.text, "", "the file ran before the review was answered")
    XCTAssertTrue(started.process.isRunning)
    XCTAssertEqual(runFolders.count, 1, "the file was not snapshotted")

    let failure = await host.decideReview(review.id, .allowOnce)

    XCTAssertNil(failure)
    expect(await waitUntil { !started.process.isRunning }, "the file never ran")
    XCTAssertEqual(try started.process.exitStatus(), .exited(0), started.errors.text)
    XCTAssertEqual(started.output.text, "ran\n")
    expect(await waitUntil { self.runFolders.isEmpty }, "the snapshot outlived its run")
  }

  /// Catches a review that titles a file by something other than its declared name, and an
  /// unnamed file that is not shown by its file name.
  func testAnUnnamedFileIsShownByItsFileName() async throws {
    reviewAnswer = nil

    let file = try source(
      "(declare-permissions {:kind :pane-control :version 1})\n(print :ran)\n", named: "plain-name")
    let started = try start(file)

    defer { started.process.signal(SIGTERM) }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertEqual(review.name, file.lastPathComponent)
    XCTAssertEqual(review.identity.controllerID, file.lastPathComponent)

    await host.decideReview(review.id, .deny)
    expect(await waitUntil { !started.process.isRunning }, "the denied file kept running")
    XCTAssertNotEqual(try started.process.exitStatus(), .exited(0))
    XCTAssertTrue(started.errors.text.contains("You denied this"), started.errors.text)
    XCTAssertEqual(started.output.text, "")
  }

  /// Catches a file name that reaches the review as it stands. A name can hold a newline or a
  /// direction override, and the review prints its title and ID, so neither may carry one.
  func testAHostileFileNameIsCleanedBeforeItIsShown() async throws {
    reviewAnswer = nil

    let file = work.appendingPathComponent("evil\u{202E}\nVersion: forged.janet")

    try Data("(declare-permissions {:kind :pane-control :version 1})\n(print :ran)\n".utf8)
      .write(to: file)

    let started = try start(file)

    defer { started.process.signal(SIGTERM) }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertEqual(review.name, "script file")
    XCTAssertEqual(review.identity.controllerID, "script file")
    XCTAssertFalse(review.identity.controllerID.contains("\n"))

    await host.decideReview(review.id, .deny)
  }

  /// Catches a long file name cut with nothing to show it. A cut name keeps its start and its
  /// extension and shows an ellipsis between, and fits a descriptor name's limit. A short name is
  /// left alone.
  func testALongFileNameKeepsItsExtensionAndShowsTheCut() {
    let long = "uniterm-ui-AD52E6A1-4F3B-42C9-B6D5-7C1E0A9F2B33-declared-file.janet"
    let title = ScriptHost.fileTitle(long)

    XCTAssertLessThanOrEqual(title.utf8.count, ControllerDescriptor.maxNameBytes)
    XCTAssertTrue(title.hasPrefix("uniterm-ui-AD52"), title)
    XCTAssertTrue(title.hasSuffix("declared-file.janet"), title)
    XCTAssertTrue(title.contains("\u{2026}"), title)
    XCTAssertEqual(ScriptHost.fileTitle("tidy.janet"), "tidy.janet")
    XCTAssertEqual(ScriptHost.fileTitle("bad\u{202E}name.janet"), "script file")

    let wide = String(repeating: "\u{00E9}", count: 80) + ".janet"
    let cut = ScriptHost.fileTitle(wide)

    XCTAssertLessThanOrEqual(cut.utf8.count, ControllerDescriptor.maxNameBytes)
    XCTAssertTrue(cut.hasSuffix(".janet") && cut.contains("\u{2026}"), cut)
  }

  /// Catches a command that runs the file at its path and not the copy the app made. The file is
  /// rewritten while the review waits, and the run still prints what the reviewed bytes print.
  func testTheCommandRunsTheSnapshotAndAnEditAfterReviewChangesNothing() async throws {
    reviewAnswer = nil

    let file = try declared(#"(print "reviewed")"#)
    let started = try start(file)

    defer { started.process.signal(SIGTERM) }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    try Data(
      "(declare-permissions {:kind :pane-control :version 1})\n(print \"edited\")\n".utf8
    ).write(to: file)

    let review = try XCTUnwrap(host.controllerReviews.first)

    await host.decideReview(review.id, .allowForSession)
    expect(await waitUntil { !started.process.isRunning }, "the file never ran")
    XCTAssertEqual(started.output.text, "reviewed\n")
  }

  /// Catches a remembered version that asks again for the same bytes, and one that covers an edit.
  func testTrustThisVersionSkipsTheNextReviewAndAnEditedFileGetsAFreshOne() async throws {
    reviewAnswer = .trustVersion

    let file = try declared(#"(print "one")"#)
    let first = try await run(file)

    XCTAssertEqual(first.status, 0, first.standardError)
    XCTAssertEqual(first.standardOutput, "one\n")
    XCTAssertEqual(seenReviews.count, 1)

    let second = try await run(file)

    XCTAssertEqual(second.status, 0, second.standardError)
    XCTAssertEqual(second.standardOutput, "one\n")
    XCTAssertEqual(seenReviews.count, 1, "trusted bytes asked again")
    XCTAssertEqual(seenRuns.last?.approval.displayText, "Trusted version")

    try Data(
      "(declare-permissions {:name \"Tidy\"} {:kind :pane-control :version 1})\n(print \"two\")\n"
        .utf8
    ).write(to: file)

    let edited = try await run(file)

    XCTAssertEqual(edited.standardOutput, "two\n", edited.standardError)
    XCTAssertEqual(seenReviews.count, 2, "an edited file ran without a fresh review")
  }

  /// Catches a file approval that lives in the controller policy file, which an older build would
  /// move aside.
  func testAFileApprovalIsWrittenToItsOwnPolicyFile() async throws {
    reviewAnswer = .trustVersion

    let result = try await run(try declared(#"(print "x")"#))

    XCTAssertEqual(result.status, 0, result.standardError)

    let names = (try? FileManager.default.contentsOfDirectory(atPath: trust.path)) ?? []

    XCTAssertTrue(names.contains("files.json"), "\(names)")
    XCTAssertFalse(names.contains("policy.json"), "\(names)")
  }

  // MARK: Refusals

  /// Catches a refused declaration that still reaches a review or runs. The fixture covers a
  /// refusal made by the command's reader and one made by the app's.
  func testARefusedDeclarationShowsNoReviewAndRunsNothing() async throws {
    reviewAnswer = nil

    let fromTheReader = try source(
      "(declare-permissions {:kind :pane-control :version 1})\n(print :ran)\n"
        + "(declare-permissions {:kind :pane-control :version 1})\n")
    let reader = try await run(fromTheReader)

    XCTAssertNotEqual(reader.status, 0)
    XCTAssertEqual(reader.standardOutput, "")
    XCTAssertTrue(reader.standardError.contains("appears again"), reader.standardError)

    let fromTheApp = try declared(
      #"(print :ran)"#, permissions: ["{:kind :pane-control :version 2}"])
    let app = try await run(fromTheApp)

    XCTAssertNotEqual(app.status, 0)
    XCTAssertEqual(app.standardOutput, "")
    XCTAssertTrue(
      app.standardError.contains("pane-control version 2 is not one this uniterm knows"),
      app.standardError)

    let native = try declared(
      #"(print :ran)"#, permissions: [#"{:kind :capability :version 1 :name :ffi}"#])
    let refused = try await run(native)

    XCTAssertNotEqual(refused.status, 0)
    XCTAssertEqual(refused.standardOutput, "")
    XCTAssertTrue(refused.standardError.contains("cannot declare ffi"), refused.standardError)

    XCTAssertTrue(seenReviews.isEmpty)
    expect(await waitUntil { self.runFolders.isEmpty }, "a refused file left its snapshot")
  }

  /// Catches a misspelled declaration form that runs as if nothing was wrong. The binding exists
  /// for the exact name, so another spelling fails as an unbound symbol.
  func testAMisspelledFormFailsAsAnUnboundSymbol() async throws {
    let file = try declared(
      "(print :before)\n(declare-permisions {:kind :pane-control :version 1})\n(print :after)")
    let result = try await run(file)

    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(
      result.standardError.contains("unknown symbol declare-permisions"), result.standardError)
    XCTAssertFalse(result.standardOutput.contains("after"))
  }

  /// Catches a declared file that can load a file. An ordinary script beside it does import the
  /// same module, so the fixture proves the loader and not a missing file.
  func testAnImportFromADeclaredFileFindsNothing() async throws {
    try Data("(print :loaded)\n(def value 1)\n".utf8).write(
      to: work.appendingPathComponent("sibling.janet"))

    let ordinary = try source("(import ./sibling)\n(print sibling/value)\n", named: "ordinary")
    let control = try await run(ordinary, allow: ["fs-read"])

    XCTAssertEqual(control.status, 0, control.standardError)
    XCTAssertTrue(control.standardOutput.contains("loaded"), "the fixture proves nothing")

    let file = try declared("(import ./sibling)\n(print :unreachable)")
    let result = try await run(file)

    XCTAssertNotEqual(result.status, 0)
    XCTAssertFalse(result.standardOutput.contains("loaded"), result.standardOutput)
    XCTAssertFalse(result.standardOutput.contains("unreachable"))
    XCTAssertTrue(result.standardError.contains("sibling"), result.standardError)
  }

  /// Catches a declared file that reaches the bundled module's calls without the power it
  /// declared. The error names the permission and the declaration, and the calls it did declare
  /// still run.
  func testACallNeedingAnUndeclaredPowerIsRefusedAndNamesThePermission() async throws {
    let file = try declared(
      """
      (import uniterm)
      (defn show [f]
        (let [[_ failure] (protect (f))]
          (print (if (string? failure) failure (string/format "%p" failure)))))
      (show (fn [] (uniterm/list-windows)))
      (show (fn [] (uniterm/write-clipboard "x")))
      """,
      permissions: ["{:kind :clipboard-read :version 1}"])
    let result = try await run(file)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertTrue(
      result.standardOutput.contains(
        "This script did not declare pane-control in its (declare-permissions ...) form"),
      result.standardOutput)
    XCTAssertTrue(
      result.standardOutput.contains("did not declare clipboard-write"), result.standardOutput)
  }

  /// Catches an empty declaration that grants more than posting status, and one that asks for a
  /// review it has nothing to put in.
  func testAnEmptyDeclarationRunsWithNoPowersBeyondPostingStatus() async throws {
    reviewAnswer = nil

    let file = try source(
      """
      (declare-permissions {:name "x"})
      (import uniterm)
      (uniterm/post-status :info "posted")
      (print (get (protect (uniterm/list-windows)) 1))
      """)
    let result = try await run(file)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertTrue(result.standardOutput.contains("pane-control"), result.standardOutput)
    XCTAssertTrue(seenReviews.isEmpty, "an empty declaration asked for a review")
  }

  /// Catches an `--allow` for a capability the file did not declare, and one it did.
  func testAllowNamesOnlyDeclaredCapabilities() async throws {
    reviewAnswer = .allowForSession

    let note = work.appendingPathComponent("note.txt")

    try Data("12345".utf8).write(to: note)

    let file = try declared(
      "(print (length (slurp \"\(note.path)\")))",
      permissions: [#"{:kind :capability :version 1 :name :fs-read}"#])
    let undeclared = try await run(file, allow: ["net-connect"])

    XCTAssertNotEqual(undeclared.status, 0)
    XCTAssertEqual(undeclared.standardOutput, "")
    XCTAssertTrue(
      undeclared.standardError.contains(
        "--allow net-connect is not a capability the file declares"),
      undeclared.standardError)

    let denied = try await run(file)

    XCTAssertNotEqual(denied.status, 0)
    XCTAssertTrue(denied.standardError.contains("forbidden by sandbox"), denied.standardError)

    let granted = try await run(file, allow: ["fs-read"])

    XCTAssertEqual(granted.status, 0, granted.standardError)
    XCTAssertEqual(granted.standardOutput, "5\n")
  }

  // MARK: Signatures

  private static let signedHeader = #"{:id "dev.uniterm.fixture.tidy" :name "Tidy"}"#

  /// Writes `file.sig` beside `file`, signed as a script file by `key`.
  @discardableResult
  private func sign(_ file: URL, with key: InMemorySigningKey? = nil) throws -> ControllerSignature
  {
    let signature = try ControllerSignature.sign(
      try Data(contentsOf: file), as: .scriptFile,
      with: try key ?? ControllerFixtures.signingKey())

    try signature.encoded().write(to: URL(fileURLWithPath: file.path + ".sig"))

    return signature
  }

  private func signed(
    _ body: String, header: String = signedHeader,
    permissions: [String] = ["{:kind :pane-control :version 1}"], key: InMemorySigningKey? = nil
  ) throws -> URL {
    let file = try declared(body, header: header, permissions: permissions)

    try sign(file, with: key)

    return file
  }

  /// Catches a signed file whose review lacks the signer. The review carries the key's fingerprint
  /// and the declared ID, which is what the panel needs to offer Trust This Identity and to print
  /// the signer.
  func testASignedFileIsReviewedWithItsSignersKeyAndID() async throws {
    reviewAnswer = nil

    let file = try signed(#"(print "ran")"#)
    let started = try start(file)

    defer { started.process.signal(SIGTERM) }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertTrue(review.isSigned)
    XCTAssertEqual(review.identity.artifact, .file)
    XCTAssertEqual(review.identity.controllerID, "dev.uniterm.fixture.tidy")
    XCTAssertEqual(review.identity.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)
    XCTAssertEqual(started.output.text, "")

    await host.decideReview(review.id, .deny)
  }

  /// Catches an unsigned file that offers identity trust. Without a `.sig` there is no key to pin.
  func testAnUnsignedFileHasNoKeyToTrust() async throws {
    reviewAnswer = nil

    let file = try declared(#"(print "ran")"#, header: Self.signedHeader)
    let started = try start(file)

    defer { started.process.signal(SIGTERM) }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")
    XCTAssertFalse(try XCTUnwrap(host.controllerReviews.first).isSigned)

    await host.decideReview(try XCTUnwrap(host.controllerReviews.first).id, .deny)
  }

  /// Catches identity trust that is not remembered, or that covers the wrong things. A new version
  /// signed by the same key that asks for nothing new runs without a review. One that asks for more
  /// is reviewed, and the review says what is new. Another key under the same ID, and the same key
  /// under another ID, are reviewed too.
  func testTrustThisIdentityCoversLaterVersionsThatAskForNothingNew() async throws {
    reviewAnswer = .trustIdentity

    let first = try signed(#"(print "one")"#)
    let result = try await run(first)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(seenReviews.count, 1)

    let names = (try? FileManager.default.contentsOfDirectory(atPath: trust.path)) ?? []

    XCTAssertTrue(names.contains("files.json"), "\(names)")

    reviewAnswer = .deny

    let update = try signed(#"(print "two")"#, key: nil)
    let updated = try await run(update)

    XCTAssertEqual(updated.status, 0, updated.standardError)
    XCTAssertEqual(updated.standardOutput, "two\n")
    XCTAssertEqual(seenReviews.count, 1, "a later version under the trusted identity was reviewed")
    XCTAssertEqual(seenRuns.last?.approval.displayText, "Trusted identity")

    let wider = try signed(
      #"(print "three")"#,
      permissions: ["{:kind :pane-control :version 1}", "{:kind :clipboard-read :version 1}"])
    let refused = try await run(wider)

    XCTAssertNotEqual(refused.status, 0)
    XCTAssertEqual(refused.standardOutput, "")
    XCTAssertEqual(seenReviews.count, 2, "a version asking for more ran without a review")
    XCTAssertEqual(seenReviews.last?.added, [.clipboardRead])
    XCTAssertNotNil(seenReviews.last?.revises)

    let otherKey = try signed(#"(print "four")"#, key: InMemorySigningKey())
    let byOtherKey = try await run(otherKey)

    XCTAssertNotEqual(byOtherKey.status, 0)
    XCTAssertEqual(seenReviews.count, 3, "another key rode on the trusted identity")

    let otherID = try signed(
      #"(print "five")"#, header: #"{:id "dev.uniterm.fixture.other" :name "Tidy"}"#)
    let byOtherID = try await run(otherID)

    XCTAssertNotEqual(byOtherID.status, 0)
    XCTAssertEqual(seenReviews.count, 4, "another ID rode on the trusted identity")
  }

  /// Catches an identity approval of a package that covers a signed file with the same ID and key.
  /// The approval is written as the controller store writes it, and the file is still reviewed.
  func testAPackageIdentityApprovalDoesNotCoverASignedFile() async throws {
    let store = ControllerTrustStore(directory: trust, artifact: .package)

    try store.update { _ in
      [
        ControllerPolicy(
          selector: .identity(
            controllerID: "dev.uniterm.fixture.tidy",
            keyFingerprint: ControllerFixtures.Hello.keyFingerprint),
          name: "Tidy", scopes: [.paneControl], approved: "2026-11-15T10:00:00Z")
      ]
    }
    reviewAnswer = .deny

    let result = try await run(try signed(#"(print "ran")"#))

    XCTAssertNotEqual(result.status, 0)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(seenReviews.count, 1, "a package approval covered a script file")
  }

  /// Catches a `.sig` that falls back to an unsigned run. A signature over other bytes, a
  /// package's signature, and a signature that is not one each refuse the file before any review
  /// and before any of its code runs, even when the same bytes were trusted unsigned.
  func testASignatureThatDoesNotVerifyRefusesTheFileAndNeverFallsBack() async throws {
    reviewAnswer = .trustVersion

    let file = try declared(#"(print "ran")"#, header: Self.signedHeader)
    let unsigned = try await run(file)

    XCTAssertEqual(unsigned.status, 0, unsigned.standardError)
    XCTAssertEqual(seenReviews.count, 1)

    reviewAnswer = nil

    let sidecar = URL(fileURLWithPath: file.path + ".sig")
    let forged = try ControllerSignature.sign(
      Data("(print :other)".utf8), as: .scriptFile, with: try ControllerFixtures.signingKey())
    let packages = try ControllerSignature.sign(
      descriptor: try Data(contentsOf: file), with: try ControllerFixtures.signingKey())

    for (bytes, fragment) in [
      (forged.encoded(), "the file was changed after it was signed"),
      (packages.encoded(), "the file was changed after it was signed"),
      (Data("{}".utf8), "the file's .sig"),
    ] {
      try bytes.write(to: sidecar)

      let result = try await run(file)

      XCTAssertNotEqual(result.status, 0, fragment)
      XCTAssertEqual(result.standardOutput, "", "the trusted bytes ran under a bad signature")
      XCTAssertTrue(result.standardError.contains(fragment), result.standardError)
    }

    XCTAssertEqual(seenReviews.count, 1, "a refused signature reached a review")
    expect(await waitUntil { self.runFolders.isEmpty }, "a refused file left its snapshot")
  }

  /// Catches a signed file with no `:id` that reaches a review. The signature would have nothing to
  /// pin, so the file is refused with a message that says what to add.
  func testASignedFileWithoutAnIDIsRefused() async throws {
    reviewAnswer = nil

    let named = try signed(#"(print "ran")"#, header: #"{:name "Tidy"}"#)
    let noHeader = try source(
      "(declare-permissions {:kind :pane-control :version 1})\n(print :ran)\n", named: "bare")

    try sign(noHeader)

    for file in [named, noHeader] {
      let result = try await run(file)

      XCTAssertNotEqual(result.status, 0)
      XCTAssertEqual(result.standardOutput, "")
      XCTAssertTrue(result.standardError.contains("must name an :id"), result.standardError)
    }

    XCTAssertTrue(seenReviews.isEmpty)
    expect(await waitUntil { self.runFolders.isEmpty }, "a refused file left its snapshot")
  }

  /// Catches an undeclared file that reads its `.sig`. In unsafe mode one runs after its own
  /// review. A valid signature beside it grants no identity, and a signature that would not
  /// verify costs it nothing.
  func testASignatureBesideAnUndeclaredFileGrantsNoIdentity() async throws {
    reviewAnswer = nil

    let file = try source(
      "(def header {:id \"dev.uniterm.fixture.tidy\"})\n(print :ran)\n", named: "plain")

    try sign(file)

    let valid = try await run(file)

    XCTAssertEqual(valid.status, 0, valid.standardError)
    XCTAssertEqual(valid.standardOutput, "ran\n")

    try Data("not a signature".utf8).write(to: URL(fileURLWithPath: file.path + ".sig"))

    let broken = try await run(file)

    XCTAssertEqual(broken.status, 0, broken.standardError)
    XCTAssertEqual(broken.standardOutput, "ran\n")
    XCTAssertTrue(seenReviews.isEmpty)
    XCTAssertTrue(
      host.allControllerRuns().allSatisfy { $0.identity.keyFingerprint == nil },
      "a plain run took an identity from a .sig")
  }

  /// Catches a signature looked up beside the link and not the file. A link to a signed file runs
  /// as signed.
  func testTheSignatureIsReadBesideTheResolvedFile() async throws {
    reviewAnswer = .allowForSession

    let file = try signed(#"(print "ran")"#)
    let link = work.appendingPathComponent("link-to-signed.janet")

    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    let result = try await run(link)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(
      seenReviews.first?.identity.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)
  }

  // MARK: Paths

  /// Catches a symlink that is refused or run from the link's own bytes, and an `(dyn :args)` that
  /// starts with anything but the path the user typed.
  func testAFileReachedThroughASymlinkRunsAndArgsStartWithTheTypedPath() async throws {
    let file = try declared(#"(print (get (dyn :args) 0)) (print (get (dyn :args) 1))"#)
    let link = work.appendingPathComponent("link.janet")

    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    let result = try await run(link, arguments: ["extra"])

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, "\(link.path)\nextra\n")
  }
}
