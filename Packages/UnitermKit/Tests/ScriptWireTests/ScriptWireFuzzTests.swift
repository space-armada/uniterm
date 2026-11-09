import Foundation
import TableTestSupport
import XCTest

@testable import ScriptWire

/// A seeded mutation fuzzer for the script wire codec as shipped. Each input is a valid frame with
/// bytes flipped, cut, or inserted, and goes through both decoders and the hello checks.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated frame traps or reads out of bounds in uniterm's codec, and that a
/// message that decodes encodes back to a frame that decodes to the same message. It cannot prove
/// the helper or the app behaves.
final class ScriptWireFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x5C21
  }

  private func corpus() -> [Data] {
    [
      ScriptHelperMessage.hello(version: 1).frame(),
      ScriptHelperMessage.begin(name: "synthetic.janet").frame(),
      ScriptHelperMessage.request(id: 3, call: .postStatus(level: .warning, text: "synthetic"))
        .frame(),
    ]
      + ScriptCodecTests.calls.map { ScriptHelperMessage.request(id: 3, call: $0).frame() }
      + [
        ScriptAppMessage.hello(version: 1).frame(),
        ScriptAppMessage.reply(id: 3, result: .ok(Data([1, 2]))).frame(),
        ScriptAppMessage.reply(id: 5, result: .failure(.notFound, "synthetic miss")).frame(),
        ScriptAppMessage.reply(id: 4, result: .failure(.refused, "synthetic refusal")).frame(),
      ]
  }

  /// Catches a mutated frame that traps a decoder, or a decoded message that does not survive its
  /// own encoding.
  func testMutatedFramesDecodeWithoutTrappingAndDecodedMessagesRoundTrip() throws {
    var random = SplitMix64(seed: seed)
    let inputs = corpus()

    for iteration in 0..<iterations {
      var frame = [UInt8](inputs[Int(random.next() % UInt64(inputs.count))])

      for _ in 0..<Int(random.next() % 3) { mutate(&frame, using: &random) }

      guard frame.count >= FrameHeader.size,
        let (type, length) = try? FrameHeader.parse(Data(frame.prefix(FrameHeader.size)))
      else { continue }

      let body = Data(frame.dropFirst(FrameHeader.size).prefix(max(length, 0)))

      if let message = try? ScriptHelperMessage.decode(type: type, body: body) {
        _ = try? ScriptHelperMessage.validateHello(message)

        let again = message.frame()
        let (againType, againLength) = try FrameHeader.parse(again.prefix(FrameHeader.size))

        XCTAssertEqual(
          try ScriptHelperMessage.decode(
            type: againType, body: again.dropFirst(FrameHeader.size).prefix(againLength)),
          message, "seed \(seed), iteration \(iteration)")
      }

      if let message = try? ScriptAppMessage.decode(type: type, body: body) {
        _ = try? ScriptAppMessage.validateHello(message)

        let again = message.frame()
        let (againType, againLength) = try FrameHeader.parse(again.prefix(FrameHeader.size))

        XCTAssertEqual(
          try ScriptAppMessage.decode(
            type: againType, body: again.dropFirst(FrameHeader.size).prefix(againLength)),
          message, "seed \(seed), iteration \(iteration)")
      }
    }
  }

  /// Catches a mutated reply value that traps the Swift value decoder, or one that decodes and
  /// does not encode back to the same value. It does not exercise the shim's reader, which
  /// `ScriptReplyReaderTests` holds against crafted bytes.
  func testMutatedValuesDecodeWithoutTrappingAndRoundTrip() throws {
    var random = SplitMix64(seed: seed &+ 1)

    let seeds = try [
      ScriptValue.record([
        "window": .integer(1), "title": .string("synthetic"),
        "tabs": .array([.record(["tab": .integer(2), "selected": .bool(true)])]),
      ]),
      .array([.integer(ScriptProtocol.maxID), .null, .bool(false), .string("caf\u{00E9}")]),
    ].map { try $0.encoded() }

    for iteration in 0..<iterations {
      var bytes = [UInt8](seeds[Int(random.next() % UInt64(seeds.count))])

      for _ in 0..<Int(random.next() % 3) { mutate(&bytes, using: &random) }

      guard let value = try? ScriptValue.decode(Data(bytes)) else { continue }

      XCTAssertEqual(
        try ScriptValue.decode(try value.encoded()), value, "seed \(seed), iteration \(iteration)")
    }
  }

  /// Catches a corpus frame that the codec refuses, so the fuzzer's mutation of it means
  /// something.
  func testTheCorpusItselfDecodes() throws {
    for frame in corpus() {
      let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))
      let body = frame.dropFirst(FrameHeader.size).prefix(length)

      XCTAssertTrue(
        (try? ScriptHelperMessage.decode(type: type, body: body)) != nil
          || (try? ScriptAppMessage.decode(type: type, body: body)) != nil)
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
