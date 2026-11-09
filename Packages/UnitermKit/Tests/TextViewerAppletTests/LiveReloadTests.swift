import AppKit
import AppletKit
import AppletTestSupport
import DocumentTestSupport
import FileWatching
import PDFKit
import StatusKit
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// Drives the pane's watch and reload against real files. The watch windows are shortened so a
/// change lands in a fraction of a second.
@MainActor
final class LiveReloadTests: XCTestCase {
  private static let fast = Harness.fastWatch
  private static let silent = Harness.silentWatch

  private func open(
    _ file: URL, in scratch: Scratch, policy: WatchPolicy = LiveReloadTests.fast,
    host: RecordingHost? = nil, size: CGSize? = nil
  ) async throws -> TextViewerApplet {
    let applet = Harness.applet(startDirectory: scratch.url.path, watching: policy)

    applet.host = host

    if let size { applet.content.frame = NSRect(origin: .zero, size: size) }

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)

    return applet
  }

  private func pdfShows(_ applet: TextViewerApplet, _ text: String) -> Bool {
    applet.content.body == .pdf
      && (applet.content.pdfView.document?.string?.contains(text) ?? false)
  }

  /// Catches a pane that never sees a save. An in-place write and an editor's write-new-then-rename
  /// both show the new document.
  func testSavingInPlaceAndByRenameReloadsThePane() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["first"]))
    let applet = try await open(file, in: scratch)

    try DocumentFixtures.pdf(pages: ["second"]).write(to: file)
    let inPlace = await Harness.eventually { self.pdfShows(applet, "second") }
    XCTAssertTrue(inPlace)

    let replacement = scratch.url.appendingPathComponent(".a.pdf.tmp")
    try DocumentFixtures.pdf(pages: ["third"]).write(to: replacement)
    XCTAssertEqual(rename(replacement.path, file.path), 0)

    let renamed = await Harness.eventually { self.pdfShows(applet, "third") }
    XCTAssertTrue(renamed)
    applet.close()
  }

  /// Catches a reload that sends the reader back to the top. A PDF reloaded on page 3 shows page 3.
  func testAReloadKeepsThePlaceInAPDF() async throws {
    let scratch = try Scratch(self)
    let pages = (1...6).map { "page \($0)" }
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: pages))
    let applet = try await open(file, in: scratch, size: CGSize(width: 600, height: 500))
    let document = try XCTUnwrap(applet.content.pdfView.document)
    let page = try XCTUnwrap(document.page(at: 3))

    applet.content.pdfView.layoutDocumentView()
    applet.content.pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: 72, y: 700)))

    let moved = await Harness.eventually {
      (try? TextViewerDescription.decode(applet.describe()).anchor?.page) == 3
    }
    XCTAssertTrue(moved)

    try DocumentFixtures.pdf(pages: pages + ["page 7 added"]).write(to: file)

    let reloaded = await Harness.eventually { self.pdfShows(applet, "page 7 added") }
    XCTAssertTrue(reloaded)

    let landed = await Harness.eventually {
      (try? TextViewerDescription.decode(applet.describe()).anchor?.page) == 3
        && applet.content.pdfView.currentPage != nil
    }
    XCTAssertTrue(landed)

    applet.close()
  }

  /// Catches a half-written file that blanks the pane. The last good render stays, one warning goes
  /// to the status bar for the load, and the next good write shows.
  func testAFailedReloadKeepsTheRenderAndWarnsOnce() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["first"]))
    let host = RecordingHost()
    let applet = try await open(file, in: scratch, host: host)

    host.forgetSent()
    try Data("half a file".utf8).write(to: file)

    let warned = await Harness.eventually { host.posts.contains { $0.text.contains("not a PDF") } }
    XCTAssertTrue(warned)
    XCTAssertEqual(host.posts.filter { $0.text.contains("not a PDF") }.count, 1)
    XCTAssertEqual(host.posts.first?.level, .warning)
    XCTAssertTrue(pdfShows(applet, "first"))

    try DocumentFixtures.pdf(pages: ["fixed"]).write(to: file)

    let shown = await Harness.eventually { self.pdfShows(applet, "fixed") }
    XCTAssertTrue(shown)
    applet.close()
  }

  /// Catches a deleted file that blanks the pane, warns twice, or never recovers. The render stays,
  /// the bar warns once, a warning segment shows until the file returns, and the return reloads.
  func testADeletedFileKeepsItsRenderShowsASegmentAndReloadsWhenBack() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["first"]))
    let host = RecordingHost()
    let applet = try await open(file, in: scratch, host: host)

    host.forgetSent()
    try FileManager.default.removeItem(at: file)

    let gone = await Harness.eventually {
      applet.segments.contains { $0.text == "Moved or deleted" && $0.style == .warning }
    }
    XCTAssertTrue(gone)
    XCTAssertTrue(pdfShows(applet, "first"))
    XCTAssertEqual(host.posts.filter { $0.text.contains("moved or deleted") }.count, 1)

    try DocumentFixtures.pdf(pages: ["back"]).write(to: file)

    let back = await Harness.eventually {
      self.pdfShows(applet, "back") && !applet.segments.contains { $0.text == "Moved or deleted" }
    }
    XCTAssertTrue(back)
    XCTAssertEqual(host.posts.filter { $0.text.contains("moved or deleted") }.count, 1)
    applet.close()
  }

  /// Catches a gone segment that sticks when the file returns with content that cannot load. The file
  /// is there, so the segment clears and the failed-load warning shows what is wrong.
  func testAFileThatReturnsUnreadableClearsTheSegmentAndWarnsOfTheFailure() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["first"]))
    let host = RecordingHost()
    let applet = try await open(file, in: scratch, host: host)

    try FileManager.default.removeItem(at: file)

    let gone = await Harness.eventually {
      applet.segments.contains { $0.text == "Moved or deleted" }
    }
    XCTAssertTrue(gone)

    host.forgetSent()
    try Data("half a file".utf8).write(to: file)

    let warned = await Harness.eventually { host.posts.contains { $0.text.contains("not a PDF") } }
    XCTAssertTrue(warned)
    XCTAssertFalse(applet.segments.contains { $0.text == "Moved or deleted" })
    XCTAssertTrue(pdfShows(applet, "first"))
    applet.close()
  }

  /// Catches a pane that follows its bookmark live. The path goes away and the bookmark names the
  /// file's new home, and the pane still waits for the path.
  func testAMovedFileIsNeverFollowedThroughTheBookmarkWhileLive() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["first"]))
    let applet = try await open(file, in: scratch)

    let moved = scratch.url.appendingPathComponent("b.pdf")
    try FileManager.default.moveItem(at: file, to: moved)

    let gone = await Harness.eventually {
      applet.segments.contains { $0.text == "Moved or deleted" }
    }
    XCTAssertTrue(gone)

    applet.reload()
    _ = await Harness.settled(applet)

    XCTAssertEqual(applet.title, "a.pdf")
    XCTAssertTrue(pdfShows(applet, "first"))
    XCTAssertTrue(applet.segments.contains { $0.text == "Moved or deleted" })
    applet.close()
  }

  /// Catches a stale watch after a restore finds a moved file. The watch follows the updated path.
  func testAfterARestoreFindsAMovedFileTheWatchFollowsTheNewPath() async throws {
    let scratch = try Scratch(self)
    let old = try scratch.write("old.pdf", DocumentFixtures.pdf(pages: ["first"]))
    let bookmark = try old.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let new = scratch.url.appendingPathComponent("new.pdf")
    try FileManager.default.moveItem(at: old, to: new)

    let applet = try Harness.restored(
      TextViewerDescription(startDirectory: scratch.url.path, path: old.path, bookmark: bookmark),
      watching: Self.fast)
    applet.start(origin: .user)
    _ = await Harness.settled(applet)

    try DocumentFixtures.pdf(pages: ["after the move"]).write(to: new)

    let reloaded = await Harness.eventually { self.pdfShows(applet, "after the move") }
    XCTAssertTrue(reloaded)
    applet.close()
  }

  /// Catches a detached pane that reloads for each change, or never. Changes collect and the
  /// reattach reloads once.
  func testADetachedPaneReloadsOnceAtReattach() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.rtf", try DocumentFixtures.rtf(body: "alpha"))
    let applet = try await open(file, in: scratch, policy: Self.silent)

    applet.detach()

    for body in ["bravo", "charlie", "delta"] {
      try DocumentFixtures.rtf(body: body).write(to: file)
      applet.fileChanged(FileSignature.of(path: file.path))
    }

    XCTAssertFalse(applet.isLoading, "a detached pane starts no reload")
    XCTAssertEqual(applet.helperStarts, 1)
    XCTAssertTrue(applet.content.textView.string.contains("alpha"))

    applet.reattach()

    let shown = await Harness.eventually { applet.content.textView.string.contains("delta") }
    XCTAssertTrue(shown)
    XCTAssertEqual(applet.helperStarts, 2)
    applet.close()
  }

  /// Catches a watch that outlives its pane. The delivery side of a stopped watch is covered by
  /// the watcher's own test, so this one proves the pane lets go of it.
  func testClosingThePaneStopsTheWatch() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["first"]))
    let applet = try await open(file, in: scratch)

    XCTAssertTrue(applet.isWatching)

    applet.close()

    XCTAssertFalse(applet.isWatching)

    applet.fileChanged(FileSignature.of(path: file.path))

    XCTAssertFalse(applet.isLoading, "a change after close starts no reload")
  }

  /// Catches a pane that stops watching after a load that finds the file and cannot read it. The
  /// watch stays, so fixing the file reloads it. A path that cannot be found at all starts no
  /// watch, and Reload covers that.
  func testAFirstLoadThatFailsKeepsTheWatchAndAFixedFileLoads() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", Data("half a file".utf8))
    let applet = try await open(file, in: scratch)

    XCTAssertTrue(Harness.message(applet)?.contains("not a PDF") ?? false)
    XCTAssertTrue(applet.isWatching)

    try DocumentFixtures.pdf(pages: ["fixed"]).write(to: file)

    let shown = await Harness.eventually { self.pdfShows(applet, "fixed") }
    XCTAssertTrue(shown)
    applet.close()
  }

  /// Catches Reload doing nothing where file events never arrive. With the watch silenced, the
  /// command still reads the file again.
  func testReloadReadsTheFileAgainWithoutAnyEvent() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["first"]))
    let applet = try await open(file, in: scratch, policy: Self.silent)

    try DocumentFixtures.pdf(pages: ["second"]).write(to: file)

    let command = try XCTUnwrap(TextViewerApplet.commandSet.commands.first { $0.name == "reload" })
    XCTAssertTrue(command.isAvailable(applet))
    XCTAssertEqual(command.key, KeyChord("r"))

    command.run(applet)

    let shown = await Harness.eventually { self.pdfShows(applet, "second") }
    XCTAssertTrue(shown)
    applet.close()
  }

  func testReloadIsOffForAnEmptyPane() {
    let command = TextViewerApplet.commandSet.commands.first { $0.name == "reload" }

    XCTAssertEqual(command?.isAvailable(Harness.applet()), false)
  }

  // MARK: The helper

  /// Catches a reload that starts a second decode while one runs. Reload ends the running helper
  /// first, and one helper is alive at a time.
  func testAReloadDuringADecodeEndsTheRunningHelperFirst() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.rtf", DocumentFixtures.fault("slow:20000"))
    let applet = Harness.applet(startDirectory: scratch.url.path)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let started = await Harness.eventually { applet.activeHelperProcessID != nil }
    XCTAssertTrue(started)

    let first = try XCTUnwrap(applet.activeHelperProcessID)

    applet.reload()

    let killed = await Harness.eventually { !Harness.isAlive(first) }
    XCTAssertTrue(killed)

    let second = await Harness.eventually {
      applet.helperStarts == 2 && applet.activeHelperProcessID != nil
    }
    XCTAssertTrue(second)
    XCTAssertNotEqual(applet.activeHelperProcessID, first)
    applet.close()
  }

  /// Catches a file rewritten without pause that never finishes loading. A change that arrives
  /// during a decode waits for it, and one more reload follows. The running helper is not killed.
  func testAChangeDuringADecodeQueuesOneReloadAfterIt() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.rtf", DocumentFixtures.fault("slow:300"))
    let applet = Harness.applet(startDirectory: scratch.url.path)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let started = await Harness.eventually { applet.activeHelperProcessID != nil }
    XCTAssertTrue(started)

    let first = try XCTUnwrap(applet.activeHelperProcessID)

    for _ in 0..<3 { applet.fileChanged(FileSignature.of(path: file.path)) }

    XCTAssertEqual(applet.activeHelperProcessID, first)
    XCTAssertEqual(applet.helperStarts, 1)

    let followed = await Harness.eventually { applet.helperStarts == 2 }
    XCTAssertTrue(followed)

    _ = await Harness.eventually { applet.activeHelperProcessID == nil }
    XCTAssertEqual(applet.helperStarts, 2, "three changes queue a single reload")
    applet.close()
  }
}
