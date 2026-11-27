import XCTest

@testable import StatusKit

/// Each expected value below is worked out by hand from the stated rules: 1.5 s dwell, 5 s idle
/// timeout, a backlog limit of 3, and a history of 100 errors and 400 other records. None comes
/// from running the queue.
final class StatusQueueTests: XCTestCase {
  private let source = StatusSource.uniterm

  private func post(
    _ queue: inout StatusQueue, _ level: StatusLevel, _ text: String, at time: TimeInterval
  ) {
    queue.post(level: level, source: source, text: text, at: time)
  }

  /// Catches a history-only record that takes a turn on the bar, raises the unseen signal, or
  /// goes missing from the history. It lands in the history and in nothing else, whatever its
  /// level, and a message on the bar stays where it was.
  func testARecordEntersTheHistoryWithoutATurnOrASignal() {
    var queue = StatusQueue()
    post(&queue, .info, "shown", at: 0)

    queue.record(level: .error, source: source, text: "kept", at: 0.1)
    queue.record(level: .warning, source: .pane(id: 3, name: "csv"), text: "also kept", at: 0.2)

    XCTAssertEqual(queue.history.map(\.text), ["shown", "kept", "also kept"])
    XCTAssertEqual(queue.history.map(\.level), [.info, .error, .warning])
    XCTAssertEqual(queue.history[2].source.paneID, 3)
    XCTAssertEqual(queue.current?.message.text, "shown")
    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertFalse(queue.hasUnseenError)
    XCTAssertEqual(queue.history.map(\.id), [1, 2, 3])
  }

  /// Catches a record that skips the history bound. Records and posts share the pool.
  func testRecordsCountAgainstTheHistoryCap() {
    var policy = StatusPolicy()
    policy.otherHistoryLimit = 3

    var queue = StatusQueue(policy: policy)

    for index in 0..<5 {
      queue.record(level: .info, source: source, text: "r\(index)", at: 0)
    }

    XCTAssertEqual(queue.history.map(\.text), ["r2", "r3", "r4"])
  }

  /// Catches a first message that waits behind a dwell nobody started.
  func testFirstMessageShowsAtOnce() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 10)

    XCTAssertEqual(queue.current?.message.text, "a")
    XCTAssertEqual(queue.pendingCount, 0)
  }

  /// Catches a message that replaces another before its minimum dwell is over.
  func testSecondMessageWaitsForTheDwell() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)
    post(&queue, .info, "b", at: 1.0)

    XCTAssertEqual(queue.current?.message.text, "a")
    XCTAssertEqual(queue.nextWake(), 1.5)

    XCTAssertFalse(queue.advance(at: 1.4))
    XCTAssertEqual(queue.current?.message.text, "a")

    XCTAssertTrue(queue.advance(at: 1.5))
    XCTAssertEqual(queue.current?.message.text, "b")
  }

  /// Catches a message that arrives after the dwell and still waits for a tick.
  func testMessageAfterTheDwellReplacesAtOnce() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)
    post(&queue, .info, "b", at: 2.0)

    XCTAssertEqual(queue.current?.message.text, "b")
  }

  /// A backlog of five infos at t=0 holds a, then [b c d e]. After the dwell the backlog (4) is
  /// above the limit of 3, so the bar skips to the newest, e. The skipped ones stay in history.
  func testBacklogSkipsToTheNewestAndKeepsHistory() {
    var queue = StatusQueue()
    for text in ["a", "b", "c", "d", "e"] {
      post(&queue, .info, text, at: 0)
    }

    XCTAssertEqual(queue.current?.message.text, "a")
    XCTAssertEqual(queue.pendingCount, 4)

    queue.advance(at: 1.5)

    XCTAssertEqual(queue.current?.message.text, "e")
    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertEqual(queue.history.map(\.text), ["a", "b", "c", "d", "e"])
  }

  /// A backlog at the limit is not skipped: a, then [b c d] shows b next.
  func testBacklogAtTheLimitIsNotSkipped() {
    var queue = StatusQueue()
    for text in ["a", "b", "c", "d"] {
      post(&queue, .info, text, at: 0)
    }

    queue.advance(at: 1.5)

    XCTAssertEqual(queue.current?.message.text, "b")
    XCTAssertEqual(queue.pendingCount, 2)
  }

  /// Catches a skip that drops an error. Pending after a is [b, E, c, d]. Skipping keeps E and the
  /// newest, d, so E shows first and d after it.
  func testSkippingNeverDropsAnError() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)
    post(&queue, .info, "b", at: 0)
    post(&queue, .error, "E", at: 0)
    post(&queue, .info, "c", at: 0)
    post(&queue, .info, "d", at: 0)

    queue.advance(at: 1.5)
    XCTAssertEqual(queue.current?.message.text, "E")

    queue.advance(at: 3.0)
    XCTAssertEqual(queue.current?.message.text, "d")
  }

  /// Three queued errors fold into the newest with a count of two.
  func testErrorBacklogCollapsesToNewestPlusCount() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)
    post(&queue, .error, "E1", at: 0)
    post(&queue, .error, "E2", at: 0)
    post(&queue, .error, "E3", at: 0)

    queue.advance(at: 1.5)

    XCTAssertEqual(queue.current?.message.text, "E3")
    XCTAssertEqual(queue.current?.collapsedErrors, 2)
    XCTAssertEqual(queue.pendingCount, 0)
  }

  /// Errors with infos between them fold too. E1 and E2 count against E3, and the infos are
  /// skipped because the backlog of six is above the limit. The bar shows E3 with a count of 2.
  func testErrorsFoldAcrossInfos() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)
    post(&queue, .error, "E1", at: 0)
    post(&queue, .error, "E2", at: 0)
    post(&queue, .info, "b", at: 0)
    post(&queue, .info, "c", at: 0)
    post(&queue, .info, "d", at: 0)
    post(&queue, .error, "E3", at: 0)

    queue.advance(at: 1.5)

    XCTAssertEqual(queue.current?.message.text, "E3")
    XCTAssertEqual(queue.current?.collapsedErrors, 2)
  }

  /// An error stays past the idle timeout. It leaves only when replaced or dismissed.
  func testErrorStaysUntilReplacedOrDismissed() {
    var queue = StatusQueue()
    post(&queue, .error, "E", at: 0)

    XCTAssertFalse(queue.advance(at: 60))
    XCTAssertEqual(queue.current?.message.text, "E")
    XCTAssertNil(queue.nextWake())

    XCTAssertTrue(queue.dismissCurrent(at: 61))
    XCTAssertNil(queue.current)
  }

  /// A newer message replaces an error once the dwell is over.
  func testNewerMessageReplacesAnError() {
    var queue = StatusQueue()
    post(&queue, .error, "E", at: 0)
    post(&queue, .info, "i", at: 3)

    XCTAssertEqual(queue.current?.message.text, "i")
  }

  /// Info clears to idle 5 s after it is shown, and not before.
  func testInfoClearsAfterTheIdleTimeout() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 100)

    XCTAssertEqual(queue.nextWake(), 105)
    XCTAssertFalse(queue.advance(at: 104.9))
    XCTAssertEqual(queue.current?.message.text, "a")

    XCTAssertTrue(queue.advance(at: 105))
    XCTAssertNil(queue.current)
  }

  /// The idle timeout waits for the queue to drain. With b pending, a is replaced at 1.5, and b
  /// then clears 5 s after it was shown, at 6.5.
  func testIdleTimeoutStartsWhenTheQueueDrains() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)
    post(&queue, .info, "b", at: 0)

    queue.advance(at: 1.5)
    XCTAssertEqual(queue.current?.message.text, "b")
    XCTAssertEqual(queue.nextWake(), 6.5)

    XCTAssertTrue(queue.advance(at: 6.5))
    XCTAssertNil(queue.current)
  }

  /// Dismissing is for errors. An info message is left to its timeout.
  func testDismissLeavesInfoAlone() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)

    XCTAssertFalse(queue.dismissCurrent(at: 1))
    XCTAssertEqual(queue.current?.message.text, "a")
  }

  /// Dismissing an error shows the next queued message at once.
  func testDismissShowsTheNextMessage() {
    var queue = StatusQueue()
    post(&queue, .error, "E", at: 0)
    post(&queue, .info, "i", at: 0.5)

    XCTAssertTrue(queue.dismissCurrent(at: 0.6))
    XCTAssertEqual(queue.current?.message.text, "i")
  }

  /// The unseen flag rises with an error and falls only when the error's record is acknowledged.
  func testUnseenErrorFlag() {
    var queue = StatusQueue()
    XCTAssertFalse(queue.hasUnseenError)

    post(&queue, .warning, "w", at: 0)
    XCTAssertFalse(queue.hasUnseenError)

    post(&queue, .error, "E", at: 2)
    XCTAssertTrue(queue.hasUnseenError)

    queue.dismissCurrent(at: 3)
    XCTAssertTrue(queue.hasUnseenError)

    queue.acknowledge(ids: queue.history.map(\.id))
    XCTAssertFalse(queue.hasUnseenError)
  }

  /// 503 info posts from one source leave the newest 400, in order, with the 103 oldest dropped.
  func testHistoryKeepsTheNewest400Others() {
    var queue = StatusQueue()
    for index in 0..<503 {
      post(&queue, .info, "m\(index)", at: Double(index) * 10)
    }

    XCTAssertEqual(queue.history.count, 400)
    XCTAssertEqual(queue.history.first?.text, "m103")
    XCTAssertEqual(queue.history.last?.text, "m502")
  }

  /// Catches a burst of infos that pushes an error off the bar before its dwell is over.
  ///
  /// The error is shown at 0 and five infos arrive at 0.5. At 1.5 the backlog of 5 is above the
  /// limit of 3, so the bar skips to the newest info.
  func testAnErrorStaysOnTheBarForItsDwellDespiteABurst() {
    var queue = StatusQueue()
    post(&queue, .error, "E", at: 0)
    for text in ["a", "b", "c", "d", "e"] {
      post(&queue, .info, text, at: 0.5)
    }

    XCTAssertFalse(queue.advance(at: 1.49))
    XCTAssertEqual(queue.current?.message.text, "E")
    XCTAssertEqual(queue.pendingCount, 5)

    XCTAssertTrue(queue.advance(at: 1.5))
    XCTAssertEqual(queue.current?.message.text, "e")
    XCTAssertEqual(queue.history.map(\.text), ["E", "a", "b", "c", "d", "e"])
  }

  /// Catches a closed pane's messages that still reach the bar, or that leave the history.
  ///
  /// Pane 7 posts b and d, and pane 8 posts c. Closing pane 7 leaves only c queued.
  func testClosingAPaneDropsItsQueuedMessagesButKeepsHistory() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)
    queue.post(level: .info, source: .pane(id: 7, name: "zsh"), text: "b", at: 0.1)
    queue.post(level: .info, source: .pane(id: 8, name: "vim"), text: "c", at: 0.2)
    queue.post(level: .info, source: .pane(id: 7, name: "zsh"), text: "d", at: 0.3)
    XCTAssertEqual(queue.pendingCount, 3)

    XCTAssertTrue(queue.removePending(fromPane: 7))
    XCTAssertEqual(queue.pendingCount, 1)

    queue.advance(at: 1.5)

    XCTAssertEqual(queue.current?.message.text, "c")
    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertEqual(queue.history.map(\.text), ["a", "b", "c", "d"])
  }

  /// Catches a pane close that wipes the message the user is reading.
  ///
  /// Only queued messages leave. The one on the bar stays, and a pane with nothing queued reports
  /// no change.
  func testClosingAPaneKeepsItsMessageThatIsOnTheBar() {
    var queue = StatusQueue()
    queue.post(level: .error, source: .pane(id: 7, name: "zsh"), text: "boom", at: 0)

    XCTAssertFalse(queue.removePending(fromPane: 7))
    XCTAssertEqual(queue.current?.message.text, "boom")
    XCTAssertEqual(queue.history.count, 1)
  }

  /// Catches a pane close that loses another pane's errors that were folded into its error.
  ///
  /// E1 from pane 8 is on the bar. An info, E2 from pane 8, and E3 from pane 7 queue. The dwell
  /// ends, i1 shows, and E2 folds into E3. Closing pane 7 removes E3, and E2 must still be shown,
  /// with no count.
  func testClosingAPaneKeepsOtherPanesErrorsFoldedIntoItsError() {
    var queue = StatusQueue()
    queue.post(level: .error, source: .pane(id: 8, name: "vim"), text: "E1", at: 0)
    post(&queue, .info, "i1", at: 0)
    queue.post(level: .error, source: .pane(id: 8, name: "vim"), text: "E2", at: 0)
    queue.post(level: .error, source: .pane(id: 7, name: "zsh"), text: "E3", at: 0)

    queue.advance(at: 1.5)
    XCTAssertEqual(queue.current?.message.text, "i1")
    XCTAssertEqual(queue.pendingCount, 1)

    XCTAssertTrue(queue.removePending(fromPane: 7))
    XCTAssertEqual(queue.pendingCount, 1)

    queue.advance(at: 3.0)
    XCTAssertEqual(queue.current?.message.text, "E2")
    XCTAssertEqual(queue.current?.collapsedErrors, 0)
    XCTAssertEqual(queue.history.map(\.text), ["E1", "i1", "E2", "E3"])
  }

  /// Catches a pane close that keeps a count for errors that left with it. Both folded errors
  /// are from the closing pane, so nothing survives.
  func testClosingAPaneDropsItsOwnFoldedErrorsToo() {
    var queue = StatusQueue()
    queue.post(level: .error, source: .pane(id: 8, name: "vim"), text: "E1", at: 0)
    post(&queue, .info, "i1", at: 0)
    queue.post(level: .error, source: .pane(id: 7, name: "zsh"), text: "E2", at: 0)
    queue.post(level: .error, source: .pane(id: 7, name: "zsh"), text: "E3", at: 0)
    queue.advance(at: 1.5)
    XCTAssertEqual(queue.pendingCount, 1)

    XCTAssertTrue(queue.removePending(fromPane: 7))

    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertEqual(queue.current?.message.text, "i1")
  }

  /// Catches a close that matches the wrong source kinds, such as pane 0, the fallback id.
  func testClosingAPaneLeavesOtherSourcesQueued() {
    var queue = StatusQueue()
    post(&queue, .info, "a", at: 0)
    queue.post(level: .info, source: .applet(id: 1, name: "x"), text: "b", at: 0)
    queue.post(level: .info, source: .script(id: 2, name: "y"), text: "c", at: 0)
    post(&queue, .info, "d", at: 0)

    XCTAssertFalse(queue.removePending(fromPane: 0))
    XCTAssertEqual(queue.pendingCount, 3)
  }

  /// The source travels with the message into the history.
  func testSourceIsRecorded() {
    var queue = StatusQueue()
    queue.post(level: .info, source: .pane(id: 7, name: "zsh"), text: "done", at: 0)

    XCTAssertEqual(queue.history.first?.source, .pane(id: 7, name: "zsh"))
    XCTAssertEqual(queue.history.first?.source.label, "zsh")
  }

  // MARK: A signal without a turn

  /// Catches a restore-time record that cannot raise the lesser signal on its own turn.
  func testARecordCanRaiseTheSignalWithoutATurn() {
    var queue = StatusQueue()

    queue.record(level: .warning, source: source, text: "restored", raisesSignal: true, at: 0)
    queue.record(level: .info, source: source, text: "quiet", raisesSignal: true, at: 0.1)

    XCTAssertNil(queue.current)
    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertEqual(queue.unseenWarningCount, 1)
    XCTAssertFalse(queue.hasUnseenError)
  }
}
