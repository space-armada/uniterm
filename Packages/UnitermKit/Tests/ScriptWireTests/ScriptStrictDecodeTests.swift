import Foundation
import XCTest

@testable import ScriptWire

/// ScriptWire at version 0 reads a message with its old meaning or refuses it, by name. These tests
/// prove the refusals a stale program meets: an unknown or retired tag, a value or a byte the
/// message does not hold, and a hello of another version. They cannot prove that a changed meaning
/// takes a new tag. Review of each change to the wire holds that, and the retired table records
/// the result.
final class ScriptStrictDecodeTests: XCTestCase {
  private static func parts(_ frame: Data) throws -> (type: UInt8, body: Data) {
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    return (type, Data(frame.dropFirst(FrameHeader.size).prefix(length)))
  }

  private func text(_ error: any Error, file: StaticString = #filePath, line: UInt = #line)
    -> String
  {
    guard case WireError.notRecognized(let text) = error else {
      XCTFail("not refused by name: \(error)", file: file, line: line)

      return ""
    }

    return text
  }

  private func assertAdvises(
    _ text: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      text.contains("Rebuild the program against this uniterm"), text, file: file, line: line)
    XCTAssertTrue(text.contains("update uniterm"), text, file: file, line: line)
    XCTAssertFalse(text.contains("Relaunch"), text, file: file, line: line)
  }

  /// One message of each kind that ends in fixed fields, so a byte after it is unread.
  private static let helperMessages: [ScriptHelperMessage] = [
    .hello(version: ScriptProtocol.version),
    .begin(name: "synthetic.janet"),
    .request(id: 1, call: .listWindows),
    .request(id: 2, call: .postStatus(level: .info, text: "synthetic")),
    .attach(token: Data(repeating: 7, count: ScriptProtocol.tokenBytes)),
    .replLine("(+ 1 2)"), .replEvaluating(true), .pong(3), .memoryLimit,
    .controllerBegin(ControllerBegin(entry: .janet, package: "/synthetic/p")),
    .fileBegin(FileBegin(path: "/synthetic/f.janet")),
    .fileDeclaration("{}"),
    .undeclaredBegin(UndeclaredBegin(name: "synthetic.janet")),
    .openBegin(OpenBegin(paths: ["/synthetic/a"])),
    .questionBegin,
    .identity(codeDirectoryHash: Data(repeating: 9, count: 20)),
  ]

  private static let appMessages: [ScriptAppMessage] = [
    .hello(version: ScriptProtocol.version),
    .reply(id: 1, result: .failure(.refused, "synthetic")),
    .attachRefused("synthetic"),
    .history(lines: ["(+ 1 2)"], final: true),
    .ping(4), .stop,
    .controllerAdmitted(snapshot: "/synthetic/s", version: Data(repeating: 1, count: 32)),
    .controllerRefused("synthetic"), .controllerReviewing("synthetic"),
    .fileAdmitted(snapshot: "/synthetic/s", version: Data(repeating: 1, count: 32)),
    .undeclaredAdmitted, .openDone, .questionOnlyAdmitted,
  ]

  /// Catches a decoder that ignores a byte after a message's last field, which a program that
  /// appended a field could use to change a meaning without a new tag. Every message ends in
  /// fixed fields here, so one extra byte must be refused, and the text must name the message.
  func testAByteAfterAMessageIsRefusedByNameForEveryMessage() throws {
    for message in Self.helperMessages {
      let (type, body) = try Self.parts(message.frame())

      XCTAssertNoThrow(try ScriptHelperMessage.decode(type: type, body: body), "\(message)")

      XCTAssertThrowsError(
        try ScriptHelperMessage.decode(type: type, body: body + [0x00]), "\(message)"
      ) { error in
        let said = text(error)

        XCTAssertTrue(said.contains(ScriptHelperMessage.name(ofType: type)), said)
        XCTAssertTrue(said.contains("after its last field"), said)
        assertAdvises(said)
      }
    }

    for message in Self.appMessages {
      let (type, body) = try Self.parts(message.frame())

      XCTAssertNoThrow(try ScriptAppMessage.decode(type: type, body: body), "\(message)")

      XCTAssertThrowsError(
        try ScriptAppMessage.decode(type: type, body: body + [0x00]), "\(message)"
      ) { error in
        let said = text(error)

        XCTAssertTrue(said.contains(ScriptAppMessage.name(ofType: type)), said)
        assertAdvises(said)
      }
    }
  }

  /// Catches a name table that falls behind the tags, which would turn a trailing-byte refusal for
  /// a live message into one that names only its number.
  func testEveryLiveTagHasAName() throws {
    for message in Self.helperMessages {
      let (type, _) = try Self.parts(message.frame())

      XCTAssertFalse(ScriptHelperMessage.name(ofType: type).hasPrefix("tag "), "\(message)")
    }

    for message in Self.appMessages {
      let (type, _) = try Self.parts(message.frame())

      XCTAssertFalse(ScriptAppMessage.name(ofType: type).hasPrefix("tag "), "\(message)")
    }
  }

  /// Catches a token or a digest that reads whatever follows it. These fields have one size, so a
  /// longer body is refused and a shorter one is truncated.
  func testAFixedSizeFieldHasExactlyItsSize() throws {
    let token = Data(repeating: 7, count: ScriptProtocol.tokenBytes)

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 5, body: token + [1])) {
      XCTAssertTrue(self.text($0).contains("attach"))
    }

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 5, body: token.dropLast())) {
      XCTAssertEqual($0 as? WireError, .truncated)
    }

    var admitted = ByteWriter()
    admitted.put(string: "/s", limit: 16)
    admitted.put(raw: Data(repeating: 1, count: ScriptProtocol.versionDigestBytes + 1))

    for type in [UInt8(7), 10] {
      XCTAssertThrowsError(try ScriptAppMessage.decode(type: type, body: admitted.bytes)) {
        _ = self.text($0)
      }
    }
  }

  /// Catches a hello that is read past its version field when the version is not this build's.
  /// A hello of another version may hold fields this build has no name for. The refusal must name
  /// the versions, so the decoder returns the version and stops.
  func testAHelloOfAnotherVersionIsReadForItsVersionAlone() throws {
    var other = ByteWriter()
    other.put(UInt16(14))
    other.put(raw: Data("fields from a later hello".utf8))

    XCTAssertEqual(
      try ScriptHelperMessage.decode(type: 1, body: other.bytes), .hello(version: 14))
    XCTAssertEqual(try ScriptAppMessage.decode(type: 1, body: other.bytes), .hello(version: 14))

    XCTAssertThrowsError(
      try ScriptHelperMessage.validateHello(.hello(version: 14))
    ) { error in
      XCTAssertEqual(
        error as? WireError, .versionMismatch(found: 14, expected: ScriptProtocol.version))
    }

    let said = ScriptProtocol.versionMismatchText(program: 14, uniterm: ScriptProtocol.version)

    XCTAssertTrue(said.contains("version 14"), said)
    XCTAssertTrue(said.contains("version \(ScriptProtocol.version)"), said)

    assertAdvises(said)

    let newer = ScriptProtocol.versionMismatchText(program: ScriptProtocol.version, uniterm: 14)

    XCTAssertTrue(newer.contains("version 14"), newer)

    assertAdvises(newer)
  }

  /// Catches an enumerated byte that falls back to a default, or one refused without its value.
  func testAnUnknownEnumeratedValueIsRefusedByNameWithItsValue() {
    var level = ByteWriter()
    level.put(UInt32(1))
    level.put(UInt16(1))
    level.put(UInt8(9))
    level.put(string: "x", limit: 16)

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: level.bytes)) {
      let said = self.text($0)

      XCTAssertTrue(said.contains("status level 9"), said)
      self.assertAdvises(said)
    }

    var failure = ByteWriter()
    failure.put(UInt32(1))
    failure.put(UInt8(77))
    failure.put(string: "x", limit: 16)

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 2, body: failure.bytes)) {
      XCTAssertTrue(self.text($0).contains("failure kind 77"))
    }

    var entry = ByteWriter()
    entry.put(UInt8(9))
    entry.put(string: "/p", limit: 16)
    entry.put(UInt8(0))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 10, body: entry.bytes)) {
      XCTAssertTrue(self.text($0).contains("controller entry kind 9"))
    }
  }

  /// Catches a call tag that reads as another call or as nothing, or an unknown call that does
  /// not say its tag.
  func testAnUnknownCallTagIsRefusedByName() {
    var unknown = ByteWriter()
    unknown.put(UInt32(1))
    unknown.put(UInt16(999))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: unknown.bytes)) {
      let said = self.text($0)

      XCTAssertTrue(said.contains("tag 999"), said)
      self.assertAdvises(said)
    }
  }

  /// Catches an identity that is empty, past its bound, or short of its own length. The message
  /// has one form, so its length byte is checked and nothing follows it.
  func testTheIdentityHasOneForm() throws {
    let hash = Data(repeating: 0x42, count: 20)
    let (type, body) = try Self.parts(ScriptHelperMessage.identity(codeDirectoryHash: hash).frame())

    XCTAssertEqual(type, 16)
    XCTAssertEqual(body, Data([20]) + hash)
    XCTAssertEqual(
      try ScriptHelperMessage.decode(type: type, body: body), .identity(codeDirectoryHash: hash))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 16, body: Data([0])))
    XCTAssertThrowsError(
      try ScriptHelperMessage.decode(
        type: 16,
        body: Data([UInt8(ScriptProtocol.maxIdentityBytes + 1)])
          + Data(repeating: 1, count: ScriptProtocol.maxIdentityBytes + 1)))
    XCTAssertThrowsError(
      try ScriptHelperMessage.decode(type: 16, body: Data([20]) + hash.dropLast())
    ) {
      XCTAssertEqual($0 as? WireError, .truncated)
    }

    XCTAssertFalse(ScriptHelperMessage.identity(codeDirectoryHash: hash).declaresRole)
  }

  /// Catches a retired tag that is read, or one that is refused without its name. Each entry of
  /// the shipped table is sent as a message. The table is empty today, so the second half of the
  /// test builds a table of its own to prove the refusal itself, and it fails when the mechanism
  /// stops naming what it retires.
  func testEveryRetiredNameIsRefusedByNameAndTheMechanismWorks() throws {
    let shipped = ScriptRetiredNames.current

    for retired in shipped.messages {
      switch retired.sender {
      case .helper:
        XCTAssertThrowsError(
          try ScriptHelperMessage.decode(type: retired.tag, body: Data())
        ) {
          let said = self.text($0)

          XCTAssertTrue(said.contains("\"\(retired.name)\""), said)
          XCTAssertTrue(said.contains("retired"), said)
        }

      case .app:
        XCTAssertThrowsError(try ScriptAppMessage.decode(type: retired.tag, body: Data())) {
          XCTAssertTrue(self.text($0).contains("\"\(retired.name)\""))
        }
      }
    }

    for retired in shipped.calls {
      var body = ByteWriter()
      body.put(UInt32(1))
      body.put(retired.tag)

      XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: body.bytes)) {
        XCTAssertTrue(self.text($0).contains("\"\(retired.name)\""))
      }
    }

    let synthetic = ScriptRetiredNames(
      messages: [
        .init(sender: .helper, tag: 90, name: "old-begin"),
        .init(sender: .app, tag: 91, name: "old-admitted"),
      ],
      calls: [.init(tag: 900, name: "old-list")])

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 90, body: Data(), retired: synthetic))
    {
      let said = self.text($0)

      XCTAssertTrue(said.contains("\"old-begin\" (tag 90)"), said)
      XCTAssertTrue(said.contains("retired"), said)
      self.assertAdvises(said)
    }

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 91, body: Data(), retired: synthetic)) {
      XCTAssertTrue(self.text($0).contains("\"old-admitted\" (tag 91)"))
    }

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 90, body: Data(), retired: synthetic)) {
      let said = self.text($0)

      XCTAssertFalse(said.contains("old-begin"), "a retired name belongs to its sender: \(said)")
      XCTAssertTrue(said.contains("does not know"), said)
    }

    var call = ByteWriter()
    call.put(UInt32(1))
    call.put(UInt16(900))

    XCTAssertThrowsError(
      try ScriptHelperMessage.decode(type: 3, body: call.bytes, retired: synthetic)
    ) {
      XCTAssertTrue(self.text($0).contains("\"old-list\" (tag 900)"))
    }
  }

  /// Catches a retired tag that is still assigned to a live message, which would read an old
  /// program's message under a new meaning.
  func testNoRetiredTagIsLive() throws {
    let live = Set(try Self.helperMessages.map { try Self.parts($0.frame()).type })
    let liveApp = Set(try Self.appMessages.map { try Self.parts($0.frame()).type })

    for retired in ScriptRetiredNames.current.messages {
      switch retired.sender {
      case .helper: XCTAssertFalse(live.contains(retired.tag), retired.name)
      case .app: XCTAssertFalse(liveApp.contains(retired.tag), retired.name)
      }
    }
  }
}
