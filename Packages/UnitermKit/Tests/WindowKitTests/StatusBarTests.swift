import AppKit
import AppletKit
import PaneModel
import Preferences
import StatusKit
import XCTest

@testable import WindowKit

@MainActor
final class StatusBarTests: XCTestCase {
  private var fixtures: [WindowFixture] = []

  override func tearDown() async throws {
    for fixture in fixtures {
      fixture.cleanUp()
    }

    fixtures = []
  }

  private func makeFixture(
    storedPosition: String? = nil, commands: CommandRegistry = .testing()
  ) throws -> WindowFixture {
    let fixture = try WindowFixture(storedPosition: storedPosition, commands: commands)
    fixtures.append(fixture)
    return fixture
  }

  /// The applet segments of the bar, without the window's own.
  private func appletTexts(_ fixture: WindowFixture) -> [String] {
    fixture.bar.segments.compactMap { segment in
      if case .applet = segment.id { return segment.text }
      return nil
    }
  }

  private func edge(_ fixture: WindowFixture) -> DockEdge? {
    fixture.controller.contentController.edge(of: .statusBar)
  }

  /// A left mouse press on the bar, `point` being in the bar's own coordinates.
  private func click(_ fixture: WindowFixture, at point: NSPoint) throws {
    let window = try XCTUnwrap(fixture.controller.window)
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: fixture.bar.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))

    fixture.bar.mouseDown(with: event)
  }

  // MARK: Narrow bar

  /// Every segment that shows in the bar, as a frame in the bar's own coordinates.
  private func shownFrames(_ fixture: WindowFixture) -> [(id: BarSegmentID, frame: NSRect)] {
    fixture.bar.segments.compactMap { segment in
      fixture.bar.frame(of: segment.id).map { (segment.id, $0) }
    }
  }

  private func activateEverything(_ fixture: WindowFixture) {
    fixture.log.made[0].segments = [
      AppletSegment(symbolName: "folder", text: "a-long-working-directory-name"),
      AppletSegment(symbolName: "tablecells", text: "1,000,000 rows"),
    ]
    fixture.controller.appletDidChange(fixture.log.made[0])

    fixture.center.post(level: .error, source: .uniterm, text: "something went badly wrong")

    var states = WindowStates()
    states.set(.layoutNotSaved, text: "Not saved.")
    states.set(.pendingPermissions, text: "Programs are asking.", label: "32 requests")
    states.set(.suspendedControllers, text: "Controllers are suspended.", label: "2 suspended")
    states.set(.survivingWork, text: "Work is still running.")
    fixture.controller.windowStates = states
  }

  /// Catches a window state that a narrow bar squeezes out, an error message squeezed to nothing,
  /// a slot's text that widens the window, and slots that overlap. At the window's real minimum
  /// width, every active kind shows inside the bar, and the message area keeps its least width. The
  /// applet's segments left, and so did the pending slot's text, so that slot is an icon alone.
  func testEveryWindowStateStaysDiscoverableAtTheMinimumWidth() throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    let minimum = window.contentMinSize.width

    window.setContentSize(
      NSSize(width: minimum, height: window.contentRect(forFrameRect: window.frame).height))
    activateEverything(fixture)
    fixture.layout()

    XCTAssertEqual(fixture.bar.bounds.width, minimum, accuracy: 0.5)

    let shown = shownFrames(fixture)

    for kind in WindowStateKind.allCases {
      let frame = try XCTUnwrap(
        shown.first { $0.id == .window(kind) }?.frame, "\(kind) is not showing")

      XCTAssertGreaterThan(frame.width, 0)
      XCTAssertTrue(fixture.bar.bounds.contains(frame), "\(kind) leaves the bar: \(frame)")
    }

    let message = try XCTUnwrap(shown.first { $0.id == .message }?.frame)
    XCTAssertGreaterThanOrEqual(message.width, StatusBarView.minimumMessageWidth - 0.5)
    XCTAssertNotNil(shown.first { $0.id == .dismiss })
    XCTAssertNotNil(shown.first { $0.id == .unseenError })

    let ordered = shown.map(\.frame).sorted { $0.minX < $1.minX }

    for (left, right) in zip(ordered, ordered.dropFirst()) {
      XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5, "\(left) overlaps \(right)")
    }

    XCTAssertNil(shown.first { $0.id == .applet(1) }, "the last applet segment should leave first")

    let pending = try XCTUnwrap(shown.first { $0.id == .window(.pendingPermissions) }?.frame)
    let iconOnly = try XCTUnwrap(shown.first { $0.id == .window(.layoutNotSaved) }?.frame)
    XCTAssertLessThan(pending.width, iconOnly.width + 10, "the pending slot kept its text")
  }

  /// Catches a bar that drops applet segments or slot text it has room for. At a wide window,
  /// every segment shows with its text, in the fixed order, and no window slot moves.
  func testAWideBarShowsEverySegmentInOrder() throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)

    window.setContentSize(NSSize(width: 960, height: 400))
    activateEverything(fixture)
    fixture.layout()

    let shown = shownFrames(fixture)

    XCTAssertEqual(shown.map(\.id), fixture.bar.segments.map(\.id))

    let pending = try XCTUnwrap(shown.first { $0.id == .window(.pendingPermissions) }?.frame)
    let iconOnly = try XCTUnwrap(shown.first { $0.id == .window(.layoutNotSaved) }?.frame)
    XCTAssertGreaterThan(pending.width, iconOnly.width + 20, "a wide bar dropped the slot's text")

    let ordered = shown.map(\.frame)

    for (left, right) in zip(ordered, ordered.dropFirst()) {
      XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5)
    }
  }

  // MARK: Docking

  /// Catches a bar that docks on the wrong edge by default.
  func testTheBarDocksAtTheBottomByDefault() throws {
    let fixture = try makeFixture()
    let safe = fixture.chrome.safeAreaRect

    XCTAssertEqual(fixture.bar.frame.minY, safe.minY)
    XCTAssertEqual(fixture.bar.frame.height, 22)
    XCTAssertEqual(fixture.paneArea.frame.minY, fixture.bar.frame.maxY)
    XCTAssertEqual(fixture.paneArea.frame.maxY, safe.maxY)
  }

  /// Catches a stored position that is ignored at launch, or a top bar under the title bar.
  ///
  /// The safe area starts below the title bar, so a bar against its top edge is clear of the
  /// traffic lights.
  func testAStoredTopPositionDocksTheBarBelowTheTitleBar() throws {
    let fixture = try makeFixture(storedPosition: "top")
    let safe = fixture.chrome.safeAreaRect

    XCTAssertEqual(fixture.bar.frame.maxY, safe.maxY)
    XCTAssertEqual(fixture.bar.frame.height, 22)
    XCTAssertEqual(fixture.paneArea.frame.maxY, fixture.bar.frame.minY)
    XCTAssertEqual(fixture.paneArea.frame.minY, safe.minY)
    XCTAssertLessThanOrEqual(fixture.bar.frame.maxY, fixture.chrome.bounds.maxY)
  }

  /// Catches a dock change that changes what the bar shows, or that fails to move it.
  func testChangingThePositionMovesTheBarAndKeepsItsSegments() async throws {
    let fixture = try makeFixture()
    fixture.log.made[0].segments = [AppletSegment(symbolName: "folder", text: "tmp")]
    fixture.controller.appletDidChange(fixture.log.made[0])
    fixture.center.post(level: .warning, source: .uniterm, text: "careful")

    let before = fixture.bar.segments
    let minimum = fixture.controller.window?.contentMinSize
    XCTAssertEqual(before.count, 3, "the message, the unseen-warning indicator, and the applet's")

    fixture.store.set(.top, for: .statusBarPosition)
    let moved = await waitUntil { edge(fixture) == .top }
    XCTAssertTrue(moved, "the bar never moved")
    fixture.layout()

    XCTAssertEqual(fixture.bar.segments, before)
    XCTAssertEqual(fixture.bar.frame.maxY, fixture.chrome.safeAreaRect.maxY)
    XCTAssertEqual(fixture.controller.window?.contentMinSize, minimum)

    fixture.store.set(.bottom, for: .statusBarPosition)
    let back = await waitUntil { edge(fixture) == .bottom }
    XCTAssertTrue(back)
    XCTAssertEqual(fixture.bar.segments, before)
  }

  /// Catches a bar that follows only its own process's writes.
  func testAValidValueWrittenByAnotherProcessMovesTheBar() async throws {
    let fixture = try makeFixture()

    _ = try runDefaults(["write", fixture.suite, "statusBarPosition", "-string", "top"])

    let moved = await waitUntil { edge(fixture) == .top }
    XCTAssertTrue(moved, "the bar never followed the other process")
  }

  // MARK: Invalid settings

  /// Catches an unknown stored value that is accepted, rewritten, or not reported.
  func testAnInvalidStoredPositionFallsBackWarnsAndIsNotWrittenBack() throws {
    let fixture = try makeFixture(storedPosition: "sideways")

    XCTAssertEqual(edge(fixture), .bottom)

    let history = fixture.center.history
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].level, .warning)
    XCTAssertEqual(history[0].source, .uniterm)
    XCTAssertEqual(
      history[0].text,
      "The status bar position \u{201C}sideways\u{201D} is not valid. Using bottom.")
    XCTAssertEqual(fixture.defaults.string(forKey: "statusBarPosition"), "sideways")
    XCTAssertEqual(fixture.messageText, "uniterm: \(history[0].text)")
  }

  /// Catches a warning that repeats on every setting change.
  ///
  /// All watched settings wake the same observer, so a theme change with a bad position stored
  /// must not warn again.
  func testAnUnrelatedSettingChangeDoesNotRepeatTheWarning() async throws {
    let fixture = try makeFixture(storedPosition: "sideways")
    XCTAssertEqual(fixture.center.history.count, 1)

    let heard = expectation(description: "a settings observer ran after the change")
    heard.assertForOverFulfill = false
    let observation = fixture.store.addObserver { heard.fulfill() }

    fixture.store.set(.dark, for: .appearance)
    await fulfillment(of: [heard], timeout: 10)
    observation.cancel()

    XCTAssertEqual(fixture.center.history.count, 1)
    XCTAssertEqual(fixture.defaults.string(forKey: "statusBarPosition"), "sideways")
  }

  /// Catches a rule that warns only the first time, or that does not reset after a good value.
  ///
  /// A new bad value warns. A good value in between resets the rule, so the first bad value warns
  /// again.
  func testEachNewBadValueWarnsAndAGoodValueResetsTheRule() async throws {
    let fixture = try makeFixture(storedPosition: "sideways")
    XCTAssertEqual(fixture.center.history.count, 1)

    fixture.defaults.set("upside", forKey: "statusBarPosition")
    let second = await waitUntil { fixture.center.history.count == 2 }
    XCTAssertTrue(second, "a second bad value did not warn")
    XCTAssertTrue(fixture.center.history.last?.text.contains("upside") ?? false)

    fixture.defaults.set("top", forKey: "statusBarPosition")
    let moved = await waitUntil { edge(fixture) == .top }
    XCTAssertTrue(moved)
    XCTAssertEqual(fixture.center.history.count, 2)

    fixture.defaults.set("upside", forKey: "statusBarPosition")
    let third = await waitUntil { fixture.center.history.count == 3 }
    XCTAssertTrue(third, "a bad value after a good one did not warn")
    XCTAssertTrue(fixture.center.history.last?.text.contains("upside") ?? false)
    XCTAssertEqual(edge(fixture), .bottom, "an invalid value falls back to the default edge")
  }

  /// Catches an invalid value from another process that goes unreported or is overwritten.
  ///
  /// This is the window's reaction. The store's own reading of a foreign write is covered in the
  /// Preferences tests.
  func testAnInvalidValueFromAnotherProcessWarnsAndIsLeftAlone() async throws {
    let fixture = try makeFixture()
    XCTAssertTrue(fixture.center.history.isEmpty)

    _ = try runDefaults(["write", fixture.suite, "statusBarPosition", "-string", "sideways"])

    let warned = await waitUntil { fixture.center.history.count == 1 }
    XCTAssertTrue(warned, "the bad value was never reported")

    XCTAssertEqual(fixture.center.history[0].level, .warning)
    XCTAssertEqual(fixture.center.history[0].source, .uniterm)
    XCTAssertTrue(fixture.center.history[0].text.contains("sideways"))
    XCTAssertEqual(edge(fixture), .bottom)
    XCTAssertEqual(
      try runDefaults(["read", fixture.suite, "statusBarPosition"]), "sideways\n")

    _ = try runDefaults(["write", fixture.suite, "statusBarPosition", "-string", "top"])

    let moved = await waitUntil { edge(fixture) == .top }
    XCTAssertTrue(moved)
    XCTAssertEqual(fixture.center.history.count, 1)
  }

  /// Catches a warning that forges a second line, or that quotes an unbounded value.
  func testTheWarningQuotesAStoredValueSafely() {
    XCTAssertEqual(StatusBarPlacement.quoted("a\nb\tc"), "a b c")
    XCTAssertEqual(StatusBarPlacement.quoted(String(repeating: "x", count: 100)).count, 40)
  }

  // MARK: Applet segments

  /// Catches applet segments that come from the wrong pane.
  ///
  /// A change in an unfocused applet must not touch the bar. A change in the focused one must.
  func testAppletSegmentsFollowTheFocusedPane() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    controller.openPane(.terminalShell, axis: .row)
    let (one, two) = (fixture.log.made[0], fixture.log.made[1])

    one.segments = [AppletSegment(symbolName: nil, text: "one")]
    two.segments = [AppletSegment(symbolName: nil, text: "two")]
    controller.appletDidChange(two)
    XCTAssertEqual(appletTexts(fixture), ["two"])

    one.segments = [AppletSegment(symbolName: nil, text: "one!")]
    controller.appletDidChange(one)
    XCTAssertEqual(appletTexts(fixture), ["two"], "an unfocused applet changed the bar")

    controller.dispatch(.focusPaneLeft)
    XCTAssertEqual(appletTexts(fixture), ["one!"])

    two.segments = [AppletSegment(symbolName: nil, text: "two!")]
    controller.appletDidChange(two)
    XCTAssertEqual(appletTexts(fixture), ["one!"])

    controller.dispatch(.focusPaneRight)
    XCTAssertEqual(appletTexts(fixture), ["two!"])
  }

  /// Catches applet segments that vanish when the keyboard leaves the panes.
  ///
  /// A text field outside the pane area stands in for Settings. The window reports an update,
  /// which is when the pane area follows the responder.
  func testAppletSegmentsStayWhileTheKeyboardIsOutsideThePanes() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    controller.openPane(.terminalShell, axis: .row)
    let two = fixture.log.made[1]
    two.segments = [AppletSegment(symbolName: nil, text: "two")]
    controller.appletDidChange(two)

    let field = NSTextField(string: "outside")
    fixture.chrome.addSubview(field)
    let window = try XCTUnwrap(controller.window)
    XCTAssertTrue(window.makeFirstResponder(field))
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

    let responder = window.firstResponder as? NSView
    XCTAssertTrue(responder === field || responder?.isDescendant(of: field) == true)
    XCTAssertEqual(controller.focusedPane, NodeID(rawValue: 2))
    XCTAssertEqual(appletTexts(fixture), ["two"])

    two.segments = [AppletSegment(symbolName: nil, text: "two!")]
    controller.appletDidChange(two)
    XCTAssertEqual(appletTexts(fixture), ["two!"])
  }

  /// Catches a sheet that blanks the applet segments.
  func testAppletSegmentsStayWhileASheetIsUp() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    let window = try XCTUnwrap(controller.window)
    window.orderFrontRegardless()
    defer { window.close() }

    fixture.log.made[0].segments = [AppletSegment(symbolName: nil, text: "one")]
    controller.appletDidChange(fixture.log.made[0])

    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.beginSheet(sheet)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

    XCTAssertEqual(appletTexts(fixture), ["one"])
    window.endSheet(sheet)
  }

  // MARK: Pane close

  /// Catches a closed pane's queued messages that still reach the bar, or that leave the history.
  ///
  /// Pane 2's message leaves the queue when pane 2 closes. Pane 1's is shown when the dwell ends.
  func testClosingAPaneDropsItsQueuedMessagesFromTheBarButNotTheHistory() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    controller.openPane(.terminalShell, axis: .row)
    let (one, two) = (fixture.log.made[0], fixture.log.made[1])

    fixture.center.post(level: .info, source: .uniterm, text: "first")
    two.say(.info, "from two")
    one.say(.info, "from one")
    XCTAssertEqual(fixture.center.queue.pendingCount, 2)

    controller.dispatch(.close)
    XCTAssertEqual(controller.paneIDs, [NodeID(rawValue: 1)])
    XCTAssertEqual(fixture.center.queue.pendingCount, 1)

    fixture.clock.now = 1.5
    fixture.scheduler.fireLast()

    XCTAssertEqual(fixture.messageText, "Fake: from one")
    XCTAssertEqual(
      fixture.center.history.map(\.text), ["first", "from two", "from one"])
  }

  // MARK: History

  /// Catches a history that hides the level or the source, or that leaves the indicator on.
  func testOpeningTheHistoryListsLevelAndSourceAndClearsTheUnseenIndicator() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    fixture.log.made[0].say(.error, "boom")
    fixture.center.post(level: .warning, source: .uniterm, text: "careful")

    XCTAssertTrue(fixture.bar.segments.contains { $0.id == .unseenError })
    XCTAssertTrue(fixture.controller.contentController.history.isHidden)

    controller.dispatch(.toggleMessageHistory)

    XCTAssertFalse(fixture.controller.contentController.history.isHidden)
    XCTAssertEqual(
      fixture.controller.contentController.history.lines,
      ["warning  uniterm: careful", "error  Fake (pane 1): boom"])
    XCTAssertFalse(fixture.center.hasUnseenError)
    XCTAssertFalse(fixture.bar.segments.contains { $0.id == .unseenError })

    controller.dispatch(.toggleMessageHistory)
    XCTAssertTrue(fixture.controller.contentController.history.isHidden)
  }

  /// Catches an error that raises the indicator while the history is already open.
  func testAnErrorPostedWhileTheHistoryIsOpenLeavesNoUnseenIndicator() throws {
    let fixture = try makeFixture()
    fixture.controller.dispatch(.toggleMessageHistory)

    fixture.center.post(level: .error, source: .uniterm, text: "late")

    XCTAssertFalse(fixture.center.hasUnseenError)
    XCTAssertEqual(fixture.controller.contentController.history.lines, ["error  uniterm: late"])
  }

  /// Catches a history that is not capped on screen, or that drops the newest instead of the oldest.
  ///
  /// 400 infos and 100 errors fill the 500 rows. Three more infos push out the three oldest infos,
  /// so m3 leads the tail and m402 heads the list.
  func testTheHistoryShowsTheNewest500() throws {
    let fixture = try makeFixture()

    for index in 0..<400 {
      fixture.center.post(level: .info, text: "m\(index)")
    }

    for index in 0..<100 {
      fixture.center.post(level: .error, text: "e\(index)")
    }

    for index in 400..<403 {
      fixture.center.post(level: .info, text: "m\(index)")
    }

    fixture.controller.dispatch(.toggleMessageHistory)
    let lines = fixture.controller.contentController.history.lines

    XCTAssertEqual(lines.count, 500)
    XCTAssertEqual(lines.first, "info  uniterm: m402")
    XCTAssertEqual(lines.last, "info  uniterm: m3")
  }

  /// Catches a history that resizes the panes when it opens, or that sits on the wrong side.
  func testTheHistoryFloatsOverThePanesAgainstTheBar() throws {
    let fixture = try makeFixture()
    let before = fixture.paneArea.frame

    fixture.controller.dispatch(.toggleMessageHistory)
    fixture.layout()

    XCTAssertEqual(fixture.paneArea.frame, before)
    XCTAssertEqual(fixture.controller.contentController.history.frame.height, 240)
    XCTAssertEqual(
      fixture.controller.contentController.history.frame.minY, fixture.bar.frame.maxY)
  }

  /// Catches a click on the message area that does not reach the history.
  func testClickingTheBarTogglesTheHistory() throws {
    let fixture = try makeFixture()
    fixture.layout()

    try click(fixture, at: NSPoint(x: 20, y: fixture.bar.bounds.midY))
    XCTAssertFalse(fixture.controller.contentController.history.isHidden)

    try click(fixture, at: NSPoint(x: 20, y: fixture.bar.bounds.midY))
    XCTAssertTrue(fixture.controller.contentController.history.isHidden)
  }

  /// Catches a menu item whose title does not follow the history state.
  func testTheMenuItemTitleFollowsTheHistoryState() throws {
    let fixture = try makeFixture()
    let harness = MenuHarness(fixture.controller)
    let item = try XCTUnwrap(harness.item(.toggleMessageHistory))

    XCTAssertTrue(harness.validate(.toggleMessageHistory))
    XCTAssertEqual(item.title, "Show Message History")

    fixture.controller.dispatch(.toggleMessageHistory)
    XCTAssertTrue(harness.validate(.toggleMessageHistory))
    XCTAssertEqual(item.title, "Hide Message History")
  }

  // MARK: Dismissing

  /// Catches an error that stays on the bar after the user dismisses it.
  func testDismissMessageClearsAnError() throws {
    let fixture = try makeFixture()
    fixture.center.post(level: .error, source: .uniterm, text: "boom")
    XCTAssertEqual(fixture.messageText, "uniterm: boom")

    fixture.controller.dispatch(.dismissMessage)

    XCTAssertEqual(fixture.messageText, "")
    XCTAssertEqual(fixture.center.history.map(\.text), ["boom"])
    XCTAssertTrue(fixture.center.hasUnseenError, "dismissing is not reading the history")
  }

  /// Catches a menu item that is live with nothing to dismiss.
  ///
  /// Info and warning messages clear themselves, so only an error can be dismissed.
  func testDismissMenuItemIsLiveOnlyWhileAnErrorIsShowing() throws {
    let fixture = try makeFixture()
    let harness = MenuHarness(fixture.controller)
    XCTAssertFalse(harness.validate(.dismissMessage), "idle bar")

    fixture.center.post(level: .info, source: .uniterm, text: "fyi")
    XCTAssertFalse(harness.validate(.dismissMessage), "info")

    fixture.clock.now = 2
    fixture.center.post(level: .error, source: .uniterm, text: "boom")
    XCTAssertTrue(harness.validate(.dismissMessage), "error")

    fixture.controller.dispatch(.dismissMessage)
    XCTAssertFalse(harness.validate(.dismissMessage), "after dismissing")
  }

  /// Catches a dismiss control that does not dismiss, or that opens the history instead.
  func testClickingTheDismissControlDismissesAndOtherClicksOpenTheHistory() throws {
    let fixture = try makeFixture()
    fixture.center.post(level: .error, source: .uniterm, text: "boom")
    fixture.layout()

    let control = try XCTUnwrap(fixture.bar.frame(of: .dismiss), "an error has no dismiss control")
    try click(fixture, at: NSPoint(x: control.midX, y: control.midY))

    XCTAssertEqual(fixture.messageText, "")
    XCTAssertTrue(fixture.controller.contentController.history.isHidden)
    XCTAssertNil(fixture.bar.frame(of: .dismiss), "the control outlives the error")
  }

  /// Catches a pending-requests slot whose click opens the history instead of the panel, and a
  /// slot that takes the clicks meant for the rest of the bar. A click on the slot asks the app
  /// for the panel and leaves the history closed. A click on the message area still opens it.
  func testClickingThePendingSlotOpensThePanelAndOtherClicksOpenTheHistory() throws {
    var opened = 0
    let commands = CommandRegistry(app: AppCommandHooks(showPendingRequests: { opened += 1 }))
    let fixture = try makeFixture(commands: commands)

    var states = WindowStates()
    states.set(.pendingPermissions, text: "1 request waits.", label: "1 request")
    fixture.controller.windowStates = states
    fixture.layout()

    let slot = try XCTUnwrap(fixture.bar.frame(of: .window(.pendingPermissions)))
    try click(fixture, at: NSPoint(x: slot.midX, y: slot.midY))

    XCTAssertEqual(opened, 1)
    XCTAssertTrue(fixture.controller.contentController.history.isHidden)

    try click(fixture, at: NSPoint(x: 20, y: fixture.bar.bounds.midY))

    XCTAssertEqual(opened, 1)
    XCTAssertFalse(fixture.controller.contentController.history.isHidden)
  }
}
