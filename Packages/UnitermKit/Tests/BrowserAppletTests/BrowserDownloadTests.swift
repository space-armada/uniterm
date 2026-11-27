import AppletKit
import BrowserModel
import BrowserTestSupport
import CoreServices
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// Downloads against a real web view and the fixture server. The Downloads folder is a temporary
/// one that the harness removes, so no test touches the user's. A held response keeps a download in
/// progress for as long as a test needs, with no timer.
@MainActor
final class BrowserDownloadTests: XCTestCase {
  private nonisolated static func handler(hold: FixtureServer.Hold) -> FixtureServer.Handler {
    { request in
      switch request.path {
      case "/file":
        return attachment("report.txt", body: "hello")

      case "/held":
        return attachment("held.bin", body: "he", hold: hold, tail: "llo")

      case "/evil-name":
        return attachment("../../..//.hidden\u{202E}txt.exe", body: "x")

      case "/zip":
        return FixtureServer.Response(
          status: 200, headers: [("Content-Type", "application/zip")], body: Data("PK".utf8))

      case "/page":
        return Pages.page("Page", "<a id=l href=/file>get</a>")

      case "/held-page":
        return Pages.page("HeldPage", "<a id=l href=/held>get</a>")

      case "/frame-attachment":
        return Pages.page("Frame", "<iframe src=/file></iframe>")

      case "/other":
        return Pages.page("Other")

      default:
        return Pages.page("Default")
      }
    }
  }

  private nonisolated static func attachment(
    _ name: String, body: String, hold: FixtureServer.Hold? = nil, tail: String = ""
  ) -> FixtureServer.Response {
    FixtureServer.Response(
      status: 200,
      headers: [
        ("Content-Type", "application/octet-stream"),
        ("Content-Disposition", "attachment; filename=\"\(name)\""),
      ], body: Data(body.utf8), hold: hold, tail: Data(tail.utf8))
  }

  private func make(
    _ hold: FixtureServer.Hold = FixtureServer.Hold(), services: BrowserServices = .testing()
  ) async throws -> BrowserHarness {
    try await BrowserHarness.make(services: services, handler: Self.handler(hold: hold))
  }

  /// A click of the user's own: the view saw a mouse-up, then the script clicks the link. A page's
  /// own script clicks are counted, so only a real click can start many downloads.
  private func clickLink(_ harness: BrowserHarness) async {
    harness.tab.noteMouseUp()

    await harness.run("document.getElementById('l').click()")
  }

  /// Catches a download that lands under a name other than the server's, loses its bytes, leaves a
  /// temporary file behind, or skips the mark that makes Gatekeeper check it. Expected values are
  /// written by hand. The system reads back the mark's type, the agent, and an event identifier. It
  /// does not return the origin and data addresses, which it keeps in its own quarantine
  /// database, so a test cannot read them from the file. The origin and data addresses are
  /// checked on the download before it ends and in `DownloadFilesTests`.
  func testAnAttachmentLandsQuarantinedAndTheUserIsTold() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold)
    defer { harness.stop() }

    await harness.load("/held-page", expecting: "HeldPage")
    await clickLink(harness)
    await harness.host.until("the download has a file") {
      harness.applet.downloads.active.first?.temporary != nil
    }

    let entry = try XCTUnwrap(harness.applet.downloads.active.first)

    XCTAssertEqual(entry.origin, harness.server.url("/held-page"))
    XCTAssertEqual(entry.source, harness.server.url("/held"))

    hold.release()
    await harness.host.until("the download is announced") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.posts.map(\.text), ["Downloaded held.bin."])
    XCTAssertEqual(harness.posts.map(\.level), [.info])
    XCTAssertEqual(harness.files(), ["held.bin"])

    let file = try XCTUnwrap(harness.downloadsDirectory).appending(path: "held.bin")

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    await harness.eventually("the tab shows its own page again") {
      harness.tab.currentURL == harness.server.url("/held-page")
    }

    XCTAssertEqual(harness.applet.title, "HeldPage")

    let quarantine = try XCTUnwrap(
      try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)

    XCTAssertEqual(
      quarantine[kLSQuarantineTypeKey as String] as? String,
      kLSQuarantineTypeWebDownload as String)
    XCTAssertEqual(
      quarantine[kLSQuarantineAgentBundleIdentifierKey as String] as? String,
      DownloadFiles.agentBundleIdentifier)
    XCTAssertNotNil(quarantine["LSQuarantineEventIdentifier"])
  }

  /// Catches a download that writes under its final name while it runs, so a crash leaves a file
  /// that looks complete, and a download whose progress the status bar never shows.
  func testWhileItRunsTheFileHasATemporaryNameAndTheStatusBarShowsIt() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold)
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/held").absoluteString)
    await harness.host.until("the download names its file") {
      harness.applet.downloads.active.first?.name == "held.bin"
        && harness.applet.downloads.active.first?.temporary != nil
    }

    let running = harness.files()

    let temporary = try XCTUnwrap(harness.applet.downloads.active.first?.temporary)

    XCTAssertTrue(temporary.lastPathComponent.hasPrefix(".uniterm-download-"), "\(temporary)")
    XCTAssertTrue(temporary.lastPathComponent.hasSuffix(".part"), "\(temporary)")
    XCTAssertTrue(
      running.allSatisfy { $0.hasPrefix(".uniterm-download-") }, "no final name yet: \(running)")
    XCTAssertTrue(harness.applet.isRunningSomething)
    XCTAssertEqual(harness.applet.runningLabels, ["held.bin"])
    XCTAssertTrue(
      harness.applet.segments.contains { $0.text?.contains("held.bin") ?? false },
      "\(harness.applet.segments)")

    hold.release()
    await harness.host.until("the download finishes") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.files(), ["held.bin"])
    XCTAssertFalse(harness.applet.isRunningSomething)
    XCTAssertTrue(harness.applet.segments.isEmpty)
  }

  /// Catches two downloads, in two panes that share a folder, taking the same name. Both are in
  /// flight with the same suggested name when they finish.
  func testTwoPanesNeverTakeTheSameName() async throws {
    let hold = FixtureServer.Hold()
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "uniterm-test-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
    let services = BrowserServices.testing(downloads: directory)
    let first = try await make(hold, services: services)
    defer { first.stop() }

    let second = BrowserHarness(
      server: first.server, applet: BrowserApplet(dataStore: .nonPersistent(), services: services))
    defer { second.stop() }

    for harness in [first, second] {
      harness.applet.submit(address: first.server.url("/held").absoluteString)
      await harness.host.until("the download names its file") {
        harness.applet.downloads.active.first?.temporary != nil
      }
    }

    hold.release()

    for harness in [first, second] {
      await harness.host.until("the download finishes") { !harness.posts.isEmpty }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
      ["held 2.bin", "held.bin"])
  }

  /// Catches many downloads of one name, one after another, losing one to a name clash, and a
  /// manager that keeps something for each of them. Each takes its own numbered name, and nothing
  /// is left running. A page that starts many downloads costs a file each and no more state than
  /// the newest finished one.
  func testManyDownloadsOfOneNameEachGetTheirOwn() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/page", expecting: "Page")

    let count = 30

    for index in 1...count {
      await clickLink(harness)
      await harness.host.until("download \(index) finishes") { harness.posts.count == index }
    }

    let names = harness.files()

    XCTAssertEqual(
      Set(names), Set((1...count).map { DownloadName.numbered("report.txt", attempt: $0) }))
    XCTAssertEqual(names.count, count)
    XCTAssertFalse(harness.applet.isRunningSomething)
    XCTAssertTrue(harness.applet.downloads.active.isEmpty)
    XCTAssertEqual(harness.applet.downloads.latest?.name, "report \(count).txt")
  }

  /// Catches a suggested name that climbs out of the folder, hides the file, or flips its
  /// extension. The cleaned table is in the model's tests, and this shows the web view's name goes
  /// through it.
  func testAnEvilSuggestedNameIsCleaned() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/evil-name").absoluteString)
    await harness.host.until("the download is announced") { !harness.posts.isEmpty }

    let names = harness.files()

    XCTAssertEqual(names.count, 1)
    XCTAssertFalse(names[0].hasPrefix("."), "\(names)")
    XCTAssertFalse(names[0].contains("/"), "\(names)")
    XCTAssertFalse(names[0].unicodeScalars.contains { $0.value == 0x202E }, "\(names)")

    let outside = try XCTUnwrap(harness.downloadsDirectory).deletingLastPathComponent()
    let escaped = try FileManager.default.contentsOfDirectory(atPath: outside.path)
      .filter { $0 == "hidden" || $0.hasPrefix(".hidden") }

    XCTAssertEqual(escaped, [])
  }

  /// Catches a failed download that leaves its partial file, says nothing, or does not name the
  /// file and the reason. Dropping the connection mid-body is the failure.
  func testAFailedDownloadLeavesNoFileAndWarnsWithTheNameAndReason() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold)
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/held").absoluteString)
    await harness.host.until("the download has a file") {
      harness.applet.downloads.active.first?.temporary != nil
    }

    hold.abort()
    await harness.host.until("the failure is reported") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertEqual(harness.posts.first?.level, .warning)

    let text = try XCTUnwrap(harness.posts.first?.text)

    XCTAssertTrue(text.hasPrefix("Could not download held.bin. "), text)
    XCTAssertGreaterThan(text.count, "Could not download held.bin. ".count)
    XCTAssertFalse(harness.applet.isRunningSomething)

    // The partial file is removed off the main thread, so the warning can arrive first.
    await harness.eventually("the partial file is gone") { harness.files() == [] }
  }

  /// Catches a download that ends with the page that started it, and one that survives a tab the
  /// user closed after being asked. The question names the file. A no keeps the download, a yes
  /// cancels it with no file and no message. The tab is not the selected one.
  func testClosingATabDuringADownloadAsksNamesTheFileAndCancelsIt() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold)
    defer { harness.stop() }

    harness.applet.openTab()
    harness.applet.submit(address: harness.server.url("/held").absoluteString)
    await harness.host.until("the download has a file") {
      harness.applet.downloads.active.first?.temporary != nil
    }

    harness.applet.selectTab(at: 0)

    harness.host.recording.answer = false

    let declined = await harness.applet.closeTab(at: 1)

    XCTAssertEqual(declined, .declined)
    XCTAssertEqual(harness.applet.tabCount, 2)
    XCTAssertTrue(harness.applet.isRunningSomething)
    XCTAssertEqual(harness.host.recording.confirmations.count, 1)
    XCTAssertTrue(
      harness.host.recording.confirmations[0].detail.contains("held.bin"),
      harness.host.recording.confirmations[0].detail)

    harness.host.recording.answer = true

    let closed = await harness.applet.closeTab(at: 1)

    XCTAssertEqual(closed, .closed)
    XCTAssertEqual(harness.applet.tabCount, 1)
    XCTAssertFalse(harness.applet.isRunningSomething)

    await harness.eventually("the partial file is gone") { harness.files() == [] }

    hold.release()

    await harness.load("/other", expecting: "Other")

    XCTAssertEqual(harness.posts.map(\.text), [], "a cancelled download posts nothing")
    XCTAssertEqual(harness.files(), [])
  }

  /// Catches a pane that closes with a download running and leaves its file behind. The window
  /// asks about the pane through `isRunningSomething` and `runningLabels`, which this shows are set
  /// while the download runs. The close cancels the download and removes its partial file.
  func testClosingThePaneCancelsTheDownloadAndRemovesItsFile() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold)
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/held").absoluteString)
    await harness.host.until("the download has a file") {
      harness.applet.downloads.active.first?.temporary != nil
    }

    XCTAssertTrue(harness.applet.isRunningSomething)
    XCTAssertEqual(harness.applet.runningLabels, ["held.bin"])

    harness.applet.close()

    XCTAssertFalse(harness.applet.isRunningSomething)

    await harness.eventually("the partial file is gone") { harness.files() == [] }

    hold.release()
    harness.server.stop()
  }

  /// Catches a download that ends when its tab navigates away. The page the user moves to is a
  /// different page, and the file is the user's.
  func testNavigatingTheTabAwayDoesNotCancelTheDownload() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold)
    defer { harness.stop() }

    await harness.load("/held-page", expecting: "HeldPage")
    await harness.run("document.getElementById('l').click()")
    await harness.host.until("the download has a file") {
      harness.applet.downloads.active.first?.temporary != nil
    }

    await harness.load("/other", expecting: "Other")

    XCTAssertTrue(harness.applet.isRunningSomething)

    hold.release()
    await harness.host.until("the download finishes") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.files(), ["held.bin"])
    XCTAssertEqual(harness.applet.title, "Other")
  }

  /// Catches an attachment in a subframe that loads as a broken frame and reaches no one. It
  /// downloads like any other.
  func testAnAttachmentInASubframeDownloads() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/frame-attachment").absoluteString)
    await harness.host.until("the download is announced") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.files(), ["report.txt"])
  }

  /// Catches a response the browser cannot show, with no attachment header, that fails as an
  /// interrupted load. It downloads too.
  func testAResponseTheBrowserCannotShowDownloads() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/zip").absoluteString)
    await harness.host.until("the download is announced") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.posts.first?.level, .info)
    XCTAssertEqual(harness.files().count, 1)
  }

  // MARK: Reveal

  /// Catches a reveal that is offered with nothing to show, one that opens Finder in a test, and a
  /// moved file that goes quiet. The command is unavailable with no finished download.
  func testRevealLatestDownloadShowsTheNewestFileAndExplainsAMovedOne() async throws {
    let revealer = FakeRevealer()
    let harness = try await make(services: .testing(reveal: revealer))
    defer { harness.stop() }

    let command = try XCTUnwrap(
      BrowserApplet.commandSet.commands.first { $0.name == "reveal-latest-download" })

    XCTAssertEqual(command.title, "Reveal Latest Download")
    XCTAssertFalse(command.isAvailable(harness.applet))

    harness.applet.revealLatestDownload()

    XCTAssertEqual(revealer.revealed, [])

    harness.applet.submit(address: harness.server.url("/file").absoluteString)
    await harness.host.until("the download is announced") { !harness.posts.isEmpty }

    XCTAssertTrue(command.isAvailable(harness.applet))

    command.run(harness.applet)

    let file = try XCTUnwrap(harness.downloadsDirectory).appending(path: "report.txt")

    XCTAssertEqual(revealer.revealed.map(\.lastPathComponent), ["report.txt"])

    harness.host.recording.forgetSent()
    try FileManager.default.removeItem(at: file)
    command.run(harness.applet)

    XCTAssertEqual(revealer.revealed.count, 1)
    XCTAssertEqual(
      harness.posts.map(\.text), ["Could not show report.txt. It was moved or deleted."])
    XCTAssertEqual(harness.posts.map(\.level), [.warning])
    XCTAssertTrue(command.isAvailable(harness.applet))
  }

  /// Catches a reveal of an older file once a newer one finishes.
  func testRevealPicksTheNewestFinishedFile() async throws {
    let revealer = FakeRevealer()
    let harness = try await make(services: .testing(reveal: revealer))
    defer { harness.stop() }

    for _ in 0..<2 {
      harness.host.recording.forgetSent()
      harness.applet.submit(address: harness.server.url("/file").absoluteString)
      await harness.host.until("the download is announced") { !harness.posts.isEmpty }
    }

    harness.applet.revealLatestDownload()

    XCTAssertEqual(revealer.revealed.map(\.lastPathComponent), ["report 2.txt"])
  }

  // MARK: Page-made downloads

  private func page(_ body: String) -> FixtureServer.Handler {
    { _ in Pages.page("Made", body) }
  }

  /// Catches a `blob:` or `data:` export that is refused or opens as a page. Each saves like any
  /// other download. A `blob:` link saves with or without a `download` attribute, since its
  /// response is known only after the navigation is allowed. A `data:` link needs the attribute,
  /// because a top-level `data:` navigation with none is a page, which stays refused.
  func testBlobAndDataExportsSave() async throws {
    let harness = try await BrowserHarness.make(
      handler: page(
        """
        <a id=data download=data.txt href="data:text/plain,from-data">d</a>
        <script>
        var a = document.createElement('a'); a.id = 'blob'; a.download = 'blob.txt';
        a.href = URL.createObjectURL(new Blob(['from-blob'], {type: 'application/octet-stream'}));
        document.body.appendChild(a);
        var b = document.createElement('a'); b.id = 'bare';
        b.href = URL.createObjectURL(new Blob(['from-bare'], {type: 'application/octet-stream'}));
        document.body.appendChild(b);
        </script>
        """))
    defer { harness.stop() }

    await harness.load("/", expecting: "Made")

    for (index, id) in ["data", "blob", "bare"].enumerated() {
      await harness.run("document.getElementById('\(id)').click()")
      await harness.host.until("the download for \(id) finishes") {
        harness.posts.count == index + 1
      }

      XCTAssertEqual(harness.posts.last?.level, .info, id)
    }

    let directory = try XCTUnwrap(harness.downloadsDirectory)
    let saved = harness.files()

    XCTAssertEqual(saved.count, 3, "\(saved)")
    XCTAssertTrue(saved.contains("data.txt"), "\(saved)")
    XCTAssertTrue(saved.contains("blob.txt"), "\(saved)")

    let contents = try saved.map {
      try String(contentsOf: directory.appending(path: $0), encoding: .utf8)
    }

    XCTAssertEqual(Set(contents), ["from-data", "from-blob", "from-bare"], "\(contents)")
    XCTAssertEqual(harness.applet.title, "Made")
  }

  /// Catches a page's own `blob:` preview that downloads or is refused. It opens in the tab.
  func testAPagesOwnBlobPreviewOpensInItsTab() async throws {
    let harness = try await BrowserHarness.make(
      handler: page(
        """
        <script>
        var a = document.createElement('a'); a.id = 'preview';
        a.href = URL.createObjectURL(new Blob(['<title>Blob Preview</title>shown'], {type: 'text/html'}));
        document.body.appendChild(a);
        </script>
        """))
    defer { harness.stop() }

    await harness.load("/", expecting: "Made")
    await harness.run("document.getElementById('preview').click()")
    await harness.host.until("the preview shows") {
      harness.applet.title == "Blob Preview" && !harness.tab.isLoading
    }

    XCTAssertTrue(harness.tab.currentURL?.scheme == "blob")
    XCTAssertEqual(harness.posts.map(\.text), [])
    XCTAssertEqual(harness.files(), [])
  }

  /// Catches a top-level `data:` page that loads. A subframe's `data:` and `srcdoc` content must
  /// load, and the refusal of the top-level one must not touch them. Each frame's script reports
  /// to its parent, which the parent shows as its title.
  func testATopLevelDataPageIsRefusedWhileSrcdocAndDataSubframesLoad() async throws {
    let harness = try await BrowserHarness.make { request in
      if request.path == "/other" { return Pages.page("Other") }

      return Pages.page(
        "Frames",
        """
        <a id=top href="data:text/html,<title>Injected</title>x">top</a>
        <iframe srcdoc="<script>parent.postMessage('srcdoc','*')</script>"></iframe>
        <iframe src="data:text/html,<script>parent.postMessage('data','*')</script>"></iframe>
        <script>
        var seen = {};
        window.addEventListener('message', function (e) {
          seen[e.data] = true;
          if (seen.srcdoc && seen.data) { document.title = 'FramesLoaded'; }
        });
        </script>
        """)
    }
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/").absoluteString)
    await harness.host.until("both frames report") { harness.applet.title == "FramesLoaded" }

    XCTAssertEqual(harness.posts.map(\.text), [])

    await harness.run("document.getElementById('top').click()")
    await harness.host.until("the refusal is reported") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertTrue(harness.posts[0].text.contains("made of data"), harness.posts[0].text)
    XCTAssertEqual(harness.applet.title, "FramesLoaded")
  }

  /// Catches a page's link to a local file, marked as a download, that saves it. WebKit stops a
  /// page's own `file:` link before the delegate, and the rule in the model refuses it too, so
  /// nothing is saved and no download starts.
  func testAFileLinkMarkedAsADownloadSavesNothing() async throws {
    let harness = try await BrowserHarness.make { request in
      request.path == "/other"
        ? Pages.page("Other")
        : Pages.page("Made", "<a id=f download=hosts.txt href=\"file:///etc/hosts\">f</a>")
    }
    defer { harness.stop() }

    await harness.load("/", expecting: "Made")
    await harness.run("document.getElementById('f').click()")
    await harness.load("/other", expecting: "Other")

    XCTAssertEqual(harness.files(), [])
    XCTAssertFalse(harness.applet.isRunningSomething)
    XCTAssertFalse(harness.applet.downloads.isRunning)
  }
}
