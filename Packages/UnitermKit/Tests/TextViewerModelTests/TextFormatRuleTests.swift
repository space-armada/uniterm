import XCTest

@testable import TextViewerModel

final class TextFormatRuleTests: XCTestCase {
  /// Catches a name that picks the wrong reader. The rule reads names only, so an `.rtf` file is
  /// never read as anything else.
  func testNamesPickTheirFormat() {
    let cases: [(String, TextFormat)] = [
      ("paper.pdf", .pdf), ("PAPER.PDF", .pdf), ("note.rtf", .rtf), ("Note.RTF", .rtf),
      ("memo.doc", .word97), ("memo.docx", .wordXML), ("MEMO.DOCX", .wordXML),
      ("README", .markdown), ("readme", .markdown), ("notes.md", .markdown),
      ("notes.markdown", .markdown), ("notes.MKD", .markdown),
    ]

    for (name, expected) in cases {
      XCTAssertEqual(TextFormatRule.format(forFileNamed: name), expected, name)
    }
  }

  /// Catches a file that is read as HTML. No name reaches an HTML reader.
  func testNoNamePicksAnHTMLReader() {
    for name in ["page.html", "page.htm", "a.rtf.html", "doc.webarchive"] {
      XCTAssertNil(TextFormatRule.format(forFileNamed: name).documentKind, name)
    }

    XCTAssertNil(TextFormat.markdown.documentKind)
    XCTAssertNil(TextFormat.pdf.documentKind)
  }

  func testOnlyAWordOrRTFFormatHasAHelperReader() {
    XCTAssertNotNil(TextFormat.rtf.documentKind)
    XCTAssertNotNil(TextFormat.word97.documentKind)
    XCTAssertNotNil(TextFormat.wordXML.documentKind)
  }

  /// Catches an unsupported message that names nothing.
  func testAnUnsupportedTypeNamesItself() {
    guard case .unsupported(let description) = TextFormatRule.format(forFileNamed: "x.png") else {
      return XCTFail("a PNG is unsupported")
    }

    XCTAssertFalse(description.isEmpty)

    guard case .unsupported(let plain) = TextFormatRule.format(forFileNamed: "Makefile") else {
      return XCTFail("a name with no extension is unsupported")
    }

    XCTAssertTrue(plain.contains("no extension"))
  }
}
