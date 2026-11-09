import Foundation

/// The app's own copy of a REPL's history, kept as lines are entered.
///
/// Saving a layout reads this and never asks a helper. The copy is bounded, and every line in it
/// is plain text that Janet's line editor could have produced. It is only ever recalled, never
/// evaluated.
public struct ReplHistory: Equatable, Sendable {
  /// The most lines kept. The helper recalls only its newest 100, so the rest is for the layout
  /// file and the user's own scrollback.
  public static let maxLines = 500

  /// The most bytes of text kept across all lines, which bounds the layout file.
  public static let maxBytes = 256 * 1024

  /// The longest line kept, in UTF-8 bytes. It is Janet's line editor's own limit.
  public static let maxLineBytes = 1024

  public private(set) var lines: [String]
  private var bytes: Int

  public init() {
    lines = []
    bytes = 0
  }

  /// Rebuilds a history from saved lines. A line the editor could not have produced is dropped,
  /// and the bounds apply as they do to a line entered now. The saved file is untrusted text.
  public init(restoring saved: [String]) {
    self.init()

    for line in saved {
      append(line)
    }
  }

  /// Adds a line the user entered. A blank line, a line that repeats the one before it, and a
  /// line with a control character are left out, as the line editor leaves them out of its own
  /// recall. The oldest lines go first when a bound is passed.
  public mutating func append(_ line: String) {
    guard let kept = Self.cleaned(line) else { return }

    if lines.last == kept { return }

    lines.append(kept)
    bytes += kept.utf8.count

    while lines.count > Self.maxLines || bytes > Self.maxBytes {
      bytes -= lines.removeFirst().utf8.count
    }
  }

  /// The line as it is kept, or nil when it is not kept.
  static func cleaned(_ line: String) -> String? {
    var text = ""
    var size = 0

    for scalar in line.unicodeScalars {
      if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { return nil }

      let width = String(scalar).utf8.count

      if size + width > maxLineBytes { break }

      text.unicodeScalars.append(scalar)
      size += width
    }

    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

    return text
  }
}
