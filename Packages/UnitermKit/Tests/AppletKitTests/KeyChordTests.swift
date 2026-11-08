import AppKit
import XCTest

@testable import AppletKit

final class KeyChordTests: XCTestCase {
  /// Catches a conflict check that misses the same key spelled two ways. Cmd-} types Cmd-Shift-],
  /// and a letter's capital is the letter with Shift.
  func testShiftedSymbolsAndCapitalsMatchTheirBaseKeyWithShift() {
    XCTAssertEqual(KeyChord("}", [.command, .shift]), KeyChord("]", [.command, .shift]))
    XCTAssertEqual(KeyChord("}", .command), KeyChord("]", [.command, .shift]))
    XCTAssertEqual(KeyChord("+", .command), KeyChord("=", [.command, .shift]))
    XCTAssertEqual(KeyChord("T", .command), KeyChord("t", [.command, .shift]))
    XCTAssertEqual(KeyChord("\u{7F}", .command), KeyChord("\u{8}", .command))
    XCTAssertEqual(KeyChord("\u{19}", .control), KeyChord("\t", [.control, .shift]))
    XCTAssertEqual(KeyChord("\u{19}", [.control, .shift]), KeyChord("\t", [.control, .shift]))
  }

  /// Catches a canonical form that is too loose. A different key, a different modifier, and a
  /// bracket without Shift are all other keys.
  func testDifferentKeysAndModifiersStayApart() {
    XCTAssertNotEqual(KeyChord("]", .command), KeyChord("}", .command))
    XCTAssertNotEqual(KeyChord("t", .command), KeyChord("t", .control))
    XCTAssertNotEqual(KeyChord("d", .command), KeyChord("d", [.command, .shift]))
    XCTAssertNotEqual(KeyChord("1", .command), KeyChord("2", .command))
  }

  /// Catches a set that treats two spellings of one key as two members.
  func testASetHoldsOneMemberPerKey() {
    let keys: Set = [KeyChord("}", .command), KeyChord("]", [.command, .shift])]

    XCTAssertEqual(keys.count, 1)
  }

  /// Catches a chord that loses the key as the menu spells it. The item must show what was declared.
  func testTheDeclaredSpellingIsKept() {
    let chord = KeyChord("}", [.command, .shift])

    XCTAssertEqual(chord.key, "}")
    XCTAssertEqual(chord.modifiers, [.command, .shift])
  }
}
