import Foundation

/// Finds the byte range of every value a policy file holds, without judging what any value means.
///
/// The strict JSON reader builds a tree and keeps no offsets, and it refuses a whole document for a
/// fault in one value. The scanner is the layer under it. It checks the grammar of the whole file,
/// so it can tell where each entry begins and ends, and leaves every other check to the strict
/// reader, which runs on one entry's own bytes. A fault inside one entry then costs only that entry.
///
/// The scanner refuses only what stops it telling where values begin and end: a stray byte, a
/// string or container that does not end, a missing comma or colon, or something after the one
/// document. It accepts a repeated key, nesting of any depth, a leading zero, an escaped NUL, and a
/// lone surrogate escape. Each of those is a fault the strict reader finds in the entry's bytes.
/// Containers are walked with an explicit stack, so a deeply nested value cannot exhaust the call
/// stack.
struct PolicyFileScanner {
  struct Member {
    /// The key token's bytes, quotes included.
    let key: Range<Int>

    /// The value's bytes, with no space around it.
    let value: Range<Int>
  }

  struct Failure: Error, CustomStringConvertible {
    let offset: Int
    let reason: String

    var description: String { "byte \(offset): \(reason)" }
  }

  private let bytes: [UInt8]
  private var index = 0

  init(_ bytes: [UInt8]) {
    self.bytes = bytes
  }

  /// The members of the file's one top-level object, in the order the bytes hold them. A key may
  /// appear twice, once for each time it is written.
  static func members(of bytes: [UInt8]) throws -> [Member] {
    var scanner = PolicyFileScanner(bytes)

    scanner.skipSpace()

    guard scanner.index < bytes.count, bytes[scanner.index] == UInt8(ascii: "{") else {
      throw scanner.failure("the file must hold one object")
    }

    scanner.index += 1
    scanner.skipSpace()

    var members: [Member] = []

    if scanner.index < bytes.count, bytes[scanner.index] == UInt8(ascii: "}") {
      scanner.index += 1
    } else {
      while true {
        let key = try scanner.keyThenColon()

        scanner.skipSpace()

        let start = scanner.index

        try scanner.skipValue()
        members.append(Member(key: key, value: start..<scanner.index))
        scanner.skipSpace()

        guard scanner.index < bytes.count else { throw scanner.failure("the object does not end") }

        let byte = bytes[scanner.index]

        scanner.index += 1

        if byte == UInt8(ascii: "}") { break }

        guard byte == UInt8(ascii: ",") else {
          scanner.index -= 1

          throw scanner.failure("a comma or } is missing")
        }

        scanner.skipSpace()
      }
    }

    scanner.skipSpace()

    guard scanner.index == bytes.count else { throw scanner.failure("something follows the file") }

    return members
  }

  /// The range of each element of the array whose bytes are `range`.
  static func elements(of range: Range<Int>, in bytes: [UInt8]) throws -> [Range<Int>] {
    var scanner = PolicyFileScanner(bytes)

    scanner.index = range.lowerBound

    guard scanner.index < range.upperBound, bytes[scanner.index] == UInt8(ascii: "[") else {
      throw scanner.failure("the policies must be an array")
    }

    scanner.index += 1
    scanner.skipSpace()

    var elements: [Range<Int>] = []

    if bytes[scanner.index] == UInt8(ascii: "]") { return elements }

    while true {
      let start = scanner.index

      try scanner.skipValue()
      elements.append(start..<scanner.index)
      scanner.skipSpace()

      // The range came from a value that already scanned, so both bytes exist.
      let byte = bytes[scanner.index]

      scanner.index += 1

      if byte == UInt8(ascii: "]") { return elements }

      scanner.skipSpace()
    }
  }

  private func failure(_ reason: String) -> Failure {
    Failure(offset: index, reason: reason)
  }

  private mutating func skipSpace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x20, 0x09, 0x0A, 0x0D: index += 1
      default: return
      }
    }
  }

  /// Reads an object key and its colon, and leaves the index at the start of the value's space.
  private mutating func keyThenColon() throws -> Range<Int> {
    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
      throw failure("an object key must be a string")
    }

    let start = index

    try skipString()

    let key = start..<index

    skipSpace()

    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
      throw failure("a colon must follow a key")
    }

    index += 1

    return key
  }

  /// Moves past one value that starts at the index, after any space.
  private mutating func skipValue() throws {
    var stack: [UInt8] = []

    while true {
      skipSpace()

      guard index < bytes.count else { throw failure("a value is missing") }

      var finished = true

      switch bytes[index] {
      case UInt8(ascii: "{"):
        index += 1
        skipSpace()

        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
          index += 1
        } else {
          stack.append(UInt8(ascii: "{"))
          _ = try keyThenColon()
          finished = false
        }

      case UInt8(ascii: "["):
        index += 1
        skipSpace()

        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
          index += 1
        } else {
          stack.append(UInt8(ascii: "["))
          finished = false
        }

      case UInt8(ascii: "\""):
        try skipString()

      case UInt8(ascii: "t"):
        try skipLiteral("true")

      case UInt8(ascii: "f"):
        try skipLiteral("false")

      case UInt8(ascii: "n"):
        try skipLiteral("null")

      case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
        try skipNumber()

      default:
        throw failure("a value must be a string, number, boolean, null, array, or object")
      }

      guard finished else { continue }

      var next = false

      while !next {
        guard let open = stack.last else { return }

        skipSpace()

        guard index < bytes.count else { throw failure("a container does not end") }

        let byte = bytes[index]

        if byte == UInt8(ascii: ",") {
          index += 1
          skipSpace()

          if open == UInt8(ascii: "{") { _ = try keyThenColon() }

          next = true
        } else if (open == UInt8(ascii: "{") && byte == UInt8(ascii: "}"))
          || (open == UInt8(ascii: "[") && byte == UInt8(ascii: "]"))
        {
          index += 1
          stack.removeLast()
        } else {
          throw failure("a comma or a closing bracket is missing")
        }
      }
    }
  }

  private mutating func skipLiteral(_ word: String) throws {
    let expected = Array(word.utf8)

    guard bytes.count - index >= expected.count,
      Array(bytes[index..<index + expected.count]) == expected
    else { throw failure("a value must be a string, number, boolean, null, array, or object") }

    index += expected.count
  }

  /// A number's grammar, with leading zeros let through. The strict reader refuses them in the
  /// entry's own bytes.
  private mutating func skipNumber() throws {
    if bytes[index] == UInt8(ascii: "-") { index += 1 }

    guard skipDigits() else { throw failure("a number needs digits") }

    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
      index += 1

      guard skipDigits() else { throw failure("a fraction needs digits") }
    }

    if index < bytes.count, [UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) {
      index += 1

      if index < bytes.count, [UInt8(ascii: "+"), UInt8(ascii: "-")].contains(bytes[index]) {
        index += 1
      }

      guard skipDigits() else { throw failure("an exponent needs digits") }
    }
  }

  private mutating func skipDigits() -> Bool {
    let start = index

    while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
      index += 1
    }

    return index > start
  }

  /// Finds where a string ends. Only a quote ends it, and a backslash hides the byte after it, so
  /// nothing else can move a boundary. A control byte, an unknown escape letter, a short `\u`
  /// escape, an escaped NUL, a lone surrogate escape, and a byte that is not UTF-8 all pass here.
  /// Each costs only the entry that holds it, since the strict reader refuses it in the entry's
  /// own bytes. A byte that is not UTF-8 is at least 0x80, so it is never a quote or a backslash.
  private mutating func skipString() throws {
    index += 1

    while true {
      guard index < bytes.count else { throw failure("a string does not end") }

      let byte = bytes[index]

      index += 1

      if byte == UInt8(ascii: "\"") { return }

      guard byte == UInt8(ascii: "\\") else { continue }

      guard index < bytes.count else { throw failure("an escape does not end") }

      index += 1
    }
  }
}
