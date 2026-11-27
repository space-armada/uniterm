import ControllerPackage
import ControllerTestSupport
import ControllerTrust
import Foundation
import ScriptTestSupport
import XCTest

@testable import ScriptHost

/// How the host reads, folds, replaces, and revokes remembered approvals when the policy file holds
/// entries this build cannot read, two entries for one selector, and older versions of one thing.
/// The host runs against a real policy file. No program runs.
@MainActor
final class StoredTrustTests: XCTestCase {
  private var directory: URL!
  private var work: URL!
  private var trust: URL!
  private var host: ScriptHost!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    trust = work.appendingPathComponent("trust")
    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { _ in nil },
      controllers: ControllerSettings(
        runsRoot: work.appendingPathComponent("runs"),
        helper: BundleHelperIdentity(helperURL: work.appendingPathComponent("none")),
        trustDirectory: trust))
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: work)
  }

  private nonisolated static let id = "dev.uniterm.fixture.stored"
  private nonisolated static let current = String(repeating: "c", count: 64)
  private nonisolated static let older = String(repeating: "a", count: 64)
  private nonisolated static let oldest = String(repeating: "b", count: 64)

  private var store: ControllerTrustStore { ControllerTrustStore(directory: trust) }

  private nonisolated static func package(
    _ digest: String, scopes: Set<ControllerPermission> = [.paneControl],
    approved: String = "2026-11-11T10:00:00Z", id: String = StoredTrustTests.id,
    versionOf: String? = StoredTrustTests.id
  ) -> ControllerPolicy {
    ControllerPolicy(
      selector: .version(controllerID: id, version: digest), name: "Stored", scopes: scopes,
      approved: approved, versionOf: versionOf)
  }

  private nonisolated static func script(
    _ digest: String, scopes: Set<ControllerPermission> = [.paneControl],
    versionOf: String? = "/work/tidy.janet"
  ) -> ControllerPolicy {
    ControllerPolicy(
      selector: .fileVersion(version: digest), name: "Tidy", scopes: scopes,
      approved: "2026-11-11T10:00:00Z", versionOf: versionOf)
  }

  private nonisolated static let run = ControllerIdentity(
    controllerID: id, version: current, keyFingerprint: nil)

  /// An entry no build here can read, for the selector of `run`. Its edition is above every one
  /// this build knows, so its selector parses and its text looks like a real approval.
  private func keepUnreadable(for digest: String = current) throws {
    let text = """
      {"approved": "2026-11-11T10:00:00Z", "artifact": "package", "name": "Newer", \
      "scopes": [{"edition": 9, "kind": "pane-control"}], \
      "selector": {"controller": "\(Self.id)", "kind": "version", "version": "\(digest)"}}
      """
    let document = try ControllerPolicyFile.read(
      ControllerPolicyFile.encode([], kept: [ControllerKeptEntry(bytes: Array(text.utf8))]))

    XCTAssertEqual(document.kept.count, 1)

    try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
    try ControllerPolicyFile.encode([], kept: document.kept).write(to: store.fileURL)
  }

  // MARK: Lookup

  /// Catches an entry this build cannot read standing in for a run. It is never covering, and it is
  /// never offered as the nearest match to show what is new, even when its selector parses and
  /// names the run. The readable entry for the same selector is the nearest.
  func testAKeptEntryIsNeverCoveringAndNeverTheNearestMatch() throws {
    try keepUnreadable()

    let found = ScriptHost.lookUp([.paneControl], for: Self.run, in: store)

    XCTAssertNil(found.covering)
    XCTAssertNil(found.nearest)
    XCTAssertEqual(found.unreadable, 1)
    XCTAssertTrue(found.writable)

    try store.update { $0 + [Self.package(Self.current, scopes: [.clipboardRead])] }

    let next = ScriptHost.lookUp([.paneControl], for: Self.run, in: store)

    XCTAssertNil(next.covering)
    XCTAssertEqual(next.nearest?.scopes, [.clipboardRead])
    XCTAssertEqual(next.unreadable, 1)
  }

  /// Catches a run covered by the union of two entries for one selector. A run is covered by one
  /// stored approval, so two entries that each hold part of it cover nothing together.
  func testTwoEntriesForOneSelectorNeverCoverARunTogether() throws {
    try store.update { _ in
      [
        Self.package(Self.current, scopes: [.paneControl], approved: "2026-11-11T10:00:00Z"),
        Self.package(Self.current, scopes: [.clipboardRead], approved: "2026-11-12T10:00:00Z"),
      ]
    }

    let both = ScriptHost.lookUp([.paneControl, .clipboardRead], for: Self.run, in: store)
    let one = ScriptHost.lookUp([.clipboardRead], for: Self.run, in: store)

    XCTAssertNil(both.covering)
    XCTAssertEqual(one.covering, .version(controllerID: Self.id, version: Self.current))
  }

  /// Catches what a version approval is a version of changing whether it covers. The same approval
  /// covers a run whether it names the right thing, another, or none.
  func testWhatAnApprovalIsAVersionOfNeverTakesPartInCoverage() throws {
    for versionOf in [Self.id, "dev.uniterm.fixture.other", nil] {
      try store.update { _ in [Self.package(Self.current, versionOf: versionOf)] }

      let found = ScriptHost.lookUp(
        [.paneControl], for: Self.run, versionOf: "/somewhere/else", in: store)

      XCTAssertEqual(
        found.covering, .version(controllerID: Self.id, version: Self.current),
        versionOf ?? "none")
    }
  }

  /// Catches an offer to replace the wrong approvals. Only version approvals of the same thing, of
  /// the same artifact kind, at another version are offered. An identity approval, another thing,
  /// a script file of the same name, and the run's own version never are.
  func testOnlyOlderVersionsOfTheSameThingAreOffered() throws {
    let identity = ControllerPolicy(
      selector: .identity(controllerID: Self.id, keyFingerprint: String(repeating: "e", count: 64)),
      name: "Key", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")

    try store.update { _ in
      [
        Self.package(Self.older), Self.package(Self.oldest),
        Self.package(Self.current),
        Self.package(
          String(repeating: "d", count: 64), id: "dev.uniterm.fixture.other",
          versionOf: "dev.uniterm.fixture.other"),
        Self.package(String(repeating: "f", count: 64), versionOf: nil),
        Self.script(String(repeating: "9", count: 64), versionOf: Self.id), identity,
      ]
    }

    let found = ScriptHost.lookUp(
      [.paneControl], for: Self.run, versionOf: Self.id, in: store)

    XCTAssertEqual(Set(found.older.map(\.selector.value)), [Self.older, Self.oldest])

    let path = ControllerIdentity(
      controllerID: "tidy.janet", version: Self.current, keyFingerprint: nil, artifact: .file)

    try store.update { _ in
      [
        Self.script(Self.older), Self.script(Self.oldest, versionOf: "/work/other.janet"),
        Self.script(Self.current),
      ]
    }

    let files = ScriptHost.lookUp(
      [.paneControl], for: path, versionOf: "/work/tidy.janet", in: store)

    XCTAssertEqual(files.older.map(\.selector.value), [Self.older])
  }

  // MARK: Trust and revoke

  /// Catches a Trust that drops a readable scope when entries for one selector exist. Every
  /// readable entry for the selector folds into one with all their scopes and the new ones. Other
  /// selectors stay.
  func testTrustFoldsEveryReadableEntryForTheSelectorIntoOne() {
    let other = Self.package(Self.older)
    let new = Self.package(
      Self.current, scopes: [.askUser], approved: "2026-11-20T10:00:00Z")
    let after = ScriptHost.trusting(
      new, replacing: [],
      in: [
        Self.package(Self.current, scopes: [.paneControl]), other,
        Self.package(Self.current, scopes: [.clipboardRead]),
      ])

    XCTAssertEqual(after.count, 2)
    XCTAssertTrue(after.contains(other))

    let folded = after.first { $0.selector == new.selector }

    XCTAssertEqual(folded?.scopes, [.paneControl, .clipboardRead, .askUser])
    XCTAssertEqual(folded?.approved, "2026-11-20T10:00:00Z")
  }

  /// Catches Trust folding several entries for one unsigned script's digest into one with no
  /// defined path. The entries were made at two paths. The folded entry takes the path of the run
  /// the user is trusting, whichever order the entries come in.
  func testFoldingEntriesForOneDigestKeepsTheTrustedRunsPath() {
    let atA = Self.script(Self.current, versionOf: "/work/a.janet")
    let atB = Self.script(Self.current, scopes: [.clipboardRead], versionOf: "/work/b.janet")
    let new = Self.script(Self.current, scopes: [.askUser], versionOf: "/work/c.janet")

    for order in [[atA, atB], [atB, atA]] {
      let after = ScriptHost.trusting(new, replacing: [], in: order)

      XCTAssertEqual(after.count, 1)
      XCTAssertEqual(after.first?.versionOf, "/work/c.janet")
      XCTAssertEqual(after.first?.scopes, [.paneControl, .clipboardRead, .askUser])
    }
  }

  /// Catches a replace that takes more than the older versions of the thing, or a keep that takes
  /// any.
  func testReplacingTakesOnlyTheOlderVersionsOfTheSameThing() {
    let new = Self.package(Self.current)
    let unrelated = [
      Self.package(
        String(repeating: "d", count: 64), id: "dev.uniterm.fixture.other",
        versionOf: "dev.uniterm.fixture.other"),
      Self.script(String(repeating: "9", count: 64), versionOf: Self.id),
      ControllerPolicy(
        selector: .identity(
          controllerID: Self.id, keyFingerprint: String(repeating: "e", count: 64)),
        name: "Key", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z"),
    ]
    let olderVersions = [Self.package(Self.older), Self.package(Self.oldest)]

    let replaced = ScriptHost.trusting(
      new, replacing: Set(olderVersions.map(\.selector)), in: olderVersions + unrelated)
    let kept = ScriptHost.trusting(new, replacing: [], in: olderVersions + unrelated)

    XCTAssertEqual(Set(replaced), Set(unrelated + [new]))
    XCTAssertEqual(Set(kept), Set(unrelated + olderVersions + [new]))
  }

  /// Catches a replace that removes an approval its prompt never named. Versions A and B of one
  /// thing both wait for review. The user trusts A, so B's review, looked up before, names nothing.
  /// Trusting B must remove nothing and end no run. A named approval revoked meanwhile is simply
  /// absent, and an approval added after the review was built stays.
  func testAReplaceRemovesOnlyWhatTheReviewNamed() async throws {
    let aSelector = ControllerSelector.version(controllerID: Self.id, version: Self.older)
    let a = Self.package(Self.older)

    try store.update { _ in [a] }
    admitted(by: a, connection: 9)
    host.controllerReviews = [review(older: [])]

    let failure = await host.decideReview(7, .trustVersion)
    XCTAssertNil(failure)
    XCTAssertEqual(
      Set(store.read().policies.map(\.selector)),
      [aSelector, .version(controllerID: Self.id, version: Self.current)])
    XCTAssertFalse(host.isRevoked(9), "a review that named nothing ended a run")

    let named = Self.package(Self.oldest)
    let added = Self.package(String(repeating: "e", count: 64))

    try store.update { _ in [named, added] }
    try store.update { $0.filter { $0.selector != named.selector } }
    host.controllerReviews = [review(older: [named])]

    let secondFailure = await host.decideReview(7, .trustVersion)
    XCTAssertNil(secondFailure)

    let left = Set(store.read().policies.map(\.selector.value))

    XCTAssertTrue(left.contains(added.selector.value), "an approval added later was removed")
    XCTAssertFalse(left.contains(Self.oldest))
    XCTAssertTrue(left.contains(Self.current))
  }

  /// Catches a path that the reader refuses reaching the writer. A script at a path holding a
  /// newline or tab is saved with no `versionOf`, the entry reads back, and it covers the run.
  func testAPathTheReaderRefusesIsNeverWrittenAndTheApprovalStillCovers() throws {
    for path in [
      "/work/a\nb.janet", "/work/a\tb.janet", "/work/\u{7F}.janet",
      "/" + String(repeating: "p", count: 5000),
    ] {
      let policy = Self.script(Self.current, versionOf: path)

      XCTAssertNil(policy.versionOf, path)

      try store.update { _ in [policy] }

      let found = ScriptHost.lookUp(
        [.paneControl],
        for: ControllerIdentity(
          controllerID: "tidy.janet", version: Self.current, keyFingerprint: nil, artifact: .file),
        in: store)

      XCTAssertEqual(store.read().unreadable, 0, path)
      XCTAssertEqual(found.covering, .fileVersion(version: Self.current), path)
    }
  }

  /// Catches a Revoke that leaves one of two entries for a selector, or removes an entry this build
  /// cannot read. It removes every readable entry for the selector and keeps the rest as written.
  func testRevokeRemovesEveryReadableEntryAndKeepsTheUnreadableOne() async throws {
    try keepUnreadable()
    try store.update {
      $0 + [
        Self.package(Self.current, scopes: [.paneControl]),
        Self.package(Self.current, scopes: [.clipboardRead]), Self.package(Self.older),
      ]
    }

    let before = try ControllerPolicyFile.read(Data(contentsOf: store.fileURL)).kept

    let failure = await host.forgetPolicy(
      .version(controllerID: Self.id, version: Self.current))

    XCTAssertNil(failure)

    let state = store.read()

    XCTAssertEqual(state.policies, [Self.package(Self.older)])
    XCTAssertEqual(state.unreadable, 1)
    XCTAssertEqual(try ControllerPolicyFile.read(Data(contentsOf: store.fileURL)).kept, before)
  }

  // MARK: The replace choice

  private func review(older: [ControllerPolicy]) -> ControllerReview {
    ControllerReview(
      id: 7, name: "Stored", identity: Self.run, requested: [.paneControl], added: [.paneControl],
      revises: nil, canRemember: true, notice: nil, waiting: [], versionOf: Self.id, older: older)
  }

  private func admitted(by policy: ControllerPolicy, connection: UInt64) {
    host.controllerRuns[connection] = ControllerRun(
      identity: ControllerIdentity(
        controllerID: Self.id, version: policy.selector.value, keyFingerprint: nil),
      name: "Stored", entryKind: .janet, entryPath: "main.janet", scopes: [.paneControl],
      approval: .remembered(policy.selector), standing: [.paneControl],
      pid: 4242 + Int32(connection),
      generation: 1, connection: connection, sourceRoot: nil, window: nil, pane: nil,
      snapshot: work.appendingPathComponent("snapshot"))
  }

  /// Catches a replace that leaves a live run of a replaced version running, or one that ends the
  /// run of an approval it kept. Trust This Version replaces the older approvals through the revoke
  /// path, so a run each one admitted ends. The new approval names what it is a version of.
  func testTrustingAVersionReplacesTheOlderOnesAndEndsTheirLiveRuns() async throws {
    let first = Self.package(Self.older)
    let second = Self.package(Self.oldest)
    let unrelated = Self.package(
      String(repeating: "d", count: 64), id: "dev.uniterm.fixture.other",
      versionOf: "dev.uniterm.fixture.other")

    try store.update { _ in [first, second, unrelated] }
    admitted(by: first, connection: 9)
    admitted(by: unrelated, connection: 10)
    host.controllerReviews = [review(older: [first, second])]

    let failure = await host.decideReview(7, .trustVersion)

    XCTAssertNil(failure)

    let stored = store.read().policies

    XCTAssertEqual(Set(stored.map(\.selector.value)), [Self.current, unrelated.selector.value])
    XCTAssertEqual(stored.first { $0.selector.value == Self.current }?.versionOf, Self.id)
    XCTAssertTrue(host.isRevoked(9), "a run of a replaced version kept running")
    XCTAssertFalse(host.isRevoked(10), "a run of an unrelated approval ended")
  }

  /// Catches Keep Both removing an older approval or ending its run.
  func testKeepingOlderVersionsRemovesNothingAndEndsNothing() async throws {
    let first = Self.package(Self.older)

    try store.update { _ in [first] }
    admitted(by: first, connection: 9)
    host.controllerReviews = [review(older: [first])]

    let failure = await host.decideReview(7, .trustVersionKeepingOlder)

    XCTAssertNil(failure)
    XCTAssertEqual(Set(store.read().policies.map(\.selector.value)), [Self.older, Self.current])
    XCTAssertFalse(host.isRevoked(9))
  }
}
