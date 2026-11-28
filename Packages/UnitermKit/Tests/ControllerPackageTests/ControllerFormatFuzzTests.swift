import ControllerTestSupport
import Foundation
import TableTestSupport
import XCTest

@testable import ControllerPackage

/// A seeded mutation fuzzer for the controller formats: the descriptor in both formats, the
/// signature file, and the Mach-O load commands. Each input is a valid document or image with bytes flipped, cut, or
/// inserted.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated input traps or reads out of bounds, and that a descriptor that reads
/// reads the same way twice. It cannot prove that a refusal names the right fault, which the format
/// tests hold.
final class ControllerFormatFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0xC0_17
  }

  private func corpus() throws -> [Data] {
    let package = ControllerFixtures.package("janet-hello")

    return [
      try Data(contentsOf: package.appendingPathComponent("controller.json")),
      try Data(contentsOf: package.appendingPathComponent("controller.sig")),
      try ControllerFixtures.descriptor(ControllerFixtures.formatZero),
      try ControllerFixtures.descriptor(ControllerFixtures.formatZeroBrowser),
    ] + (try ControllerFixtures.rejected.map { try ControllerFixtures.descriptor($0.name) })
  }

  /// Catches a mutated descriptor or signature that traps a reader, or a descriptor whose second
  /// reading differs from its first.
  func testMutatedDescriptorsAndSignaturesReadWithoutTrapping() throws {
    var random = SplitMix64(seed: seed)
    let inputs = try corpus()

    for iteration in 0..<iterations {
      var bytes = [UInt8](inputs[Int(random.next() % UInt64(inputs.count))])

      for _ in 0..<Int(random.next() % 4) { mutate(&bytes, using: &random) }

      let data = Data(bytes)

      if let descriptor = try? ControllerDescriptor.parse(data) {
        XCTAssertEqual(
          try ControllerDescriptor.parse(data), descriptor, "seed \(seed), iteration \(iteration)")
      }

      _ = try? ControllerSignature.parse(data)
    }
  }

  /// Catches a mutated file declaration that traps the reader, or one whose second reading differs
  /// from its first.
  func testMutatedFileDeclarationsReadWithoutTrapping() throws {
    var random = SplitMix64(seed: seed &+ 2)
    let inputs = [
      #"{"header":{"id":"dev.example.tidy","name":"Tidy"},"permissions":[]}"#,
      #"{"permissions":[{"kind":"pane-control"},{"kind":"clipboard-read"}]}"#,
      #"{"permissions":[{"kind":"capability","name":"fs-read"}]}"#,
      #"{"permissions":[{"kind":"host-launch","executable":"/usr/bin/git","directory":"/a","environment":["HOME"]}]}"#,
      #"{"permissions":[{"kind":"path-read","directories":["/a","/a/b"]}]}"#,
      #"{"header":{"kynd":"x"},"permissions":[{"kidn":"y"}]}"#,
    ].map { [UInt8]($0.utf8) }

    for iteration in 0..<iterations {
      var bytes = inputs[Int(random.next() % UInt64(inputs.count))]

      for _ in 0..<Int(random.next() % 4) { mutate(&bytes, using: &random) }

      guard let text = String(validating: bytes, as: UTF8.self) else { continue }

      if let declaration = try? FileDeclaration.parse(text) {
        XCTAssertEqual(
          try FileDeclaration.parse(text), declaration, "seed \(seed), iteration \(iteration)")
      }
    }
  }

  /// Catches a mutated Mach-O image that traps the load check or reads past its end.
  func testMutatedImagesCheckWithoutTrapping() throws {
    var random = SplitMix64(seed: seed &+ 1)
    let entry = MachOLoadCheckTests.image([
      .linker("/usr/lib/dyld"), .library("/usr/lib/libSystem.B.dylib"),
      .rpath("@loader_path/../lib"), .library("@rpath/inner.dylib"),
    ])
    let library = MachOLoadCheckTests.image([.library("@loader_path/inner.dylib")])

    for _ in 0..<iterations {
      var bytes = [UInt8](random.next() % 2 == 0 ? entry : library)

      for _ in 0..<Int(1 + random.next() % 4) { mutate(&bytes, using: &random) }

      _ = try? MachOLoadCheck.check(
        entry: "bin/tool", files: ["bin/tool": Data(bytes), "lib/inner.dylib": library])
    }
  }

  private func mutate(_ bytes: inout [UInt8], using random: inout SplitMix64) {
    guard !bytes.isEmpty else { return }

    let at = Int(random.next() % UInt64(bytes.count))

    switch random.next() % 5 {
    case 0: bytes[at] ^= UInt8(truncatingIfNeeded: random.next())
    case 1: bytes[at] = [0, 0xFF, 0x7F, 0x80, 0x22, 0x5C][Int(random.next() % 6)]
    case 2: bytes.removeSubrange(at..<min(bytes.count, at + 1 + Int(random.next() % 8)))
    case 3: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
    default: bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: Int(random.next() % 16)))
    }
  }
}
