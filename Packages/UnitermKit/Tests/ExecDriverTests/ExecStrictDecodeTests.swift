import AppletKit
import Foundation
import XCTest

@testable import ExecDriver

/// The exec wire at version 0 reads a driver's message with its old meaning or refuses it, by name.
/// These tests prove the refusals a stale driver meets: a key or a type this build does not know,
/// a retired name, and a hello of another version with keys of its own. They cannot prove that a
/// changed meaning takes a new name. Review of each change to the wire holds that, and the retired
/// table records the result.
final class ExecStrictDecodeTests: XCTestCase {
  private func refusal(
    _ line: String, retired: [ExecRetiredName] = ExecRetired.names,
    file: StaticString = #filePath, line sourceLine: UInt = #line
  ) -> String {
    do {
      let message = try ExecWire.decode(Data(line.utf8), retired: retired)

      XCTFail("decoded \(message)", file: file, line: sourceLine)
    } catch {
      guard case .unrecognized(let text) = error else {
        XCTFail("not refused by name: \(error)", file: file, line: sourceLine)

        return ""
      }

      XCTAssertTrue(
        error.description.contains("Rebuild the driver against this uniterm"), error.description,
        file: file, line: sourceLine)
      XCTAssertTrue(
        error.description.contains("update uniterm"), error.description, file: file,
        line: sourceLine)

      return text
    }

    return ""
  }

  /// Catches a decoder that ignores a key it does not know. A driver that renamed a key to change
  /// its meaning would then run under the old one. Every message type refuses an extra key and
  /// names the key and the message.
  func testEveryMessageRefusesAKeyItDoesNotKnowByName() {
    let lines: [(type: String, line: String)] = [
      ("hello", #"{"type":"hello","protocol":0,"applet":"a","schema":[0,0],"tab":1}"#),
      ("command", #"{"type":"command","id":1,"name":"x","tab":1}"#),
      (
        "command",
        #"{"type":"command","id":1,"name":"x","pane":2,"applet":"a","schema":[0,0],"tab":1}"#
      ),
      ("layout", #"{"type":"layout","id":1,"layout":{},"tab":1}"#),
      ("clipboard-read", #"{"type":"clipboard-read","id":1,"tab":1}"#),
      ("clipboard-write", #"{"type":"clipboard-write","id":1,"text":"t","tab":1}"#),
      ("error", #"{"type":"error","message":"m","tab":1}"#),
    ]

    for (type, line) in lines {
      let text = refusal(line)

      XCTAssertTrue(text.contains("the key \"tab\" in a \"\(type)\" message"), text)
      XCTAssertTrue(text.contains("does not know"), text)
    }
  }

  /// Catches a command that takes the applet or schema of a pane command without naming the pane.
  /// Those keys only mean something with `pane`, so without it they are unknown, and the command
  /// must not run on the driver's own pane.
  func testAppletAndSchemaWithoutAPaneAreUnknownKeys() {
    let text = refusal(#"{"type":"command","id":1,"name":"x","applet":"a","schema":[0,0]}"#)

    XCTAssertTrue(text.contains("the key \"applet\""), text)
  }

  /// Catches a type that is read as another or as nothing.
  func testAnUnknownMessageTypeIsRefusedByName() {
    let text = refusal(#"{"type":"unheard-of","id":1}"#)

    XCTAssertTrue(text.contains("the message type \"unheard-of\""), text)
  }

  /// Catches a hello of another protocol that is refused for its keys, or its schema shape, in
  /// place of its version. A driver from before the reset names protocol 4, a schema of a shape
  /// this build does not read, and keys of its own. The decoder reads the protocol first and the
  /// refusal names both versions, so the user is told to rebuild the driver.
  func testAHelloOfAnotherVersionIsReadForItsProtocolAlone() throws {
    let lines = [
      #"{"type":"hello","protocol":4,"applet":"a","schema":{"major":1,"minor":0},"extra":true}"#,
      #"{"type":"hello","protocol":4,"applet":"a","schema":[1,0],"offer":[1,2]}"#,
      #"{"type":"hello","protocol":14,"extra":1}"#,
    ]

    for (line, version) in zip(lines, [4, 4, 14]) {
      XCTAssertEqual(
        try ExecWire.decode(Data(line.utf8)), .helloOfAnotherVersion(protocolVersion: version))
    }

    XCTAssertNil(try? ExecWire.decode(Data(#"{"type":"hello","applet":"a","schema":[0,0]}"#.utf8)))
  }

  /// Catches a strict decoder that stops reading the error text from either place a driver may put
  /// it, or that takes a key of another message for an error's.
  func testAnErrorMessageStillReadsBothFormsOfItsText() throws {
    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"error","error":{"code":"c","message":"nested"}}"#.utf8)),
      .refusal("nested"))
    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"error","message":"flat"}"#.utf8)), .refusal("flat"))
    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"error"}"#.utf8)), .refusal("the driver gave no reason"))
  }

  /// Catches a retired name that is read, or one refused without being named as retired. Each
  /// entry of the shipped table is sent. The table is empty today, so the second half builds a
  /// table of its own to prove the refusal itself, and it fails when the mechanism stops naming
  /// what it retires.
  func testEveryRetiredNameIsRefusedByNameAndTheMechanismWorks() {
    for name in ExecRetired.names {
      let line =
        name.key.map { #"{"type":"\#(name.messageType)","\#($0)":1}"# }
        ?? #"{"type":"\#(name.messageType)"}"#

      XCTAssertTrue(refusal(line).contains("retired"), line)
    }

    let synthetic = [
      ExecRetiredName(messageType: "old-command"),
      ExecRetiredName(messageType: "command", key: "old-pane"),
    ]

    let type = refusal(#"{"type":"old-command","id":1}"#, retired: synthetic)

    XCTAssertTrue(
      type.contains("the message type \"old-command\", which this uniterm retired"), type)

    let key = refusal(#"{"type":"command","id":1,"name":"x","old-pane":2}"#, retired: synthetic)

    XCTAssertTrue(
      key.contains("the key \"old-pane\" in a \"command\" message, which this uniterm retired"), key
    )

    let other = refusal(#"{"type":"layout","id":1,"layout":{},"old-pane":2}"#, retired: synthetic)

    XCTAssertTrue(other.contains("does not know"), "a retired key belongs to its message: \(other)")
  }

  /// Catches a message that is still live under a name the table retired.
  func testNoRetiredTypeIsLive() {
    let live: Set<String> = [
      "hello", "command", "layout", "clipboard-read", "clipboard-write", "error",
    ]

    for name in ExecRetired.names where name.key == nil {
      XCTAssertFalse(live.contains(name.messageType), name.messageType)
    }
  }
}
