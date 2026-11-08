import AppKit
import AppletTestSupport
import Darwin
import DocumentTestSupport
import DocumentWire
import HelperHost
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// Proves the helper's failures against an unsandboxed SwiftPM build of the real helper, with
/// faults that a debug build reads from a marker at the start of a file. The shipped helper's
/// sandbox is proved by `make test-helper-sandbox`.
@MainActor
final class DocumentHelperTests: XCTestCase {
  private func open(
    _ data: Data, named name: String, limits: TextViewerLimits = .standard, in scratch: Scratch
  ) async throws -> TextViewerApplet {
    let file = try scratch.write(name, data)
    let applet = Harness.applet(
      startDirectory: scratch.url.path, settings: Harness.settings(limits: limits))

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    return applet
  }

  /// Catches a helper crash that takes the app or the pane with it. The pane says so, stays
  /// usable, and the next file opens.
  func testACrashingHelperLeavesThePaneRunningWithAMessage() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(DocumentFixtures.fault("crash"), named: "a.rtf", in: scratch)

    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("stopped while reading") ?? false)

    let good = try scratch.write("good.rtf", try DocumentFixtures.rtf(body: "after the crash"))
    try applet.replaceSource(with: good, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)

    XCTAssertEqual(applet.content.body, .text)
    XCTAssertTrue(applet.content.textView.string.contains("after the crash"))
  }

  /// Catches a stopped helper that leaves the pane waiting. A process that stops answering pings is
  /// ended and the pane says so.
  func testAStoppedHelperIsEnded() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(DocumentFixtures.fault("stop"), named: "a.docx", in: scratch)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("stopped answering") ?? false)
  }

  /// Catches a decode that never finishes and is called a hang. The helper answers pings, so the
  /// time bound is a limit and the message says how long.
  func testADecodePastTheTimeBoundEndsAtTheLimit() async throws {
    let scratch = try Scratch(self)
    var limits = TextViewerLimits.standard
    limits.decodeTimeBound = .milliseconds(400)

    let applet = try await open(
      DocumentFixtures.fault("spin"), named: "a.rtf", limits: limits, in: scratch)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("took more than") ?? false)
  }

  /// Catches a `.docx` that inflates past the memory the pane allows and ends in the app. The helper
  /// is ended at the footprint cap.
  func testAHelperPastTheFootprintCapIsEnded() async throws {
    let scratch = try Scratch(self)
    var limits = TextViewerLimits.standard
    limits.footprintCap = 120 << 20

    let applet = try await open(
      DocumentFixtures.fault("balloon:400"), named: "a.docx", limits: limits, in: scratch)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("more memory") ?? false)
  }

  /// Catches a superseded open that leaves its helper running. Opening another file kills the
  /// slow decode's helper, and the new file shows.
  func testOpeningAnotherFileKillsTheRunningDecode() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(DocumentFixtures.fault("slow:20000"), named: "a.rtf", in: scratch)

    let started = await Harness.eventually { applet.activeHelperProcessID != nil }
    XCTAssertTrue(started)

    let pid = try XCTUnwrap(applet.activeHelperProcessID)
    let next = try scratch.write("b.pdf", DocumentFixtures.pdf(pages: ["b"]))

    try applet.replaceSource(with: next, startDirectory: scratch.url.path)

    let killed = await Harness.eventually { !Harness.isAlive(pid) }
    _ = await Harness.settled(applet)

    XCTAssertTrue(killed)
    XCTAssertEqual(applet.content.body, .pdf)
    XCTAssertNil(applet.activeHelperProcessID)
  }

  /// Catches a helper that outlives its pane.
  func testClosingThePaneKillsTheHelper() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(DocumentFixtures.fault("slow:20000"), named: "a.rtf", in: scratch)

    let started = await Harness.eventually { applet.activeHelperProcessID != nil }
    XCTAssertTrue(started)

    let pid = try XCTUnwrap(applet.activeHelperProcessID)

    applet.close()

    let killed = await Harness.eventually { !Harness.isAlive(pid) }

    XCTAssertTrue(killed)
    XCTAssertNil(applet.activeHelperProcessID)
  }

  /// Catches a reopen that reuses a dead helper. Each load starts a fresh process.
  func testEachLoadStartsAFreshHelper() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.rtf", try DocumentFixtures.rtf())
    let applet = Harness.applet(startDirectory: scratch.url.path)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)

    let restored = try Harness.restored(TextViewerDescription.decode(applet.describe()))
    restored.start(origin: .restore)
    _ = await Harness.settled(restored)

    XCTAssertEqual(applet.helperStarts, 1)
    XCTAssertEqual(restored.helperStarts, 1)
    XCTAssertEqual(restored.content.body, .text)
  }

  /// Catches a missing helper executable that freezes the pane.
  func testAMissingHelperShowsAMessage() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.rtf", try DocumentFixtures.rtf())
    let applet = Harness.applet(
      startDirectory: scratch.url.path,
      settings: Harness.settings(location: HelperLocation(url: nil)))

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("missing from this copy") ?? false)
  }

  /// Catches a helper that sends bytes the app should refuse. A stand-in script writes garbage to
  /// the socket, and the pane reports that it could not trust the reader.
  func testAHelperThatSendsGarbageIsRefused() async throws {
    let scratch = try Scratch(self)
    let path = scratch.url.appendingPathComponent("fake-helper").path

    try "#!/bin/sh\nprintf '\\377\\377\\377\\377\\377\\377\\377\\377' >&3\nexec /bin/sleep 30\n"
      .write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)

    let file = try scratch.write("a.rtf", try DocumentFixtures.rtf())
    let applet = Harness.applet(
      startDirectory: scratch.url.path,
      settings: Harness.settings(location: HelperLocation(url: URL(fileURLWithPath: path))))

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("could not trust") ?? false)
  }

  // MARK: Caps

  /// Catches a document past the decoded length that reaches the text view. The cap runs before any
  /// layout, so the text storage stays empty.
  func testADocumentPastTheLengthCapShowsAMessageAndNeverLaysOut() async throws {
    let scratch = try Scratch(self)
    var limits = TextViewerLimits.standard
    limits.maxDecodedLength = 50

    let applet = try await open(
      DocumentFixtures.rtf(body: String(repeating: "word ", count: 100)), named: "long.rtf",
      limits: limits, in: scratch)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("more than 50 characters") ?? false)
    XCTAssertEqual(applet.content.textView.textStorage?.length, 0)
  }

  func testADocumentPastTheTableCellCapShowsAMessage() async throws {
    let scratch = try Scratch(self)
    var limits = TextViewerLimits.standard
    limits.maxTableCells = 6

    let applet = try await open(
      DocumentFixtures.rtfWithTable(rows: 4, columns: 4), named: "table.rtf", limits: limits,
      in: scratch)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("more than 6 table cells") ?? false)
    XCTAssertEqual(applet.content.textView.textStorage?.length, 0)
  }

  func testATableWithinTheCapShows() async throws {
    let scratch = try Scratch(self)
    let applet = try await open(
      DocumentFixtures.rtfWithTable(rows: 2, columns: 2), named: "table.rtf", in: scratch)
    _ = await Harness.settled(applet)

    XCTAssertEqual(applet.content.body, .text)
    XCTAssertTrue(applet.content.textView.string.contains("r1c1"))
  }

  /// Catches a link in a document that opens through any scheme, here from a real RTF read by the
  /// helper.
  func testALinkInAnRTFOpensOnlyWhenItsSchemeIsSafe() async throws {
    let scratch = try Scratch(self)
    let opener = RecordingOpener()

    for (link, opens) in [("https://example.com/x", true), ("file:///etc/hosts", false)] {
      let file = try scratch.write("link.rtf", try DocumentFixtures.rtfWithLink(link))
      let applet = Harness.applet(startDirectory: scratch.url.path, opener: opener)

      try applet.replaceSource(with: file, startDirectory: scratch.url.path)
      _ = await Harness.settled(applet)

      let storage = try XCTUnwrap(applet.content.textView.textStorage)
      let range = (storage.string as NSString).range(of: "a link")
      let value = storage.attribute(.link, at: range.location, effectiveRange: nil)
      let handler = applet.content.textView.delegate as? LinkHandler
      let before = opener.opened.count

      handler?.handle(LinkPolicy.url(from: value))

      XCTAssertEqual(opener.opened.count - before, opens ? 1 : 0, link)
    }
  }
}
