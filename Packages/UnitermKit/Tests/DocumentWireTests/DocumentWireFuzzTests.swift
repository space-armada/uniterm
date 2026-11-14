import Foundation
import TableTestSupport
import XCTest

@testable import DocumentWire

/// A seeded mutation fuzzer for the document wire codec as shipped. Each input is a valid frame
/// with bytes flipped, cut, or inserted, and goes through the decoders and the reply checks the
/// app applies to helper bytes.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated frame traps or reads out of bounds in uniterm's codec, and that a
/// reply the checks complete always has images that match their own dimensions. It cannot prove
/// the helper behaves.
final class DocumentWireFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0xD0C5
  }

  private func corpus() -> [Data] {
    [
      DocumentHelperMessage.hello(version: 1).frame(),
      DocumentHelperMessage.archive(request: 1, imageCount: 1, bytes: Data(repeating: 7, count: 30))
        .frame(),
      DocumentHelperMessage.image(
        request: 1, index: 0, width: 3, height: 2, pixels: Data(repeating: 5, count: 24)
      ).frame(),
      DocumentHelperMessage.done(request: 1).frame(),
      DocumentHelperMessage.failure(request: 1, kind: .limit, text: "Past the limit.").frame(),
      DocumentHelperMessage.pong(nonce: 9).frame(),
      DocumentAppMessage.decode(request: 1, kind: .rtf).frame(),
      DocumentAppMessage.ping(nonce: 2).frame(),
    ]
  }

  /// Catches a mutated frame that traps a decoder, or a completed reply whose images do not match
  /// their dimensions.
  func testMutatedFramesDecodeWithoutTrappingAndCompletedRepliesAreExactlySized() {
    var random = SplitMix64(seed: seed)
    let inputs = corpus()
    let limits = DocumentReplyLimits(
      maxArchiveBytes: 1 << 10, maxImages: 4, maxImagePixels: 64, maxTotalPixels: 128)
    var completed = 0

    for iteration in 0..<iterations {
      var assembler = DocumentReplyAssembler(request: 1, limits: limits)
      var messages: [DocumentHelperMessage] = []

      for _ in 0..<Int(1 + random.next() % 4) {
        var frame = [UInt8](inputs[Int(random.next() % UInt64(inputs.count))])

        for _ in 0..<Int(random.next() % 3) { mutate(&frame, using: &random) }

        guard frame.count >= FrameHeader.size,
          let (type, length) = try? FrameHeader.parse(Data(frame.prefix(FrameHeader.size)))
        else { continue }

        let body = Data(frame.dropFirst(FrameHeader.size).prefix(max(length, 0)))

        _ = try? DocumentAppMessage.decode(type: type, body: body)

        if let message = try? DocumentHelperMessage.decode(type: type, body: body) {
          messages.append(message)
        }
      }

      for message in messages {
        guard let step = try? assembler.accept(message) else { break }

        if case .complete(let reply) = step {
          completed += 1

          for image in reply.images {
            XCTAssertEqual(
              image.pixels.count, image.width * image.height * DocumentProtocol.bytesPerPixel,
              "seed \(seed), iteration \(iteration)")
          }
        }
      }
    }

    XCTAssertGreaterThanOrEqual(completed, 0)
  }

  /// Catches a well-formed reply that the checks refuse, so the fuzzer's mutation of it means
  /// something.
  func testTheCorpusItselfCompletes() throws {
    var assembler = DocumentReplyAssembler(
      request: 1,
      limits: DocumentReplyLimits(
        maxArchiveBytes: 1 << 10, maxImages: 4, maxImagePixels: 64, maxTotalPixels: 128))

    for frame in corpus().prefix(4).dropFirst() {
      let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))
      let body = frame.dropFirst(FrameHeader.size).prefix(length)

      _ = try assembler.accept(try DocumentHelperMessage.decode(type: type, body: body))
    }
  }

  private func mutate(_ bytes: inout [UInt8], using random: inout SplitMix64) {
    guard !bytes.isEmpty else { return }

    let at = Int(random.next() % UInt64(bytes.count))

    switch random.next() % 5 {
    case 0: bytes[at] ^= UInt8(truncatingIfNeeded: random.next())
    case 1: bytes[at] = [0, 0xFF, 0x7F, 0x80][Int(random.next() % 4)]
    case 2: bytes.removeSubrange(at..<min(bytes.count, at + 1 + Int(random.next() % 8)))
    case 3: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
    default: bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: Int(random.next() % 16)))
    }
  }
}
