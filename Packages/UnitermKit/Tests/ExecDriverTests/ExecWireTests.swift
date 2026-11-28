import AppletKit
import Foundation
import XCTest

@testable import ExecDriver

/// The exec wire's framing and messages, apart from any process. Each bound is checked at its
/// edge, so a bound that drifts by one fails here.
final class ExecWireTests: XCTestCase {
  /// Catches a reader that buffers a whole oversized line before refusing it, or that refuses a
  /// line exactly at the bound.
  func testTheReaderRefusesALongLineBeforeItEndsAndAcceptsOneAtTheBound() throws {
    var reader = ExecFrameReader(maximumFrameBytes: 8)

    XCTAssertEqual(try reader.feed(Array("12345678\n".utf8)), [Data("12345678".utf8)])
    XCTAssertEqual(try reader.feed(Array("1234".utf8)), [])
    XCTAssertEqual(reader.pendingBytes, 4)
    XCTAssertThrowsError(try reader.feed(Array("56789".utf8))) {
      XCTAssertEqual($0 as? ExecWireError, .frameTooLong)
    }
  }

  /// Catches a line split across reads that comes back broken, or a partial line at the end of
  /// the stream that is taken as a message.
  func testLinesJoinAcrossChunksAndAPartialLineAtTheEndIsRefused() throws {
    var reader = ExecFrameReader()

    XCTAssertEqual(try reader.feed(Array("{\"a\"".utf8)), [])
    XCTAssertEqual(try reader.feed(Array(":1}\n{\"b\"".utf8)), [Data("{\"a\":1}".utf8)])
    XCTAssertThrowsError(try reader.finish()) {
      XCTAssertEqual($0 as? ExecWireError, .partialFrameAtEOF)
    }
  }

  /// Catches a decoder that takes a message with the wrong shape, or that lets nesting or a value
  /// count past their bounds reach the JSON decoder. A command to another pane must name the
  /// pane, the applet type, and the schema version, and a layout must be an object.
  func testTheDecoderRefusesBadShapesAndPassesNoBoundOn() throws {
    let refused = [
      "not json", "[1]", #"{"type":"hello"}"#, #"{"type":"unheard"}"#,
      #"{"type":"command","id":1.5,"name":"x"}"#, #"{"type":"command","id":1,"name":""}"#,
      #"{"type":"command","id":1,"name":"x","arguments":[1]}"#,
      #"{"type":"command","id":1,"name":"x","pane":3}"#,
      #"{"type":"command","id":1,"name":"x","pane":0,"applet":"a","schema":[1,0]}"#,
      #"{"type":"command","id":1,"name":"x","pane":2.5,"applet":"a","schema":[1,0]}"#,
      #"{"type":"command","id":1,"name":"x","pane":"3","applet":"a","schema":[1,0]}"#,
      #"{"type":"command","id":1,"name":"x","pane":3,"applet":"a","schema":1}"#,
      #"{"type":"command","id":1,"name":"x","pane":3,"applet":"a","schema":[1]}"#,
      #"{"type":"command","id":1,"name":"x","pane":3,"applet":"a","schema":[1,0,0]}"#,
      #"{"type":"command","id":1,"name":"x","pane":3,"applet":"a","schema":[1,-1]}"#,
      #"{"type":"command","id":1,"name":"x","pane":3,"applet":"a","schema":[1.5,0]}"#,
      #"{"type":"command","id":1,"name":"x","pane":3,"applet":"a","schema":"1.0"}"#,
      #"{"type":"layout","id":1}"#, #"{"type":"layout","id":1,"layout":[1]}"#,
      #"{"type":"layout","layout":{}}"#,
      #"{"type":"clipboard-read"}"#, #"{"type":"clipboard-write","id":1}"#,
      #"{"type":"clipboard-write","id":1,"text":3}"#,
      String(repeating: "[", count: ExecProtocol.maxDepth + 1),
      "[" + Array(repeating: "1", count: ExecProtocol.maxValues + 1).joined(separator: ","),
    ]

    for line in refused {
      XCTAssertThrowsError(try ExecWire.decode(Data(line.utf8)), String(line.prefix(40)))
    }

    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"command","id":"r1","name":"status"}"#.utf8)),
      .command(id: .string("r1"), name: "status", arguments: .object([:])))

    XCTAssertEqual(
      try ExecWire.decode(
        Data(
          #"{"type":"command","id":2,"name":"clear","pane":9,"applet":"fixture-notes","schema":[1,0]}"#
            .utf8)),
      .paneCommand(
        id: .number(2), pane: 9, appletType: "fixture-notes",
        schemaVersion: AppletSchemaVersion(1, 0),
        name: "clear",
        arguments: .object([:])))

    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"layout","id":3,"layout":{"pane":1}}"#.utf8)),
      .layout(id: .number(3), layout: .object(["pane": .number(1)])))

    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"clipboard-read","id":4}"#.utf8)),
      .clipboardRead(id: .number(4)))

    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"clipboard-write","id":"w","text":"a\nb"}"#.utf8)),
      .clipboardWrite(id: .string("w"), text: "a\nb"))
  }

  /// Catches a hello from another protocol that fails as a malformed line, or that carries a
  /// placeholder schema the schema check could accept. Protocol 3 wrote its schema as one whole
  /// number. The app must still read that hello, so the refusal names the protocol versions and
  /// says to update. The decoded hello holds no schema at all. A hello of the current protocol
  /// with that schema stays malformed.
  func testAHelloOfAnotherProtocolDecodesWhateverShapeItsSchemaHas() throws {
    XCTAssertEqual(
      try ExecWire.decode(
        Data(#"{"type":"hello","protocol":3,"applet":"fixture-notes","schema":1}"#.utf8)),
      .helloOfAnotherVersion(protocolVersion: 3))

    XCTAssertThrowsError(
      try ExecWire.decode(
        Data(
          #"{"type":"hello","protocol":\#(ExecProtocol.version),"applet":"a","schema":1}"#.utf8)))
  }

  /// Catches a clipboard text that passes the byte bound and still overruns the frame once JSON
  /// escapes it. A control character escapes to six bytes, so a text at the bound must fit one
  /// frame both ways: in the app's reply to a read, and in a driver's write with every byte and
  /// the longest request ID escaped. The channel refuses a longer write as one call, so the
  /// decoder passes it on rather than failing the wire.
  func testAClipboardTextAtTheBoundFitsOneFrameEitherWayWhenEveryByteEscapes() throws {
    let text = String(repeating: "\u{1}", count: ExecProtocol.maxClipboardBytes)
    let id = String(repeating: "\u{1}", count: ExecProtocol.maxRequestIDBytes)

    let reply = ExecWire.frame(.reply(id: .string(id), result: .object(["text": .string(text)])))

    XCTAssertLessThanOrEqual(reply.count - 1, ExecProtocol.maxFrameBytes)

    let escaped = String(repeating: #"\u0001"#, count: ExecProtocol.maxClipboardBytes)
    let escapedID = String(repeating: #"\u0001"#, count: ExecProtocol.maxRequestIDBytes)
    let write = #"{"id":"\#(escapedID)","text":"\#(escaped)","type":"clipboard-write"}"#
    var reader = ExecFrameReader()
    let lines = try reader.feed(Array((write + "\n").utf8))

    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(
      try ExecWire.decode(try XCTUnwrap(lines.first)), .clipboardWrite(id: .string(id), text: text))

    let over = String(repeating: "x", count: ExecProtocol.maxClipboardBytes + 1)

    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"clipboard-write","id":1,"text":"\#(over)"}"#.utf8)),
      .clipboardWrite(id: .number(1), text: over))
  }

  /// Catches a frame for the driver that holds a raw newline, which would split one message into
  /// two, or that loses the request ID a reply must carry back.
  func testAppFramesAreOneLineAndCarryTheRequestID() throws {
    let frame = ExecWire.frame(
      .reply(id: .number(7), result: .object(["text": .string("two\nlines")])))

    XCTAssertEqual(frame.filter { $0 == 0x0A }.count, 1)
    XCTAssertEqual(frame.last, 0x0A)

    let decoded = try JSONDecoder().decode(JSONValue.self, from: frame.dropLast())

    XCTAssertEqual(
      decoded,
      .object([
        "type": .string("reply"), "id": .number(7),
        "result": .object(["text": .string("two\nlines")]),
      ]))
  }

  /// Catches a base environment that takes anything from uniterm's own environment, or that
  /// lets a declared value fail to replace a base one.
  func testTheBaseEnvironmentIsOnlyTheDocumentedFive() throws {
    let base = ExecEnvironment(
      home: "/Users/synthetic", user: "synthetic", temporaryDirectory: "/t/")

    XCTAssertEqual(
      base.environment(adding: ["PATH": "/opt/bin", "TOKEN": "x"]),
      [
        "HOME": "/Users/synthetic", "USER": "synthetic", "LOGNAME": "synthetic", "TMPDIR": "/t/",
        "PATH": "/opt/bin", "TOKEN": "x",
      ])

    let current = try XCTUnwrap(ExecEnvironment.current())

    XCTAssertEqual(Set(current.base.keys), ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"])
    XCTAssertEqual(current.base["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
  }
}
