import Foundation
import XCTest

@testable import ScriptWire

/// The script wire codec as the app and the helper share it. These tests prove that every
/// message survives a round trip, that a version mismatch is refused by name, and that each
/// size and value check holds. They cannot prove either side behaves. The integration tests
/// run a real helper for that.
final class ScriptCodecTests: XCTestCase {
  private func roundTrip(_ message: ScriptHelperMessage) throws -> ScriptHelperMessage {
    let frame = message.frame()
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    XCTAssertEqual(frame.count, FrameHeader.size + length)

    return try ScriptHelperMessage.decode(type: type, body: frame.dropFirst(FrameHeader.size))
  }

  private func roundTrip(_ message: ScriptAppMessage) throws -> ScriptAppMessage {
    let frame = message.frame()
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    XCTAssertEqual(frame.count, FrameHeader.size + length)

    return try ScriptAppMessage.decode(type: type, body: frame.dropFirst(FrameHeader.size))
  }

  /// Catches a field that is encoded but decoded into a different value.
  func testEveryHelperMessageRoundTrips() throws {
    var messages: [ScriptHelperMessage] = [
      .hello(version: 7),
      .begin(name: "tidy-up.janet"),
      .begin(name: ""),
    ]

    for level in ScriptStatusLevel.allCases {
      messages.append(.request(id: 41, call: .postStatus(level: level, text: "synthetic text")))
    }

    for message in messages {
      XCTAssertEqual(try roundTrip(message), message)
    }
  }

  /// Catches a reply whose request ID, failure kind, or payload is lost on the wire.
  func testEveryAppMessageRoundTrips() throws {
    let messages: [ScriptAppMessage] = [
      .hello(version: 7),
      .reply(id: 41, result: .ok(Data())),
      .reply(id: 42, result: .ok(Data([1, 2, 3]))),
      .reply(id: 43, result: .failure(.badArgument, "the level is not known")),
      .reply(id: 44, result: .failure(.refused, "no window")),
      .reply(id: 45, result: .failure(.failed, "")),
    ]

    for message in messages {
      XCTAssertEqual(try roundTrip(message), message)
    }
  }

  /// Catches a hello that accepts another version, in either direction. The refusal names both
  /// versions so the message to the user can be exact.
  func testAMismatchedHelloIsRefusedByVersion() {
    XCTAssertThrowsError(
      try ScriptHelperMessage.validateHello(.hello(version: ScriptProtocol.version + 1))
    ) { error in
      XCTAssertEqual(
        error as? WireError,
        .versionMismatch(found: ScriptProtocol.version + 1, expected: ScriptProtocol.version))
    }

    XCTAssertThrowsError(
      try ScriptAppMessage.validateHello(.hello(version: ScriptProtocol.version &+ 2))
    ) { error in
      XCTAssertEqual(
        error as? WireError,
        .versionMismatch(found: ScriptProtocol.version &+ 2, expected: ScriptProtocol.version))
    }

    XCTAssertNoThrow(try ScriptHelperMessage.validateHello(.hello(version: ScriptProtocol.version)))
    XCTAssertNoThrow(try ScriptAppMessage.validateHello(.hello(version: ScriptProtocol.version)))
  }

  /// Catches a connection that starts with anything but a hello and still passes validation.
  func testAFirstMessageThatIsNotAHelloIsRefused() {
    XCTAssertThrowsError(try ScriptHelperMessage.validateHello(.begin(name: "x")))
    XCTAssertThrowsError(
      try ScriptHelperMessage.validateHello(
        .request(id: 1, call: .postStatus(level: .info, text: "x"))))
    XCTAssertThrowsError(
      try ScriptAppMessage.validateHello(.reply(id: 1, result: .ok(Data()))))
  }

  /// Catches a writer that emits a field the reader refuses. The writer cuts text at a character
  /// boundary, so a long message degrades instead of killing the connection.
  func testLongStatusTextIsCutAtACharacterBoundary() throws {
    let text = String(repeating: "\u{00E9}", count: ScriptProtocol.maxStatusBytes)
    let decoded = try roundTrip(.request(id: 1, call: .postStatus(level: .info, text: text)))

    guard case .request(_, .postStatus(_, let carried)) = decoded else {
      return XCTFail("the request did not decode as a status post")
    }

    XCTAssertEqual(carried.utf8.count, ScriptProtocol.maxStatusBytes)
    XCTAssertTrue(text.hasPrefix(carried))
  }

  /// Catches a reader that allocates for a string longer than the limit the sender may write.
  func testAStringPastItsLimitIsRefused() {
    var body = ByteWriter()
    body.put(UInt32(1))
    body.put(UInt16(1))
    body.put(UInt8(0))
    body.put(UInt16(ScriptProtocol.maxStatusBytes + 1))
    body.put(raw: Data(repeating: 0x61, count: ScriptProtocol.maxStatusBytes + 1))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: body.bytes)) { error in
      XCTAssertEqual(
        error as? WireError,
        .tooLong(
          declared: ScriptProtocol.maxStatusBytes + 1, limit: ScriptProtocol.maxStatusBytes))
    }
  }

  /// Catches a reader that guesses at a call, a level, or a failure kind it does not know, or
  /// that accepts bytes after a message.
  func testUnknownValuesAndTrailingBytesAreRefused() {
    var unknownCall = ByteWriter()
    unknownCall.put(UInt32(1))
    unknownCall.put(UInt16(999))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: unknownCall.bytes))

    var unknownLevel = ByteWriter()
    unknownLevel.put(UInt32(1))
    unknownLevel.put(UInt16(1))
    unknownLevel.put(UInt8(9))
    unknownLevel.put(string: "x", limit: 16)

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: unknownLevel.bytes))

    var unknownKind = ByteWriter()
    unknownKind.put(UInt32(1))
    unknownKind.put(UInt8(77))
    unknownKind.put(string: "x", limit: 16)

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 2, body: unknownKind.bytes))

    var trailing = ByteWriter()
    trailing.put(UInt16(1))
    trailing.put(UInt8(0xFF))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 1, body: trailing.bytes)) { error in
      XCTAssertEqual(error as? WireError, .trailingBytes)
    }

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 99, body: Data())) { error in
      XCTAssertEqual(error as? WireError, .unknownType(99))
    }

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 99, body: Data())) { error in
      XCTAssertEqual(error as? WireError, .unknownType(99))
    }
  }
}
