import ControllerPackage
import ControllerTestSupport
import Foundation
import XCTest

@testable import ControllerTrust

/// Remembered approvals of script files, beside packages in the one policy file: their selectors,
/// how an entry names its artifact kind, and how the stores of earlier builds are retired.
final class FilePolicyTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = try ControllerFixtures.temporaryFolder().appendingPathComponent("controllers")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private static let digest = String(repeating: "ab", count: 32)
  private static let key = String(repeating: "cd", count: 32)

  private static func filePolicy(
    _ selector: ControllerSelector? = nil, versionOf: String? = nil
  ) -> ControllerPolicy {
    ControllerPolicy(
      selector: selector ?? .fileVersion(version: digest), name: "Tidy",
      scopes: [.paneControl, .clipboardRead], approved: "2026-11-11T10:00:00Z",
      versionOf: versionOf)
  }

  private static func packagePolicy() -> ControllerPolicy {
    ControllerPolicy(
      selector: .version(controllerID: "dev.uniterm.fixture.policy", version: digest),
      name: "Fixture", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")
  }

  private var store: ControllerTrustStore { ControllerTrustStore(directory: folder) }

  private var names: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  private var retiredNames: [String] {
    let retired = store.retiredDirectory.path

    return ((try? FileManager.default.contentsOfDirectory(atPath: retired)) ?? []).sorted()
  }

  private func plant(_ name: String, _ text: String = "{}") throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: folder.appendingPathComponent(name))
  }

  // MARK: Selectors

  /// Catches a file approval that covers a package, or a package approval that covers a file, even
  /// when the ID, the key, and the version all agree.
  func testAFileSelectorNeverMatchesAPackageAndAPackageSelectorNeverMatchesAFile() {
    let package = ControllerIdentity(
      controllerID: "dev.example.same", version: Self.digest, keyFingerprint: Self.key)
    let file = ControllerIdentity(
      controllerID: "dev.example.same", version: Self.digest, keyFingerprint: Self.key,
      artifact: .file)

    let packageSelectors: [ControllerSelector] = [
      .version(controllerID: "dev.example.same", version: Self.digest),
      .identity(controllerID: "dev.example.same", keyFingerprint: Self.key),
    ]
    let fileSelectors: [ControllerSelector] = [
      .fileVersion(version: Self.digest),
      .fileIdentity(fileID: "dev.example.same", keyFingerprint: Self.key),
    ]

    for selector in packageSelectors {
      XCTAssertTrue(selector.matches(package), "\(selector)")
      XCTAssertFalse(selector.matches(file), "\(selector)")
    }

    for selector in fileSelectors {
      XCTAssertTrue(selector.matches(file), "\(selector)")
      XCTAssertFalse(selector.matches(package), "\(selector)")
    }
  }

  /// Catches a file version that needs an ID, and a file identity that matches without the key.
  func testAFileVersionNeedsNoIDAndAFileIdentityNeedsTheKey() {
    let unsigned = ControllerIdentity(
      controllerID: "tidy.janet", version: Self.digest, keyFingerprint: nil, artifact: .file)

    XCTAssertTrue(ControllerSelector.fileVersion(version: Self.digest).matches(unsigned))
    XCTAssertFalse(
      ControllerSelector.fileVersion(version: String(repeating: "00", count: 32)).matches(unsigned))
    XCTAssertFalse(
      ControllerSelector.fileIdentity(fileID: "tidy.janet", keyFingerprint: Self.key)
        .matches(unsigned))
  }

  /// Catches what a version approval is a version of taking part in whether it matches a run. A run
  /// named by a path, an ID, or nothing at all is matched by the digest alone.
  func testWhatAnApprovalIsAVersionOfNeverTakesPartInMatching() {
    let run = ControllerIdentity(
      controllerID: "tidy.janet", version: Self.digest, keyFingerprint: nil, artifact: .file)

    for versionOf in [nil, "/somewhere/else.janet", "dev.example.other"] {
      let policy = Self.filePolicy(versionOf: versionOf)

      XCTAssertTrue(policy.selector.matches(run), "\(versionOf ?? "nil")")
      XCTAssertEqual(policy.uncovered([.paneControl]), [], "\(versionOf ?? "nil")")
    }
  }

  // MARK: The one file

  /// Catches a codec that loses an artifact kind, a selector, a version-of name, or a scope on the
  /// way through the one file, or that writes the same entries two ways.
  func testPackageAndFilePoliciesRoundTripThroughOneFile() throws {
    let policies = [
      Self.packagePolicy(),
      ControllerPolicy(
        selector: .version(controllerID: "dev.uniterm.fixture.versioned", version: Self.digest),
        name: "Versioned", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z",
        versionOf: "dev.uniterm.fixture.versioned"),
      Self.filePolicy(versionOf: "/Users/someone/tidy.janet"),
      Self.filePolicy(
        .fileIdentity(fileID: "dev.example.tidy", keyFingerprint: Self.key)),
    ]
    let bytes = ControllerPolicyFile.encode(policies)
    let text = String(decoding: bytes, as: UTF8.self)

    XCTAssertEqual(Set(try ControllerPolicyFile.decode(bytes)), Set(policies))
    XCTAssertEqual(ControllerPolicyFile.encode(policies.reversed()), bytes)
    XCTAssertTrue(text.contains("\"artifact\": \"file\""), text)
    XCTAssertTrue(text.contains("\"artifact\": \"package\""), text)
    XCTAssertTrue(text.contains("\"versionOf\": \"/Users/someone/tidy.janet\""), text)
  }

  /// Catches a version-of name on an identity approval, or a version-of that is no plain text. An
  /// identity approval is of no one version, and a control character could fake a line in a
  /// review. Either makes only that entry unreadable.
  func testAVersionOfIsReadOnlyOnAVersionApprovalAsPlainText() throws {
    let good = String(
      decoding: ControllerPolicyFile.encode([Self.filePolicy(versionOf: "/tmp/tidy.janet")]),
      as: UTF8.self)

    XCTAssertEqual(try ControllerPolicyFile.read(Data(good.utf8)).policies.count, 1)

    let bad = [
      good.replacingOccurrences(of: "\"kind\": \"version\"", with: "\"kind\": \"identity\""),
      good.replacingOccurrences(of: "/tmp/tidy.janet", with: "/tmp/\\u0007bell"),
      good.replacingOccurrences(of: "\"/tmp/tidy.janet\"", with: "\"\""),
      good.replacingOccurrences(of: "\"/tmp/tidy.janet\"", with: "7"),
    ]

    for text in bad {
      let document = try ControllerPolicyFile.read(Data(text.utf8))

      XCTAssertEqual(document.policies, [], text)
      XCTAssertEqual(document.kept.count, 1, text)
    }
  }

  /// Catches an approval of one artifact kind that stands for another's. One selector of two kinds
  /// is two entries. Revoking one kind's leaves the other's, and each survives the file.
  func testOneSelectorOfTwoKindsIsTwoDistinctEntries() throws {
    let package = ControllerPolicy(
      selector: .identity(controllerID: "dev.example.same", keyFingerprint: Self.key),
      name: "Same", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")
    let file = ControllerPolicy(
      selector: .fileIdentity(fileID: "dev.example.same", keyFingerprint: Self.key),
      name: "Same", scopes: [.clipboardRead], approved: "2026-11-11T10:00:00Z")

    try store.update { _ in [package, file] }

    XCTAssertEqual(Set(store.read().policies), [package, file])

    try store.update { $0.filter { $0.selector != package.selector } }

    XCTAssertEqual(store.read().policies, [file])
  }

  /// Catches a record limit, or a file per artifact kind. Every kind lives in policy.json, with no
  /// count of approvals, so a store of thousands is read and saved.
  func testThousandsOfApprovalsAreReadAndSavedWithNoCount() throws {
    let many = (0..<3000).map { index in
      Self.filePolicy(.fileVersion(version: String(format: "%064x", index)))
    }

    try store.update { _ in many }
    try store.update {
      $0 + [Self.filePolicy(.fileVersion(version: String(repeating: "f", count: 64)))]
    }

    XCTAssertEqual(store.read().policies.count, 3001)
    XCTAssertEqual(names, ["policy.json", "policy.lock"])
  }

  /// Catches a reader that sets up a date parser for each entry. A read makes at most one, and
  /// makes it only for an approval time in a spelling uniterm does not write, so the count of
  /// setups stays the same whatever the number of entries.
  func testReadingSetsUpTheDateParserOnceWhateverTheNumberOfEntries() throws {
    for count in [1, 40, 400] {
      let entries = (0..<count).map { index in
        ControllerPolicy(
          selector: .fileVersion(version: String(format: "%064x", index)), name: "Tidy",
          scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")
      }
      let text = String(decoding: ControllerPolicyFile.encode(entries), as: UTF8.self)
        .replacingOccurrences(of: "10:00:00Z", with: "10:00:00+00:00")
      let made = Counter()
      let document = try ControllerPolicyFile.read(
        Data(text.utf8), editions: .current,
        makeFormatter: {
          made.increment()

          return ISO8601DateFormatter()
        })

      XCTAssertEqual(document.policies.count, count)
      XCTAssertEqual(made.value, 1, "\(count) entries set the parser up \(made.value) times")
    }

    let plain = Counter()

    _ = try ControllerPolicyFile.read(
      ControllerPolicyFile.encode([Self.filePolicy()]), editions: .current,
      makeFormatter: {
        plain.increment()

        return ISO8601DateFormatter()
      })

    XCTAssertEqual(plain.value, 0, "the plain spelling needed a parser")
  }

  /// A coarse guard only. It catches a reader that has become slow by an order of magnitude, and
  /// cannot catch a per-entry setup, which the test above pins. A debug build runs about ten times
  /// slower than a release build, so the bound is loose. The sub-second figure for a store near the
  /// bound is a one-off release measurement.
  func testReadingAStoreNearTheBoundIsFast() throws {
    var policies: [ControllerPolicy] = []
    var index = 0

    while ControllerPolicyFile.encode(policies).count < ControllerPolicyFile.maxBytes * 9 / 10 {
      policies += (0..<500).map { _ in
        index += 1

        return Self.filePolicy(
          .fileVersion(version: String(format: "%064x", index)), versionOf: "/tmp/tidy.janet")
      }
    }

    let bytes = ControllerPolicyFile.encode(policies)
    let clock = ContinuousClock()
    var document = ControllerPolicyDocument()
    let elapsed = try clock.measure { document = try ControllerPolicyFile.read(bytes) }

    XCTAssertEqual(document.policies.count, policies.count)
    XCTAssertGreaterThan(bytes.count, ControllerPolicyFile.maxBytes * 8 / 10)
    XCTAssertLessThan(elapsed, .seconds(3), "read \(policies.count) approvals in \(elapsed)")
  }

  /// Catches a fast path for approval times that accepts a time the date formatter refuses, which
  /// would let a damaged entry read. Every text the fast path takes is one the formatter takes too.
  func testTheFastApprovalTimeCheckAcceptsOnlyWhatTheFormatterAccepts() {
    let formatter = ISO8601DateFormatter()
    let samples = [
      "2026-11-11T10:00:00Z", "1000-01-01T00:00:00Z", "9999-12-28T23:59:59Z",
      "2026-02-28T12:30:30Z", "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z",
      "2026-11-00T00:00:00Z", "2026-11-29T00:00:00Z", "2026-11-11T24:00:00Z",
      "2026-11-11T10:60:00Z", "2026-11-11T10:00:60Z", "0999-11-11T10:00:00Z",
      "2026-11-11 10:00:00Z", "2026-11-11T10:00:00z", "2026-11-11T10:00:00", "yesterday", "",
      "2026-11-11T1O:00:00Z", "２０２６-11-11T10:00:00Z",
    ]

    for text in samples where ControllerPolicyFile.isPlainTime(text) {
      XCTAssertNotNil(formatter.date(from: text), text)
    }

    XCTAssertTrue(ControllerPolicyFile.isPlainTime("2026-11-11T10:00:00Z"))
    XCTAssertFalse(ControllerPolicyFile.isPlainTime("2026-13-01T00:00:00Z"))
  }

  // MARK: Retired stores

  /// Catches an earlier store that stays beside the new one, or is lost. `files.json`, its lock, and
  /// its kept-aside copies are moved to the retired folder as they were. The new file starts empty,
  /// at once, so a second build finds nothing to retire.
  func testFilesJSONAndItsCompanionsAreRetiredAndAnEmptyFileIsWrittenAtOnce() throws {
    try plant("files.json", "{\"format\": 1, \"policies\": []}")
    try plant("files.lock", "")
    try plant("files.aside-1.json", "old aside")

    let state = store.read()

    XCTAssertEqual(state.policies, [])
    XCTAssertTrue(state.writable)
    XCTAssertTrue(state.notice?.contains("approved again once") == true, "\(state)")
    XCTAssertEqual(
      retiredNames.filter { $0 != ".notified" }, ["files.aside-1.json", "files.json", "files.lock"])
    XCTAssertEqual(
      try String(
        contentsOf: store.retiredDirectory.appendingPathComponent("files.aside-1.json"),
        encoding: .utf8), "old aside")
    XCTAssertEqual(try ControllerPolicyFile.read(Data(contentsOf: store.fileURL)).policies, [])
    XCTAssertFalse(names.contains { $0.hasPrefix("files.") }, "\(names)")
  }

  /// Catches a retired file that counts toward, or prunes, the five kept-aside copies of
  /// `policy.json`, and a later retiring that prunes an earlier retired copy. Old builds that keep
  /// writing their files make many copies. All stay, and the policy copies stay five.
  func testRetiringNeverPrunesAndNeverCountsTowardPolicyAsideCopies() throws {
    for index in 1...5 {
      try plant("policy.aside-\(index).json", "kept \(index)")
    }

    for round in 1...4 {
      try plant("files.json", "round \(round)")
      try plant("policy.json", "{\"format\": 2, \"policies\": []}")

      _ = store.read()
    }

    XCTAssertEqual(
      names.filter { $0.hasPrefix("policy.aside-") }.count, 5, "policy copies were counted")
    XCTAssertEqual(
      try String(
        contentsOf: folder.appendingPathComponent("policy.aside-1.json"), encoding: .utf8),
      "kept 1")
    XCTAssertEqual(
      retiredNames.filter { $0.hasPrefix("files.json") },
      ["files.json", "files.json.2", "files.json.3", "files.json.4"])
    XCTAssertEqual(
      retiredNames.filter { $0.hasPrefix("policy.json") },
      ["policy.json", "policy.json.2", "policy.json.3", "policy.json.4"])
    XCTAssertEqual(
      try String(
        contentsOf: store.retiredDirectory.appendingPathComponent("files.json"), encoding: .utf8),
      "round 1")
  }

  /// Catches the reapproval notice lost when the first load after an earlier store is retired is a
  /// change. A change returns no notice, so it must leave the notice for the next read.
  func testAChangeThatRetiresAnEarlierStoreLeavesTheNoticeForTheNextRead() throws {
    try plant("files.json")

    try store.update { $0 + [Self.packagePolicy()] }

    let state = store.read()

    XCTAssertTrue(state.notice?.contains("approved again once") == true, "\(state)")
    XCTAssertNil(store.read().notice)
  }

  /// Catches the notice that every approval is given again once repeating each time an older build
  /// writes its `files.json` again. It shows the first time, and the file is still retired.
  func testTheReapprovalNoticeShowsOnce() throws {
    try plant("files.json")

    XCTAssertTrue(store.read().notice?.contains("approved again once") == true)

    try plant("files.json")

    let second = store.read()

    XCTAssertNil(second.notice)
    XCTAssertFalse(names.contains("files.json"))
    XCTAssertEqual(retiredNames.filter { $0.hasPrefix("files.json") }.count, 2)
  }

  /// Catches a store of an unbuilt feature staying beside the new one. A store a build names for
  /// retiring is retired like `files.json`.
  func testAnotherEarlierStoreIsRetiredLikeFilesJSON() throws {
    try plant("folders.json")
    try plant("folders.lock", "")

    let state = ControllerTrustStore(directory: folder, retiring: ["files", "folders"]).read()

    XCTAssertTrue(state.notice?.contains("approved again once") == true, "\(state)")
    XCTAssertEqual(retiredNames.filter { $0 != ".notified" }, ["folders.json", "folders.lock"])
  }

  /// Catches an approval read from an earlier store, or one carried over. Nothing in `files.json`
  /// reaches the new store, even a well-formed file approval.
  func testApprovalsInAnEarlierStoreNeverReachTheNewOne() throws {
    try plant(
      "files.json",
      """
      {"format": 1, "policies": [{"approved": "2026-11-11T10:00:00Z", "name": "Tidy", \
      "scopes": [{"kind": "pane-control", "version": 1}], \
      "selector": {"kind": "version", "version": "\(Self.digest)"}}]}
      """)

    XCTAssertEqual(store.read().policies, [])

    try store.update { $0 }

    XCTAssertEqual(store.read().policies, [])
  }

  /// Catches a retiring that touches a newer file. A file in a newer format stays where it is and
  /// is never moved aside, whatever sits beside it.
  func testANewerWholeFileFormatIsNeverMovedAside() throws {
    let newer = "{\"format\": 4, \"policies\": [], \"flag\": {\"a\": [1, 2]}}"

    try plant("policy.json", newer)

    let state = store.read()

    XCTAssertFalse(state.writable)
    XCTAssertEqual(state.policies, [])
    XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), newer)
    XCTAssertEqual(names, ["policy.json", "policy.lock"])
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }

    return count
  }
}
