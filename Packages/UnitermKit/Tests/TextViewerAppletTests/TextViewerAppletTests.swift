import AppKit
import AppletKit
import AppletTestSupport
import DocumentTestSupport
import PDFKit
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

@MainActor
final class TextViewerAppletTests: XCTestCase {
  // MARK: Opening

  /// Catches a PDF that does not show, and one that starts a helper it has no use for.
  func testAPDFOpensInPDFKitAndStartsNoHelper() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["one", "two"]))
    let applet = Harness.applet(startDirectory: scratch.url.path)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    let done = await Harness.settled(applet)

    XCTAssertTrue(done)
    XCTAssertEqual(applet.content.body, .pdf)
    XCTAssertEqual(applet.content.pdfView.document?.pageCount, 2)
    XCTAssertEqual(applet.title, "a.pdf")
    XCTAssertEqual(applet.segments.first?.text, "Page 1 of 2")
    XCTAssertEqual(applet.helperStarts, 0)
    XCTAssertTrue(applet.content.pdfView.document?.string?.contains("one") ?? false)
  }

  /// Catches an RTF, Word 97, or Word XML document that does not reach the text view.
  func testRTFAndWordDocumentsOpenThroughTheHelper() async throws {
    let scratch = try Scratch(self)
    let cases: [(String, Data)] = [
      ("a.rtf", try DocumentFixtures.rtf(body: "alpha rtf")),
      ("a.doc", try DocumentFixtures.doc(body: "alpha rtf")),
      ("a.docx", try DocumentFixtures.docx(body: "alpha rtf")),
    ]

    for (name, data) in cases {
      let file = try scratch.write(name, data)
      let applet = Harness.applet(startDirectory: scratch.url.path)

      try applet.replaceSource(with: file, startDirectory: scratch.url.path)
      let done = await Harness.settled(applet)

      XCTAssertTrue(done, name)
      XCTAssertEqual(applet.content.body, .text, name)
      XCTAssertTrue(applet.content.textView.string.contains("alpha rtf"), name)
      XCTAssertEqual(applet.helperStarts, 1, name)

      let gone = await Harness.eventually { applet.activeHelperProcessID == nil }
      XCTAssertTrue(gone, "no helper stays after the load: \(name)")
    }
  }

  /// Catches a pane view that the accessibility tree cannot find. UI tests locate the pane by
  /// identifier, and a plain view with an identifier but no element flag is invisible to them.
  func testThePaneIsAnAccessibleGroupWithItsIdentifier() {
    let view = Harness.applet().content

    XCTAssertTrue(view.isAccessibilityElement())
    XCTAssertEqual(view.accessibilityRole(), .group)
    XCTAssertEqual(view.accessibilityIdentifier(), "text-viewer")
  }

  /// Catches a text view with its own find bar, which would shadow the pane's find.
  func testTheTextViewsBuiltInFindIsOff() {
    let applet = Harness.applet()

    XCTAssertFalse(applet.content.textView.usesFindBar)
    XCTAssertFalse(applet.content.textView.usesFindPanel)
  }

  /// Catches a PDF or text view that takes a file drop for itself instead of giving it to the pane.
  func testNeitherInnerViewRegistersForDrops() {
    let applet = Harness.applet()

    XCTAssertTrue(applet.content.pdfView.registeredDraggedTypes.isEmpty)
    XCTAssertTrue(applet.content.textView.registeredDraggedTypes.isEmpty)
    XCTAssertTrue(applet.content.registeredDraggedTypes.contains(.fileURL))
  }

  /// Catches a PDF view that stays backed by its file. A load is one full read, so truncating the
  /// file afterward must not change what the view reads or draws. The watch is silent here, so no
  /// reload runs. This proves the snapshot, and the reload tests prove what replaces it.
  func testALoadedPDFIsNotBackedByTheFileAfterTheLoad() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["first", "second"]))
    let applet = Harness.applet(startDirectory: scratch.url.path)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)

    try Data().write(to: file)

    let document = try XCTUnwrap(applet.content.pdfView.document)
    let page = try XCTUnwrap(document.page(at: 1))

    XCTAssertEqual(document.pageCount, 2)
    XCTAssertEqual(page.string?.contains("second"), true)
    XCTAssertGreaterThan(document.dataRepresentation()?.count ?? 0, 100)
    XCTAssertGreaterThan(
      page.thumbnail(of: CGSize(width: 80, height: 100), for: .cropBox).size.width, 0)
  }

  /// Catches a link that is not a PDF, an unreadable one, and a file with no reader.
  func testMessagesNameWhatWentWrong() async throws {
    let scratch = try Scratch(self)
    let applet = Harness.applet(startDirectory: scratch.url.path)

    let cases: [(String, Data, String)] = [
      ("bad.pdf", Data("nope".utf8), "not a PDF"),
      ("pic.png", Data([1, 2, 3]), "does not open"),
      ("bad.rtf", Data("not rtf".utf8), "could not be read"),
    ]

    for (name, data, expected) in cases {
      let file = try scratch.write(name, data)

      try applet.replaceSource(with: file, startDirectory: scratch.url.path)
      _ = await Harness.settled(applet)

      let text = Harness.message(applet)

      XCTAssertTrue(text?.contains(expected) ?? false, "\(name): \(text ?? "no message")")
      XCTAssertTrue(text?.contains(name) ?? false, name)
    }
  }

  func testAMissingFileShowsAMessageInThePane() async throws {
    let applet = Harness.applet()

    try applet.replaceSource(
      with: URL(fileURLWithPath: "/no/such/a.pdf"), startDirectory: "/no/such")
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("missing") ?? false)
  }

  // MARK: Read caps

  /// Catches a file past the cap that loads anyway, for both read paths.
  func testAFileTooLargeNamesItsSizeAndNeverLoads() async throws {
    let scratch = try Scratch(self)
    var limits = TextViewerLimits.standard
    limits.maxPDFBytes = 500
    limits.maxDocumentBytes = 500

    let applet = Harness.applet(settings: Harness.settings(limits: limits))

    for (name, data) in [
      ("big.pdf", DocumentFixtures.pdf(pages: ["page"])),
      ("big.rtf", try DocumentFixtures.rtf(body: String(repeating: "x", count: 2000))),
    ] {
      let file = try scratch.write(name, data)

      try applet.replaceSource(with: file, startDirectory: scratch.url.path)
      _ = await Harness.settled(applet)

      let text = Harness.message(applet)

      XCTAssertTrue(text?.contains(name) ?? false, name)
      XCTAssertTrue(text?.contains("opens files up to") ?? false, text ?? name)
    }

    XCTAssertEqual(applet.helperStarts, 0, "a file past the cap never reaches a helper")
  }

  /// Catches a symlink to a device or a FIFO that hangs the pane or reads forever.
  func testADeviceAndAPipeShowAMessage() async throws {
    let scratch = try Scratch(self)
    let device = scratch.url.appendingPathComponent("zero.pdf")
    let pipe = scratch.url.appendingPathComponent("pipe.rtf")

    try FileManager.default.createSymbolicLink(
      atPath: device.path, withDestinationPath: "/dev/zero")
    XCTAssertEqual(mkfifo(pipe.path, 0o644), 0)

    for file in [device, pipe] {
      let applet = Harness.applet(startDirectory: scratch.url.path)

      try applet.replaceSource(with: file, startDirectory: scratch.url.path)
      _ = await Harness.settled(applet)

      XCTAssertTrue(
        Harness.message(applet)?.contains("not a file with data in it") ?? false,
        file.lastPathComponent)
    }
  }

  // MARK: Replace and drop

  /// Catches a second open that leaves the first load running, and a drop of several files that
  /// replaces what shows.
  func testOpeningAnotherFileReplacesAndSeveralDroppedFilesAreRefused() async throws {
    let scratch = try Scratch(self)
    let first = try scratch.write("one.pdf", DocumentFixtures.pdf(pages: ["one"]))
    let second = try scratch.write("two.pdf", DocumentFixtures.pdf(pages: ["two", "more"]))
    let host = RecordingHost()
    let applet = Harness.applet(startDirectory: scratch.url.path)
    applet.host = host

    XCTAssertTrue(applet.handleDrop([first]))
    _ = await Harness.settled(applet)
    XCTAssertEqual(applet.title, "one.pdf")

    XCTAssertFalse(applet.handleDrop([first, second]))
    XCTAssertEqual(applet.title, "one.pdf")
    XCTAssertEqual(applet.content.pdfView.document?.pageCount, 1)
    XCTAssertTrue(host.posts.contains { $0.text.contains("one file at a time") })

    XCTAssertTrue(applet.handleDrop([second]))
    _ = await Harness.eventually { applet.title == "two.pdf" && applet.content.body == .pdf }
    XCTAssertEqual(applet.content.pdfView.document?.pageCount, 2)
  }

  /// Catches the open panel starting in AppKit's remembered folder instead of the pane's.
  func testTheOpenPanelStartsInTheCurrentDirectory() async throws {
    let scratch = try Scratch(self)
    let applet = Harness.applet(startDirectory: scratch.url.path)
    var requested: OpenPanelRequest?

    await SourceOpening.open(applet) { request, _ in
      requested = request
      return []
    }

    XCTAssertEqual(requested?.directory.path, scratch.url.path)
    XCTAssertEqual(requested?.allowsMultipleSelection, false)
    XCTAssertEqual(applet.openPanelContentTypes, TextFormatRule.openPanelTypes)
  }

  // MARK: Describe and restore

  /// Catches a layout save that depends on the disk or changes between calls.
  func testDescribeReadsOnlyMemoryAndIsStable() throws {
    let description = TextViewerDescription(
      startDirectory: "/no/such/dir", path: "/no/such/dir/x.pdf", bookmark: Data([9]),
      anchor: .pdf(page: 3, x: 1, y: 2), sidebarShown: true)
    let applet = try Harness.restored(description)

    XCTAssertEqual(applet.describe(), applet.describe())
    XCTAssertEqual(try TextViewerDescription.decode(applet.describe()), description)
  }

  func testAnEmptyPaneReopensEmptyInItsStartDirectory() throws {
    let scratch = try Scratch(self)
    let applet = Harness.applet(startDirectory: scratch.url.path)
    let back = try Harness.restored(TextViewerDescription.decode(applet.describe()))

    XCTAssertEqual(back.currentDirectory, scratch.url.path)
    XCTAssertEqual(try TextViewerDescription.decode(back.describe()).path, nil)
    XCTAssertEqual(Harness.message(back), TextViewerApplet.emptyText)
  }

  /// Catches an anchor lost on restore, for a PDF page and a text position.
  func testRestoreBringsBackThePDFPage() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write(
      "a.pdf", DocumentFixtures.pdf(pages: ["p0", "p1", "p2", "p3"]))
    let applet = try Harness.restored(
      TextViewerDescription(
        startDirectory: scratch.url.path, path: file.path, anchor: .pdf(page: 2, x: 72, y: 700)))

    applet.content.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    XCTAssertEqual(try TextViewerDescription.decode(applet.describe()).anchor?.page, 2)

    applet.start(origin: .restore)
    _ = await Harness.settled(applet)

    let reached = await Harness.eventually {
      (try? TextViewerDescription.decode(applet.describe()).anchor?.page) == 2
        && applet.content.pdfView.currentPage != nil
    }

    XCTAssertTrue(reached)
    XCTAssertEqual(
      applet.content.pdfView.document?.index(for: applet.content.pdfView.currentPage!), 2)
  }

  func testRestoreScrollsAnRTFToItsCharacter() async throws {
    let scratch = try Scratch(self)
    let body = (0..<400).map { "Line \($0) of the document." }.joined(separator: "\n")
    let file = try scratch.write("a.rtf", try DocumentFixtures.rtf(body: body))
    let index = (body as NSString).range(of: "Line 300 ").location
    let applet = try Harness.restored(
      TextViewerDescription(
        startDirectory: scratch.url.path, path: file.path, anchor: .text(characterIndex: index)))

    applet.content.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    applet.content.layoutSubtreeIfNeeded()
    applet.start(origin: .restore)
    _ = await Harness.settled(applet)

    let scrolled = await Harness.eventually {
      applet.content.scrollView.contentView.bounds.minY > 1000
    }

    XCTAssertTrue(scrolled)

    let anchor = try TextViewerDescription.decode(applet.describe()).anchor?.characterIndex ?? 0

    XCTAssertEqual(Double(anchor), Double(index), accuracy: 200)
  }

  /// Catches a restored pane that describes its restored record forever. After the load shows,
  /// moving the view must change what `describe()` returns, for a PDF page and a text position.
  func testARestoredPaneSavesWhereTheReaderScrollsTo() async throws {
    let scratch = try Scratch(self)
    let pdf = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["p0", "p1", "p2", "p3"]))
    let applet = try Harness.restored(
      TextViewerDescription(
        startDirectory: scratch.url.path, path: pdf.path, anchor: .pdf(page: 0, x: 72, y: 700)))

    applet.content.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    applet.start(origin: .restore)
    _ = await Harness.settled(applet)

    let view = applet.content.pdfView
    let target = try XCTUnwrap(view.document?.page(at: 3))

    view.go(to: PDFDestination(page: target, at: CGPoint(x: 72, y: 700)))

    let followed = await Harness.eventually {
      (try? TextViewerDescription.decode(applet.describe()).anchor?.page) == 3
    }

    XCTAssertTrue(followed, "describe still returns the restored anchor after the view moved")

    let body = (0..<400).map { "Line \($0) of the document." }.joined(separator: "\n")
    let rtf = try scratch.write("a.rtf", try DocumentFixtures.rtf(body: body))
    let text = try Harness.restored(
      TextViewerDescription(
        startDirectory: scratch.url.path, path: rtf.path, anchor: .text(characterIndex: 0)))

    text.content.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    text.content.layoutSubtreeIfNeeded()
    text.start(origin: .restore)
    _ = await Harness.settled(text)

    text.content.textView.scroll(NSPoint(x: 0, y: 3000))

    let moved = await Harness.eventually {
      (try? TextViewerDescription.decode(text.describe()).anchor?.characterIndex ?? 0) ?? 0 > 1000
    }

    XCTAssertTrue(moved, "describe still returns the restored anchor after the text scrolled")
  }

  /// Catches a restore that returns something other than the restored payload while the file is
  /// still being found.
  func testWhileTheFileIsBeingFoundDescribeReturnsTheRestoredPayload() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf())
    let description = TextViewerDescription(
      startDirectory: scratch.url.path, path: file.path, anchor: .pdf(page: 0, x: 5, y: 6))
    let applet = try Harness.restored(description)

    XCTAssertEqual(try TextViewerDescription.decode(applet.describe()), description)
    applet.start(origin: .restore)

    XCTAssertEqual(try TextViewerDescription.decode(applet.describe()).anchor, description.anchor)
  }

  /// Catches a moved file that is not found, and a stored path that does not follow it.
  func testAMovedFileIsFoundThroughItsBookmarkAndThePathFollows() async throws {
    let scratch = try Scratch(self)
    let old = try scratch.write("old.pdf", DocumentFixtures.pdf())
    let bookmark = try old.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let new = scratch.url.appendingPathComponent("new.pdf")
    try FileManager.default.moveItem(at: old, to: new)

    let host = RecordingHost()
    let applet = try Harness.restored(
      TextViewerDescription(startDirectory: scratch.url.path, path: old.path, bookmark: bookmark))
    applet.host = host
    applet.start(origin: .user)
    _ = await Harness.settled(applet)

    XCTAssertEqual(applet.content.body, .pdf)
    XCTAssertEqual(applet.title, "new.pdf")
    XCTAssertTrue(host.posts.contains { $0.text.contains("Moved. Found at") })

    let saved = try TextViewerDescription.decode(applet.describe())

    XCTAssertEqual(URL(fileURLWithPath: saved.path ?? "").resolvingSymlinksInPath().path, new.path)
  }

  /// Catches a bookmark that sends a restore to a rotated-away file. A new file at the stored path
  /// wins, and the bookmark is made again for it.
  func testANewFileAtTheStoredPathWinsAndTheBookmarkIsRemade() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["old"]))
    let bookmark = try file.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let backup = scratch.url.appendingPathComponent("a.pdf.bak")
    try FileManager.default.moveItem(at: file, to: backup)
    try DocumentFixtures.pdf(pages: ["new", "pages"]).write(to: file)

    let applet = try Harness.restored(
      TextViewerDescription(startDirectory: scratch.url.path, path: file.path, bookmark: bookmark))
    applet.start(origin: .user)
    _ = await Harness.settled(applet)

    XCTAssertEqual(applet.content.pdfView.document?.pageCount, 2)

    let remade = try XCTUnwrap(try TextViewerDescription.decode(applet.describe()).bookmark)
    var stale = false
    let named = try URL(
      resolvingBookmarkData: remade, options: [.withoutUI, .withoutMounting],
      bookmarkDataIsStale: &stale)

    XCTAssertEqual(named.resolvingSymlinksInPath().path, file.path)
  }

  /// Catches a file in a protected folder that reads as missing, and a restore that raises a prompt
  /// of uniterm's own. The message says permission, and only the history hears of it.
  func testAFileThatCannotBeReadSaysPermissionWithoutAlerting() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("locked.pdf", DocumentFixtures.pdf())
    XCTAssertEqual(chmod(file.path, 0), 0)

    let host = RecordingHost()
    let anchor = TextViewerAnchor.pdf(page: 1, x: 0, y: 0)
    let applet = try Harness.restored(
      TextViewerDescription(startDirectory: scratch.url.path, path: file.path, anchor: anchor))
    applet.host = host
    applet.start(origin: .restore)
    _ = await Harness.settled(applet)

    XCTAssertTrue(Harness.message(applet)?.contains("permission") ?? false)
    XCTAssertTrue(host.posts.isEmpty)
    XCTAssertTrue(host.attentions.isEmpty)
    XCTAssertEqual(try TextViewerDescription.decode(applet.describe()).anchor, anchor)
  }

  func testCurrentDirectoryFollowsTheFileThenTheStartDirectory() throws {
    let scratch = try Scratch(self)
    let start = scratch.url.appendingPathComponent("start", isDirectory: true)
    let other = scratch.url.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

    XCTAssertEqual(Harness.applet(startDirectory: start.path).currentDirectory, start.path)

    let withFile = try Harness.restored(
      TextViewerDescription(startDirectory: start.path, path: other.path + "/x.pdf"))

    XCTAssertEqual(withFile.currentDirectory, other.path)

    try FileManager.default.removeItem(at: other)
    XCTAssertEqual(withFile.currentDirectory, start.path)

    try FileManager.default.removeItem(at: start)
    XCTAssertNil(withFile.currentDirectory)
  }

  /// Catches a description from a newer build that this build rebuilds into an applet.
  func testANewerDescriptionIsRefused() throws {
    let newer = AppletDescription(
      type: TextViewerDescription.typeID, version: TextViewerDescription.currentVersion + 1,
      payload: try TextViewerDescription(path: "/a.pdf").appletDescription().payload)

    XCTAssertThrowsError(try TextViewerApplet(restoring: newer))
  }

  // MARK: Lifecycle

  /// Catches a pane that asks before it closes, even mid-decode.
  func testAViewerNeverCountsAsRunningSomething() {
    let applet = Harness.applet()

    XCTAssertFalse(applet.isRunningSomething)
    XCTAssertTrue(applet.runningLabels.isEmpty)
  }

  // MARK: Links

  /// Catches a link that opens through a scheme other than http, https, or mailto.
  func testOnlyWebAndMailLinksOpen() {
    let opener = RecordingOpener()
    let applet = Harness.applet(opener: opener)
    let host = RecordingHost()
    applet.host = host

    let handler = applet.content.textView.delegate as? LinkHandler

    for text in [
      "https://example.com/a", "http://example.com", "mailto:a@example.com", "HTTPS://EXAMPLE.COM",
    ] {
      handler?.handle(URL(string: text))
    }

    for text in [
      "file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:", "ssh://host",
      "data:text/html,hi", "/relative/path",
    ] {
      handler?.handle(URL(string: text))
    }

    XCTAssertEqual(opener.opened.count, 4)
    XCTAssertEqual(LinkPolicy.url(from: "https://example.com")?.scheme, "https")
    XCTAssertNil(LinkPolicy.url(from: 7))
  }

  /// Catches a PDF action that reaches past the document. Navigation and safe links run. A link to
  /// another file, a form reset, a print command, and a URL with a file or custom scheme do not.
  /// PDFKit's header says a delegate that implements the link method replaces the default
  /// `NSWorkspace` open, so URL links reach only the handler, and this covers the other actions.
  func testOnlyNavigationAndSafeLinksRunAsPDFActions() throws {
    let file = URL(fileURLWithPath: "/etc/hosts")
    let applet = Harness.applet()
    var refused = 0
    applet.content.pdfView.onRefusedAction = { _ in refused += 1 }

    let allowed: [PDFAction] = [
      PDFActionURL(url: URL(string: "https://example.com")!),
      PDFActionURL(url: URL(string: "mailto:a@example.com")!),
      PDFActionNamed(name: .nextPage), PDFActionNamed(name: .firstPage),
    ]

    let denied: [PDFAction] = [
      PDFActionRemoteGoTo(pageIndex: 0, at: .zero, fileURL: file), PDFActionResetForm(),
      PDFActionNamed(name: .print), PDFActionURL(url: URL(string: "file:///etc/hosts")!),
      PDFActionURL(url: URL(string: "x-apple.systempreferences:")!),
    ]

    for action in allowed { XCTAssertTrue(LinkPolicy.allows(action), "\(action)") }

    for action in denied {
      XCTAssertFalse(LinkPolicy.allows(action), "\(action)")
      applet.content.pdfView.perform(action)
    }

    XCTAssertEqual(refused, denied.count)
  }

  func testThePDFViewSendsLinkClicksToTheSameHandler() {
    let applet = Harness.applet()

    XCTAssertTrue(applet.content.pdfView.delegate === applet.content.textView.delegate)
  }

  // MARK: Commands

  /// Catches an Open that asks for a key, which would shadow the window's Cmd-O, a Reload without
  /// Cmd-R, a find command that leaves Edit > Find, and a declaration that drifts from the owner
  /// rank for the formats the viewer reads.
  func testTheCommandSetAndDeclaration() {
    let commands = TextViewerApplet.commandSet.commands

    XCTAssertEqual(
      commands.map(\.name),
      [
        "open", "find", "find-next", "find-previous", "use-selection-for-find", "show-contents",
        "reload",
      ])
    XCTAssertNil(commands.first?.key)
    XCTAssertEqual(commands.first?.home, .file)

    let reload = commands.first { $0.name == "reload" }

    XCTAssertEqual(reload?.key, KeyChord("r"))
    XCTAssertEqual(reload?.home, .view)
    XCTAssertEqual(
      TextViewerApplet.typeDeclaration.opens,
      [
        OpenedType("com.adobe.pdf", rank: .owner),
        OpenedType("public.rtf", rank: .owner),
        OpenedType("com.microsoft.word.doc", rank: .owner),
        OpenedType("org.openxmlformats.wordprocessingml.document", rank: .owner),
        OpenedType("net.daringfireball.markdown", rank: .owner),
      ])
  }
}
