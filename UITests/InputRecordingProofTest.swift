import XCTest

/// Sends one of each kind of input the debug build records. A `log show` of the app's
/// `input-recording` category over this test's run then shows a record for each. The runner is
/// sandboxed and cannot read the system log, so it cannot check the records itself.
///
/// What the test does prove is that recording keeps a nested tracking loop working. The window's
/// close button takes its mouse up inside its own tracking loop, under its `mouseDown:`, and that
/// loop dequeues through the recording application's `nextEvent` override. A close button that
/// never asks means the override broke that loop.
///
/// The sheet's Cancel button does not track that way. It takes its mouse up from the main loop,
/// like any other event.
@MainActor
final class InputRecordingProofTest: UnitermUITestCase {
  private func tab(_ index: Int, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["tab-\(index)"]
  }

  func testEachRecordedKindOfInputReachesTheApp() {
    let app = launchApp()
    let window = mainWindow(in: app)
    let terminal = waitForTerminal(in: app)

    terminal.typeText("a")

    let center = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.click()
    center.rightClick()
    sendWheel(deltaY: -100, at: terminal, in: window)
    terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).hover()

    let dragStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
    let dragEnd = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2))
    dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)

    // Cmd-T is the modified key. Its second tab runs `cat`, so closing the window asks first.
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(tab(1, in: app).appears(timeout: 10), "Cmd-T opened no tab")
    XCTAssertTrue(waitFor(terminal, timeout: 40) { $0.contains("% ") })

    app.typeText("echo \"IR:$((6*7)):\"; cat\n")
    XCTAssertTrue(waitFor(terminal, timeout: 20) { $0.contains("IR:42:") })

    window.buttons[XCUIIdentifierCloseWindow].click()
    let sheet = window.sheets.firstMatch
    XCTAssertTrue(sheet.appears(timeout: 10), "the close button asked nothing")

    sheet.buttons["Cancel"].click()
    XCTAssertTrue(waitForNoSheet(in: window), "Cancel left the sheet open")
    XCTAssertTrue(tab(1, in: app).exists, "Cancel still closed the window")
  }
}
