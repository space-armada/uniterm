import AppletKit
import XCTest

@testable import TextViewerModel

final class TextViewerDescriptionTests: XCTestCase {
  /// Catches a description field that does not survive a save and a restore.
  func testADescriptionRoundTrips() throws {
    let original = TextViewerDescription(
      startDirectory: "/tmp", path: "/tmp/a.pdf", bookmark: Data([1, 2, 3]),
      anchor: .pdf(page: 4, x: 10.5, y: 700), sidebarShown: true)

    let back = try TextViewerDescription.decode(original.appletDescription())

    XCTAssertEqual(back, original)
  }

  func testAnEmptyDescriptionRoundTripsWithTheSidebarHidden() throws {
    let original = TextViewerDescription(startDirectory: "/tmp")
    let back = try TextViewerDescription.decode(original.appletDescription())

    XCTAssertEqual(back, original)
    XCTAssertFalse(back.sidebarShown)
  }

  /// Catches a description that the sidebar flag would break for a build that never wrote one.
  func testAPayloadWithoutTheSidebarFlagStillReads() throws {
    let description = AppletDescription(
      type: TextViewerDescription.typeID, version: 1,
      payload: .object(["path": .string("/tmp/a.rtf")]))

    let back = try TextViewerDescription.decode(description)

    XCTAssertEqual(back.path, "/tmp/a.rtf")
    XCTAssertFalse(back.sidebarShown)
  }

  func testAnAnchorForRTFCarriesACharacterIndex() throws {
    let original = TextViewerDescription(path: "/a.rtf", anchor: .text(characterIndex: 1234))

    XCTAssertEqual(
      try TextViewerDescription.decode(original.appletDescription()).anchor?.characterIndex, 1234)
  }

  /// Catches a description this build reads that it should refuse, so a bad one is kept byte for
  /// byte by the caller.
  func testWrongTypeNewerVersionAndBadShapesAreRefused() {
    let good = TextViewerDescription(path: "/a.pdf")

    XCTAssertThrowsError(
      try TextViewerDescription.decode(
        AppletDescription(type: "other", version: 1, payload: .object([:]))))
    XCTAssertThrowsError(
      try TextViewerDescription.decode(
        AppletDescription(
          type: TextViewerDescription.typeID, version: 2,
          payload: try! good.appletDescription().payload)))
    XCTAssertThrowsError(
      try TextViewerDescription.decode(
        TextViewerDescription(path: "relative.pdf").appletDescription()))
    XCTAssertThrowsError(
      try TextViewerDescription.decode(
        TextViewerDescription(startDirectory: "relative").appletDescription()))
    XCTAssertThrowsError(
      try TextViewerDescription.decode(
        TextViewerDescription(path: "/a.pdf", anchor: .pdf(page: -1, x: 0, y: 0))
          .appletDescription()))
    XCTAssertThrowsError(
      try TextViewerDescription.decode(
        TextViewerDescription(path: "/a.pdf", anchor: .text(characterIndex: -4))
          .appletDescription()))
    XCTAssertThrowsError(
      try TextViewerDescription.decode(
        AppletDescription(
          type: TextViewerDescription.typeID, version: 1, payload: .string("nope"))))
  }
}
