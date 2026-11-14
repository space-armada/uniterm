import DocumentTestSupport
import Foundation
import PDFKit
import TableTestSupport
import XCTest

@testable import TextViewerApplet

/// A seeded mutation fuzzer for PDF loading as shipped. Each input is a valid PDF with bytes
/// flipped, cut, or inserted, and goes through the same load path the pane uses: bytes read in
/// full, then `PDFDocument(data:)`, then a touch of text and page count so PDFKit parses.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// PDFKit and CoreGraphics are the system's, so a crash here is a bug uniterm cannot fix. The run
/// records it. It proves nothing about a PDF the corpus does not resemble.
final class PDFFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 60
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x9DF
  }

  private func corpus() -> [Data] {
    [
      DocumentFixtures.pdf(pages: ["one"]),
      DocumentFixtures.pdf(pages: ["alpha", "beta", "gamma"]),
      Data(
        "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 100 100]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"
          .utf8),
    ]
  }

  /// Catches a mutated PDF that traps the load path, or hangs it. A document that loads reports a
  /// page count that is not negative and text that PDFKit can read back.
  func testMutatedPDFsLoadWithoutTrapping() {
    var random = SplitMix64(seed: seed)
    let inputs = corpus()
    var loaded = 0

    for iteration in 0..<iterations {
      var bytes = [UInt8](inputs[Int(random.next() % UInt64(inputs.count))])

      for _ in 0..<Int(1 + random.next() % 6) { mutate(&bytes, using: &random) }

      guard case .success(let pdf) = PDFLoading.document(from: Data(bytes)) else { continue }

      loaded += 1

      XCTAssertGreaterThanOrEqual(
        pdf.document.pageCount, 0, "seed \(seed), iteration \(iteration)")

      _ = pdf.document.string
      _ = pdf.document.page(at: 0)?.string
      _ = pdf.document.page(at: 0)?.bounds(for: .cropBox)
    }

    if iterations >= 40 { XCTAssertGreaterThan(loaded, 0, "no mutated PDF still loaded") }
  }

  /// Catches the read path accepting a file past its cap, or a device, through the shipped loader.
  func testTheShippedLoaderRefusesWhatTheCapsRefuse() throws {
    let folder = try DocumentFixtures.makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let file = try DocumentFixtures.write(DocumentFixtures.pdf(), named: "a.pdf", in: folder)

    XCTAssertNotNil(try? PDFLoading.loadBlocking(path: file.path, limit: 1 << 20).get())

    if case .success = PDFLoading.loadBlocking(path: file.path, limit: 10) {
      XCTFail("a PDF past the cap loaded")
    }

    if case .success = PDFLoading.loadBlocking(path: "/dev/zero", limit: 1 << 20) {
      XCTFail("a device loaded")
    }
  }

  private func mutate(_ bytes: inout [UInt8], using random: inout SplitMix64) {
    guard !bytes.isEmpty else { return }

    let at = Int(random.next() % UInt64(bytes.count))

    switch random.next() % 6 {
    case 0: bytes[at] ^= UInt8(truncatingIfNeeded: random.next())
    case 1: bytes[at] = [0, 0xFF, 0x7F, 0x80][Int(random.next() % 4)]
    case 2: bytes.removeSubrange(at..<min(bytes.count, at + 1 + Int(random.next() % 16)))
    case 3: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
    case 4: bytes.removeSubrange(at...)
    default: bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: Int(random.next() % 16)))
    }
  }
}
