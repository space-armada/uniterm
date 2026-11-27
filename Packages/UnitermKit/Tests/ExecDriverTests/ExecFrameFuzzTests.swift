import AppletKit
import Foundation
import TableTestSupport
import XCTest

@testable import ExecDriver

/// A seeded mutation fuzzer for the exec wire's frame reader and message decoder. Each input is a
/// valid stream of lines with bytes flipped, cut, or inserted, fed in chunks of random sizes.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated stream traps, that the reader never holds more than one frame's
/// bound, and that every line it returns is within the bound. It cannot prove a driver behaves.
final class ExecFrameFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0xE7EC
  }

  private static let corpus: [String] = [
    #"{"type":"hello","protocol":2,"applet":"fixture-slides","schema":[1,0]}"#,
    #"{"type":"command","id":1,"name":"set-deck","arguments":{"titles":["a","b\nc"]}}"#,
    #"{"type":"command","id":"x-2","name":"show-slide","arguments":{"index":1}}"#,
    #"{"type":"error","error":{"code":"unsupported-version","message":"synthetic"}}"#,
    #"{"type":"command","id":3,"name":"set-series","arguments":{"values":[1.5,-2,4e3,[[{}]]]}}"#,
    #"{"type":"command","id":4,"pane":7,"applet":"fixture-notes","schema":[1,0],"name":"clear"}"#,
    #"{"type":"hello","protocol":4,"applet":"fixture-notes","schema":{"major":1,"minor":0},"x":1}"#,
    #"{"type":"layout","id":5,"layout":{"split":"row","children":[{"pane":1},{"open":"x"}]}}"#,
  ]

  /// Catches a mutated stream that traps the reader or the decoder, or a reader that holds or
  /// returns more than the frame bound.
  func testMutatedStreamsReadAndDecodeWithoutTrappingWithinTheBound() {
    var random = SplitMix64(seed: seed)
    let limit = 512

    for iteration in 0..<iterations {
      var stream: [UInt8] = []

      for _ in 0..<(1 + Int(random.next() % 4)) {
        stream += Array(Self.corpus[Int(random.next() % UInt64(Self.corpus.count))].utf8) + [0x0A]
      }

      for _ in 0..<(1 + Int(random.next() % 6)) where !stream.isEmpty {
        let at = Int(random.next() % UInt64(stream.count))

        switch random.next() % 4 {
        case 0: stream[at] = UInt8(truncatingIfNeeded: random.next())
        case 1: stream.removeSubrange(at..<min(stream.count, at + Int(random.next() % 8)))
        case 2: stream.insert(contentsOf: [UInt8](repeating: 0x5B, count: 40), at: at)
        default: stream.insert(contentsOf: [UInt8](repeating: 0x61, count: 600), at: at)
        }
      }

      var reader = ExecFrameReader(maximumFrameBytes: limit)
      var offset = 0

      reading: while offset < stream.count {
        let size = 1 + Int(random.next() % 97)
        let chunk = stream[offset..<min(stream.count, offset + size)]
        offset += chunk.count

        do {
          for line in try reader.feed(chunk) {
            XCTAssertLessThanOrEqual(line.count, limit, "seed \(seed), iteration \(iteration)")
            _ = try? ExecWire.decode(line)
          }
        } catch {
          break reading
        }

        XCTAssertLessThanOrEqual(reader.pendingBytes, limit, "seed \(seed), iteration \(iteration)")
      }
    }
  }

  /// Catches a corpus line the decoder refuses, so the fuzzer's mutation of it means something.
  func testTheCorpusItselfDecodes() throws {
    for line in Self.corpus {
      XCTAssertNoThrow(try ExecWire.decode(Data(line.utf8)), line)
    }
  }
}
