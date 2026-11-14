import Foundation

/// Where a contents entry scrolls to.
public enum ContentsTarget: Equatable, Sendable {
  /// A page index, counted from zero, and a point on the page in page points.
  case pdf(page: Int, x: Double, y: Double)

  /// A character index in the text storage.
  case text(characterIndex: Int)

  /// The heading's position in the page's heading list.
  case markdown(heading: Int)
}

public struct ContentsEntry: Equatable, Sendable {
  public var level: Int
  public var title: String
  public var target: ContentsTarget

  public init(level: Int, title: String, target: ContentsTarget) {
    self.level = level
    self.title = title
    self.target = target
  }
}

/// Why a contents list is shorter than its source.
public enum ContentsCut: Equatable, Sendable {
  /// The list reached the entry cap.
  case entryCap

  /// An outline nested deeper than the depth cap.
  case depthCap

  /// An entry pointed back to one already listed, as a cyclic outline does.
  case repeated
}

/// A flat contents list, with the reason it was cut when a cap or a cycle cut it.
public struct Contents: Equatable, Sendable {
  public var entries: [ContentsEntry]
  public var cut: ContentsCut?

  public init(entries: [ContentsEntry] = [], cut: ContentsCut? = nil) {
    self.entries = entries
    self.cut = cut
  }

  public var wasCut: Bool { cut != nil }

  /// What the sidebar says about a cut list, by cause.
  public var cutMessage: String? {
    switch cut {
    case nil:
      return nil
    case .entryCap?:
      return "The list was cut. It shows the first \(Self.maxEntries.formatted()) entries."
    case .depthCap?:
      return
        "The list was cut. Entries nested more than \(Self.maxDepth) levels deep are not shown."
    case .repeated?:
      return
        "The list was cut. Some entries point back to an entry already listed, so they are skipped."
    }
  }

  public static let empty = Contents()

  public var isEmpty: Bool { entries.isEmpty }

  /// The most entries any format lists.
  public static let maxEntries = 5000

  /// The longest title kept.
  public static let maxTitleLength = 200

  /// The deepest outline level the walker follows.
  public static let maxDepth = 32

  public static func title(_ raw: String) -> String {
    String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
  }

  /// Flattens a tree depth first. It ends at the entry cap, at the depth cap, and at a node it has
  /// already met, so a cyclic outline cannot loop. A node that would add an entry past a cap marks
  /// the list as cut.
  public static func flatten<Node>(
    root: Node, children: (Node) -> [Node], identity: (Node) -> AnyHashable,
    entry: (Node, Int) -> ContentsEntry?
  ) -> Contents {
    var result = Contents()
    var seen: Set<AnyHashable> = [identity(root)]

    func visit(_ node: Node, depth: Int) -> Bool {
      for child in children(node) {
        guard seen.insert(identity(child)).inserted else {
          result.cut = result.cut ?? .repeated
          continue
        }

        if let made = entry(child, depth) {
          if result.entries.count >= maxEntries {
            result.cut = result.cut ?? .entryCap
            return false
          }

          result.entries.append(made)
        }

        if depth + 1 >= maxDepth {
          if !children(child).isEmpty { result.cut = result.cut ?? .depthCap }
        } else if !visit(child, depth: depth + 1) {
          return false
        }
      }

      return true
    }

    _ = visit(root, depth: 0)

    return result
  }
}
