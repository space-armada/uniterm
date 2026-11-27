import ControllerPackage
import Foundation
import SourceAccess
import TableTestSupport
import XCTest

@testable import ControllerTrust

/// A seeded mutation fuzzer for the policy file reader. Each input is a valid file with bytes
/// flipped, cut, or inserted.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated file traps the reader, and that a file that reads writes back to
/// bytes that read the same. It cannot prove that a refusal names the right fault, which the
/// format tests hold.
final class ControllerPolicyFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x7_0115
  }

  /// Catches a mutated policy file that traps the reader, or one whose rewrite reads differently.
  /// A file that reads, whatever mutated, writes back to bytes that read the same: the same
  /// approvals, and every entry it kept, byte for byte. The seed holds package, script file, and
  /// kept entries, so a mutation lands in each shape.
  func testMutatedPolicyFilesReadWithoutTrapping() throws {
    var random = SplitMix64(seed: seed)
    let keptEntry = ControllerKeptEntry(
      bytes: Array(
        """
        {"approved": "2026-11-11T10:00:00Z", "artifact": "driver", "name": "Kept", \
        "scopes": [{"edition": 7, "kind": "future"}], \
        "selector": {"kind": "version", "version": "\(String(repeating: "1a", count: 32))"}}
        """.utf8))
    let seedFile = ControllerPolicyFile.encode(
      [
        ControllerPolicy(
          selector: .version(
            controllerID: "dev.uniterm.fixture.fuzz", version: String(repeating: "0f", count: 32)),
          name: "Fuzz",
          scopes: [
            .paneControl, .clipboardRead, .clipboardWrite, .capability("fs-read"),
            .hostLaunch(
              try HostLaunchScope(
                executable: "/bin/echo", directory: "/tmp", environmentKeys: ["K"])),
            .pathRead(try ReadScope(directories: ["/tmp/a", "/tmp/b"])),
          ], approved: "2026-11-11T10:00:00Z", versionOf: "dev.uniterm.fixture.fuzz"),
        ControllerPolicy(
          selector: .identity(
            controllerID: "dev.uniterm.fixture.fuzz",
            keyFingerprint: String(repeating: "e", count: 64)),
          name: "Fuzz", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z"),
        ControllerPolicy(
          selector: .fileVersion(version: String(repeating: "0f", count: 32)), name: "Fuzz",
          scopes: [.paneControl, .clipboardRead, .capability("fs-read")],
          approved: "2026-11-11T10:00:00Z", versionOf: "/tmp/fuzz.janet"),
        ControllerPolicy(
          selector: .fileIdentity(
            fileID: "dev.uniterm.fixture.fuzz", keyFingerprint: String(repeating: "e", count: 64)),
          name: "Fuzz", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z"),
      ], kept: [keptEntry],
      members: [
        ControllerKeptMember(key: Array("\"extra\"".utf8), value: Array("{\"a\": [1]}".utf8))
      ])

    for iteration in 0..<iterations {
      var bytes = [UInt8](seedFile)

      for _ in 0..<Int(random.next() % 4) { mutate(&bytes, using: &random) }

      guard let document = try? ControllerPolicyFile.read(Data(bytes)) else { continue }

      let again = try ControllerPolicyFile.read(
        ControllerPolicyFile.encode(
          document.policies, kept: document.kept, members: document.members))

      XCTAssertEqual(
        Set(again.policies), Set(document.policies), "seed \(seed), iteration \(iteration)")
      XCTAssertEqual(
        Set(again.kept), Set(document.kept), "seed \(seed), iteration \(iteration)")
      XCTAssertEqual(
        Set(again.members), Set(document.members), "seed \(seed), iteration \(iteration)")
    }
  }

  /// Catches the scanner and the strict reader drifting apart. The two tokenizers are written by
  /// hand, and an entry the scanner cuts a byte short or long is read wrong without any trap. Each
  /// generated file is valid, so every range the scanner reports must be exactly the text that was
  /// written, must parse whole under the strict reader, and must be separated from the next only
  /// by a comma and whitespace. It cannot prove anything about an invalid file, which the mutation
  /// test and the format tests hold.
  func testScannerRangesAreValuesTheStrictReaderParsesWhole() throws {
    var random = SplitMix64(seed: seed &+ 1)

    for iteration in 0..<iterations {
      let entries = (0..<Int(random.next() % 6)).map { _ in
        Self.value(depth: 0, using: &random, objectOnly: true)
      }
      let space = { Self.space(using: &random) }
      var text = "{" + space() + "\"format\"" + space() + ":" + space() + "3" + space() + ","
      text += space() + "\"extra\"" + space() + ":" + space()
      text += Self.value(depth: 0, using: &random, objectOnly: false) + space() + ","
      text += space() + "\"policies\"" + space() + ":" + space() + "[" + space()

      for (index, entry) in entries.enumerated() {
        if index > 0 { text += "," + space() }

        text += entry + space()
      }

      text += "]" + space() + "}" + space()

      let bytes = Array(text.utf8)
      let at = "seed \(seed), iteration \(iteration)"
      let members = try PolicyFileScanner.members(of: bytes)
      let policies = try XCTUnwrap(
        members.first { Array(bytes[$0.key]) == Array("\"policies\"".utf8) })
      let ranges = try PolicyFileScanner.elements(of: policies.value, in: bytes)

      XCTAssertEqual(
        ranges.map { String(decoding: bytes[$0], as: UTF8.self) }, entries, at)

      for range in ranges {
        XCTAssertNoThrow(
          try StrictJSONReader.parse(Data(bytes[range]), maxBytes: ControllerPolicyFile.maxBytes),
          at)
      }

      var cursor = policies.value.lowerBound + 1

      for range in ranges {
        let between = bytes[cursor..<range.lowerBound].filter { $0 != UInt8(ascii: ",") }

        XCTAssertTrue(between.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }, at)

        cursor = range.upperBound
      }

      let rest = bytes[cursor..<(policies.value.upperBound - 1)]

      XCTAssertTrue(rest.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }, at)
    }
  }

  private static func space(using random: inout SplitMix64) -> String {
    String(
      (0..<Int(random.next() % 3)).map { _ in [" ", "\t", "\n", "\r"][Int(random.next() % 4)] })
  }

  private static func string(using random: inout SplitMix64) -> String {
    let pieces = [
      "a", "z", " ", "{", "}", "[", "]", ",", ":", "\\\"", "\\\\", "\\/", "\\n", "\\u007d",
      "\\u0022", "\u{E9}", "\u{1F600}", "\u{2028}",
    ]

    return "\""
      + (0..<Int(random.next() % 6)).map { _ in
        pieces[Int(random.next() % UInt64(pieces.count))]
      }.joined() + "\""
  }

  private static func value(
    depth: Int, using random: inout SplitMix64, objectOnly: Bool
  ) -> String {
    let choice = objectOnly ? 7 : Int(random.next() % (depth >= 3 ? 6 : 9))

    switch choice {
    case 0: return string(using: &random)
    case 1: return ["0", "-0", "7", "-12", "1.5", "0.5e-2", "1E3", "2e+10"][Int(random.next() % 8)]
    case 2: return "true"
    case 3: return "false"
    case 4: return "null"
    case 5: return "[]"
    case 6, 7:
      let count = Int(random.next() % 4)
      let members = (0..<count).map { index in
        "\"k\(index)\"" + space(using: &random) + ":" + space(using: &random)
          + value(depth: depth + 1, using: &random, objectOnly: false) + space(using: &random)
      }

      return "{" + space(using: &random) + members.joined(separator: "," + space(using: &random))
        + "}"
    default:
      let count = Int(random.next() % 4)
      let elements = (0..<count).map { _ in
        value(depth: depth + 1, using: &random, objectOnly: false) + space(using: &random)
      }

      return "[" + space(using: &random) + elements.joined(separator: "," + space(using: &random))
        + "]"
    }
  }

  private func mutate(_ bytes: inout [UInt8], using random: inout SplitMix64) {
    guard !bytes.isEmpty else { return }

    let at = Int(random.next() % UInt64(bytes.count))

    switch random.next() % 5 {
    case 0: bytes[at] ^= UInt8(truncatingIfNeeded: random.next())
    case 1: bytes[at] = [0, 0xFF, 0x7F, 0x80, 0x22, 0x5C, 0x31][Int(random.next() % 7)]
    case 2: bytes.removeSubrange(at..<min(bytes.count, at + 1 + Int(random.next() % 8)))
    case 3: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
    default: bytes.append(contentsOf: [UInt8](repeating: 0x20, count: Int(random.next() % 16)))
    }
  }
}
