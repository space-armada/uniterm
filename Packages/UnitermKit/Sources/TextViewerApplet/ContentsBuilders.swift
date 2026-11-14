import AppKit
import PDFKit
import TextViewerModel

/// Builds a contents list from the structure a format carries. Nothing is inferred from fonts or
/// text.
enum ContentsBuilders {
  /// The PDF outline, if the document has one. The walk stops at the entry cap and the depth cap,
  /// and at an outline it has met, so a cyclic or enormous outline ends. The visited set holds the
  /// outline objects themselves, so an address is never reused while the walk runs.
  static func pdf(_ document: PDFDocument) -> Contents {
    guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return .empty }

    return Contents.flatten(
      root: root,
      children: { node in
        let count = min(node.numberOfChildren, Contents.maxEntries + 1)

        return (0..<count).compactMap { node.child(at: $0) }
      },
      identity: { AnyHashable($0) },
      entry: { node, depth in
        guard let destination = node.destination, let page = destination.page else { return nil }

        let title = Contents.title(node.label ?? "")

        guard !title.isEmpty else { return nil }

        let index = document.index(for: page)

        guard index != NSNotFound else { return nil }

        return ContentsEntry(
          level: depth + 1, title: title,
          target: .pdf(page: index, x: Double(destination.point.x), y: Double(destination.point.y)))
      })
  }

  /// The paragraphs of `text` whose paragraph style carries a heading level. The system readers set
  /// the level only where the file names one, so a document without it has no contents.
  static func text(_ text: NSAttributedString) -> Contents {
    var contents = Contents()
    let whole = NSRange(location: 0, length: text.length)
    let string = text.string as NSString

    text.enumerateAttribute(.paragraphStyle, in: whole, options: []) { value, range, stop in
      guard let style = value as? NSParagraphStyle, style.headerLevel > 0 else { return }

      string.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) {
        _, paragraph, _, innerStop in
        let title = Contents.title(string.substring(with: paragraph))

        guard !title.isEmpty else { return }

        if contents.entries.count >= Contents.maxEntries {
          contents.cut = .entryCap
          innerStop.pointee = true
          stop.pointee = true
          return
        }

        contents.entries.append(
          ContentsEntry(
            level: min(max(style.headerLevel, 1), 6), title: title,
            target: .text(characterIndex: paragraph.location)))
      }
    }

    return contents
  }

  static func markdown(_ headings: [MarkdownHeading], cut: Bool) -> Contents {
    Contents(
      entries: headings.enumerated().map { index, heading in
        ContentsEntry(
          level: heading.level, title: Contents.title(heading.text),
          target: .markdown(heading: index))
      }, cut: cut ? .entryCap : nil)
  }
}
