import XCTest

@testable import TableData

/// The one budget that every data viewer pane shares.
final class TableBudgetTests: XCTestCase {
  /// Catches a budget counted per pane. Two leases draw on one limit, and a lease that is over
  /// the limit is refused beyond its floor.
  func testLeasesShareOneLimit() {
    let budget = TableBudget(limit: 1_000, floor: 100)
    let first = budget.makeLease()
    let second = budget.makeLease()

    XCTAssertEqual(first.reserve(900), .granted)
    XCTAssertEqual(second.reserve(100), .granted)
    XCTAssertEqual(second.reserve(1), .overBudget)
    XCTAssertEqual(budget.used, 1_000)
  }

  /// Catches a close that does not give memory back, and a released lease that still grants. A
  /// loader that is slow to notice its cancellation must not take bytes back after the release.
  /// Releasing and dropping the lease both free every reserved byte at once.
  func testReleasingALeaseGivesTheBytesBackAndRefusesMore() {
    let budget = TableBudget(limit: 1_000, floor: 0)
    let lease = budget.makeLease()

    XCTAssertEqual(lease.reserve(600), .granted)
    lease.release()
    XCTAssertEqual(budget.used, 0)

    XCTAssertNotEqual(lease.reserve(600), .granted)
    XCTAssertEqual(budget.used, 0)
  }

  /// Catches a dropped lease that keeps its bytes.
  func testDroppingALeaseGivesTheBytesBack() {
    let budget = TableBudget(limit: 1_000, floor: 0)
    var lease: TableBudget.Lease? = budget.makeLease()

    XCTAssertEqual(lease?.reserve(600), .granted)
    lease = nil
    XCTAssertEqual(budget.used, 0)
  }

  /// Catches a floor that does not hold when the budget is spent: the lease gets its floor and
  /// nothing past it.
  func testTheFloorHoldsWhenTheBudgetIsSpent() {
    let budget = TableBudget(limit: 100, floor: 50)
    let hog = budget.makeLease()
    XCTAssertEqual(hog.reserve(100), .granted)

    let late = budget.makeLease()
    XCTAssertEqual(late.reserve(50), .granted)
    XCTAssertEqual(late.reserve(1), .overBudget)
  }

  /// Catches a warning that spares the loads that exist, or one that blocks later leases. Work on
  /// loaded rows is not a load, so a warning leaves it alone.
  func testAMemoryWarningEndsExistingLoadsOnly() {
    let budget = TableBudget(limit: 1_000, floor: 0)
    let before = budget.makeLease()

    budget.memoryPressureWarning()

    XCTAssertEqual(before.reserve(1), .memoryPressure)
    XCTAssertEqual(before.reserveForWork(1), .granted)
    XCTAssertEqual(budget.makeLease().reserve(1), .granted)
  }
}
