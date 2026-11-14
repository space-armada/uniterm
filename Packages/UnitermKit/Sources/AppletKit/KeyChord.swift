import AppKit

/// A key and its modifiers, as a menu item names them.
///
/// Two chords are equal when they type the same key. Cmd-} and Cmd-Shift-] are equal, since the brace
/// is the bracket key with Shift. A letter's case folds into Shift in the same way. The key is kept
/// as it was declared, so a menu item shows it the way its owner wrote it.
///
/// The shifted symbols are those of a US layout. A layout that moves them compares by the symbol its
/// keys type, which is how a menu item matches a key press as well.
public struct KeyChord: Hashable, Sendable {
  /// The modifiers that make a chord. Caps Lock, Fn, and the numeric-pad flag are not part of one.
  public static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

  /// The key as declared, such as `}` or `k`.
  public let key: String

  private let declaredBits: UInt
  private let canonicalKey: String
  private let canonicalBits: UInt

  public var modifiers: NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: declaredBits)
  }

  public init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
    let bits = modifiers.intersection(Self.modifierMask).rawValue

    self.key = key
    declaredBits = bits
    (canonicalKey, canonicalBits) = Self.canonicalize(key, bits)
  }

  public static func == (lhs: KeyChord, rhs: KeyChord) -> Bool {
    lhs.canonicalKey == rhs.canonicalKey && lhs.canonicalBits == rhs.canonicalBits
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(canonicalKey)
    hasher.combine(canonicalBits)
  }

  private static let shiftedSymbols: [String: String] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
    ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
    ">": ".", "?": "/", "~": "`",
  ]

  /// The Delete key sends 0x7F, and menus spell it 0x08.
  ///
  /// Shift-Tab types the back-tab character 0x19, and a menu names it Tab with Shift.
  private static func canonicalize(_ key: String, _ bits: UInt) -> (String, UInt) {
    var flags = NSEvent.ModifierFlags(rawValue: bits)
    var folded = key == "\u{7F}" ? "\u{8}" : key

    if folded == "\u{19}" {
      folded = "\t"
      flags.insert(.shift)
    } else if let base = shiftedSymbols[folded] {
      folded = base
      flags.insert(.shift)
    } else {
      let lower = folded.lowercased()

      if lower != folded {
        folded = lower
        flags.insert(.shift)
      }
    }

    return (folded, flags.rawValue)
  }
}
