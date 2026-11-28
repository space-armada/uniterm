import AppKit
import AppletFixtures
import AppletKit
import Foundation
import LayoutKit
import PaneModel
import ScriptHost
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import WindowKit

/// The presentation example end to end: a real Janet script in a real helper process, over the
/// real listener and host, lays out a real window with the slides, notes, and chart fixtures in
/// separate panes, then drives each one through `uniterm/send-command`.
///
/// The test process stands in for the source pane's session root, so the helper binds to that
/// pane through ancestry, as a script in a terminal pane does. This proves the whole path from a
/// script's layout to the applets' state, and what a restore keeps of it. It cannot prove the
/// panes on screen. `PresentationUITests` drives the same script in the app.
@MainActor
final class PresentationTests: XCTestCase {
  /// The script the presentation runs. It lays out its own pane beside the three fixtures, and
  /// commands each one by the reference the layout returned for it.
  static let script = """
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

    (assert (= (length (uniterm/list-panes source)) 4) "the script cannot reach its panes")

    (uniterm/send-command slides :fixture-slides 1 :set-deck {:titles ["Intro" "Results"]})
    (uniterm/send-command slides :fixture-slides 1 :show-slide {:index 1})
    (uniterm/send-command notes :fixture-notes 1 :set-notes {:text "Mention the deadline."})
    (uniterm/send-command chart :fixture-chart 1 :set-series {:values [1.5 -2 4]})
    (def point (uniterm/send-command chart :fixture-chart 1 :select-point {:index 2}))

    (assert (= (point :value) 4) (string "the chart answered " (point :value)))
    (print "presented")
    """

  /// The unsandboxed helper that SwiftPM builds beside the test bundle.
  static func helper() -> URL {
    let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
    let products = bundle?.bundleURL.deletingLastPathComponent()

    return (products ?? URL(fileURLWithPath: ".")).appendingPathComponent("ScriptHelper")
  }

  /// Runs the helper on a script and waits for it off the main actor, so the host answers its
  /// calls meanwhile. A helper that hangs is ended after 60 seconds.
  static func run(script: URL, socket: String) async throws -> (Int32, String, String) {
    var environment = ProcessInfo.processInfo.environment

    environment["UNITERM_SOCKET"] = nil

    let run = try await HelperHandle.spawn(
      executable: helper(), arguments: ["run", "--socket", socket, script.path],
      environment: environment,
      deadlines: [
        HelperDeadline(after: .seconds(60), signal: SIGTERM),
        HelperDeadline(after: .seconds(70), signal: SIGKILL),
      ]
    ).finish()

    return (run.status, run.standardOutput, run.standardError)
  }

  /// Catches any break on the path from a script's layout to the fixtures it drives: a layout
  /// that does not reach the window, panes that are not separate, a group that is not the
  /// script's, a command that does not land, or a reply that does not come back. When the script
  /// ends, its group loses its owner. A save and a restore keep the arrangement and the fixtures'
  /// state, and bring every pane back disconnected in a group with no owner.
  func testAScriptLaysOutAndDrivesSlidesNotesAndChartInSeparatePanes() async throws {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let socketDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pr-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: socketDirectory) }

    let center = StatusCenter()
    let host = ScriptHost(
      listener: try ScriptListener.start(directory: socketDirectory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) },
      windows: fixture.scripting)

    host.start()
    addTeardownBlock { @MainActor in host.stop() }
    fixture.windows.wireControllers(to: host)

    fixture.nextIsFake = true

    let controller = try fixture.openWindow()
    let source = controller.focusedPane

    fixture.nextIsFake = false
    controller.enableRemoteControl(source)
    TestSessionRoot.record(in: host, window: controller.scriptWindowID, pane: source)

    let script = fixture.scratch.appendingPathComponent("presentation.janet")
    try Data(Self.script.utf8).write(to: script)

    let (status, output, errors) = try await Self.run(script: script, socket: host.instanceAddress)

    XCTAssertEqual(status, 0, errors)
    XCTAssertTrue(output.contains("presented"), output)

    let panes = controller.paneIDs

    XCTAssertEqual(panes.count, 4)
    XCTAssertEqual(panes.first, source)

    let slides = try XCTUnwrap(controller.paneArea.applet(for: panes[1]) as? SlidesFixture)
    let notes = try XCTUnwrap(controller.paneArea.applet(for: panes[2]) as? NotesFixture)
    let chart = try XCTUnwrap(controller.paneArea.applet(for: panes[3]) as? ChartFixture)

    XCTAssertEqual(slides.titles, ["Intro", "Results"])
    XCTAssertEqual(slides.index, 1)
    XCTAssertEqual(notes.text, "Mention the deadline.")
    XCTAssertEqual(chart.values, [1.5, -2, 4])
    XCTAssertEqual(chart.selected, 2)

    let frames = controller.paneArea.tree.layout(in: controller.paneArea.bounds.size).frames

    for (index, pane) in panes.enumerated() {
      for other in panes.dropFirst(index + 1) {
        let overlap = try XCTUnwrap(frames[pane]).intersection(try XCTUnwrap(frames[other]))

        XCTAssertTrue(overlap.isEmpty || overlap.width * overlap.height < 1, "\(pane) and \(other)")
      }
    }

    let group = try XCTUnwrap(controller.paneArea.tree.groups.first)

    XCTAssertEqual(group.source, source)
    XCTAssertEqual(group.members, Set(panes.dropFirst()))

    await settle { controller.paneArea.tree.groups.first?.owner == nil }

    XCTAssertNil(controller.paneArea.tree.groups.first?.owner, "the ended script kept its group")

    let saved = try XCTUnwrap(controller.savedWindow())
    let file = try LayoutCodec.encode(SavedLayout(windows: [saved]))
    let restored = try fixture.windows.open(
      restoring: RestoredWindow(saved: try LayoutCodec.decode(file).windows[0]))

    restored.window?.contentView?.layoutSubtreeIfNeeded()

    XCTAssertEqual(restored.paneIDs, panes)
    XCTAssertEqual(restored.paneArea.tree.groups.map(\.owner), [nil])
    XCTAssertEqual(restored.paneArea.tree.groups.first?.members, group.members)

    for pane in restored.paneIDs {
      XCTAssertEqual(restored.control(of: pane).access, .disconnected)
      XCTAssertEqual(
        restored.paneArea.paneView(for: pane)?.controlMark?.savedIntent, .remoteControlled)
    }

    XCTAssertEqual(
      (restored.paneArea.applet(for: panes[1]) as? SlidesFixture)?.titles, ["Intro", "Results"])
  }

  private func settle(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}
