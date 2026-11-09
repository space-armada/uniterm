import AppletKit
import ScriptWire
import XCTest

@testable import WindowKit

/// The IDs that scripts name windows by. The source has no clock input, so these tests prove the
/// property a moving clock would threaten from the other side: the ID depends only on the epoch the
/// launch drew and a counter that only grows. Two launches that draw different epochs never share
/// an ID, whatever order the wall clock put them in.
@MainActor
final class WindowIDSourceTests: XCTestCase {
  /// Catches an ID that a Janet number cannot hold exactly. The largest epoch with the largest
  /// counter is the largest ID the source can make.
  func testEveryIDFitsAJanetNumberExactly() {
    let epochs = UInt64(1 << WindowIDSource.epochBits) - 1
    var source = WindowIDSource(draw: { epochs })

    let ids = (0..<70_000).map { _ in source.next() }

    XCTAssertTrue(ids.allSatisfy { $0 <= ScriptProtocol.maxID })
    XCTAssertTrue(ids.allSatisfy { UInt64(Double($0)) == $0 })
  }

  /// Catches a counter that wraps and repeats an ID inside one launch, including after the counter
  /// runs out and the source draws again. A draw that returns an epoch the launch already used must
  /// not bring its IDs back.
  func testNoIDRepeatsInOneLaunchEvenWhenTheDrawRepeatsAnEpoch() {
    var draws = [5, 5, 6, 5, 6, 7].map(UInt64.init).makeIterator()
    var source = WindowIDSource(draw: { draws.next() ?? 100 })

    let count = 3 * (1 << WindowIDSource.counterBits)
    var seen = Set<UInt64>()

    for _ in 0..<count {
      XCTAssertTrue(seen.insert(source.next()).inserted)
    }

    XCTAssertEqual(seen.count, count)
  }

  /// Catches a launch whose first epoch is zero, which would make an ID a bare counter that a
  /// script could write by hand as `1`.
  func testNoEpochIsZero() {
    var source = WindowIDSource(draw: { 0 })

    XCTAssertGreaterThan(source.next(), UInt64(1 << WindowIDSource.counterBits))
  }

  /// Catches IDs that overlap between launches. The second launch draws a different epoch, and the
  /// two share no ID, in either order. The same draw gives the same sequence, which shows that
  /// nothing but the draw feeds an ID, the clock included.
  func testTwoLaunchesThatDrawDifferentEpochsShareNoID() {
    var first = WindowIDSource(draw: { 0x1234 })
    var second = WindowIDSource(draw: { 0x4321 })

    let firstIDs = Set((0..<5_000).map { _ in first.next() })
    let secondIDs = Set((0..<5_000).map { _ in second.next() })

    XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs))

    var again = WindowIDSource(draw: { 0x1234 })

    XCTAssertEqual(Set((0..<5_000).map { _ in again.next() }), firstIDs)
  }

  /// Catches a default source that draws a fixed epoch, which would make every launch share IDs.
  func testTwoDefaultSourcesDrawDifferentEpochs() {
    var epochs = Set<UInt64>()

    for _ in 0..<8 {
      var source = WindowIDSource()
      epochs.insert(source.next() >> UInt64(WindowIDSource.counterBits))
    }

    XCTAssertGreaterThan(epochs.count, 1)
  }

  /// Catches a tab number that is reused, or that changes between two looks at the same tab. A
  /// number never issued names nothing.
  func testTabNumbersOnlyGrowAndAreNeverReused() {
    var numbers = ScriptTabNumbers()
    let tabs = (0..<5).map { _ in AppletTabID.make() }
    let issued = tabs.map { numbers.number(for: $0) }

    XCTAssertEqual(issued, [1, 2, 3, 4, 5])
    XCTAssertEqual(numbers.number(for: tabs[2]), 3)
    XCTAssertEqual(numbers.number(for: .make()), 6)
    XCTAssertEqual(numbers.tab(for: 3), tabs[2])
    XCTAssertNil(numbers.tab(for: 0))
    XCTAssertNil(numbers.tab(for: 99))
  }
}
