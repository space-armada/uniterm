import AppletKit
import XCTest

@testable import ReplApplet

/// The app's own copy of a REPL's history, and the description that saves it. These prove the
/// bounds that keep the layout file small, the lines the copy refuses, and that a description from
/// an unreadable file is refused whole. They cannot prove what a user sees after a restore, which
/// the UI tests drive.
final class ReplHistoryTests: XCTestCase {
  /// Catches a history that grows without bound in the layout file. The line count and the byte
  /// count each hold on their own, and the newest lines survive.
  func testTheHistoryIsBoundedByLinesAndByBytes() {
    var byLines = ReplHistory()

    for number in 0..<(ReplHistory.maxLines + 40) {
      byLines.append("(line \(number))")
    }

    XCTAssertEqual(byLines.lines.count, ReplHistory.maxLines)
    XCTAssertEqual(byLines.lines.last, "(line \(ReplHistory.maxLines + 39))")
    XCTAssertEqual(byLines.lines.first, "(line 40)")

    var byBytes = ReplHistory()
    let wide = String(repeating: "x", count: ReplHistory.maxLineBytes)

    for number in 0..<400 {
      byBytes.append("\(number)\(wide)")
    }

    let total = byBytes.lines.reduce(0) { $0 + $1.utf8.count }

    XCTAssertLessThanOrEqual(total, ReplHistory.maxBytes)
    XCTAssertLessThan(byBytes.lines.count, ReplHistory.maxLines)
    XCTAssertTrue(byBytes.lines.last?.hasPrefix("399") == true)
  }

  /// Catches the saved copy being larger than the bound the proposal states. The encoded payload of
  /// the fullest history stays within the byte bound and the JSON escapes the bound allows.
  func testTheFullestHistoryEncodesWithinTheLayoutBound() throws {
    var history = ReplHistory()

    for number in 0..<1000 {
      history.append("\(number)" + String(repeating: "\u{00E9}", count: 600))
    }

    let description = try ReplDescription(history: history.lines).appletDescription()
    let data = try JSONEncoder().encode(description)

    XCTAssertLessThanOrEqual(history.lines.count, ReplHistory.maxLines)
    XCTAssertLessThan(data.count, ReplHistory.maxBytes + ReplHistory.maxLines * 32)
  }

  /// Catches a line the editor would never produce reaching the editor's recall. A saved file is
  /// untrusted text, so a control character, a blank line, and a repeat are left out, and a long
  /// line is cut at a character.
  func testRestoredHistoryDropsWhatTheEditorCouldNotHaveProduced() {
    let long = String(repeating: "\u{00E9}", count: ReplHistory.maxLineBytes)

    let history = ReplHistory(
      restoring: [
        "(+ 1 2)", "(+ 1 2)", "", "   ", "(print \"a\u{1B}[2Jb\")", "tab\there",
        "(def x 1)\n(def y 2)",
        "(ok)", long,
      ])

    XCTAssertEqual(history.lines.count, 3)
    XCTAssertEqual(Array(history.lines.prefix(2)), ["(+ 1 2)", "(ok)"])
    XCTAssertEqual(history.lines[2].utf8.count, ReplHistory.maxLineBytes)
    XCTAssertTrue(long.hasPrefix(history.lines[2]))
  }

  /// Catches a description that round trips with another history, or one this build reads that it
  /// should have kept aside. A newer version, another type, and a payload that is not a REPL's are
  /// each refused.
  func testTheDescriptionRoundTripsAndRefusesWhatItCannotRead() throws {
    let description = try ReplDescription(history: ["(+ 1 2)", "(def x 1)"]).appletDescription()

    XCTAssertEqual(description.type, "repl")
    XCTAssertEqual(description.version, 1)
    XCTAssertEqual(try ReplDescription.decode(description).history, ["(+ 1 2)", "(def x 1)"])

    let newer = AppletDescription(type: "repl", version: 2, payload: description.payload)

    XCTAssertThrowsError(try ReplDescription.decode(newer)) {
      XCTAssertEqual($0 as? AppletRestoreError, .newerVersion(found: 2, supported: 1))
    }

    let other = AppletDescription(type: "terminal", version: 1, payload: description.payload)

    XCTAssertThrowsError(try ReplDescription.decode(other))

    let bad = AppletDescription(type: "repl", version: 1, payload: .string("history"))

    XCTAssertThrowsError(try ReplDescription.decode(bad)) {
      guard case .corrupt? = $0 as? AppletRestoreError else { return XCTFail("\($0)") }
    }
  }
}
