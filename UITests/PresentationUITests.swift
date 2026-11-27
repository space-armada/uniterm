import XCTest

/// Runs the presentation example in the real app: a Janet script, started by the bundled command
/// from the first pane's terminal, lays out the hosted slide, notes, and chart fixtures beside
/// that pane and drives each one. A debug build registers the fixtures behind
/// `UNITERM_TEST_APPLETS`.
///
/// What only the real app shows is the layout on screen, each fixture's view changing under the
/// script's commands, and the badge on each pane the script owns. The package tests prove the
/// scope rules, publication, and restore.
@MainActor
final class PresentationUITests: UnitermUITestCase {
  /// Catches a layout that never reaches the screen, fixtures that share a pane, a command that
  /// never lands, or a member pane with no control badge.
  func testAScriptLaysOutAndDrivesTheSlidesNotesAndChart() throws {
    let command = try bundledCommand()

    // The capture holds the terminal pane too, so the prompt names no user or host. The script
    // clears the screen before it finishes, which takes the login banner and the scratch paths.
    try write("PROMPT='%% '\nRPROMPT=''\n", to: scratch + "-shell/.zshrc")

    let app = launchApp(environment: ["UNITERM_TEST_APPLETS": "1"])
    let window = mainWindow(in: app)
    let terminal = waitForTerminal(in: app)
    enableRemoteControl(pane: 1, in: app)

    let script = scratch + "-presentation.janet"
    let shell = scratch + "-presentation.sh"
    let errors = scratch + "-presentation.err"
    let status = scratch + "-presentation.status"

    try write(
      """
      (declare-permissions {:name "Synthetic Presentation"}
        {:kind :pane-control})

      (import uniterm)

      (def me (get (uniterm/list-windows) 0))
      (def source {:window (me :window) :pane (me :pane)})

      (def layout
        (uniterm/request-layout
          source
          {:split :row
           :children [{:pane (me :pane)}
                      {:open :fixture-slides :control :remote-controlled :weight 2}
                      {:split :column
                       :children [{:open :fixture-notes :control :remote-controlled}
                                  {:open :fixture-chart :control :remote-controlled}]}]}))

      (def [_ slides notes chart] (layout :panes))

      (uniterm/send-command slides :fixture-slides 0 :set-deck {:titles ["Intro" "Results"]})
      (uniterm/send-command slides :fixture-slides 0 :show-slide {:index 1})
      (uniterm/send-command notes :fixture-notes 0 :set-notes {:text "Mention the deadline."})
      (uniterm/send-command chart :fixture-chart 0 :set-series {:values [1.5 -2 4]})
      (uniterm/send-command chart :fixture-chart 0 :select-point {:index 2})
      (print (string/join (map |(string ($ :pane)) [slides notes chart]) " "))
      """, to: script)

    try write(
      """
      attempts=0
      while [ $attempts -lt 100 ]; do
        "\(command)" run --socket "\(testSocket)" "\(script)" > "\(status).panes" 2> "\(errors)"
        code=$?
        [ $code -ne 69 ] && break
        attempts=$((attempts + 1))
        sleep 0.1
      done
      printf '\\033[H\\033[2J\\033[3J'
      echo "exit=$code" > "\(status)"
      """, to: shell)

    defer {
      for path in [script, shell, errors, status, status + ".panes"] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    runInTerminal(shell, in: app)
    answerFirstReview(in: app, pressing: "pending-requests-allow-session")

    let result = try XCTUnwrap(waitForFile(status), "the shell never finished the script")
    let errorText = (try? String(contentsOfFile: errors, encoding: .utf8)) ?? ""

    XCTAssertEqual(result, "exit=0\n", errorText)

    let panes = try String(contentsOfFile: status + ".panes", encoding: .utf8)
      .split(whereSeparator: \.isWhitespace).map(String.init)

    XCTAssertEqual(panes.count, 3, "the script printed \(panes)")

    let title = window.staticTexts["fixture-slides-title"]
    let notes = window.staticTexts["fixture-notes-text"]
    let chart = window.staticTexts["fixture-chart-summary"]

    XCTAssertTrue(waitFor(title, timeout: 10) { $0 == "Results" }, "the slides never changed")
    XCTAssertTrue(
      waitFor(notes, timeout: 10) { $0 == "Mention the deadline." }, "the notes never changed")
    XCTAssertTrue(
      waitFor(chart, timeout: 10) { $0 == "3 points, point 3 selected" }, "the chart never changed")

    for pane in panes {
      let frame = window.groups["pane-\(pane)"]

      XCTAssertTrue(frame.exists, "pane \(pane) is not on screen")
      XCTAssertTrue(window.buttons["pane-control-\(pane)"].exists, "pane \(pane) has no badge")
    }

    let frames = panes.map { window.groups["pane-\($0)"].frame }

    for (index, frame) in frames.enumerated() {
      for other in frames.dropFirst(index + 1) {
        let shared = frame.intersection(other)

        XCTAssertTrue(shared.isNull || shared.width * shared.height < 2, "two fixtures overlap")
      }
    }

    XCTAssertTrue(
      waitFor(terminal, timeout: 10) { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "%" },
      "the terminal shows more than the synthetic prompt, so the capture is not kept")

    keepScreenshot(of: window, named: "presentation")
  }

  /// Keeps a screenshot of uniterm's own element, never of the screen.
  private func keepScreenshot(of element: XCUIElement, named name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
