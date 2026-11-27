import AppKit
import AppletKit
import DocumentTestSupport
import SourceAccess
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// Holds the wakeups a wait asks for, so a test fires a timeout by hand and never sleeps for one.
@MainActor
final class ManualWaitClock {
  private var counter = 0
  private(set) var pending: [Int: @MainActor () -> Void] = [:]
  private(set) var delays: [Double] = []

  func schedule(
    _ seconds: Double, _ action: @escaping @MainActor () -> Void
  ) -> @MainActor () -> Void {
    counter += 1
    delays.append(seconds)

    let id = counter

    pending[id] = action

    return { [weak self] in self?.pending[id] = nil }
  }

  func fire() {
    let all = pending.sorted { $0.key < $1.key }

    pending = [:]

    for (_, action) in all { action() }
  }
}

/// The turns a dispatcher asks for, held until a test runs them.
@MainActor
final class TurnQueue {
  private var bodies: [@MainActor () -> Void] = []

  func add(_ body: @escaping @MainActor () -> Void) {
    bodies.append(body)
  }

  func run() {
    while !bodies.isEmpty {
      let now = bodies

      bodies = []

      for body in now { body() }
    }
  }
}

/// A text viewer pane behind a real dispatcher, as a remote caller reaches it. The dispatcher's
/// queue is stepped by hand and every wait on a reply is bounded, so a regression fails in seconds
/// and never hangs.
@MainActor
final class RemoteRig {
  final class Box {
    var result: Result<JSONValue, AppletCommandError>?

    /// Runs inside the reply, at the moment the dispatcher hands it over.
    var onReply: (@MainActor () -> Void)?
  }

  let applet: TextViewerApplet
  let dispatcher: ControlDispatcher
  let clock = ManualWaitClock()
  let window: NSWindow
  private let turns = TurnQueue()

  /// What the caller may read and see. A rig caller holds the whole disk by default, so the tests
  /// of a command's effect see the answers they check. The redaction tests narrow it.
  var access = ReadAccess(scope: try? ReadScope(directories: ["/"]))

  init(
    applet: TextViewerApplet = Harness.applet(), size: NSSize = NSSize(width: 800, height: 500)
  ) {
    self.applet = applet

    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.contentView = applet.content

    let turns = turns

    dispatcher = ControlDispatcher { body in turns.add(body) }
    applet.remote.scheduler = { [clock] seconds, action in clock.schedule(seconds, action) }
  }

  /// Submits a command and steps the queue until the dispatcher has delivered it.
  @discardableResult
  func send(
    _ name: String, _ arguments: JSONValue = .object([:]),
    version: AppletSchemaVersion = AppletSchemaVersion(0, 0),
    onReply: (@MainActor () -> Void)? = nil
  ) -> Box {
    let box = Box()

    box.onReply = onReply

    let submission = AppletCommandSubmission(
      appletType: TextViewerDescription.typeID, schemaVersion: version, name: name,
      arguments: arguments)

    dispatcher.submit(
      submission, to: applet, authority: { nil },
      reads: CommandReads(access: { [weak self] in self?.access ?? .none }),
      reply: { result in
        box.result = result
        box.onReply?()
      })

    turns.run()

    return box
  }

  /// A reply, or nil when none arrived in `seconds`.
  func reply(_ box: Box, seconds: Double = 10) async -> Result<JSONValue, AppletCommandError>? {
    _ = await Harness.eventually(seconds: seconds) { box.result != nil }

    return box.result
  }

  /// The handle a command answered with.
  func handle(_ box: Box, file: StaticString = #filePath, line: UInt = #line) async -> Int? {
    guard case .success(.object(let fields))? = await reply(box, seconds: 5),
      case .number(let number)? = fields["handle"]
    else {
      XCTFail(
        "the command did not answer with a handle: \(String(describing: box.result))", file: file,
        line: line)
      return nil
    }

    return Int(number)
  }

  /// The handle a command answered with, or a thrown failure.
  func requireHandle(
    _ box: Box, file: StaticString = #filePath, line: UInt = #line
  ) async throws -> Int {
    guard let handle = await handle(box, file: file, line: line) else {
      throw XCTSkip("no handle")
    }

    return handle
  }

  /// What a wait on `handle` answers, as fields.
  func waited(
    _ handle: Int, timeout: Int? = nil, file: StaticString = #filePath, line: UInt = #line
  ) async -> [String: JSONValue]? {
    var arguments: [String: JSONValue] = ["handle": .number(Double(handle))]

    if let timeout { arguments["timeout-ms"] = .number(Double(timeout)) }

    guard case .success(.object(let fields))? = await reply(send("wait", .object(arguments)))
    else {
      XCTFail("the wait did not answer", file: file, line: line)
      return nil
    }

    return fields
  }

  func state(_ handle: Int, file: StaticString = #filePath, line: UInt = #line) async -> String? {
    guard case .string(let state)? = await waited(handle, file: file, line: line)?["state"] else {
      return nil
    }

    return state
  }

  /// Shows `text` and waits until the page has rendered it.
  @discardableResult
  func show(_ text: String, file: StaticString = #filePath, line: UInt = #line) async -> Int? {
    guard
      let handle = await handle(
        send("show-markdown", .object(["text": .string(text)])), file: file, line: line)
    else { return nil }

    let state = await state(handle, file: file, line: line)

    XCTAssertEqual(state, "loaded", file: file, line: line)

    return handle
  }

  func pageText() async -> String {
    await applet.content.markdownView?.run("return document.body.innerText") as? String ?? ""
  }

  /// The failure a command answered with, or nil when it succeeded.
  func failure(_ box: Box) async -> AppletCommandError? {
    guard case .failure(let error)? = await reply(box, seconds: 5) else { return nil }

    return error
  }
}

/// The text viewer's remote commands, reached the way a controller reaches them. Each test names
/// the regression it catches.
@MainActor
final class TextViewerRemoteTests: XCTestCase {
  private func tall() -> String {
    (0..<200).map { "## Heading \($0)\n\nparagraph \($0) with some words in it.\n" }
      .joined(separator: "\n")
  }

  private func integer(_ fields: [String: JSONValue]?, _ name: String) -> Int? {
    guard case .number(let number)? = fields?[name] else { return nil }

    return Int(number)
  }

  /// The path the pane's description names, which a pane showing inline content has none of.
  private func path(of applet: TextViewerApplet) -> String? {
    try? TextViewerDescription.decode(applet.describe()).path
  }

  private func anchor(_ fields: [String: JSONValue]?) -> [String: JSONValue]? {
    guard case .object(let anchor)? = fields?["anchor"] else { return nil }

    return anchor
  }

  // MARK: Showing

  /// Catches a show that waits for the render before it answers, which ADR-11 forbids for a
  /// command with an effect, and a handle that does not end `loaded` once the page rendered.
  func testShowMarkdownAnswersAtOnceWithAHandleAndWaitReportsLoaded() async throws {
    let rig = RemoteRig(applet: Harness.applet(startDirectory: "/tmp"))

    let box = rig.send("show-markdown", .object(["text": .string("# Notes\n\nthe deadline\n")]))

    XCTAssertNotNil(box.result, "the reply did not come at once")
    XCTAssertEqual(box.result, .success(.object(["handle": .number(1)])))

    let waited = await rig.waited(1)

    XCTAssertEqual(waited, ["state": .string("loaded")])
    XCTAssertEqual(rig.applet.content.body, .markdown)

    let text = await rig.pageText()

    XCTAssertTrue(text.contains("the deadline"))
    XCTAssertEqual(rig.applet.title, "Text viewer")

    rig.applet.close()
  }

  /// Catches a wait that answers before the content loaded, one that never answers when it does,
  /// and a pending wait the dispatcher does not track.
  func testWaitPendsUntilTheLoadEnds() async throws {
    let rig = RemoteRig()

    let shown = rig.send("show-markdown", .object(["text": .string("# One\n")]))
    let handle = await rig.handle(shown)
    let waiting = rig.send("wait", .object(["handle": .number(Double(try XCTUnwrap(handle)))]))

    XCTAssertNil(waiting.result, "the wait answered before the page rendered")
    XCTAssertEqual(rig.dispatcher.pendingCount, 1)
    XCTAssertEqual(rig.applet.remote.waitCount, 1)

    let answered = await rig.reply(waiting)

    XCTAssertEqual(answered, .success(.object(["state": .string("loaded")])))
    XCTAssertEqual(rig.dispatcher.pendingCount, 0)
    XCTAssertEqual(rig.applet.remote.waitCount, 0)

    rig.applet.close()
  }

  /// Catches a wait that outlives its timeout, or one that sleeps for it in a test. The timer is
  /// the pane's injected scheduler, the cap holds, and a timed-out wait answers `pending` and
  /// leaves nothing behind.
  func testAWaitTimesOutAsPendingThroughTheInjectedClock() async throws {
    let rig = RemoteRig()

    let handle = await rig.handle(rig.send("show-markdown", .object(["text": .string("# One\n")])))
    let waiting = rig.send(
      "wait",
      .object(["handle": .number(Double(try XCTUnwrap(handle))), "timeout-ms": .number(30_000)]))

    XCTAssertNil(waiting.result)
    XCTAssertEqual(rig.clock.delays, [30])

    rig.clock.fire()

    XCTAssertEqual(waiting.result, .success(.object(["state": .string("pending")])))
    XCTAssertEqual(rig.applet.remote.waitCount, 0)
    XCTAssertEqual(rig.dispatcher.pendingCount, 0)

    let tooLong = rig.send(
      "wait", .object(["handle": .number(1), "timeout-ms": .number(30_001)]))
    let refusal = await rig.failure(tooLong)

    XCTAssertEqual(refusal?.code, .badArgument)

    rig.applet.close()
  }

  /// Catches a wait that stays pending past its settle, and a wait with no time that blocks.
  func testAWaitWithNoTimeAnswersAtOnce() async throws {
    let rig = RemoteRig()
    let handle = await rig.handle(rig.send("show-markdown", .object(["text": .string("# One\n")])))
    let waiting = rig.send(
      "wait", .object(["handle": .number(Double(try XCTUnwrap(handle))), "timeout-ms": .number(0)]))

    XCTAssertEqual(waiting.result, .success(.object(["state": .string("pending")])))
    XCTAssertEqual(rig.clock.delays, [])

    rig.applet.close()
  }

  /// Catches a handle that is not found as such: an unknown handle, and one the table dropped
  /// after the pane kept too many results.
  func testAnUnknownOrFreedHandleIsNotFound() async throws {
    let rig = RemoteRig()

    let unknown = await rig.failure(rig.send("wait", .object(["handle": .number(77)])))

    XCTAssertEqual(unknown?.code, .notFound)

    let first = await rig.show("# One\n")

    for index in 0..<RemoteHandleTable.capacity {
      let box = rig.send("show-markdown", .object(["text": .string("# \(index)\n")]))

      _ = await rig.reply(box)
    }

    let freed = await rig.failure(
      rig.send("wait", .object(["handle": .number(Double(try XCTUnwrap(first)))])))

    XCTAssertEqual(freed?.code, .notFound, "the oldest finished handle should be gone")

    rig.applet.close()
  }

  /// Catches a second show that leaves the first handle running forever, and a late first render
  /// that replaces the second text.
  func testASecondShowSupersedesTheFirst() async throws {
    let rig = RemoteRig()

    let first = await rig.handle(rig.send("show-markdown", .object(["text": .string("# Old\n")])))
    let second = await rig.handle(
      rig.send("show-markdown", .object(["text": .string("# New heading\n")])))

    let firstState = await rig.state(try XCTUnwrap(first))
    let secondState = await rig.state(try XCTUnwrap(second))

    XCTAssertEqual(firstState, "superseded")
    XCTAssertEqual(secondState, "loaded")

    let text = await rig.pageText()

    XCTAssertTrue(text.contains("New heading"))
    XCTAssertFalse(text.contains("Old"))

    rig.applet.close()
  }

  /// Catches inline notes that leave the file's path, watch, or load behind. A file load still
  /// running when the notes arrive must never replace them.
  func testShowingInlineClearsThePathStopsTheWatchAndDiscardsALateFileLoad() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("file.md", Data("# From the file\n".utf8))
    let applet = Harness.applet(startDirectory: scratch.url.path, watching: Harness.fastWatch)
    let rig = RemoteRig(applet: applet)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let settled = await Harness.eventually { applet.content.markdownView?.isRendered == true }

    XCTAssertTrue(settled)
    XCTAssertTrue(applet.isWatching)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    XCTAssertTrue(applet.isLoading, "the file load should be running")

    await rig.show("# Inline notes\n")

    XCTAssertNil(path(of: applet))
    XCTAssertFalse(applet.isWatching)
    XCTAssertFalse(applet.isLoading)
    XCTAssertEqual(applet.currentDirectory, scratch.url.path)

    try Data("# Rewritten file\n".utf8).write(to: file)

    let replaced = await Harness.eventually(seconds: 1) { path(of: applet) != nil }
    let text = await rig.pageText()

    XCTAssertFalse(replaced, "a file load or reload replaced the notes")
    XCTAssertTrue(text.contains("Inline notes"))
    XCTAssertFalse(text.contains("file"))

    applet.close()
  }

  /// Catches inline content that asks the scheme handler for a relative image. The page shows the
  /// alt text where a file's page would ask for the image.
  func testInlineContentLoadsNoRelativeResources() async throws {
    let rig = RemoteRig()

    await rig.show("![the alt text](pic.png)\n\n![](../x.png)\n")

    let view = try XCTUnwrap(rig.applet.content.markdownView)
    let count = await view.run("return document.querySelectorAll('img').length") as? Int
    let sources =
      await view.run(
        "return Array.from(document.querySelectorAll('img')).filter(i => i.hasAttribute('src')).length"
      )
      as? Int
    let alt = await view.run("return document.querySelector('img').getAttribute('alt')") as? String

    XCTAssertEqual(count, 2)
    XCTAssertEqual(sources, 0)
    XCTAssertEqual(alt, "the alt text")

    rig.applet.close()
  }

  /// Catches a cap the dispatcher does not enforce before the pane changes.
  func testTooMuchTextIsRefusedAndTheOldContentStays() async throws {
    let rig = RemoteRig()

    await rig.show("# Keep me\n")

    let limit = TextViewerLimits.maxInlineMarkdownBytes
    let over = rig.send(
      "show-markdown", .object(["text": .string(String(repeating: "a", count: limit + 1))]))
    let refusal = await rig.failure(over)

    XCTAssertEqual(refusal?.code, .badArgument)

    let text = await rig.pageText()

    XCTAssertTrue(text.contains("Keep me"))

    let exact = rig.send(
      "show-markdown", .object(["text": .string(String(repeating: "a", count: limit))]))
    let handle = await rig.handle(exact)

    XCTAssertNotNil(handle)

    rig.applet.close()
  }

  // MARK: Reload

  /// Catches a reload with no file that pretends to work, and a reload of a file that does not
  /// answer with a handle that ends `loaded`.
  func testReloadIsRefusedWithoutAFileAndLoadsWithOne() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("file.md", Data("# From the file\n".utf8))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    let empty = await rig.failure(rig.send("reload"))

    XCTAssertEqual(empty?.code, .refused)

    await rig.show("# Inline\n")

    let inline = await rig.failure(rig.send("reload"))

    XCTAssertEqual(inline?.code, .refused)

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.markdownView?.isRendered == true }

    XCTAssertTrue(opened)

    let handle = await rig.handle(rig.send("reload"))
    let state = await rig.state(try XCTUnwrap(handle))

    XCTAssertEqual(state, "loaded")

    rig.applet.close()
  }

  /// Catches a reload of a file that went away that reports success, and a reply that names the
  /// file.
  func testAFailedReloadEndsFailedWithAFixedCode() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("secret-name.md", Data("# From the file\n".utf8))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.markdownView?.isRendered == true }

    XCTAssertTrue(opened)

    try FileManager.default.removeItem(at: file)

    let handle = await rig.handle(rig.send("reload"))
    let waited = await rig.waited(try XCTUnwrap(handle))

    XCTAssertEqual(waited, ["state": .string("failed"), "code": .string("unreadable")])

    rig.applet.close()
  }

  // MARK: Busy

  /// Catches a scroll or a find that acts on a document that is still loading. Nothing changes,
  /// and the error names the load's handle so the caller can wait on it.
  func testScrollAndFindAreBusyWhileALoadRuns() async throws {
    let rig = RemoteRig()

    let handle = try await rig.requireHandle(
      (rig.send("show-markdown", .object(["text": .string(self.tall())]))))

    let scroll = rig.send(
      "scroll", .object(["anchor": .object(["kind": .string("line"), "line": .number(40)])]))
    let find = rig.send("find", .object(["query": .string("Heading")]))

    for box in [scroll, find] {
      guard case .failure(let error)? = box.result else {
        return XCTFail("the command was not refused: \(String(describing: box.result))")
      }

      XCTAssertEqual(error.code, .busy)
      XCTAssertTrue(error.message.contains("handle \(handle)"), error.message)
    }

    XCTAssertEqual(rig.applet.remote.table.entries.count, 1, "a refused command made a handle")
    XCTAssertEqual(rig.applet.finder.state.query, "")

    let state = await rig.state(handle)

    XCTAssertEqual(state, "loaded")

    let after = await rig.handle(rig.send("find", .object(["query": .string("Heading")])))

    XCTAssertNotNil(after)

    rig.applet.close()
  }

  /// Catches a scroll or a find sent to an empty pane that does something, or that is told the
  /// pane is busy when no load runs.
  func testScrollAndFindAreRefusedWithNoDocument() async throws {
    let rig = RemoteRig()

    let scroll = await rig.failure(
      rig.send(
        "scroll", .object(["anchor": .object(["kind": .string("line"), "line": .number(1)])])))
    let find = await rig.failure(rig.send("find", .object(["query": .string("x")])))

    XCTAssertEqual(scroll?.code, .refused)
    XCTAssertEqual(find?.code, .refused)

    rig.applet.close()
  }

  // MARK: Scroll

  /// Catches a Markdown scroll that lands elsewhere or reports where it was before. The page
  /// reports the landed anchor, and a heading is named by its place in the contents list.
  func testScrollMarkdownByLineAndByHeadingReportsWhereItLanded() async throws {
    let rig = RemoteRig()

    await rig.show(tall())

    let line = await rig.handle(
      rig.send(
        "scroll",
        .object(["anchor": .object(["kind": .string("line"), "line": .number(400)])])))
    let landed = await rig.waited(try XCTUnwrap(line))
    let fields = anchor(landed)

    XCTAssertEqual(landed?["state"], .string("done"))
    XCTAssertEqual(fields?["kind"], .string("line"))
    XCTAssertEqual(integer(fields, "line"), 400)

    let heading = await rig.handle(
      rig.send(
        "scroll",
        .object(["anchor": .object(["kind": .string("heading"), "heading": .number(20)])])))
    let again = await rig.waited(try XCTUnwrap(heading))
    let lineOfHeading =
      rig.applet.contents.entries.count > 20 ? integer(anchor(again), "line") : nil

    XCTAssertEqual(again?["state"], .string("done"))
    XCTAssertEqual(lineOfHeading, 80, "heading 20 starts at source line 80")

    let past = await rig.failure(
      rig.send(
        "scroll",
        .object(["anchor": .object(["kind": .string("heading"), "heading": .number(5000)])])))

    XCTAssertEqual(past?.code, .badArgument)

    rig.applet.close()
  }

  /// Catches an anchor kind that fits the wrong document, or fields that do not belong to the kind.
  func testAnAnchorThatDoesNotFitTheDocumentIsABadArgument() async throws {
    let rig = RemoteRig()

    await rig.show(tall())

    let cases: [[String: JSONValue]] = [
      ["kind": .string("page"), "page": .number(0)],
      ["kind": .string("character"), "character": .number(1)],
      ["kind": .string("line")],
      ["kind": .string("line"), "line": .number(1), "page": .number(1)],
    ]

    for anchor in cases {
      let box = rig.send("scroll", .object(["anchor": .object(anchor)]))

      guard case .failure(let error)? = box.result else {
        XCTFail("\(anchor) was accepted")
        continue
      }

      XCTAssertEqual(error.code, .badArgument, "\(anchor)")
    }

    rig.applet.close()
  }

  /// Catches a PDF scroll that lands on another page, one past the end that is accepted, and a
  /// reply that does not name the page.
  func testScrollAPDFToAPage() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write(
      "a.pdf", DocumentFixtures.pdf(pages: ["one", "two", "three", "four", "five"]))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.body == .pdf }

    XCTAssertTrue(opened)
    rig.applet.content.layoutSubtreeIfNeeded()

    let handle = await rig.handle(
      rig.send(
        "scroll", .object(["anchor": .object(["kind": .string("page"), "page": .number(3)])])))
    let landed = await rig.waited(try XCTUnwrap(handle))

    XCTAssertEqual(landed?["state"], .string("done"))
    XCTAssertEqual(anchor(landed)?["kind"], .string("page"))
    XCTAssertEqual(integer(anchor(landed), "page"), 3)

    let past = await rig.failure(
      rig.send(
        "scroll", .object(["anchor": .object(["kind": .string("page"), "page": .number(5)])])))

    XCTAssertEqual(past?.code, .badArgument)

    rig.applet.close()
  }

  /// Catches an RTF or Word scroll that ignores the character index.
  func testScrollTextToACharacter() async throws {
    let rig = RemoteRig()
    let body = (0..<400).map { "Line \($0) of the document, long enough to wrap somewhere.\n" }
      .joined()

    rig.applet.show(text: NSAttributedString(string: body), contents: .empty, anchor: nil)
    rig.applet.content.layoutSubtreeIfNeeded()

    let handle = await rig.handle(
      rig.send(
        "scroll",
        .object(["anchor": .object(["kind": .string("character"), "character": .number(9000)])])))
    let landed = await rig.waited(try XCTUnwrap(handle))
    let index = integer(anchor(landed), "character")

    XCTAssertEqual(landed?["state"], .string("done"))
    XCTAssertEqual(anchor(landed)?["kind"], .string("character"))
    XCTAssertGreaterThan(index ?? 0, 8000)
    XCTAssertLessThanOrEqual(index ?? 0, 9000)

    let past = await rig.failure(
      rig.send(
        "scroll",
        .object([
          "anchor": .object([
            "kind": .string("character"), "character": .number(Double(body.utf16.count)),
          ])
        ])))

    XCTAssertEqual(past?.code, .badArgument)

    rig.applet.close()
  }

  // MARK: Find

  /// Catches a Markdown find that drives something other than the pane's own query, reports the
  /// wrong count, ignores backward, or reports an anchor from before the match was shown.
  func testFindInMarkdownReportsCountCurrentAndAnchor() async throws {
    let rig = RemoteRig()

    await rig.show(tall())

    let forward = await rig.handle(rig.send("find", .object(["query": .string("paragraph 2")])))
    let first = await rig.waited(try XCTUnwrap(forward))

    XCTAssertEqual(first?["state"], .string("done"))
    XCTAssertEqual(integer(first, "count"), 11)
    XCTAssertEqual(integer(first, "current"), 0)
    XCTAssertEqual(first?["capped"], .bool(false))
    XCTAssertEqual(anchor(first)?["kind"], .string("line"))
    XCTAssertEqual(rig.applet.finder.state.query, "paragraph 2")
    XCTAssertEqual(rig.applet.content.findBar.query, "paragraph 2")

    let backward = await rig.handle(
      rig.send(
        "find", .object(["query": .string("paragraph 2"), "backward": .bool(true)])))
    let last = await rig.waited(try XCTUnwrap(backward))

    XCTAssertEqual(integer(last, "current"), 10)
    XCTAssertGreaterThan(
      integer(anchor(last), "line") ?? 0, integer(anchor(first), "line") ?? 0,
      "the last match lies below the first")

    let none = await rig.handle(rig.send("find", .object(["query": .string("zzzzqq")])))
    let missed = await rig.waited(try XCTUnwrap(none))

    XCTAssertEqual(integer(missed, "count"), 0)
    XCTAssertNil(missed?["current"])
    XCTAssertNil(missed?["anchor"])

    let empty = await rig.failure(rig.send("find", .object(["query": .string("")])))

    XCTAssertEqual(empty?.code, .badArgument)

    rig.applet.close()
  }

  /// Catches a find whose handle never ends when a newer find takes its place.
  func testANewerFindSupersedesTheOlderOne() async throws {
    let rig = RemoteRig()

    await rig.show(tall())

    let older = await rig.handle(rig.send("find", .object(["query": .string("paragraph")])))
    let newer = await rig.handle(rig.send("find", .object(["query": .string("Heading 1")])))

    let olderState = await rig.state(try XCTUnwrap(older))
    let newerState = await rig.state(try XCTUnwrap(newer))

    XCTAssertEqual(olderState, "superseded")
    XCTAssertEqual(newerState, "done")

    rig.applet.close()
  }

  /// Catches a text find that skips the completion, and a query cut wrong. A query past 500
  /// characters is cut, as the find bar cuts it.
  func testFindInTextCountsAndCutsTheQuery() async throws {
    let rig = RemoteRig()
    let body = String(repeating: "alpha beta gamma\n", count: 50)

    rig.applet.show(text: NSAttributedString(string: body), contents: .empty, anchor: nil)

    let handle = await rig.handle(rig.send("find", .object(["query": .string("BETA")])))
    let found = await rig.waited(try XCTUnwrap(handle))

    XCTAssertEqual(integer(found, "count"), 50)
    XCTAssertEqual(integer(found, "current"), 0)
    XCTAssertEqual(integer(anchor(found), "character"), 6)

    let long = String(repeating: "q", count: 600)
    let cut = await rig.handle(rig.send("find", .object(["query": .string(long)])))
    let none = await rig.waited(try XCTUnwrap(cut))

    XCTAssertEqual(integer(none, "count"), 0)
    XCTAssertEqual(rig.applet.finder.state.query.count, 500)

    rig.applet.close()
  }

  /// Catches a PDF find that never reports its end, so a wait would hang to its timeout.
  func testFindInAPDFReportsThePageOfTheMatch() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write(
      "a.pdf", DocumentFixtures.pdf(pages: ["alpha", "beta", "alpha again"]))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.body == .pdf }

    XCTAssertTrue(opened)

    let forward = await rig.handle(rig.send("find", .object(["query": .string("alpha")])))
    let first = await rig.waited(try XCTUnwrap(forward))

    XCTAssertEqual(first?["state"], .string("done"))
    XCTAssertEqual(integer(first, "count"), 2)
    XCTAssertEqual(integer(first, "current"), 0)
    XCTAssertEqual(integer(anchor(first), "page"), 0)

    let backward = await rig.handle(
      rig.send("find", .object(["query": .string("alpha"), "backward": .bool(true)])))
    let last = await rig.waited(try XCTUnwrap(backward))

    XCTAssertEqual(integer(last, "current"), 1)
    XCTAssertEqual(integer(anchor(last), "page"), 2)

    rig.applet.close()
  }

  /// Catches a PDF find that stops at the match cap and never reports its end. The engine cancels
  /// the search at the cap, so PDFKit's own end callback never fires and a wait would hang.
  func testAPDFFindPastTheMatchCapEndsCapped() async throws {
    let scratch = try Scratch(self)
    let page = String(repeating: "a", count: 60)
    let file = try scratch.write(
      "many.pdf", DocumentFixtures.pdf(pages: Array(repeating: page, count: 400)))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.body == .pdf }

    XCTAssertTrue(opened)

    let handle = try await rig.requireHandle(rig.send("find", .object(["query": .string("a")])))
    let found = await rig.waited(handle)

    XCTAssertEqual(found?["state"], .string("done"))
    XCTAssertEqual(found?["capped"], .bool(true))
    XCTAssertEqual(integer(found, "count"), FindMatching.maxMatches)

    rig.applet.close()
  }

  /// Catches a remote find that writes the system find pasteboard.
  func testAFindNeverTouchesTheSystemFindPasteboard() async throws {
    let rig = RemoteRig()
    let pasteboard = NSPasteboard(name: .find)
    let before = pasteboard.changeCount

    await rig.show(tall())

    let handle = await rig.handle(rig.send("find", .object(["query": .string("Heading")])))

    _ = await rig.waited(try XCTUnwrap(handle))

    XCTAssertEqual(pasteboard.changeCount, before)

    rig.applet.close()
  }

  // MARK: Redaction

  private func anotherScope(_ scratch: Scratch) throws -> ReadAccess {
    let elsewhere = scratch.url.appendingPathComponent("elsewhere")

    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

    return ReadAccess(scope: try ReadScope(directories: [elsewhere.path]))
  }

  /// Catches a find that tells a caller how many times a word occurs in, or where it sits in, a
  /// user's file outside its scope. The command still runs and the pane still moves. The wait says
  /// only that it is done, for a wait started before the find ended and for one started after.
  func testFindResultsOfAFileOutsideTheScopeCarryNoCountsOrAnchors() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("notes.md", Data("alpha beta alpha gamma alpha\n".utf8))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.markdownView?.isRendered == true }

    XCTAssertTrue(opened)

    let inside = try await rig.requireHandle(rig.send("find", .object(["query": .string("alpha")])))
    let counted = await rig.waited(inside)

    XCTAssertEqual(counted?["count"], .number(3), "a caller that holds the file sees the count")

    rig.access = try anotherScope(scratch)

    let outside = try await rig.requireHandle(
      rig.send("find", .object(["query": .string("alpha")])))
    let hidden = await rig.waited(outside)

    XCTAssertEqual(hidden, ["state": .string("done")])
    XCTAssertEqual(rig.applet.finder.state.query, "alpha", "the find itself still ran")

    let again = await rig.waited(inside)

    XCTAssertEqual(again, ["state": .string("done")], "the old handle is hidden from this caller")

    rig.applet.close()
  }

  /// Catches content the caller sent itself being hidden from it. Inline text has no file, and a
  /// file under the sent folder is the caller's own, so each is shown with no scope.
  func testInlineAndSentContentAreShownToTheCallerThatSentThem() async throws {
    let scratch = try Scratch(self)
    let sent = scratch.url.appendingPathComponent("sent")

    try FileManager.default.createDirectory(at: sent, withIntermediateDirectories: true)

    let file = try scratch.write("sent/x.md", Data("one two one\n".utf8))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    rig.access = ReadAccess(scope: nil, controllerSentRoot: sent.path)
    try rig.applet.replaceSource(with: file, startDirectory: sent.path)

    let opened = await Harness.eventually { rig.applet.content.markdownView?.isRendered == true }

    XCTAssertTrue(opened)

    let found = try await rig.requireHandle(rig.send("find", .object(["query": .string("one")])))

    let sentSeen = await rig.waited(found)

    XCTAssertEqual(sentSeen?["count"], .number(2))

    rig.access = .none
    await rig.show("# inline\n\nbody body\n")

    let inline = try await rig.requireHandle(rig.send("find", .object(["query": .string("body")])))

    let inlineSeen = await rig.waited(inline)

    XCTAssertEqual(inlineSeen?["count"], .number(2), "inline text is no user's file")

    rig.applet.close()
  }

  /// Catches a reload whose reply says why it failed: a file gone and a file over the cap must
  /// look the same to a caller outside the scope, while the caller that holds it hears the code.
  func testAReloadOfAFileOutsideTheScopeFailsWithOneCode() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("gone.md", Data("text\n".utf8))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.markdownView?.isRendered == true }

    XCTAssertTrue(opened)

    try FileManager.default.removeItem(at: file)

    let reload = try await rig.requireHandle(rig.send("reload"))
    let ended = await Harness.eventually {
      rig.applet.remote.table.entry(reload)?.isSettled == true
    }

    XCTAssertTrue(ended)

    let seen = await rig.waited(reload)

    XCTAssertEqual(seen?["state"], .string("failed"))

    rig.access = try anotherScope(scratch)

    let hiddenSeen = await rig.waited(reload)

    XCTAssertEqual(hiddenSeen, ["state": .string("failed"), "code": .string("unreadable")])

    rig.applet.close()
  }

  /// Catches a scroll that measures a file outside the scope. An anchor past the end answers as one
  /// that fits, so the caller cannot find the file's length by trying.
  func testAScrollPastTheEndOfAFileOutsideTheScopeAnswersAsAFit() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("two.pdf", DocumentFixtures.pdf(pages: ["one", "two"]))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.body == .pdf }

    XCTAssertTrue(opened)

    let past = JSONValue.object([
      "anchor": .object([
        "kind": .string("page"), "page": .number(50), "x": .number(0), "y": .number(0),
      ])
    ])

    let refused = await rig.failure(rig.send("scroll", past))

    XCTAssertEqual(refused?.code, .badArgument, "a caller that holds the file is told")

    rig.access = try anotherScope(scratch)

    let handle = await rig.handle(rig.send("scroll", past))

    XCTAssertNotNil(handle, "a caller outside the scope is not")

    rig.applet.close()
  }

  // MARK: Ordering

  /// Catches a load handle that ends before the contents list is in place. The page reports its
  /// headings in the same message as its render, and the pane installs them afterward. A command
  /// sent on seeing `loaded` runs in a later turn, but a wait's reply is handed over inside the
  /// settle, so the contents are checked at that moment. A heading scroll on `loaded` must find
  /// the list.
  func testAMarkdownLoadEndsOnlyOnceItsContentsAreInPlace() async throws {
    let rig = RemoteRig()
    let handle = try await rig.requireHandle(
      rig.send("show-markdown", .object(["text": .string(tall())])))
    var seen = -1
    var sidebarReady = false

    let waiting = rig.send(
      "wait", .object(["handle": .number(Double(handle))]),
      onReply: { [applet = rig.applet] in
        seen = applet.contents.entries.count
        sidebarReady = applet.content.sidebar.isReady
      })

    _ = await rig.reply(waiting)

    XCTAssertEqual(seen, 200, "the load ended before the headings were installed")
    XCTAssertTrue(sidebarReady)

    let past = rig.send(
      "scroll", .object(["anchor": .object(["kind": .string("heading"), "heading": .number(200)])]))

    guard case .failure(let error)? = past.result else { return XCTFail("a heading past the end") }

    XCTAssertEqual(error.code, .badArgument)

    rig.applet.close()
  }

  /// Catches the same early end for a text document, whose contents come with the load.
  func testATextLoadEndsOnlyOnceItsContentsAreInPlace() async throws {
    let rig = RemoteRig()
    let handle = try XCTUnwrap(rig.applet.remote.begin(.load))
    var seen = -1

    let waiting = rig.send(
      "wait", .object(["handle": .number(Double(handle))]),
      onReply: { [applet = rig.applet] in seen = applet.contents.entries.count })

    XCTAssertNil(waiting.result)

    let found = Contents(entries: [
      ContentsEntry(level: 1, title: "One", target: .text(characterIndex: 0)),
      ContentsEntry(level: 1, title: "Two", target: .text(characterIndex: 4)),
    ])

    rig.applet.show(text: NSAttributedString(string: "one\ntwo\n"), contents: found, anchor: nil)

    XCTAssertEqual(seen, 2, "the load ended before the contents were installed")

    rig.applet.close()
  }

  // MARK: Focus

  private final class FocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
  }

  /// Catches a remote command that moves keyboard focus into the pane. A program's change never
  /// takes the keyboard from where the user left it, so the first responder stays on a probe
  /// outside the viewer's body through a show, a scroll, and a find in Markdown, a PDF, and text.
  func testRemoteCommandsNeverMoveKeyboardFocus() async throws {
    let scratch = try Scratch(self)
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))
    let probe = FocusProbe(frame: NSRect(x: 0, y: 0, width: 10, height: 10))

    rig.applet.content.addSubview(probe)
    XCTAssertTrue(rig.window.makeFirstResponder(probe))

    await rig.show(tall())

    let scrolled = try await rig.requireHandle(
      rig.send(
        "scroll", .object(["anchor": .object(["kind": .string("heading"), "heading": .number(3)])]))
    )
    _ = await rig.waited(scrolled)

    let found = try await rig.requireHandle(rig.send("find", .object(["query": .string("body")])))
    let result = await rig.waited(found)

    XCTAssertEqual(result?["state"], .string("done"))
    XCTAssertTrue(rig.window.firstResponder === probe, "markdown moved focus")

    rig.applet.show(
      text: NSAttributedString(string: String(repeating: "alpha\n", count: 50)), contents: .empty,
      anchor: nil)

    let text = try await rig.requireHandle(rig.send("find", .object(["query": .string("alpha")])))
    _ = await rig.waited(text)

    XCTAssertTrue(rig.window.firstResponder === probe, "text moved focus")

    let file = try scratch.write("a.pdf", DocumentFixtures.pdf(pages: ["alpha", "beta alpha"]))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.body == .pdf }

    XCTAssertTrue(opened)

    let pdf = try await rig.requireHandle(rig.send("find", .object(["query": .string("alpha")])))
    _ = await rig.waited(pdf)

    XCTAssertTrue(rig.window.firstResponder === probe, "pdf moved focus")

    rig.applet.close()
  }

  // MARK: Replies

  /// Catches a reply that leaks what the schema promises it never carries: the document's text, a
  /// heading, the query, or a path. Every reply the commands give is scanned.
  func testNoReplyCarriesDocumentTextTheQueryOrAPath() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("quiet-file-name.md", Data("# Zebra heading\n".utf8))
    let rig = RemoteRig(applet: Harness.applet(startDirectory: scratch.url.path))
    var replies: [String] = []

    func record(_ box: RemoteRig.Box) async {
      if let result = await rig.reply(box), let data = try? JSONEncoder().encode(Wrapped(result)) {
        replies.append(String(decoding: data, as: UTF8.self))
      }
    }

    let text = "# Zebra secret heading\n\nZEBRA-BODY text\n"
    let show = rig.send("show-markdown", .object(["text": .string(text)]))

    await record(show)

    let shown = try await rig.requireHandle((show))

    await record(rig.send("wait", .object(["handle": .number(Double(shown))])))
    await record(
      rig.send(
        "scroll", .object(["anchor": .object(["kind": .string("heading"), "heading": .number(0)])]))
    )

    let find = rig.send("find", .object(["query": .string("ZEBRA-BODY")]))

    await record(find)
    let found = try await rig.requireHandle(find)

    await record(rig.send("wait", .object(["handle": .number(Double(found))])))

    try rig.applet.replaceSource(with: file, startDirectory: scratch.url.path)

    let opened = await Harness.eventually { rig.applet.content.markdownView?.isRendered == true }

    XCTAssertTrue(opened)

    try FileManager.default.removeItem(at: file)

    let reload = rig.send("reload")

    await record(reload)
    let reloaded = try await rig.requireHandle(reload)

    await record(rig.send("wait", .object(["handle": .number(Double(reloaded))])))
    await record(rig.send("reload"))
    await record(rig.send("wait", .object(["handle": .number(999)])))

    XCTAssertGreaterThanOrEqual(replies.count, 8)

    for reply in replies {
      for secret in ["ZEBRA", "Zebra", "zebra", "quiet-file-name", scratch.url.path, "secret"] {
        XCTAssertFalse(reply.contains(secret), "\(reply) holds \(secret)")
      }
    }

    rig.applet.close()
  }

  private struct Wrapped: Encodable {
    let result: Result<JSONValue, AppletCommandError>

    init(_ result: Result<JSONValue, AppletCommandError>) {
      self.result = result
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()

      switch result {
      case .success(let value): try container.encode(value)
      case .failure(let error): try container.encode("\(error.code.rawValue): \(error.message)")
      }
    }
  }

  // MARK: Versions

  /// Catches a command naming a version the viewer does not speak that takes effect. The viewer is
  /// at 0.0, so 0.0 works. A caller written for 1.0 before the reset, a minor above 0.0, and 2.0
  /// are refused with nothing changed.
  func testOnlyVersionZeroReachesTheViewer() async throws {
    let rig = RemoteRig()

    for version in [
      AppletSchemaVersion(1, 0), AppletSchemaVersion(0, 1), AppletSchemaVersion(2, 0),
    ] {
      let box = rig.send(
        "show-markdown", .object(["text": .string("# no\n")]), version: version)
      let error = await rig.failure(box)

      XCTAssertEqual(error?.code, .unsupportedVersion, "\(version)")
    }

    XCTAssertNil(rig.applet.content.markdownView)
    XCTAssertTrue(rig.applet.remote.table.entries.isEmpty)

    let works = rig.send("show-markdown", .object(["text": .string("# yes\n")]))

    XCTAssertNotNil(works.result)

    rig.applet.close()
  }

  // MARK: Close

  /// Catches a wait that survives its pane, a handle that outlives it, and an event outlet left
  /// open. The failed wait tells the caller nothing ran.
  func testClosingThePaneFailsPendingWaitsAndFreesHandles() async throws {
    let rig = RemoteRig()
    let handle = try await rig.requireHandle(
      (rig.send("show-markdown", .object(["text": .string("# One\n")]))))
    let waiting = rig.send("wait", .object(["handle": .number(Double(handle))]))

    XCTAssertNil(waiting.result)

    rig.applet.close()

    guard case .failure(let error)? = waiting.result else {
      return XCTFail("the wait was not failed at close")
    }

    XCTAssertEqual(error.code, .notFound)
    XCTAssertEqual(rig.applet.remote.waitCount, 0)
    XCTAssertTrue(rig.applet.remote.table.entries.isEmpty)
    XCTAssertTrue(rig.applet.events.isClosed)
    XCTAssertEqual(rig.dispatcher.pendingCount, 0)
    XCTAssertTrue(rig.clock.pending.isEmpty)

    let after = rig.send("show-markdown", .object(["text": .string("# late\n")]))

    guard case .failure(let late)? = after.result else {
      return XCTFail("a closed pane took a command")
    }

    XCTAssertEqual(late.code, .notFound)
  }

  // MARK: Description

  /// Catches inline text in a layout, a description that re-encodes the text at every call, and a
  /// payload version that an older build would misread. The flag makes a version 2 payload, and a
  /// description without it stays at version 1.
  func testInlineContentDescribesAFlagAndKeepsTheTextOnlyInTheUndoPart() async throws {
    let rig = RemoteRig(applet: Harness.applet(startDirectory: "/tmp"))

    let plain = rig.applet.describe()

    XCTAssertEqual(plain.version, 1)

    await rig.show("# Notes ZEBRA\n")

    let first = rig.applet.describe()
    let second = rig.applet.describe()

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.version, 2)

    let decoded = try TextViewerDescription.decode(first)

    XCTAssertTrue(decoded.inlineContent)
    XCTAssertNil(decoded.path)

    let layout = try JSONEncoder().encode(first)

    XCTAssertFalse(String(decoding: layout, as: UTF8.self).contains("ZEBRA"))
    XCTAssertNil(first.withoutUndoState.undoState)
    XCTAssertNotNil(first.undoState)

    await rig.show("# Another\n")

    XCTAssertNotEqual(rig.applet.describe().undoState, first.undoState)

    rig.applet.close()
  }

  /// Catches a pane restored from an undo description that has not started yet, whose own
  /// description then drops the notes, so a second reopen would find none.
  func testAnUnstartedRestoredPaneStillDescribesItsNotes() async throws {
    let rig = RemoteRig(applet: Harness.applet(startDirectory: "/tmp"))

    await rig.show("# Notes to keep\n")

    let described = rig.applet.describe()

    rig.applet.close()

    let restored = try Harness.restoredDescription(described)

    XCTAssertEqual(restored.describe().undoState, described.undoState)
    XCTAssertEqual(restored.describe().version, 2)

    restored.close()
  }

  /// Catches a reopen within the launch that loses the notes, and a relaunch that pretends to
  /// have them. The undo part brings the text back. A layout file has none, so the pane says
  /// the content was not restored.
  func testReopenBringsTheNotesBackAndARelaunchSaysItCouldNot() async throws {
    let rig = RemoteRig(applet: Harness.applet(startDirectory: "/tmp"))

    await rig.show("# Notes to keep\n")

    let described = rig.applet.describe()

    rig.applet.close()

    let reopened = try Harness.restoredDescription(described)
    let again = RemoteRig(applet: reopened)

    reopened.start(origin: .user)

    let rendered = await Harness.eventually { reopened.content.markdownView?.isRendered == true }
    let text = await again.pageText()

    XCTAssertTrue(rendered)
    XCTAssertTrue(text.contains("Notes to keep"))
    XCTAssertNil(path(of: reopened))
    XCTAssertEqual(reopened.currentDirectory, "/tmp")

    reopened.close()

    let relaunched = try Harness.restoredDescription(described.withoutUndoState)

    relaunched.start(origin: .restore)

    XCTAssertEqual(relaunched.messageText, TextViewerApplet.inlineNotRestoredText)
    XCTAssertEqual(Harness.message(relaunched), TextViewerApplet.inlineNotRestoredText)
    XCTAssertNil(relaunched.content.markdownView)

    relaunched.close()
  }
}
