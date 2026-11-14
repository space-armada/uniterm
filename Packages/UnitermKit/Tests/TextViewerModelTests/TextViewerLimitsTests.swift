import XCTest

@testable import TextViewerModel

final class TextViewerLimitsTests: XCTestCase {
  func testEachCapNamesItsLimit() {
    let limits = TextViewerLimits.standard

    XCTAssertNil(limits.violation(length: 10, tableCells: 10, attachments: 1))
    XCTAssertEqual(
      limits.violation(length: limits.maxDecodedLength + 1, tableCells: 0, attachments: 0),
      .length(limit: limits.maxDecodedLength))
    XCTAssertEqual(
      limits.violation(length: 0, tableCells: limits.maxTableCells + 1, attachments: 0),
      .tableCells(limit: limits.maxTableCells))
    XCTAssertEqual(
      limits.violation(length: 0, tableCells: 0, attachments: limits.maxImages + 1),
      .images(limit: limits.maxImages))
  }

  /// Catches a cap at its edge that is off by one.
  func testTheCapsHoldAtTheirLimits() {
    let limits = TextViewerLimits.standard

    XCTAssertNil(
      limits.violation(
        length: limits.maxDecodedLength, tableCells: limits.maxTableCells,
        attachments: limits.maxImages))
  }

  func testTheMessagesNameTheLimitAndTheFile() {
    let limits = TextViewerLimits.standard
    let text = TextViewerLimits.CapViolation.length(limit: 4_000_000).message(fileName: "a.rtf")

    XCTAssertTrue(text.contains("a.rtf"))
    XCTAssertTrue(text.contains("4,000,000") || text.contains("4.000.000"))
    XCTAssertTrue(
      limits.tooLargeMessage(fileName: "big.pdf", bytes: 300 << 20, format: .pdf).contains(
        "big.pdf"))
  }

  func testAPDFReadsMoreThanAWordFile() {
    let limits = TextViewerLimits.standard

    XCTAssertGreaterThan(limits.fileLimit(for: .pdf), limits.fileLimit(for: .rtf))
  }
}
