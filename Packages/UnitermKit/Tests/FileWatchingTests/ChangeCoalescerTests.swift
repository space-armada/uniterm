import XCTest

@testable import FileWatching

@MainActor
final class ChangeCoalescerTests: XCTestCase {
  private func rig(settle: Double = 0.2, ceiling: Double = 1) -> (
    ManualScheduler, ChangeCoalescer, Counter
  ) {
    let scheduler = ManualScheduler()
    let counter = Counter()
    let coalescer = ChangeCoalescer(settle: settle, ceiling: ceiling, scheduler: scheduler) {
      counter.count += 1
    }

    return (scheduler, coalescer, counter)
  }

  final class Counter { var count = 0 }

  /// Catches a burst that delivers more than once, or a last write that is never delivered.
  func testABurstDeliversOnceAfterItGoesQuiet() {
    let (scheduler, coalescer, counter) = rig()

    for _ in 0..<5 {
      coalescer.note()
      scheduler.advance(by: 0.05)
    }

    XCTAssertEqual(counter.count, 0)

    scheduler.advance(by: 0.2)

    XCTAssertEqual(counter.count, 1)
    XCTAssertFalse(coalescer.hasPending)
  }

  /// Catches a file rewritten without pause that reloads on every write, or never. The ceiling
  /// bounds the rate at one delivery per second here, and the last note still lands after.
  func testAContinuousBurstDeliversAtTheCeilingAndTheLastNoteStillLands() {
    let (scheduler, coalescer, counter) = rig()

    for _ in 0..<100 {
      coalescer.note()
      scheduler.advance(by: 0.05)
    }

    XCTAssertEqual(counter.count, 4)

    scheduler.advance(by: 0.5)

    XCTAssertEqual(counter.count, 5)
  }

  /// Catches a ceiling below the quiet time, which would deliver before the quiet it waits for.
  func testACeilingBelowTheSettleTimeIsRaised() {
    let (scheduler, coalescer, counter) = rig(settle: 0.5, ceiling: 0.1)

    coalescer.note()
    scheduler.advance(by: 0.4)
    XCTAssertEqual(counter.count, 0)

    scheduler.advance(by: 0.2)
    XCTAssertEqual(counter.count, 1)
  }

  func testNoSettleTimeDeliversEveryNoteAtOnce() {
    let (_, coalescer, counter) = rig(settle: 0, ceiling: 0)

    coalescer.note()
    coalescer.note()

    XCTAssertEqual(counter.count, 2)
  }

  /// Catches a delivery that fires after the watch is stopped.
  func testCancelDropsAPendingDelivery() {
    let (scheduler, coalescer, counter) = rig()

    coalescer.note()
    coalescer.cancel()
    scheduler.advance(by: 5)

    XCTAssertEqual(counter.count, 0)
  }
}
