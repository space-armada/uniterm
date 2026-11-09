import Foundation

/// A source position in a Markdown document: the first line of the top block, and how far down
/// that block the top of the view is. The page computes it from the parser's own token map.
struct MarkdownAnchor: Equatable, Sendable {
  var line: Int
  var fraction: Double
}

/// A heading the page found, for the contents sidebar a later milestone adds.
struct MarkdownHeading: Equatable, Sendable {
  var level: Int
  var text: String
  var id: String
  var line: Int
}

/// What the page tells the host. Every field is checked. A message that does not fit is dropped,
/// so a page that misbehaves cannot hand the host a value it did not expect.
enum MarkdownMessage: Equatable {
  case ready
  case rendered(lines: Int, headings: [MarkdownHeading], anchor: MarkdownAnchor?)
  case anchor(MarkdownAnchor)
  case failed(String)

  static let maxHeadings = 5000
  static let maxLine = 1 << 28

  init?(body: Any) {
    guard let fields = body as? [String: Any], let kind = fields["kind"] as? String else {
      return nil
    }

    switch kind {
    case "ready":
      self = .ready

    case "anchor":
      guard let anchor = Self.anchor(from: fields) else { return nil }

      self = .anchor(anchor)

    case "failed":
      self = .failed(String((fields["reason"] as? String ?? "").prefix(200)))

    case "rendered":
      guard let lines = Self.integer(fields["lines"]), (0...Self.maxLine).contains(lines),
        let list = fields["headings"] as? [Any], list.count <= Self.maxHeadings
      else { return nil }

      var headings: [MarkdownHeading] = []

      for entry in list {
        guard let heading = Self.heading(from: entry) else { return nil }

        headings.append(heading)
      }

      var anchor: MarkdownAnchor?

      if let raw = fields["anchor"] as? [String: Any] {
        guard let parsed = Self.anchor(from: raw) else { return nil }

        anchor = parsed
      }

      self = .rendered(lines: lines, headings: headings, anchor: anchor)

    default:
      return nil
    }
  }

  /// The generation a page message carries. The host shows one document at a time, and a message
  /// from an earlier document names an earlier generation.
  static func generation(of body: Any) -> Int? {
    guard let fields = body as? [String: Any] else { return nil }

    return integer(fields["generation"])
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }

    let double = number.doubleValue

    guard double.isFinite, double == double.rounded(), abs(double) < Double(1 << 53) else {
      return nil
    }

    return Int(double)
  }

  private static func anchor(from fields: [String: Any]) -> MarkdownAnchor? {
    guard let line = integer(fields["line"]), (0...maxLine).contains(line),
      let number = fields["fraction"] as? NSNumber, number.doubleValue.isFinite
    else { return nil }

    return MarkdownAnchor(line: line, fraction: min(1, max(0, number.doubleValue)))
  }

  private static func heading(from entry: Any) -> MarkdownHeading? {
    guard let fields = entry as? [String: Any], let level = integer(fields["level"]),
      (1...6).contains(level), let text = fields["text"] as? String,
      let id = fields["id"] as? String, let line = integer(fields["line"]),
      (0...maxLine).contains(line)
    else { return nil }

    return MarkdownHeading(
      level: level, text: String(text.prefix(200)), id: String(id.prefix(400)), line: line)
  }
}
