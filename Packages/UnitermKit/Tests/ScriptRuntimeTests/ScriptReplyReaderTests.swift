import CJanet
import Foundation
import XCTest

/// The shim's reader for a reply from the app, held against crafted bytes through a hand-written
/// host callback. The reader runs inside the helper, in C, so only a run of the real shim can prove
/// it. Each rejected reply must reach the script as a Janet error and leave the VM standing. A
/// reply the app writes is always well formed, so these prove the reader's own checks and nothing
/// about the app.
final class ScriptReplyReaderTests: XCTestCase {
  private final class Reply {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }
  }

  private static let callback:
    @convention(c) (
      UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
      UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?,
      UnsafeMutablePointer<CChar>?, Int
    ) -> Int32 = { userdata, _, _, reply, replyLength, _, _ in
      guard let userdata, let reply, let replyLength else { return 1 }

      let crafted = Unmanaged<Reply>.fromOpaque(userdata).takeUnretainedValue()

      guard let memory = malloc(crafted.bytes.count) else { return 1 }

      crafted.bytes.withUnsafeBytes {
        memory.copyMemory(from: $0.baseAddress!, byteCount: $0.count)
      }
      reply.pointee = memory.assumingMemoryBound(to: UInt8.self)
      replyLength.pointee = crafted.bytes.count

      return 0
    }

  private let rejects = """
    (import uniterm)
    (def [ok message] (protect (uniterm/list-windows)))
    (assert (not ok) "the reply was accepted")
    (assert (string/find "could not be read" (string message)) (string "failed with " message))
    """

  /// Runs `script` with `list-windows` answering `reply`. Returns the shim's verdict and message.
  private func run(_ script: String, reply: [UInt8]) -> (uniterm_script_status, String) {
    let crafted = Reply(reply)
    var failure = uniterm_script_failure()
    let source = Array(script.utf8)

    let status = withExtendedLifetime(crafted) {
      var host = uniterm_host(
        userdata: Unmanaged.passUnretained(crafted).toOpaque(), post_status: nil,
        call: Self.callback)

      return source.withUnsafeBufferPointer {
        uniterm_janet_run(
          &host, "reply-test", $0.baseAddress, $0.count, uniterm_janet_default_sandbox, &failure)
      }
    }

    let message = withUnsafeBytes(of: failure.message) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }

    return (status, message)
  }

  private func assertRejected(_ reply: [UInt8], _ label: String, line: UInt = #line) {
    let (status, message) = run(rejects, reply: reply)

    XCTAssertEqual(status, UNITERM_SCRIPT_OK, "\(label): \(message)", line: line)
  }

  /// Catches a harness that cannot tell an accepted reply from a rejected one. Well-formed replies
  /// of each kind must come back as the Janet values they describe, including the largest ID and
  /// the deepest nesting.
  func testWellFormedRepliesBecomeJanetValues() {
    let cases: [(label: String, reply: [UInt8], script: String)] = [
      (
        "an array", [5, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 7, 2],
        "(assert (and (= (length v) 2) (= (v 0) 7) (= (v 1) true)))"
      ),
      (
        "the largest ID", [3, 0, 0x1F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        "(assert (= v 9007199254740991))"
      ),
      (
        "a record", [6, 0, 2, 1, 0x61, 1, 2, 0x62, 0x63, 4, 0, 0, 0, 1, 0x7A],
        "(assert (and (= (v :a) false) (= (v :bc) \"z\")))"
      ),
      (
        "eight levels", [UInt8]([5, 0, 1]).repeated(8) + [0],
        "(assert (array? v))"
      ),
    ]

    for (label, reply, check) in cases {
      let script = "(import uniterm)\n(def v (uniterm/list-windows))\n\(check)"
      let (status, message) = run(script, reply: reply)

      XCTAssertEqual(status, UNITERM_SCRIPT_OK, "\(label): \(message)")
    }
  }

  /// Catches a reader that walks past the end of a reply, or builds a value from bytes it did not
  /// check. Each reply is cut short somewhere, and each must be refused.
  func testTruncatedRepliesAreRefused() {
    assertRejected([3, 0, 0, 0], "an integer cut short")
    assertRejected([4, 0, 0, 0, 9, 0x61], "a string longer than the reply")
    assertRejected([4, 0, 0], "a string with no length")
    assertRejected([5, 0, 2, 0], "an array missing an element")
    assertRejected([6, 0, 1, 1, 0x61], "a record missing a value")
    assertRejected([6, 0], "a record with no count")
  }

  /// Catches a count that the reader believes without checking it against the bytes that remain,
  /// which would loop far past the reply or allocate for it.
  func testACountLargerThanTheRemainingBytesIsRefused() {
    assertRejected([5, 0xFF, 0xFF, 0], "an array that claims 65535 elements")
    assertRejected([6, 0xFF, 0xFF], "a record that claims 65535 fields")
    assertRejected([4, 0xFF, 0xFF, 0xFF, 0xFF], "a string that claims 4 GiB")
  }

  /// Catches nesting past the depth the reader allows. Eight levels are fine, and the ninth is not.
  func testNestingPastTheLimitIsRefused() {
    assertRejected([UInt8]([5, 0, 1]).repeated(9) + [0], "nine levels")
    assertRejected([UInt8]([5, 0, 1]).repeated(500) + [0], "five hundred levels")
  }

  /// Catches a string that is not UTF-8 reaching the script as a Janet string.
  func testBadUTF8IsRefused() {
    assertRejected([4, 0, 0, 0, 2, 0xC3, 0x28], "a bad continuation byte")
    assertRejected([4, 0, 0, 0, 1, 0xFF], "a byte that is never UTF-8")
    assertRejected([4, 0, 0, 0, 3, 0xED, 0xA0, 0x80], "a surrogate")
    assertRejected([4, 0, 0, 0, 2, 0xC0, 0x80], "an overlong NUL")
  }

  /// Catches an integer a Janet number cannot hold exactly. 2^53 is one past the limit.
  func testAnIntegerPastTwoToThe53IsRefused() {
    assertRejected([3, 0, 0x20, 0, 0, 0, 0, 0, 0], "2^53")
    assertRejected([3, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], "the largest 64-bit value")
  }

  /// Catches a record with a key twice, which would let the later value hide the earlier one, and
  /// a key that is empty or not a name.
  func testRecordsWithRepeatedOrBadKeysAreRefused() {
    assertRejected([6, 0, 2, 1, 0x61, 0, 1, 0x61, 0], "a repeated key")
    assertRejected([6, 0, 1, 0, 0], "an empty key")
    assertRejected([6, 0, 1, 1, 0x20, 0], "a key that is a space")
    assertRejected([6, 0, 1, 2, 0x61, 0x7F, 0], "a key with a control character")
  }

  /// Catches bytes after a complete value, and a byte that names no kind of value.
  func testTrailingBytesAndUnknownTagsAreRefused() {
    assertRejected([0, 0], "a value followed by a byte")
    assertRejected([9], "an unknown tag")
  }

  /// Catches a failure that ends the VM. After a refused reply, the same script reads a good one
  /// from the next call.
  func testTheScriptKeepsRunningAfterARefusedReply() {
    let script = """
      (import uniterm)
      (def [ok _] (protect (uniterm/list-windows)))
      (assert (not ok))
      (assert (= (uniterm/api-version) 1))
      """

    let (status, message) = run(script, reply: [9])

    XCTAssertEqual(status, UNITERM_SCRIPT_OK, message)
  }
}

extension Array {
  fileprivate func repeated(_ count: Int) -> [Element] {
    Array([[Element]](repeating: self, count: count).joined())
  }
}
