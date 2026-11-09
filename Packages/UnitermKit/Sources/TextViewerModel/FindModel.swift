import Foundation

/// The one matching rule every format follows: Foundation's case- and diacritic-insensitive
/// comparison. The PDF engine passes these options to PDFKit, the text engine to `NSString`, and the
/// Markdown page folds text the same way in JavaScript.
public enum FindMatching {
  public static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  /// The most matches any engine reports. A search past it stops and says so.
  public static let maxMatches = 10_000

  /// The longest query any engine takes.
  public static let maxQueryLength = 500

  public struct Outcome: Equatable, Sendable {
    public var ranges: [NSRange]
    public var capped: Bool
  }

  /// A query as the engines receive it: cut to the length cap, and nil when empty.
  public static func prepared(_ query: String) -> String? {
    let cut = String(query.prefix(maxQueryLength))

    return cut.isEmpty ? nil : cut
  }

  /// Every non-overlapping match of `query` in `text`, in order. Returns nil when `isCancelled`
  /// says to stop. The search is linear in the text, and a caller with a large text runs it off the
  /// main thread.
  public static func search(
    in text: String, for query: String, isCancelled: () -> Bool = { false }
  ) -> Outcome? {
    guard let query = prepared(query) else { return Outcome(ranges: [], capped: false) }

    let source = NSString(string: text)
    var ranges: [NSRange] = []
    var position = 0

    while position < source.length {
      if isCancelled() { return nil }

      let found = source.range(
        of: query, options: options,
        range: NSRange(location: position, length: source.length - position))

      guard found.location != NSNotFound, found.length > 0 else { break }

      if ranges.count >= maxMatches { return Outcome(ranges: ranges, capped: true) }

      ranges.append(found)
      position = NSMaxRange(found)
    }

    return Outcome(ranges: ranges, capped: false)
  }

  /// The same search as a task that checks for cancellation between matches. A document at the
  /// decoded cap is millions of characters, so it never runs on the main thread.
  @concurrent
  public static func searchOffMain(in text: String, for query: String) async -> Outcome? {
    search(in: text, for: query, isCancelled: { Task.isCancelled })
  }
}

/// What the find bar shows for one search.
public struct FindState: Equatable, Sendable {
  public var query = ""
  public var matchCount = 0

  /// The match shown now, or nil when none is.
  public var current: Int?
  public var capped = false
  public var isSearching = false

  public init() {}

  public var hasMatch: Bool { matchCount > 0 }

  /// The index a step lands on. Stepping past either end wraps. With no current match, forward
  /// goes to the first and backward to the last.
  public func stepTarget(forward: Bool) -> Int? {
    guard matchCount > 0 else { return nil }

    guard let current else { return forward ? 0 : matchCount - 1 }

    return forward ? (current + 1) % matchCount : (current + matchCount - 1) % matchCount
  }

  /// The line beside the query field.
  public var status: String {
    guard !query.isEmpty else { return "" }

    if matchCount == 0 { return isSearching ? "Searching\u{2026}" : "No matches" }

    let total = matchCount.formatted() + (capped || isSearching ? "+" : "")

    if let current { return "\(current + 1) of \(total)" }

    return matchCount == 1 && !capped && !isSearching ? "1 match" : "\(total) matches"
  }
}
