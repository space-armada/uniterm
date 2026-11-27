import AppKit
import AppletKit
import PaneModel
import ScriptHost
import ScriptWire
import XCTest

@testable import TextViewerApplet
@testable import WindowKit

/// Real windows whose panes hold a real text viewer, reached through the window side of the host
/// API as a script reaches it. The package tests of the viewer prove each command. These prove the
/// path from the script call to the viewer: the schema version gate, the declaration, the send
/// function, and the page a controller's pane builds.
@MainActor
final class TextViewerRemoteWindowTests: XCTestCase {
  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func viewerPane(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController
  ) throws -> (pane: NodeID, viewer: TextViewerApplet) {
    controller.openPane(.textViewer, axis: .row)

    let pane = controller.focusedPane

    controller.enableRemoteControl(pane)

    return (pane, try XCTUnwrap(controller.paneArea.applet(for: pane) as? TextViewerApplet))
  }

  private func command(
    _ fixture: ExecPaneFixture, _ controller: MainWindowController, _ pane: NodeID,
    _ name: String, _ arguments: String,
    version: ScriptSchemaVersion = ScriptSchemaVersion(major: 0)
  ) async throws -> ScriptValue {
    try await fixture.command(
      controller, pane, name, arguments, type: "text-viewer", version: version)
  }

  /// A call's outcome, or nil when it did not settle in 10 seconds. A nil has failed the test, so a
  /// regression fails in seconds and never hangs.
  private func settled(
    _ what: String, file: StaticString = #filePath, line: UInt = #line,
    _ call: @escaping @MainActor () async throws -> ScriptValue
  ) async -> Result<ScriptValue, Error>? {
    final class Box { var result: Result<ScriptValue, Error>? }
    let box = Box()

    Task { @MainActor in box.result = await Task { @MainActor in try await call() }.result }

    let deadline = Date().addingTimeInterval(10)

    while box.result == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }

    if box.result == nil { XCTFail("\(what) never settled", file: file, line: line) }

    return box.result
  }

  /// Catches a show whose effect never reaches the page, a wait that is not the answer to the
  /// handle, and a viewer that takes a version it does not speak. The viewer is at 0.0, so 0.0
  /// works. A caller written for 1.0 before the reset, a minor above 0.0, and another major are
  /// refused before any effect.
  func testAScriptShowsMarkdownWaitsForItAndIsRefusedOnOtherVersions() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, viewer) = try viewerPane(fixture, controller)

    for version in [
      ScriptSchemaVersion(major: 1), ScriptSchemaVersion(major: 0, minor: 1),
      ScriptSchemaVersion(major: 2),
    ] {
      let refused = await settled("a command on \(version)") {
        try await self.command(
          fixture, controller, pane, "show-markdown", ##"{"text":"# Nope"}"##, version: version)
      }

      guard case .failure(let error as ScriptCallError)? = refused else {
        XCTFail("a command on \(version) was not refused")
        continue
      }

      XCTAssertEqual(error.kind, .unsupported)
    }

    XCTAssertNil(viewer.content.markdownView, "a refused command changed the pane")

    let shown = await settled("the show") {
      try await self.command(
        fixture, controller, pane, "show-markdown", ##"{"text":"# Window notes\n\nbody"}"##)
    }

    XCTAssertEqual(try shown?.get(), .record(["handle": .integer(1)]))

    let waited = await settled("the wait") {
      try await self.command(fixture, controller, pane, "wait", #"{"handle":1}"#)
    }

    XCTAssertEqual(try waited?.get(), .record(["state": .string("loaded")]))

    let text = await viewer.content.markdownView?.run("return document.body.innerText") as? String

    XCTAssertTrue(text?.contains("Window notes") == true)
  }

  /// Catches a script's whole session with a viewer failing in the real window path: show notes,
  /// wait, scroll to a heading, find, and wait on each handle, as the UI test's script does.
  func testAScriptsWholeSessionWithAViewerRuns() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, viewer) = try viewerPane(fixture, controller)
    let notes = (0..<40).map {
      "## Section \($0)\n\nThe body of section \($0) names the deadline.\n"
    }
    .joined(separator: "\n")
    let text = String(decoding: try JSONEncoder().encode(notes), as: UTF8.self)

    func run(_ name: String, _ arguments: String) async -> ScriptValue? {
      let outcome = await settled(name) {
        try await self.command(fixture, controller, pane, name, arguments)
      }

      switch outcome {
      case .success(let value)?:
        XCTAssertNoThrow(try value.encoded(), "\(name)'s reply cannot cross the wire")
        return value

      case .failure(let error)?:
        XCTFail("\(name) failed: \(error)")
        return nil
      case nil: return nil
      }
    }

    func handle(_ value: ScriptValue?) -> UInt64 {
      guard case .record(let fields)? = value, case .integer(let id)? = fields["handle"] else {
        XCTFail("no handle in \(String(describing: value))")
        return 0
      }

      return id
    }

    let shown = handle(await run("show-markdown", #"{"text":\#(text)}"#))
    let loaded = await run("wait", #"{"handle":\#(shown),"timeout-ms":20000}"#)

    XCTAssertEqual(loaded, .record(["state": .string("loaded")]))
    XCTAssertTrue(viewer.content.markdownView?.isRendered == true)

    let scrolled = handle(
      await run("scroll", #"{"anchor":{"kind":"heading","heading":20}}"#))
    let landed = await run("wait", #"{"handle":\#(scrolled),"timeout-ms":20000}"#)

    guard case .record(let landedFields)? = landed else { return XCTFail("no landing") }

    XCTAssertEqual(landedFields["state"], .string("done"))

    let found = handle(await run("find", #"{"query":"deadline"}"#))
    let result = await run("wait", #"{"handle":\#(found),"timeout-ms":20000}"#)

    guard case .record(let resultFields)? = result else { return XCTFail("no result") }

    XCTAssertEqual(resultFields["state"], .string("done"))
    XCTAssertEqual(resultFields["count"], .integer(40))
  }

  /// Catches a viewer that lets an exec driver start. A controller may drive the viewer, and no
  /// exec driver may, since the viewer never owns a child process.
  func testAnExecDriverCannotBeDeclaredOnAViewerPane() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, _) = try viewerPane(fixture, controller)

    XCTAssertThrowsError(try controller.declareExecDriver(fixture.declaration("script"), for: pane))
    { error in
      XCTAssertEqual(error as? ExecPaneError, .unsupported("text-viewer"))
    }
  }

  /// Catches a send that never reaches a real viewer, now that the viewer declares remote control.
  /// UTERM-003's send stays file-based, so the content arrives as a file the viewer reads.
  func testSendShowsAFileInARealViewerPane() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let (pane, viewer) = try viewerPane(fixture, controller)
    let file = fixture.scratch.appendingPathComponent("sent.md")

    try Data("# Sent by a script\n".utf8).write(to: file)

    let reference = ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)

    XCTAssertEqual(
      try fixture.scripting.send(
        to: reference, file: file, caller: fixture.caller(controller, pane)),
      .null)

    var text = ""

    for _ in 0..<1000 {
      text =
        await viewer.content.markdownView?.run("return document.body.innerText") as? String ?? ""

      if text.contains("Sent by a script") { break }

      try? await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertTrue(text.contains("Sent by a script"))
    XCTAssertEqual(viewer.content.body, .markdown)
  }

  /// Catches a controller's pane that shares web data with another pane or keeps it on disk. Each
  /// pane a controller opens builds its own web view with its own non-persistent store.
  func testPanesAControllerOpensEachGetTheirOwnNonPersistentStore() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let first = controller.focusedPane
    let caller = fixture.caller(controller, first)
    var viewers: [TextViewerApplet] = []

    controller.enableRemoteControl(first)

    for _ in 0..<2 {
      let opened = await settled("the open") {
        try await fixture.scripting.openPane(
          kind: "text-viewer",
          beside: .pane(
            ScriptPaneReference(window: controller.scriptWindowID, pane: first.rawValue)),
          axis: .row, directory: nil, access: .remoteControlled, caller: caller)
      }

      guard case .record(let fields)? = try opened?.get(), case .integer(let id)? = fields["pane"]
      else { return XCTFail("the open did not name a pane") }

      let viewer = try XCTUnwrap(
        controller.paneArea.applet(for: NodeID(rawValue: id)) as? TextViewerApplet)
      let target = ScriptTarget.pane(
        ScriptPaneReference(window: controller.scriptWindowID, pane: id))

      let shown = await settled("the show") {
        try await fixture.scripting.sendCommand(
          to: target, appletType: "text-viewer", schemaVersion: ScriptSchemaVersion(major: 0),
          command: "show-markdown", arguments: ##"{"text":"# Owned"}"##, caller: caller,
          stillAllowed: {})
      }

      XCTAssertNotNil(try shown?.get())

      let rendered = await {
        for _ in 0..<1000 {
          if viewer.content.markdownView?.isRendered == true { return true }

          try? await Task.sleep(for: .milliseconds(10))
        }

        return false
      }()

      XCTAssertTrue(rendered)
      viewers.append(viewer)
    }

    let stores = try viewers.map {
      try XCTUnwrap($0.content.markdownView?.webView.configuration.websiteDataStore)
    }

    XCTAssertEqual(stores.map(\.isPersistent), [false, false])
    XCTAssertFalse(stores[0] === stores[1])
  }
}

/// Where a controlled viewer pane puts the find bar's trailing controls, against the host's badge.
@MainActor
final class TextViewerBadgeClearanceTests: XCTestCase {
  private func button(_ identifier: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.accessibilityIdentifier() == identifier {
      return button
    }

    for child in view.subviews {
      if let found = button(identifier, in: child) { return found }
    }

    return nil
  }

  private func pane(controlled: Bool) throws -> (PaneFrameView, TextViewerApplet, NSWindow) {
    let applet = TextViewerApplet(startDirectory: nil)
    let frame = PaneFrameView(
      paneID: NodeID(rawValue: 1), applet: applet,
      frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.contentView = frame

    if controlled {
      frame.controlMark = PaneControlMark(
        access: .remoteControlled, driver: .none, owner: nil, inUnownedGroup: false,
        enableAvailable: false, revokeAvailable: true)
    }

    applet.content.findBar.reveal()
    frame.layoutSubtreeIfNeeded()
    applet.content.layoutSubtreeIfNeeded()

    return (frame, applet, window)
  }

  /// Catches the host's badge drawn over the find bar's Done button. A remote find is the first
  /// time a controlled pane shows its bar. With a badge, Done sits clear of it. Without one, Done
  /// sits where it always did.
  func testTheFindBarsDoneButtonClearsTheHostsBadge() throws {
    let (controlled, viewer, window) = try pane(controlled: true)
    let done = try XCTUnwrap(button("text-viewer-find-close", in: viewer.content.findBar))
    let doneFrame = controlled.convert(done.bounds, from: done)

    XCTAssertFalse(controlled.controlBadge.isHidden)
    XCTAssertFalse(
      doneFrame.intersects(controlled.controlBadge.frame),
      "\(doneFrame) lies under the badge \(controlled.controlBadge.frame)")

    let (plain, plainViewer, plainWindow) = try pane(controlled: false)
    let plainDone = try XCTUnwrap(button("text-viewer-find-close", in: plainViewer.content.findBar))
    let plainFrame = plain.convert(plainDone.bounds, from: plainDone)

    XCTAssertTrue(plain.controlBadge.isHidden)
    XCTAssertEqual(plainFrame.maxX, 700 - 2 - 10, accuracy: 1, "an unbadged bar moved")
    XCTAssertGreaterThan(plainFrame.maxX, doneFrame.maxX)

    plain.controlMark = PaneControlMark(
      access: .remoteControlled, driver: .none, owner: nil, inUnownedGroup: false,
      enableAvailable: false, revokeAvailable: true)
    plain.layoutSubtreeIfNeeded()
    plainViewer.content.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      plain.convert(plainDone.bounds, from: plainDone).maxX, doneFrame.maxX, accuracy: 1)

    plain.controlMark = nil
    plain.layoutSubtreeIfNeeded()
    plainViewer.content.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      plain.convert(plainDone.bounds, from: plainDone).maxX, plainFrame.maxX, accuracy: 1)

    withExtendedLifetime((window, plainWindow)) {}
  }
}
