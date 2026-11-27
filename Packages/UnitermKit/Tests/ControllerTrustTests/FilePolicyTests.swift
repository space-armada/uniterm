import ControllerPackage
import ControllerTestSupport
import Foundation
import XCTest

@testable import ControllerTrust

/// Remembered approvals of script files: their selectors, their policy file, and that neither the
/// file store nor the controller store reads, counts, sweeps, or moves aside the other's names.
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

  private static func filePolicy(_ selector: ControllerSelector? = nil) -> ControllerPolicy {
    ControllerPolicy(
      selector: selector ?? .fileVersion(version: digest), name: "Tidy",
      scopes: [.paneControl, .clipboardRead], approved: "2026-11-11T10:00:00Z")
  }

  private static func packagePolicy() -> ControllerPolicy {
    ControllerPolicy(
      selector: .version(controllerID: "dev.uniterm.fixture.policy", version: digest),
      name: "Fixture", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")
  }

  private func files() -> ControllerTrustStore {
    ControllerTrustStore(directory: folder, artifact: .file)
  }

  private func packages() -> ControllerTrustStore {
    ControllerTrustStore(directory: folder, artifact: .package)
  }

  private var names: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
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

  // MARK: The file's format

  /// Catches a file codec that loses a selector or a scope on the way through the file.
  func testFilePoliciesRoundTripThroughTheirOwnFormat() throws {
    let policies = [
      Self.filePolicy(),
      Self.filePolicy(.fileIdentity(fileID: "dev.example.tidy", keyFingerprint: Self.key)),
    ]
    let bytes = ControllerPolicyFile.encode(policies)
    let text = String(decoding: bytes, as: UTF8.self)

    XCTAssertEqual(Set(try ControllerPolicyFile.decode(bytes, artifact: .file)), Set(policies))
    XCTAssertFalse(text.contains("\"controller\""), text)
    XCTAssertEqual(ControllerPolicyFile.encode(policies.reversed()), bytes)
  }

  /// Catches a file store that reads a controller policy file, and a controller store that reads a
  /// file policy file. Either is unreadable to the other, so neither is taken for trust.
  func testEachStoresFormatIsUnreadableToTheOther() throws {
    let fileBytes = ControllerPolicyFile.encode([Self.filePolicy()])
    let packageBytes = ControllerPolicyFile.encode([Self.packagePolicy()])

    XCTAssertThrowsError(try ControllerPolicyFile.decode(fileBytes, artifact: .package))
    XCTAssertThrowsError(try ControllerPolicyFile.decode(packageBytes, artifact: .file))
    XCTAssertThrowsError(
      try ControllerPolicyFile.decode(
        ControllerPolicyFile.encode([
          Self.filePolicy(.fileIdentity(fileID: "dev.example.tidy", keyFingerprint: Self.key))
        ]), artifact: .package))
  }

  /// Catches a file record written to the controller policy file, which would cost an older build
  /// every controller approval.
  func testFileRecordsLiveOnlyInTheirOwnFile() throws {
    try files().update { _ in [Self.filePolicy()] }
    try packages().update { _ in [Self.packagePolicy()] }

    XCTAssertEqual(
      names, ["files.json", "files.lock", "policy.json", "policy.lock"])
    XCTAssertEqual(files().read().policies, [Self.filePolicy()])
    XCTAssertEqual(packages().read().policies, [Self.packagePolicy()])
  }

  /// Catches a build that predates file approvals losing its controller approvals when the folder
  /// holds a file policy file. The controller store is the one an older build ran, and it reads
  /// the folder as it did, leaves `files.json` as it is, and moves nothing aside.
  func testAnOlderBuildKeepsItsControllerApprovalsBesideAFilePolicyFile() throws {
    try packages().update { _ in [Self.packagePolicy()] }
    try files().update { _ in [Self.filePolicy()] }

    let fileBytes = try Data(contentsOf: files().fileURL)
    let older = ControllerTrustStore(directory: folder)

    XCTAssertEqual(older.read().policies, [Self.packagePolicy()])
    XCTAssertNil(older.read().notice)
    XCTAssertTrue(older.read().writable)
    XCTAssertEqual(try Data(contentsOf: files().fileURL), fileBytes)
    XCTAssertEqual(older.keptAsideFiles, [])
    XCTAssertEqual(files().keptAsideFiles, [])

    try older.update { $0 }

    XCTAssertEqual(try Data(contentsOf: files().fileURL), fileBytes)
    XCTAssertEqual(files().read().policies, [Self.filePolicy()])
  }

  // MARK: Names

  /// Catches a store that sweeps the other's temporary files. A crashed write leaves
  /// `<file>.json.tmp-<pid>`, and each store removes only its own.
  func testEachStoreSweepsOnlyItsOwnTemporaryFiles() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for name in ["policy.json.tmp-11", "files.json.tmp-22"] {
      try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }

    _ = files().read()

    XCTAssertEqual(names.filter { $0.contains(".tmp-") }, ["policy.json.tmp-11"])

    try Data("x".utf8).write(to: folder.appendingPathComponent("files.json.tmp-22"))

    _ = packages().read()

    XCTAssertEqual(names.filter { $0.contains(".tmp-") }, ["files.json.tmp-22"])
  }

  /// Catches a store that counts or trims the other's kept-aside copies, so one store's corrupt
  /// file costs the other its recovery copies. Each keeps five of its own.
  func testEachStoreKeepsAndNumbersItsOwnAsideCopies() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for index in 1...6 {
      try Data("kept \(index)".utf8).write(
        to: folder.appendingPathComponent("policy.aside-\(index).json"))
    }

    try Data("{broken".utf8).write(to: files().fileURL)

    let state = files().read()

    XCTAssertEqual(state.policies, [])
    XCTAssertTrue(state.notice?.contains("files.aside-1.json") == true, "\(state)")
    XCTAssertTrue(state.notice?.contains("script file policy file") == true, "\(state)")
    XCTAssertEqual(
      names.filter { $0.hasPrefix("policy.aside-") }.count, 6,
      "the file store trimmed policy asides")
    XCTAssertEqual(names.filter { $0.hasPrefix("files.aside-") }, ["files.aside-1.json"])

    try Data("{broken".utf8).write(to: packages().fileURL)

    XCTAssertTrue(packages().read().notice?.contains("policy.aside-7.json") == true)
    XCTAssertEqual(names.filter { $0.hasPrefix("files.aside-") }, ["files.aside-1.json"])
    XCTAssertEqual(files().keptAsideFiles.count, 1)
    XCTAssertEqual(packages().keptAsideFiles.count, 5)
  }

  // MARK: Rules

  /// Catches the newer-format rule being skipped for files: a newer file grants nothing, is not
  /// rewritten, and costs the controller store nothing.
  func testANewerFilePolicyFileIsLeftAloneAndCostsNoControllerApproval() throws {
    try packages().update { _ in [Self.packagePolicy()] }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let newer = Data("{\"format\": 3, \"policies\": []}".utf8)

    try newer.write(to: files().fileURL)

    let state = files().read()

    XCTAssertEqual(state.policies, [])
    XCTAssertFalse(state.writable)
    XCTAssertTrue(state.notice?.contains("script file policy file") == true, "\(state)")
    XCTAssertThrowsError(try files().update { _ in [Self.filePolicy()] })
    XCTAssertEqual(try Data(contentsOf: files().fileURL), newer)
    XCTAssertEqual(packages().read().policies, [Self.packagePolicy()])
  }

  /// Catches a record limit shared between the stores. Each has its own 256.
  func testEachStoreHasItsOwnRecordLimit() throws {
    let many = (0..<ControllerPolicyFile.maxPolicies).map { index in
      Self.filePolicy(
        .fileVersion(version: String(format: "%064x", index)))
    }

    try files().update { _ in many }

    XCTAssertThrowsError(
      try files().update {
        $0 + [Self.filePolicy(.fileVersion(version: String(repeating: "f", count: 64)))]
      }
    ) { error in
      XCTAssertTrue("\(error)".contains("256 script file approvals"), "\(error)")
    }

    try packages().update { _ in [Self.packagePolicy()] }

    XCTAssertEqual(packages().read().policies.count, 1)
    XCTAssertEqual(files().read().policies.count, ControllerPolicyFile.maxPolicies)
  }

  /// Catches a file store that shares the controller store's lock, so a hung write of one holds up
  /// the other.
  func testTheStoresTakeSeparateLocks() throws {
    try files().update { _ in [] }
    try packages().update { _ in [] }

    XCTAssertTrue(names.contains("files.lock"))
    XCTAssertTrue(names.contains("policy.lock"))
  }
}
