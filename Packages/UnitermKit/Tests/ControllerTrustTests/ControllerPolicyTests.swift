import ControllerPackage
import ControllerTestSupport
import Darwin
import Foundation
import SourceAccess
import XCTest

@testable import ControllerTrust

/// Remembered approvals: how one request is compared with an approval, and how the policy file
/// is read, written, and kept when it cannot be used.
final class ControllerPolicyTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = try ControllerFixtures.temporaryFolder().appendingPathComponent("controllers")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private func launch(_ directory: String, keys: [String] = []) throws -> ControllerPermission {
    .hostLaunch(
      try HostLaunchScope(executable: "/usr/bin/true", directory: directory, environmentKeys: keys))
  }

  private static let version = String(repeating: "ab", count: 32)

  private static func policy(_ scopes: Set<ControllerPermission>) -> ControllerPolicy {
    ControllerPolicy(
      selector: .version(controllerID: "dev.uniterm.fixture.policy", version: Self.version),
      name: "Fixture", scopes: scopes, approved: "2026-11-11T10:00:00Z")
  }

  // MARK: Containment

  /// Catches a comparison that lets a broader or new power ride on an approval: another power, a
  /// directory outside the approved one, a sibling folder that shares its prefix, an extra
  /// environment key, or another executable. Narrower and equal requests are covered.
  func testOnlyAnUnchangedOrNarrowerRequestIsCovered() throws {
    let approved: Set<ControllerPermission> = [
      .paneControl, .clipboardRead, try launch("/work/project", keys: ["TOKEN", "HOME_URL"]),
    ]

    XCTAssertEqual(PermissionContainment.uncovered([.paneControl], by: approved), [])
    XCTAssertEqual(
      PermissionContainment.uncovered(
        [try launch("/work/project/sub", keys: ["TOKEN"])], by: approved), [])
    XCTAssertEqual(
      PermissionContainment.uncovered([try launch("/work/project")], by: approved), [])

    for wider in [
      ControllerPermission.clipboardWrite, .capability("fs-read"), try launch("/work"),
      try launch("/work/project-other"), try launch("/work/project", keys: ["TOKEN", "SECRET"]),
      .hostLaunch(
        try HostLaunchScope(executable: "/bin/sh", directory: "/work/project", environmentKeys: [])),
    ] {
      XCTAssertEqual(
        PermissionContainment.uncovered([.paneControl, wider], by: approved), [wider], "\(wider)")
    }
  }

  /// Catches an approval that keeps covering a kind whose meaning grew. A test grows the kind's
  /// edition through an injected table, then checks that the approval made at the older edition
  /// covers nothing of the request, so the user is asked again. A new approval at the grown
  /// edition covers it.
  func testAnApprovalAtAnOlderEditionNoLongerCoversAGrownKind() throws {
    let grown = ControllerPermissionEditions(["pane-control": 1, "clipboard-read": 0])
    let old: Set<ControllerPermission> = [.paneControl, .clipboardRead]
    let asked = ControllerPermission(.paneControl, edition: 1)

    XCTAssertEqual(old.first { $0.kindName == "pane-control" }?.edition, 0)
    XCTAssertEqual(PermissionContainment.uncovered([asked], by: old), [asked])
    XCTAssertEqual(
      PermissionContainment.uncovered([asked, .clipboardRead], by: old), [asked],
      "a kind whose edition did not move stays covered")

    let stored = ControllerPolicyFile.encode([Self.policy(old)])
    let decoded = try ControllerPolicyFile.decode(stored, editions: grown)

    XCTAssertEqual(decoded[0].scopes, old, "an older edition reads, and keeps its edition")
    XCTAssertEqual(decoded[0].uncovered([asked]), [asked])

    let approved = PermissionContainment.merged(old, with: [asked])

    XCTAssertEqual(PermissionContainment.uncovered([asked], by: approved), [])

    let saved = ControllerPolicyFile.encode([Self.policy(approved)])

    XCTAssertEqual(try ControllerPolicyFile.decode(saved, editions: grown)[0].scopes, approved)
  }

  /// Catches an approval at an edition above this build's that reads as something narrower. A file
  /// written by a build whose kind is at edition 1 reads as newer to a build at edition 0, so it
  /// grants nothing there and is left alone. An approval at a higher edition than a request
  /// covers nothing either, since the two meanings differ.
  func testAnEditionAboveThisBuildsIsNewerAndNeverCovers() throws {
    let above = ControllerPermission(.paneControl, edition: 1)
    let bytes = ControllerPolicyFile.encode([Self.policy([above])])

    XCTAssertThrowsError(try ControllerPolicyFile.decode(bytes)) { error in
      XCTAssertEqual(error as? ControllerPolicyFileError, .newer("pane-control edition 1"))
    }

    XCTAssertEqual(PermissionContainment.uncovered([.paneControl], by: [above]), [.paneControl])
    XCTAssertEqual(
      try ControllerPolicyFile.decode(
        bytes, editions: ControllerPermissionEditions(["pane-control": 1]))[0].scopes, [above])
  }

  // MARK: The file format

  /// Catches a codec that loses a selector, a scope, or an edition on the way through the file, or
  /// that writes the same policies two ways.
  func testPoliciesRoundTripThroughTheFile() throws {
    let policies = [
      Self.policy([.paneControl, .clipboardWrite, try launch("/tmp", keys: ["B", "A"])]),
      ControllerPolicy(
        selector: .identity(
          controllerID: "dev.uniterm.fixture.signed",
          keyFingerprint: String(repeating: "c", count: 64)),
        name: "Signed \"one\"", scopes: [.capability("fs-read")], approved: "2026-11-11T11:00:00Z"),
    ]

    let bytes = ControllerPolicyFile.encode(policies)

    XCTAssertEqual(Set(try ControllerPolicyFile.decode(bytes)), Set(policies))
    XCTAssertEqual(ControllerPolicyFile.encode(policies.reversed()), bytes)
  }

  /// Catches a reader that takes a newer format's file for a broken one when the file holds a
  /// boolean, null, negative, or fractional value. It cannot prove that a newer file with other
  /// values this build refuses to parse is kept.
  func testNewerFormatWithValuesOutsideTheIntegerDomainReadsAsNewer() throws {
    for extra in ["true", "false", "null", "-1", "0.5", "1e3"] {
      let text = "{\"format\": 3, \"policies\": [], \"flag\": \(extra)}"

      XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(text.utf8)), extra) { error in
        XCTAssertEqual(error as? ControllerPolicyFileError, .newer("format 3"), extra)
      }
    }
  }

  /// Catches a widened reader that lets a current format file hold a value kind it refused before,
  /// or reads a negative or fractional format or edition as a newer one.
  func testCurrentFormatStillRefusesTheNewValueKinds() {
    let good = String(
      decoding: ControllerPolicyFile.encode([Self.policy([.paneControl])]), as: UTF8.self)

    for extra in ["true", "null", "-1", "0.5"] {
      for text in [
        "{\"format\": 2, \"policies\": [], \"flag\": \(extra)}",
        "{\"format\": \(extra), \"policies\": []}",
        good.replacingOccurrences(of: "\"edition\": 0", with: "\"edition\": \(extra)"),
      ] {
        XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(text.utf8)), text) { error in
          guard case .unreadable? = error as? ControllerPolicyFileError else {
            return XCTFail("\(text) read as \(error)")
          }
        }
      }
    }
  }

  /// Catches a reader that reads a newer or unknown meaning as a narrower known one, or that takes
  /// a newer build's file for a broken one. A newer format, a kind this build does not know, and
  /// an edition above this build's read as newer. A repeated key or an unknown field reads as broken.
  func testUnknownMeaningsReadAsNewerAndBrokenFilesAsUnreadable() throws {
    let good = String(
      decoding: ControllerPolicyFile.encode([Self.policy([.paneControl])]), as: UTF8.self)

    for (text, expected) in [
      (
        good.replacingOccurrences(
          of: "\"kind\": \"pane-control\"",
          with: "\"kind\": \"pane-everything\", \"reach\": \"far\""),
        "the kind pane-everything"
      ),
      (
        good.replacingOccurrences(of: "\"edition\": 0", with: "\"edition\": 2"),
        "pane-control edition 2"
      ),
      (good.replacingOccurrences(of: "\"format\": 2", with: "\"format\": 3"), "format 3"),
    ] {
      XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(text.utf8))) { error in
        XCTAssertEqual(error as? ControllerPolicyFileError, .newer(expected))
      }
    }

    for (text, expected) in [
      (
        good.replacingOccurrences(
          of: "\"name\": \"Fixture\"", with: "\"name\": \"Fixture\", \"name\": \"X\""), "twice"
      ),
      (
        good.replacingOccurrences(of: "\"approved\"", with: "\"trusted\": \"yes\", \"approved\""),
        "unknown field"
      ),
    ] {
      XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(text.utf8))) { error in
        guard case .unreadable(let reason) = error as? ControllerPolicyFileError else {
          return XCTFail("\(error)")
        }

        XCTAssertTrue(reason.contains(expected), "\(reason) does not say \(expected)")
      }
    }
  }

  // MARK: The store

  /// Catches a policy file or folder another user can read, or a write that leaves a temp file.
  func testTheFileIsPrivateAndWrittenWhole() throws {
    let store = ControllerTrustStore(directory: folder)

    try store.update { _ in [Self.policy([.paneControl])] }

    var info = stat()

    XCTAssertEqual(stat(store.fileURL.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    XCTAssertEqual(stat(folder.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)

    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)

    XCTAssertFalse(names.contains { $0.contains(".tmp-") }, "\(names)")
    XCTAssertEqual(store.read().policies, [Self.policy([.paneControl])])
  }

  /// Catches a corrupt file that grants something, that is overwritten and lost, or that blocks
  /// trust from then on. It grants nothing, is kept aside byte for byte, and a later write leaves
  /// the kept copy alone.
  func testACorruptFileGrantsNothingAndIsKeptForRecovery() throws {
    let store = ControllerTrustStore(directory: folder)

    try store.update { _ in [Self.policy([.paneControl])] }

    let corrupt = Data("{\"format\": 2, \"policies\": [".utf8)

    try corrupt.write(to: store.fileURL)

    let state = store.read()

    XCTAssertEqual(state.policies, [])
    XCTAssertTrue(state.writable)
    XCTAssertTrue(state.notice?.contains("policy.aside-1.json") == true, "\(state)")
    XCTAssertEqual(store.keptAsideFiles.count, 1)

    try store.update { _ in [Self.policy([.clipboardRead])] }

    XCTAssertEqual(try Data(contentsOf: store.keptAsideFiles[0]), corrupt)
    XCTAssertEqual(store.read().policies, [Self.policy([.clipboardRead])])
  }

  /// Catches a file from before approvals carried an edition that is read as one. Its scopes name
  /// a permission version, which this build must never read as an edition. The file is kept aside
  /// byte for byte with a notice that each approval is given again once, and the next approval is
  /// saved. The same holds for the script file store.
  func testAFileFromBeforeEditionsIsSetAsideWithANoticeAndTheNextApprovalIsSaved() throws {
    let before = Data(
      """
      {
        "format": 1,
        "policies": [
          {
            "approved": "2026-11-11T10:00:00Z",
            "name": "Fixture",
            "scopes": [{"kind": "pane-control", "version": 1}],
            "selector": {"controller": "dev.uniterm.fixture.policy", "kind": "version", "version": "\(Self.version)"}
          }
        ]
      }

      """.utf8)

    for (artifact, subject) in [(ControllerArtifact.package, "controller"), (.file, "script file")]
    {
      let directory = folder.appendingPathComponent(
        subject.replacingOccurrences(of: " ", with: "-"))
      let store = ControllerTrustStore(directory: directory, artifact: artifact)

      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try before.write(to: store.fileURL)

      let state = store.read()

      XCTAssertEqual(state.policies, [], subject)
      XCTAssertTrue(state.writable, subject)
      XCTAssertTrue(state.notice?.contains("approved again once") == true, "\(state)")
      XCTAssertTrue(state.notice?.contains("aside-1.json") == true, "\(state)")
      XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.keptAsideFiles.first)), before)

      let policy =
        artifact == .package
        ? Self.policy([.paneControl])
        : ControllerPolicy(
          selector: .fileVersion(version: Self.version), name: "Fixture", scopes: [.paneControl],
          approved: "2026-11-11T10:00:00Z")

      try store.update { _ in [policy] }

      XCTAssertEqual(store.read().policies, [policy], subject)
      XCTAssertEqual(store.read().notice, nil, subject)
    }
  }

  /// Catches an older build that trusts a newer file's policies, or rewrites the file and loses
  /// them. A newer format and a permission edition this build lacks both grant nothing, write
  /// nothing, and leave the bytes where they are, so two builds that run together never move each
  /// other's file aside.
  func testANewerFileGrantsNothingAndIsLeftUntouched() throws {
    let store = ControllerTrustStore(directory: folder)
    let current = String(
      decoding: ControllerPolicyFile.encode([Self.policy([.paneControl])]), as: UTF8.self)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for newerText in [
      current.replacingOccurrences(of: "\"format\": 2", with: "\"format\": 7"),
      current.replacingOccurrences(of: "\"edition\": 0", with: "\"edition\": 4"),
      "{\"format\": 3, \"policies\": [], \"flag\": true}",
    ] {
      let newer = Data(newerText.utf8)

      try newer.write(to: store.fileURL)

      let state = store.read()

      XCTAssertEqual(state.policies, [])
      XCTAssertFalse(state.writable)
      XCTAssertThrowsError(try store.update { _ in [Self.policy([.paneControl])] })
      XCTAssertEqual(try Data(contentsOf: store.fileURL), newer)
      XCTAssertEqual(store.keptAsideFiles, [])
    }
  }

  /// Catches a store that follows a link in place of its folder and makes the link's target
  /// private, or that waits forever on a policy file that is no regular file, such as a FIFO,
  /// while it holds the lock every other read needs. Both grant nothing, and neither changes or
  /// waits on anything.
  func testALinkedFolderOrASpecialFileGrantsNothingAndBlocksNothing() throws {
    let target = folder.deletingLastPathComponent().appendingPathComponent("elsewhere")

    try FileManager.default.createDirectory(
      at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: target)

    let linked = ControllerTrustStore(directory: folder).read()
    var info = stat()

    XCTAssertEqual(linked.policies, [])
    XCTAssertNotNil(linked.notice)
    XCTAssertEqual(stat(target.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o755, "the store changed a folder it does not own")

    try FileManager.default.removeItem(at: folder)

    let store = ControllerTrustStore(directory: folder)

    try store.update { _ in [] }
    try FileManager.default.removeItem(at: store.fileURL)
    XCTAssertEqual(mkfifo(store.fileURL.path, 0o600), 0)

    let finished = DispatchSemaphore(value: 0)
    let result = LockedState()

    Thread.detachNewThread {
      result.set(store.read())
      finished.signal()
    }

    guard finished.wait(timeout: .now() + 5) == .success else {
      // Lets the blocked open go, so the thread does not outlive the test.
      let writer = open(store.fileURL.path, O_WRONLY | O_NONBLOCK)

      if writer >= 0 { close(writer) }

      return XCTFail("a read waited on a FIFO")
    }

    XCTAssertEqual(result.state?.policies, [])
    XCTAssertNotNil(result.state?.notice)
  }

  /// Catches two instances that each rewrite the file from what they read earlier, so one loses
  /// the other's change. Every change rereads the file under the lock.
  func testTwoStoresOnOneFolderKeepEachOthersChanges() throws {
    let first = ControllerTrustStore(directory: folder)
    let second = ControllerTrustStore(directory: folder)
    let other = ControllerPolicy(
      selector: .version(controllerID: "dev.uniterm.fixture.other", version: Self.version),
      name: "Other", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")

    try first.update { $0 + [Self.policy([.paneControl])] }
    try second.update { $0 + [other] }

    XCTAssertEqual(Set(first.read().policies), [Self.policy([.paneControl]), other])

    try second.update { $0.filter { $0.selector != other.selector } }

    XCTAssertEqual(first.read().policies, [Self.policy([.paneControl])])
  }

  /// Catches a write the reader would refuse as too large. The next read would move the whole file
  /// aside, and every remembered approval would stop working. Policies under the count cap can still
  /// pass the byte limit through host-launch environment keys, so the store refuses the write and
  /// keeps the file it had.
  func testAWriteOverTheByteLimitIsRefusedAndTheFileKept() throws {
    let store = ControllerTrustStore(directory: folder)

    try store.update { _ in [Self.policy([.paneControl])] }

    let padding = String(repeating: "K", count: HostLaunchScope.maxKeyBytes - 3)
    let keys = (0..<HostLaunchScope.maxEnvironmentKeys).map { padding + String(format: "%03d", $0) }
    let large = try (0..<200).map { index in
      ControllerPolicy(
        selector: .version(
          controllerID: "dev.uniterm.fixture.large\(index)", version: Self.version),
        name: "Large", scopes: [try launch("/tmp", keys: keys)], approved: "2026-11-11T10:00:00Z")
    }

    XCTAssertGreaterThan(ControllerPolicyFile.encode(large).count, ControllerPolicyFile.maxBytes)
    XCTAssertThrowsError(try store.update { _ in large })

    let state = store.read()

    XCTAssertEqual(state.policies, [Self.policy([.paneControl])])
    XCTAssertTrue(state.writable)
    XCTAssertEqual(store.keptAsideFiles.count, 0)
  }

  // MARK: Path reading

  private func reads(_ directories: String...) throws -> ControllerPermission {
    .pathRead(try ReadScope(directories: directories))
  }

  /// Catches a path-reading approval compared on raw directories. A narrower scope is covered. A
  /// wider one, a sibling that shares a prefix, and a protected place under an approved folder
  /// that only contains it are not. A request held by two approvals together is covered.
  func testPathReadingIsCoveredOnlyByAScopeThatHoldsItsEffectiveScope() throws {
    let home = NSHomeDirectory()
    let approved: Set<ControllerPermission> = [try reads(home + "/work", home + "/notes")]

    XCTAssertEqual(
      PermissionContainment.uncovered([try reads(home + "/work/project")], by: approved), [])
    XCTAssertEqual(
      PermissionContainment.uncovered([try reads(home + "/work", home + "/notes")], by: approved),
      [])

    for wider in [
      try reads(home), try reads(home + "/work-other"), try reads(home + "/work", home + "/src"),
    ] {
      XCTAssertEqual(PermissionContainment.uncovered([wider], by: approved), [wider], "\(wider)")
    }

    let everything: Set<ControllerPermission> = [try reads(home)]

    for protected in ["Documents", "Documents/x", "Desktop", "Downloads/a.zip"] {
      let asked = try reads(home + "/" + protected)

      XCTAssertEqual(
        PermissionContainment.uncovered([asked], by: everything), [asked],
        "\(protected) is broader than an approved home folder")
    }

    XCTAssertEqual(
      PermissionContainment.uncovered(
        [try reads(home + "/Documents/x")], by: [try reads(home, home + "/Documents")]), [])

    let split: Set<ControllerPermission> = [try reads(home + "/a"), try reads(home + "/b")]

    XCTAssertEqual(
      PermissionContainment.uncovered([try reads(home + "/a/x")], by: split), [])
    XCTAssertEqual(PermissionContainment.uncovered([.paneControl], by: split), [.paneControl])
    XCTAssertEqual(
      PermissionContainment.uncovered(
        [ControllerPermission(.pathRead(try ReadScope(directories: ["/a"])), edition: 1)],
        by: split
      ).count,
      1, "an approval at another edition is never covered")
  }

  /// Catches a merge that lists the power twice, which a later review would show as two powers.
  func testMergingTwoPathReadScopesKeepsOneAndTheirUnion() throws {
    let merged = PermissionContainment.merged(
      [.paneControl, try reads("/a")], with: [try reads("/b"), try reads("/a/c")])

    XCTAssertEqual(merged, [.paneControl, try reads("/a", "/b")])
  }

  /// Catches a path-reading scope lost in the file, or written two ways.
  func testPathReadingRoundTripsThroughTheFile() throws {
    let policies = [Self.policy([.paneControl, try reads("/work/b", "/work/a")])]
    let bytes = ControllerPolicyFile.encode(policies)

    XCTAssertEqual(try ControllerPolicyFile.decode(bytes), policies)
    XCTAssertTrue(
      String(decoding: bytes, as: UTF8.self).contains("\"directories\""), "the scope is written")
    XCTAssertTrue(
      String(decoding: bytes, as: UTF8.self).contains("\"format\": 2"),
      "the policy file format did not change")
  }

  /// Catches a policy file that a merged approval makes unreadable. Approvals add up past the count
  /// one descriptor may declare, and a reader that applied that count would move the whole file
  /// aside, losing every approval in it.
  func testAMergedScopeWiderThanOneDescriptorRoundTripsThroughTheFile() throws {
    var held: Set<ControllerPermission> = []

    for index in 0...ReadScope.maxDirectories {
      held = PermissionContainment.merged(held, with: [try reads("/work/\(index)")])
    }

    let policies = [Self.policy(held)]

    XCTAssertEqual(try ControllerPolicyFile.decode(ControllerPolicyFile.encode(policies)), policies)
  }

  // MARK: Browser powers

  /// Catches an approval of pane control, or of one browser power, that covers another power. ADR-09
  /// keeps one power from granting another, and an approval that predates the browser kinds holds
  /// neither of them.
  func testBrowserPowersAreCoveredOnlyByThemselvesAtTheirOwnEdition() {
    let both: Set<ControllerPermission> = [.browserNavigation, .browserRead]

    XCTAssertEqual(PermissionContainment.uncovered(both, by: [.paneControl]).count, 2)
    XCTAssertEqual(
      PermissionContainment.uncovered([.browserRead], by: [.paneControl, .browserNavigation]),
      [.browserRead])
    XCTAssertEqual(
      PermissionContainment.uncovered([.browserNavigation], by: [.paneControl, .browserRead]),
      [.browserNavigation])
    XCTAssertEqual(PermissionContainment.uncovered(both, by: both), [])
    XCTAssertEqual(
      PermissionContainment.uncovered(
        [ControllerPermission(.browserRead, edition: 1)], by: both
      ).count,
      1, "an approval at another edition is never covered")
  }

  /// Catches a browser power lost in the file, written with a field it should not carry, or read
  /// from a file that spells it with one.
  func testBrowserPowersRoundTripThroughTheFile() throws {
    let policies = [Self.policy([.paneControl, .browserNavigation, .browserRead])]
    let bytes = ControllerPolicyFile.encode(policies)
    let text = String(decoding: bytes, as: UTF8.self)

    XCTAssertEqual(try ControllerPolicyFile.decode(bytes), policies)
    XCTAssertTrue(text.contains("\"browser-navigation\""))
    XCTAssertTrue(text.contains("\"browser-read\""))
    XCTAssertTrue(text.contains("\"format\": 2"), "the policy file format did not change")

    let extra = text.replacingOccurrences(
      of: "\"kind\": \"browser-read\"", with: "\"kind\": \"browser-read\", \"directories\": []")

    XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(extra.utf8)))
  }

  /// Catches the ask power lost in the file, written with a field it should not carry, covered by
  /// another power, or shown with words that hide what it grants.
  func testAskUserRoundTripsAndIsCoveredOnlyByItself() throws {
    let policies = [Self.policy([.paneControl, .askUser])]
    let bytes = ControllerPolicyFile.encode(policies)
    let text = String(decoding: bytes, as: UTF8.self)

    XCTAssertEqual(try ControllerPolicyFile.decode(bytes), policies)
    XCTAssertTrue(text.contains("\"ask-user\""))
    XCTAssertTrue(text.contains("\"format\": 2"), "the policy file format did not change")

    let extra = text.replacingOccurrences(
      of: "\"kind\": \"ask-user\"", with: "\"kind\": \"ask-user\", \"directories\": []")

    XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(extra.utf8)))

    XCTAssertEqual(PermissionContainment.uncovered([.askUser], by: [.paneControl]), [.askUser])
    XCTAssertEqual(PermissionContainment.uncovered([.paneControl], by: [.askUser]), [.paneControl])
    XCTAssertEqual(PermissionContainment.uncovered([.askUser], by: [.askUser]), [])
    XCTAssertEqual(
      ControllerPermission.askUser.displayText,
      "Ask you questions in a Questions pane and read your answers")
  }

  /// Catches a stored approval from before the browser kinds that grows to cover them when the
  /// file is read again: the kinds are new, so the old scopes name neither.
  func testAnApprovalFromBeforeTheBrowserKindsCoversNeither() throws {
    let before = [Self.policy([.paneControl, .clipboardRead])]
    let decoded = try ControllerPolicyFile.decode(ControllerPolicyFile.encode(before))

    XCTAssertEqual(
      decoded[0].uncovered([.paneControl, .browserNavigation, .browserRead]),
      [.browserNavigation, .browserRead])
  }

  /// Catches a path-reading scope that an older build would read. A build that lacks the kind
  /// reads the file as a newer one: it grants nothing and writes nothing, as for any unknown kind.
  /// The test stands in for that build by naming a kind this one lacks, and checks that the current
  /// file differs from an older build's only in that kind, with no new format number.
  func testAnOlderBuildReadsAPathReadingFileAsNewer() throws {
    let current = String(
      decoding: ControllerPolicyFile.encode([Self.policy([try reads("/work")])]), as: UTF8.self)

    XCTAssertTrue(current.contains("\"format\": 2"))

    let older = current.replacingOccurrences(of: "\"path-read\"", with: "\"path-reading\"")

    XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(older.utf8))) { error in
      XCTAssertEqual(error as? ControllerPolicyFileError, .newer("the kind path-reading"))
    }

    let store = ControllerTrustStore(directory: folder)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(older.utf8).write(to: store.fileURL)

    let state = store.read()

    XCTAssertEqual(state.policies, [])
    XCTAssertFalse(state.writable)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), Data(older.utf8))

    for broken in [
      current.replacingOccurrences(of: "\"directories\": [", with: "\"directories\": [\"rel\", "),
      current.replacingOccurrences(of: "\"directories\"", with: "\"folders\""),
    ] {
      XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(broken.utf8))) { error in
        guard case .unreadable = error as? ControllerPolicyFileError else {
          return XCTFail("\(error)")
        }
      }
    }
  }

  /// Catches a review that shows a path-reading power without its directories.
  func testPathReadingNamesItsDirectories() throws {
    let text = try reads("/work/b", "/work/a").displayText

    XCTAssertTrue(text.contains("/work/a, /work/b"), text)
  }
}

/// The state a read on another thread returned.
private final class LockedState: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ControllerTrustState?

  func set(_ state: ControllerTrustState) {
    lock.lock()
    stored = state
    lock.unlock()
  }

  var state: ControllerTrustState? {
    lock.lock()
    defer { lock.unlock() }

    return stored
  }
}
