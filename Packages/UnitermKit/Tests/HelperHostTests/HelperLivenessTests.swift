import XCTest

@testable import HelperHost

final class HelperLivenessTests: XCTestCase {
  private let start = ContinuousClock.now

  private func liveness() -> HelperLiveness {
    HelperLiveness(timeBound: .seconds(10), pongGrace: .seconds(3), footprintCap: 1000)
  }

  /// Catches a probe of an idle helper that ends it or pings it.
  func testAnIdleHelperIsHealthy() {
    var liveness = liveness()

    XCTAssertEqual(liveness.probe(footprint: 5000, now: start), .healthy)
  }

  /// Catches a footprint over the cap that goes unnoticed.
  func testAFootprintPastTheCapEndsTheHelper() {
    var liveness = liveness()
    liveness.markBusy(now: start)

    XCTAssertEqual(liveness.probe(footprint: 1001, now: start), .end(.overFootprint))
  }

  /// Catches a helper that never answers a ping and is called slow instead of hung.
  func testAHelperThatStopsAnsweringIsUnresponsive() {
    var liveness = liveness()
    liveness.markBusy(now: start)

    XCTAssertEqual(liveness.probe(footprint: 1, now: start), .sendPing(1))
    XCTAssertEqual(liveness.probe(footprint: 1, now: start + .seconds(1)), .healthy)
    XCTAssertEqual(liveness.probe(footprint: 1, now: start + .seconds(4)), .end(.unresponsive))
  }

  /// Catches a helper that answers pings past the time bound and is called hung. That is a limit,
  /// and a retry would repeat it.
  func testAHelperThatAnswersPastTheTimeBoundOverranIt() {
    var liveness = liveness()
    liveness.markBusy(now: start)

    XCTAssertEqual(liveness.probe(footprint: 1, now: start), .sendPing(1))
    liveness.pong(1, now: start + .seconds(9))

    XCTAssertEqual(liveness.probe(footprint: 1, now: start + .seconds(11)), .end(.overranTimeBound))
    XCTAssertFalse(HelperEnd.overranTimeBound.offersRetry)
  }

  func testAPongForAnotherNonceIsIgnored() {
    var liveness = liveness()
    liveness.markBusy(now: start)

    XCTAssertEqual(liveness.probe(footprint: 1, now: start), .sendPing(1))
    liveness.pong(9, now: start + .seconds(1))

    XCTAssertEqual(liveness.probe(footprint: 1, now: start + .seconds(4)), .end(.unresponsive))
  }

  /// Catches a helper with no time bound being ended for working long while it answers. A REPL has
  /// none, since an evaluation may run as long as the user likes. It is ended only when it stops
  /// answering.
  func testAHelperWithNoTimeBoundIsNeverEndedForAnsweringLate() {
    var liveness = HelperLiveness(
      timeBound: nil, pongGrace: .seconds(3), footprintCap: Int.max)
    var now = start

    liveness.markBusy(now: now)

    for second in 1...120 {
      now = start + .seconds(second)

      guard case .sendPing(let nonce) = liveness.probe(footprint: nil, now: now) else {
        return XCTFail("no ping at second \(second)")
      }

      liveness.pong(nonce, now: now + .milliseconds(10))
    }

    XCTAssertEqual(liveness.probe(footprint: nil, now: now + .seconds(1)).isEnd, false)
    XCTAssertEqual(liveness.probe(footprint: nil, now: now + .seconds(10)), .end(.unresponsive))
  }
}

extension HelperLiveness.Verdict {
  fileprivate var isEnd: Bool {
    if case .end = self { return true }

    return false
  }
}
