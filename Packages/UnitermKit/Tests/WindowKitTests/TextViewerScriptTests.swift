import AppKit
import AppletKit
import Foundation
import ScriptHost
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import TextViewerApplet
@testable import WindowKit

/// A real Janet script in a real helper process drives a real text viewer over the real listener
/// and host. The package tests of the viewer and the window tests call the window layer directly.
/// This is the path a controller takes, including the script wire and the Janet reply reader.
@MainActor
final class TextViewerScriptTests: XCTestCase {
  /// The script the UI test runs. A failure prints its kind and message, so a refusal explains
  /// itself.
  ///
  /// A line break in the notes is written as a Janet escape. Janet's reader drops a literal line
  /// break inside a quoted string, so the notes would collapse into one line.
  static let script = """
    (import uniterm)

    (def me (get (uniterm/list-windows) 0))
    (def layout
      (uniterm/request-layout
        {:window (me :window) :pane (me :pane)}
        {:split :row
         :children [{:pane (me :pane)}
                    {:open :text-viewer :control :remote-controlled :weight 2}]}))

    (def [_ viewer] (layout :panes))

    (defn send [name arguments]
      (def [ok result] (protect (uniterm/send-command viewer :text-viewer [0 0] name arguments)))

      (unless ok
        (error (if (struct? result)
                 (string name " failed: " (get result :kind) ": " (get result :message))
                 (string name " failed: " result))))

      result)

    (defn wait-for [handle]
      (send :wait {:handle (handle :handle) :timeout-ms 20000}))

    (def notes
      (string/join
        (map |(string "## Section " $ "\\n\\nThe body of section " $ " names the deadline.\\n")
             (range 40))
        "\\n"))

    (def loaded (wait-for (send :show-markdown {:text notes})))
    (eprint "loaded: " (string/format "%q" loaded))
    (def found (wait-for (send :find {:query "deadline"})))
    (eprint "found: " (string/format "%q" found))
    (def scrolled (wait-for (send :scroll {:anchor {:kind "heading" :heading 20}})))

    (print (loaded :state) " " (scrolled :state) " " (found :state) " " (found :count))
    """

  /// Runs `source` in a real helper against a window with a text viewer pane, and returns the
  /// helper's status, output, and errors. The script's `viewer` is that pane's reference.
  private func run(_ source: String) async throws -> (Int32, String, String) {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let socketDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tv-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: socketDirectory) }

    let center = StatusCenter()
    let host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: socketDirectory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) },
      windows: fixture.scripting)

    host.start()
    addTeardownBlock { @MainActor in host.stop() }
    fixture.windows.wireControllers(to: host)

    fixture.nextIsFake = true

    let controller = try fixture.openWindow()
    let sourcePane = controller.focusedPane

    fixture.nextIsFake = false
    controller.enableRemoteControl(sourcePane)
    TestSessionRoot.record(in: host, window: controller.scriptWindowID, pane: sourcePane)

    let script = fixture.scratch.appendingPathComponent("notes.janet")
    try Data(source.utf8).write(to: script)

    return try await PresentationTests.run(script: script, socket: host.instanceAddress)
  }

  /// The script's opening: lay out a viewer beside the script's pane, and define `send`.
  private static let opening = script.components(separatedBy: "(defn wait-for").first ?? ""

  /// Catches any break on the path from a script to a real viewer: the script wire, the version
  /// tuple, the dispatcher, the viewer's commands, and the reply reader in the Janet shim.
  func testAScriptShowsNotesInAViewerThenScrollsAndFinds() async throws {
    let (status, output, errors) = try await run(Self.script)

    XCTAssertEqual(status, 0, errors)
    XCTAssertEqual(output, "loaded done done 40\n", errors)
  }

  /// Catches an inline cap that the script helper's own JSON writer refuses. The cap is checked
  /// against the real writer: the largest text, made only of characters that cost two bytes each,
  /// is accepted. Text made of control characters costs six bytes each and can pass the cap and
  /// fail in the helper. That is the documented limit, and it fails with a structured error.
  func testTheInlineCapAgainstTheHelpersRealJSONWriter() async throws {
    let cap = TextViewerLimits.maxInlineMarkdownBytes
    let script =
      Self.opening
        + """
        (def doubled (string/repeat "\\"\\\\" \(cap / 2)))
        (def accepted (send :show-markdown {:text doubled}))
        (def [ok failure] (protect (uniterm/send-command viewer :text-viewer [0 0] :show-markdown
                                     {:text (string/repeat "\\x01" \(cap))})))
        (print (not (nil? (accepted :handle))) " " ok " " (failure :kind))
        """

    let (status, output, errors) = try await run(script)

    XCTAssertEqual(status, 0, errors)
    XCTAssertEqual(output, "true false bad-argument\n", errors)
  }

  /// Catches the helper's JSON writer spending six bytes on a line break or a tab. The cap's
  /// budget counts both at two bytes, so text at the cap made only of them must reach the viewer.
  /// Code slides are mostly short, tab-indented lines.
  func testTheInlineCapHoldsTextMadeOfLineBreaksAndTabs() async throws {
    let cap = TextViewerLimits.maxInlineMarkdownBytes
    let script =
      Self.opening
        + """
        (def breaks (send :show-markdown {:text (string/repeat "\\n\\r" \(cap / 2))}))
        (def tabs (send :show-markdown {:text (string/repeat "\\t" \(cap))}))
        (print (not (nil? (breaks :handle))) " " (not (nil? (tabs :handle))))
        """

    let (status, output, errors) = try await run(script)

    XCTAssertEqual(status, 0, errors)
    XCTAssertEqual(output, "true true\n", errors)
  }

  /// Catches the UI test's script drifting from the script this file runs. The UI test cannot run
  /// here, so its text is compared to this one line by line, after Swift's own escapes are read.
  func testTheUITestRunsTheSameScript() throws {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("UITests/TextViewerUITests.swift")
    let ui = try String(contentsOf: source, encoding: .utf8)
      .replacingOccurrences(of: "\\\\", with: "\\")
    let lines = ui.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

    for line in Self.script.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
    where !line.isEmpty && !line.hasPrefix("(declare") {
      XCTAssertTrue(lines.contains(line), "the UI test's script lacks: \(line)")
    }
  }
}
