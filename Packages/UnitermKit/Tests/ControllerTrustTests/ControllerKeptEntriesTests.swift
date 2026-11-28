import ControllerPackage
import ControllerTestSupport
import Foundation
import XCTest

@testable import ControllerTrust

/// The policy file keeps what this build cannot read. One entry it cannot read costs only that
/// entry: the rest still applies, and a save writes the entry back byte for byte.
final class ControllerKeptEntriesTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = try ControllerFixtures.temporaryFolder().appendingPathComponent("controllers")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private static let digest = String(repeating: "ab", count: 32)
  private static let pane = #"[{"edition": 0, "kind": "pane-control"}]"#

  /// One entry's text. Every part can be replaced, so a test breaks one.
  private static func entry(
    id: String = "dev.uniterm.fixture.a", artifact: String = "package", name: String = "Fixture",
    digest: String = ControllerKeptEntriesTests.digest,
    scopes: String = ControllerKeptEntriesTests.pane, kind: String = "version",
    extra: String = ""
  ) -> String {
    let selector =
      artifact == "package"
      ? #"{"controller": "\#(id)", "kind": "\#(kind)", "\#(kind == "version" ? "version" : "key")": "\#(digest)"}"#
      : #"{"kind": "\#(kind)", "version": "\#(digest)"}"#

    return
      #"{"approved": "2026-11-11T10:00:00Z", "artifact": "\#(artifact)", "name": "\#(name)", "scopes": \#(scopes), "selector": \#(selector)\#(extra)}"#
  }

  private static func file(_ entries: [String], extra: String = "") -> Data {
    Data(
      ("{\"format\": 3, \"policies\": [\(entries.joined(separator: ",\n"))]\(extra)}\n").utf8)
  }

  private static func goodPolicy(_ id: String = "dev.uniterm.fixture.good") -> ControllerPolicy {
    ControllerPolicy(
      selector: .version(controllerID: id, version: digest), name: "Fixture",
      scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")
  }

  private var store: ControllerTrustStore { ControllerTrustStore(directory: folder) }

  private func write(_ data: Data) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: store.fileURL)
  }

  // MARK: What counts as unreadable

  /// Catches an entry with a part this build does not know that grants, or that costs the others.
  /// An unknown permission kind, selector kind, artifact kind, or edition each grants nothing, and
  /// the good entry beside them still applies. No file is moved aside or left unwritable.
  func testAnEntryWithAnUnknownPartGrantsNothingAndTheOthersStillApply() throws {
    let unknown = [
      Self.entry(
        id: "dev.uniterm.fixture.kind",
        scopes: #"[{"edition": 0, "kind": "pane-control"}, {"edition": 0, "kind": "teleport"}]"#),
      Self.entry(id: "dev.uniterm.fixture.selector", kind: "pinned"),
      Self.entry(id: "dev.uniterm.fixture.artifact", artifact: "driver"),
      Self.entry(
        id: "dev.uniterm.fixture.edition", scopes: #"[{"edition": 1, "kind": "pane-control"}]"#),
    ]
    let good = Self.entry(id: "dev.uniterm.fixture.good")

    try write(Self.file(unknown + [good]))

    let state = store.read()

    XCTAssertEqual(state.policies, [Self.goodPolicy()])
    XCTAssertEqual(state.unreadable, 4)
    XCTAssertTrue(state.writable)
    XCTAssertNil(state.notice)
    XCTAssertEqual(store.keptAsideFiles, [])
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
      ["policy.json", "policy.lock"])
  }

  /// Catches an approval acted on with an unreadable scope dropped. The entry holds a readable scope
  /// and an unknown one, and grants neither, so a request for the readable one is not covered.
  func testAnApprovalWithOneUnreadableScopeGrantsNoneOfItsScopes() throws {
    try write(
      Self.file([
        Self.entry(
          scopes:
            #"[{"edition": 0, "kind": "pane-control"}, {"edition": 0, "kind": "clipboard-read"}, {"edition": 0, "kind": "future-power"}]"#
        )
      ]))

    let state = store.read()

    XCTAssertEqual(state.policies, [])
    XCTAssertEqual(state.unreadable, 1)
  }

  /// Catches a damaged entry of a known kind that is dropped, fails the file, or is told apart from
  /// a newer build's entry. A digest that is not 64 hex digits, a scope missing a field, an unknown
  /// field, a bad name, and a bad time are each kept and counted like an unknown kind.
  func testAnEntryOfAKnownKindThatFailsACheckIsKeptLikeAnUnknownOne() throws {
    let damaged = [
      Self.entry(id: "dev.uniterm.fixture.digest", digest: "abc"),
      Self.entry(
        id: "dev.uniterm.fixture.scope", scopes: #"[{"edition": 0, "kind": "capability"}]"#),
      Self.entry(id: "dev.uniterm.fixture.field", extra: #", "trusted": true"#),
      Self.entry(id: "dev.uniterm.fixture.name", name: ""),
      Self.entry(id: "dev.uniterm.fixture.id", scopes: Self.pane).replacingOccurrences(
        of: "dev.uniterm.fixture.id", with: "Not An ID"),
      Self.entry(id: "dev.uniterm.fixture.time").replacingOccurrences(
        of: "2026-11-11T10:00:00Z", with: "yesterday"),
      "12",
      "\"text\"",
      "[]",
      "null",
    ]

    try write(Self.file(damaged + [Self.entry(id: "dev.uniterm.fixture.good")]))

    let state = store.read()

    XCTAssertEqual(state.policies, [Self.goodPolicy()])
    XCTAssertEqual(state.unreadable, damaged.count)
    XCTAssertTrue(state.writable)
  }

  // MARK: Kept byte for byte

  /// Catches a save that rewrites a kept entry, so the build that wrote it cannot read it again.
  /// The entry's odd spacing, escapes, and key order survive a save by another build, and a build
  /// that knows the edition reads it back as its own approval. The strict reader keeps a parse tree
  /// with no spans, so the scanner's byte ranges are what keep the bytes.
  func testASaveWritesEveryKeptEntryBackByteForByteAndANewerBuildReadsItAgain() throws {
    let grown = ControllerPermissionEditions(["pane-control": 1])
    let newer = ControllerTrustStore(directory: folder, editions: grown)
    let older = store
    let wrote = ControllerPolicy(
      selector: .version(controllerID: "dev.uniterm.fixture.future", version: Self.digest),
      name: "Future", scopes: [ControllerPermission(.paneControl, edition: 1)],
      approved: "2026-11-11T10:00:00Z")

    try newer.update { _ in [wrote] }

    let spelled = try String(contentsOf: older.fileURL, encoding: .utf8)
    let odd = spelled.replacingOccurrences(
      of: "\"name\": \"Future\"", with: "\"name\" :\"F\\u0075ture\"")

    XCTAssertNotEqual(spelled, odd)

    try Data(odd.utf8).write(to: older.fileURL)

    XCTAssertEqual(older.read().policies, [])
    XCTAssertEqual(older.read().unreadable, 1)

    let other = Self.goodPolicy("dev.uniterm.fixture.other")

    try older.update { $0 + [other] }

    let after = try ControllerPolicyFile.read(Data(contentsOf: older.fileURL))

    XCTAssertEqual(after.kept.count, 1)
    XCTAssertTrue(
      String(decoding: after.kept[0].bytes, as: UTF8.self).contains("\"name\" :\"F\\u0075ture\""))

    let read = newer.read()

    XCTAssertEqual(Set(read.policies.map(\.name)), ["Future", "Fixture"])
    XCTAssertEqual(read.unreadable, 0)
    XCTAssertEqual(read.policies.first { $0.name == "Future" }?.scopes, wrote.scopes)
  }

  /// Catches two builds that save the same file and lose each other's entries. Each keeps what the
  /// other wrote, whichever saves first, and neither is moved aside.
  func testTwoBuildsSavingTheSameFileKeepEachOthersEntries() throws {
    let grown = ControllerPermissionEditions(["pane-control": 1])
    let newer = ControllerTrustStore(directory: folder, editions: grown)
    let older = store
    let theirs = ControllerPolicy(
      selector: .version(controllerID: "dev.uniterm.fixture.theirs", version: Self.digest),
      name: "Theirs", scopes: [ControllerPermission(.paneControl, edition: 1)],
      approved: "2026-11-11T10:00:00Z")
    let mine = Self.goodPolicy("dev.uniterm.fixture.mine")

    try newer.update { $0 + [theirs] }
    try older.update { $0 + [mine] }
    try newer.update { $0 }
    try older.update { $0 }

    XCTAssertEqual(Set(newer.read().policies), [theirs, mine])
    XCTAssertEqual(newer.read().unreadable, 0)
    XCTAssertEqual(older.read().policies, [mine])
    XCTAssertEqual(older.read().unreadable, 1)
    XCTAssertEqual(older.keptAsideFiles, [])
  }

  /// Catches a member at the top of the file that this build does not know being a fault, or being
  /// dropped on the next save. It is kept as written, and the file is not broken.
  func testAnUnknownTopLevelMemberIsAllowedAndKept() throws {
    try write(
      Self.file(
        [Self.entry(id: "dev.uniterm.fixture.good")],
        extra: ", \"future\" :{\"a\":[1,  2]}"))

    let state = store.read()

    XCTAssertEqual(state.policies, [Self.goodPolicy()])
    XCTAssertTrue(state.writable)

    try store.update { $0 + [Self.goodPolicy("dev.uniterm.fixture.more")] }

    let text = try String(contentsOf: store.fileURL, encoding: .utf8)

    XCTAssertTrue(text.contains("\"future\" :{\"a\":[1,  2]}") == false)
    XCTAssertTrue(text.contains("\"future\": {\"a\":[1,  2]}"), text)
    XCTAssertEqual(store.read().policies.count, 2)
  }

  // MARK: Faults inside one entry

  /// Catches a key repeated inside one entry, at any depth, that fails the file or is dropped. The
  /// entry is kept and counted, written back as it was, and the reader still finds where the next
  /// entry starts.
  func testAKeyRepeatedInsideOneEntryCostsOnlyThatEntry() throws {
    let repeated = [
      Self.entry(id: "dev.uniterm.fixture.top").replacingOccurrences(
        of: "\"name\": \"Fixture\"", with: "\"name\": \"Fixture\", \"name\": \"Again\""),
      Self.entry(id: "dev.uniterm.fixture.selector").replacingOccurrences(
        of: "\"kind\": \"version\"", with: "\"kind\": \"version\", \"kind\": \"version\""),
      Self.entry(
        id: "dev.uniterm.fixture.scope",
        scopes: #"[{"edition": 0, "kind": "pane-control", "edition": 0}]"#),
      Self.entry(id: "dev.uniterm.fixture.deep", extra: #", "x": {"y": {"z": 1, "z": 2}}"#),
    ]
    let good = Self.entry(id: "dev.uniterm.fixture.good")

    try write(Self.file(repeated + [good]))

    XCTAssertEqual(store.read().policies, [Self.goodPolicy()])
    XCTAssertEqual(store.read().unreadable, repeated.count)

    try store.update { $0 }

    let kept = try ControllerPolicyFile.read(Data(contentsOf: store.fileURL)).kept.map {
      String(decoding: $0.bytes, as: UTF8.self)
    }

    XCTAssertEqual(Set(kept), Set(repeated))
  }

  /// Catches a key repeated at the top of the file, or invalid JSON, that is read in part. Neither
  /// lets the reader tell where entries begin, so the whole file is set aside, kept byte for byte.
  func testARepeatedTopLevelKeyOrInvalidJSONSetsTheWholeFileAside() throws {
    let good = Self.entry(id: "dev.uniterm.fixture.good")

    for broken in [
      "{\"format\": 3, \"policies\": [\(good)], \"policies\": []}",
      "{\"format\": 3, \"format\": 3, \"policies\": [\(good)]}",
      "{\"format\": 3, \"extra\": 1, \"extra\": 2, \"policies\": [\(good)]}",
      "{\"format\": 3, \"policies\": [\(good), ]}",
      "{\"format\": 3, \"policies\": [\(good)]} trailing",
      "{\"format\": 3, \"policies\": [\(good)",
      "[]",
      "\u{FEFF}{\"format\": 3, \"policies\": []}",
      "{\"format\": 3}",
    ] {
      try? FileManager.default.removeItem(at: folder)

      let bytes = Data(broken.utf8)

      try write(bytes)

      let state = store.read()

      XCTAssertEqual(state.policies, [], broken)
      XCTAssertTrue(state.notice?.contains("aside-1.json") == true, "\(broken): \(state)")
      XCTAssertEqual(
        try Data(contentsOf: try XCTUnwrap(store.keptAsideFiles.first, broken)), bytes, broken)
    }
  }

  /// Catches a fault the strict reader finds inside one entry that costs the whole file, where the
  /// reader can still tell the entries apart. Nesting past the depth bound, an escaped NUL, an
  /// unpaired surrogate, and a leading zero each cost only their entry. Each is pinned here.
  func testDepthNULSurrogateAndLeadingZeroInsideOneEntryCostOnlyThatEntry() throws {
    let deep = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
    let deeper = String(repeating: "[", count: 20000) + String(repeating: "]", count: 20000)
    let faulty = [
      Self.entry(id: "dev.uniterm.fixture.depth", extra: ", \"x\": \(deep)"),
      Self.entry(id: "dev.uniterm.fixture.deeper", extra: ", \"x\": \(deeper)"),
      Self.entry(id: "dev.uniterm.fixture.nul", name: "a\\u0000b"),
      Self.entry(id: "dev.uniterm.fixture.surrogate", name: "a\\ud800b"),
      Self.entry(id: "dev.uniterm.fixture.low", name: "a\\udc00b"),
      Self.entry(
        id: "dev.uniterm.fixture.zero", scopes: #"[{"edition": 00, "kind": "pane-control"}]"#),
    ]
    let good = Self.entry(id: "dev.uniterm.fixture.good")

    try write(Self.file(faulty + [good]))

    let state = store.read()

    XCTAssertEqual(state.policies, [Self.goodPolicy()])
    XCTAssertEqual(state.unreadable, faulty.count)

    try store.update { $0 }

    let kept = try ControllerPolicyFile.read(Data(contentsOf: store.fileURL)).kept.map {
      String(decoding: $0.bytes, as: UTF8.self)
    }

    XCTAssertEqual(Set(kept), Set(faulty))
  }

  /// Catches a string fault that hides no boundary and still sets the whole file aside. A raw
  /// control byte, an unknown escape letter, a short `\u` escape, and a byte that is not UTF-8 each
  /// leave the entry's end plain to see. The entry is kept byte for byte, its neighbours still
  /// grant, and no file is moved aside.
  func testAStringFaultThatHidesNoBoundaryCostsOnlyThatEntry() throws {
    let faulty: [[UInt8]] = [
      Array(Self.entry(id: "dev.uniterm.fixture.control", name: "a\u{1}b").utf8),
      Array(Self.entry(id: "dev.uniterm.fixture.escape", name: #"a\xb"#).utf8),
      Array(Self.entry(id: "dev.uniterm.fixture.short", name: #"a\u12"#).utf8),
      Array(Self.entry(id: "dev.uniterm.fixture.utf8", name: "a\u{E9}b").utf8)
        .map { $0 == 0xC3 ? 0xFF : $0 },
    ]
    let good = Array(Self.entry(id: "dev.uniterm.fixture.good").utf8)
    var bytes = Array("{\"format\": 3, \"policies\": [".utf8)

    for entry in faulty + [good] {
      if bytes.last != UInt8(ascii: "[") { bytes += Array(",\n".utf8) }

      bytes += entry
    }

    bytes += Array("]}\n".utf8)

    try write(Data(bytes))

    let state = store.read()

    XCTAssertEqual(state.policies, [Self.goodPolicy()])
    XCTAssertEqual(state.unreadable, faulty.count)
    XCTAssertTrue(store.keptAsideFiles.isEmpty)

    try store.update { $0 }

    XCTAssertEqual(
      Set(try ControllerPolicyFile.read(Data(contentsOf: store.fileURL)).kept.map(\.bytes)),
      Set(faulty))
    XCTAssertTrue(store.keptAsideFiles.isEmpty)
  }

  /// Catches bytes that are not UTF-8 outside every entry being let through. In a top-level key or
  /// member, such a byte could be a damaged unknown member the file cannot tell from a good one, so
  /// the whole file is set aside, byte for byte.
  func testNonUTF8OutsideEveryEntrySetsTheWholeFileAside() throws {
    let good = Self.entry(id: "dev.uniterm.fixture.good")
    let prefix = Array("{\"format\": 3, \"policies\": [\(good)]".utf8)

    for (index, tail) in [
      Array(", \"ex\u{E9}\": 1}".utf8).map { $0 == 0xC3 ? 0xFF : $0 },
      Array(", \"extra\": \"a\u{E9}\"}".utf8).map { $0 == 0xC3 ? 0xFF : $0 },
    ].enumerated() {
      try? FileManager.default.removeItem(at: folder)

      let bytes = Data(prefix + tail)

      try write(bytes)

      XCTAssertEqual(store.read().policies, [], "\(index)")
      XCTAssertEqual(store.keptAsideFiles.count, 1, "\(index)")
      XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.keptAsideFiles.first)), bytes)
    }
  }

  /// Catches a scanner that takes text inside a string for structure, or a number form for a fault.
  /// A brace, bracket, comma, escaped quote, or escaped backslash inside a string value of a readable
  /// entry and of a kept one does not end the entry early. `1e3`, `-0`, and `1.5` inside a kept
  /// entry do not break the scan. Each entry's range is the entry's exact text, and the neighbours
  /// still read.
  func testStringContentThatLooksLikeStructureAndOddNumbersDoNotMoveEntryBoundaries() throws {
    let texts = ["a}b", "a]b", "a,b", #"a\"b"#, #"a\\b"#, "{x: [1, 2]}", #"\u007d"#]

    for text in texts {
      let readable = Self.entry(id: "dev.uniterm.fixture.readable", name: text)
      let kept = Self.entry(
        id: "dev.uniterm.fixture.kept", artifact: "driver", name: text,
        extra: ", \"n\": [1e3, -0, 1.5, 0.5e-2, \"\(text)\"]")
      let left = Self.entry(id: "dev.uniterm.fixture.left")
      let right = Self.entry(id: "dev.uniterm.fixture.right")
      let bytes = Self.file([left, readable, kept, right])
      let members = try PolicyFileScanner.members(of: [UInt8](bytes))
      let policies = try XCTUnwrap(members.first { $0.key.count == 10 })
      let ranges = try PolicyFileScanner.elements(of: policies.value, in: [UInt8](bytes))

      XCTAssertEqual(ranges.count, 4, text)
      XCTAssertEqual(
        ranges.map { String(decoding: bytes[$0], as: UTF8.self) }, [left, readable, kept, right],
        text)

      let document = try ControllerPolicyFile.read(bytes)

      XCTAssertEqual(document.policies.count, 3, text)
      XCTAssertEqual(document.kept.map { String(decoding: $0.bytes, as: UTF8.self) }, [kept], text)
    }
  }

  // MARK: Order and size

  /// Catches a file whose bytes depend on the order its entries were handed in. Entries that share
  /// a selector, a readable one and kept ones among them, are ordered by their own bytes, so one
  /// set of entries has one spelling.
  func testEntriesSharingASelectorHaveOneSpelling() throws {
    let first = Self.goodPolicy("dev.uniterm.fixture.same")
    let second = ControllerPolicy(
      selector: first.selector, name: "Second", scopes: [.clipboardRead],
      approved: "2026-11-12T10:00:00Z")
    let keptA = ControllerKeptEntry(
      bytes: Array(
        Self.entry(
          id: "dev.uniterm.fixture.same", scopes: #"[{"edition": 3, "kind": "pane-control"}]"#
        )
        .utf8))
    let keptB = ControllerKeptEntry(
      bytes: Array(Self.entry(id: "dev.uniterm.fixture.same", artifact: "driver").utf8))

    let one = ControllerPolicyFile.encode([first, second], kept: [keptA, keptB])
    let two = ControllerPolicyFile.encode([second, first], kept: [keptB, keptA])

    XCTAssertEqual(one, two)

    let read = try ControllerPolicyFile.read(one)

    XCTAssertEqual(Set(read.policies), [first, second])
    XCTAssertEqual(Set(read.kept), [keptA, keptB])
  }

  /// Catches a size check that ignores kept entries, so a save writes a file its own reader
  /// refuses. The kept entries count toward the bound, the write is refused, and the file is
  /// untouched.
  func testTheSizeCheckCountsKeptEntries() throws {
    let padding = String(repeating: "p", count: 200_000)
    let kept = (0..<20).map { index in
      Self.entry(
        id: "dev.uniterm.fixture.kept\(index)", artifact: "driver", name: "K",
        extra: ", \"pad\": \"\(padding)\"")
    }

    try write(Self.file(kept))

    let before = try Data(contentsOf: store.fileURL)

    XCTAssertEqual(store.read().unreadable, 20)
    XCTAssertLessThan(before.count, ControllerPolicyFile.maxBytes)

    let large = try ControllerPolicyTests.largePolicies(count: 100)

    XCTAssertThrowsError(try store.update { _ in large }) { error in
      XCTAssertTrue("\(error)".contains("looks damaged"), "\(error)")
    }

    XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    XCTAssertEqual(store.read().unreadable, 20)
  }

  // MARK: The format number

  /// Catches a format number an earlier build's strict reader would not take for newer. Every
  /// number an earlier build wrote reads as older here, and this build's is above them all.
  func testTheFormatNumberIsAboveEveryEarlierOne() throws {
    XCTAssertGreaterThan(ControllerPolicyFile.format, 2)

    for number in [1, 2] {
      let text = "{\"format\": \(number), \"policies\": []}"

      XCTAssertThrowsError(try ControllerPolicyFile.read(Data(text.utf8))) { error in
        XCTAssertEqual(error as? ControllerPolicyFileError, .older(number))
      }
    }
  }
}
