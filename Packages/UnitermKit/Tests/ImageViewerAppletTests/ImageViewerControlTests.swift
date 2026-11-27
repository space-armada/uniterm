import AppKit
import AppletKit
import AppletTestSupport
import ImageTestSupport
import ImageViewerModel
import SourceAccess
import XCTest

@testable import ImageViewerApplet

/// Collects the events a pane emits, as an exec driver's channel would receive them.
@MainActor
private final class EventRecorder: AppletEventSink {
  private(set) var events: [(name: String, data: JSONValue)] = []

  func deliver(event name: String, data: JSONValue) { events.append((name, data)) }

  func outletClosed() {}
}

extension JSONValue {
  fileprivate var doubleValue: Double? {
    if case .number(let number) = self { return number }

    return nil
  }

  fileprivate var intValue: Int? { doubleValue.map { Int($0) } }
}

/// One command sent through shared dispatch. The reply lands in `result`, at once or later.
@MainActor
private final class Call {
  var result: Result<JSONValue, AppletCommandError>?

  var fields: [String: JSONValue] {
    if case .success(.object(let fields))? = result { return fields }

    return [:]
  }

  var handle: Int? { fields["handle"]?.intValue }
}

/// The image viewer's control commands, sent through the dispatcher a window uses and run against
/// a real helper. The folder holds three images, a text file, and a link to an image outside it.
///
/// The scope of the controllers here is the folder. The package's other tests prove the scoped
/// open itself. These prove what the pane tells a controller, and what it never does.
@MainActor
final class ImageViewerControlTests: XCTestCase {
  private var folder: URL!
  private var outside: URL!
  private var panes: PaneFactory!
  private var scope: ReadScope!

  /// A folder of three images and nothing else, inside a scope that holds the whole fixture.
  private var plain: URL!
  private var wide: ReadScope!
  private var turns: [@MainActor () -> Void] = []
  private var dispatcher: ControlDispatcher!

  override func setUp() async throws {
    // A scope is compared as written, and the pane reports real paths, so the fixture is real too.
    let made = try ImageFixtures.makeFolder("scope")

    folder = URL(
      fileURLWithPath: try XCTUnwrap(realpath(made.path, nil).map { String(cString: $0) }))
    panes = PaneFactory(folder: folder)

    let root = folder.deletingLastPathComponent()

    outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    for name in ["a.png", "b.png", "c.png"] {
      try ImageFixtures.write(ImageFixtures.png(width: 64, height: 32), named: name, in: folder)
    }

    try ImageFixtures.write(ImageFixtures.png(width: 40, height: 40), named: "o.png", in: outside)
    try Data("not an image".utf8).write(to: folder.appendingPathComponent("notes.txt"))
    try FileManager.default.createSymbolicLink(
      atPath: folder.appendingPathComponent("link.png").path,
      withDestinationPath: outside.appendingPathComponent("o.png").path)

    scope = try ReadScope(directories: [folder.path])

    plain = root.appendingPathComponent("plain", isDirectory: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

    for name in ["a.png", "b.png", "c.png"] {
      try ImageFixtures.write(ImageFixtures.png(width: 64, height: 32), named: name, in: plain)
    }

    wide = try ReadScope(directories: [root.path])
    dispatcher = ControlDispatcher { [weak self] body in self?.turns.append(body) }
  }

  override func tearDown() async throws {
    panes.closeAll()

    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  // MARK: Support

  private func path(_ name: String) -> String { folder.appendingPathComponent(name).path }

  private func send(
    _ name: String, _ arguments: [String: JSONValue] = [:], to applet: ImageViewerApplet,
    scope given: ReadScope?? = nil, version: AppletSchemaVersion = AppletSchemaVersion(1, 0)
  ) -> Call {
    let call = Call()
    let granted = given ?? scope
    let submission = AppletCommandSubmission(
      appletType: ImageViewerDescription.typeID, schemaVersion: version, name: name,
      arguments: .object(arguments))
    var opened: [String: Result<OpenedPath, ScopedOpenError>] = [:]

    for (argument, path) in dispatcher.pathArguments(of: submission, for: applet) {
      opened[argument] =
        granted.map { ScopedOpen.open(path: path, in: $0) } ?? .failure(.unavailable)
    }

    dispatcher.submit(
      submission, to: applet, authority: { nil },
      reads: CommandReads(opened: opened, access: { ReadAccess(scope: granted) }),
      reply: { call.result = $0 })

    let bodies = turns
    turns = []

    for body in bodies { body() }

    return call
  }

  private func settled(_ call: Call) async {
    let done = await Harness.eventually { call.result != nil }

    XCTAssertTrue(done, "the command never answered")
  }

  /// Sends a command with an effect and waits on its handle.
  private func run(
    _ name: String, _ arguments: [String: JSONValue] = [:], to applet: ImageViewerApplet,
    scope given: ReadScope?? = nil
  ) async throws -> [String: JSONValue] {
    let started = send(name, arguments, to: applet, scope: given)

    guard case .success? = started.result, let handle = started.handle else {
      XCTFail("\(name) was refused: \(String(describing: started.result))")
      return [:]
    }

    let waited = send(
      "wait", ["handle": .number(Double(handle)), "timeout-ms": .number(20_000)], to: applet,
      scope: given)

    await settled(waited)

    return waited.fields
  }

  private func pane(scanPace: ScanPace = ScanPace()) -> (ImageViewerApplet, RecordingHost) {
    panes.make(scanPace: scanPace)
  }

  private func listed(_ applet: ImageViewerApplet) async {
    let complete = await Harness.eventually { applet.listing.isComplete }

    XCTAssertTrue(complete)
  }

  // MARK: Show

  /// Catches a show that never reaches the pane, or a wait that answers with something other than
  /// what is on screen. A file in the scope shows, and its siblings are listed beside it.
  func testShowingAFileInTheScopeAnswersWithItsPathIndexAndCount() async throws {
    let (applet, _) = pane()

    _ = try await run("show", ["path": .string(path("b.png"))], to: applet)
    await listed(applet)

    let again = try await run("show", ["path": .string(path("b.png"))], to: applet)

    XCTAssertEqual(again["state"], .string("shown"))
    XCTAssertEqual(again["path"], .string(path("b.png")))
    XCTAssertEqual(again["outside-scope"], .bool(false))
    XCTAssertEqual(applet.committedName, "b.png")
  }

  /// Catches a folder show that lands on the wrong image, or that mislabels the listing. The folder
  /// shows its first image, and the count names the listed images once the scan ends.
  func testShowingAFolderShowsItsFirstImageAndReportsTheListing() async throws {
    let (applet, _) = pane()

    _ = try await run("show", ["path": .string(folder.path)], to: applet)
    await listed(applet)

    let next = try await run("first", to: applet)

    XCTAssertEqual(next["path"], .string(path("a.png")))
    XCTAssertEqual(next["index"], .number(0))
    XCTAssertEqual(next["count"], .number(4), "three images and a link, and no text file")
    XCTAssertEqual(next["partial"], .bool(false))
  }

  /// Catches a path that was not checked against the scope, or a refusal that tells causes apart. A
  /// file outside, a missing one, a link out, and a relative path in the scope all fail before
  /// any effect, and the first three read alike.
  func testAPathOutsideTheScopeOrRelativeIsRefusedAndChangesNothing() {
    let (applet, _) = pane()
    var refusals: [AppletCommandError] = []

    for named in [
      outside.appendingPathComponent("o.png").path, outside.appendingPathComponent("no.png").path,
      path("link.png"), "/etc/hosts",
    ] {
      let call = send("show", ["path": .string(named)], to: applet)

      guard case .failure(let error)? = call.result else {
        return XCTFail("\(named) was not refused")
      }

      refusals.append(error)
    }

    XCTAssertEqual(Set(refusals.map(\.message)).count, 1, "\(refusals)")
    XCTAssertEqual(refusals.first, ControlDispatcher.unreadable)

    let relative = send("show", ["path": .string("a.png")], to: applet)

    guard case .failure(let error)? = relative.result else { return XCTFail("a relative path ran") }

    XCTAssertEqual(error.code, .badArgument)
    XCTAssertEqual(applet.phase, .empty)
    XCTAssertEqual(applet.remote.table.entries.count, 0)
  }

  /// Catches a file in the scope that is not an image reading as the one outside-scope error, or
  /// opening. Inside the scope it keeps its own cause.
  func testAFileInTheScopeThatIsNotAnImageFailsWithItsOwnCode() async throws {
    let (applet, _) = pane()
    let reply = try await run("show", ["path": .string(path("notes.txt"))], to: applet)

    XCTAssertEqual(reply["state"], .string("failed"))
    XCTAssertEqual(reply["code"], .string("not-an-image"))
  }

  /// Catches a folder with no image, shown to a controller, reading as a success.
  func testAFolderWithNoImageFailsWithItsOwnCode() async throws {
    let empty = outside.appendingPathComponent("empty", isDirectory: true)

    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

    let (applet, _) = pane()
    let wide = try ReadScope(directories: [outside.path])
    let reply = try await run("show", ["path": .string(empty.path)], to: applet, scope: wide)

    XCTAssertEqual(reply["code"], .string("no-images"))
  }

  /// Catches the entry point forking. A user's open replaces what a controller showed, the
  /// controller's step works on that source in its scope, and a controller's show replaces the
  /// user's source. Both reach one load.
  func testAUsersOpenAndAControllersShowShareOneLoadPath() async throws {
    let (applet, _) = pane()

    try applet.replaceSource(
      with: folder.appendingPathComponent("a.png"), startDirectory: folder.path)

    let opened = await Harness.eventually { applet.committedName == "a.png" }
    XCTAssertTrue(opened)
    await listed(applet)

    let stepped = try await run("next", to: applet)

    XCTAssertEqual(stepped["path"], .string(path("b.png")))

    let shown = send("show", ["path": .string(path("c.png"))], to: applet)
    let handle = try XCTUnwrap(shown.handle)

    try applet.replaceSource(
      with: folder.appendingPathComponent("a.png"), startDirectory: folder.path)

    let waited = send("wait", ["handle": .number(Double(handle))], to: applet)

    await settled(waited)

    XCTAssertEqual(waited.fields["state"], .string("superseded"), "a new load replaces the wait")
  }

  /// Catches a pane a controller filled that stores more than a path. The description names the real
  /// path of what was shown, like any pane, and restores with no grant.
  func testAPaneAControllerFilledDescribesTheRealPathOnly() async throws {
    let (applet, _) = pane()

    _ = try await run("show", ["path": .string(folder.path)], to: applet)

    let record = try ImageViewerDescription.decode(applet.describe())

    XCTAssertEqual(record.path, folder.path)
    XCTAssertEqual(record.kind, .folder)
  }

  // MARK: Stepping

  /// Catches stepping that cannot reach every image, or that errors at an end. Next and previous
  /// move through the order, first and last jump, and a step past either end answers with the image
  /// on screen.
  func testSteppingMovesThroughTheFolderAndAnswersWithTheCurrentImageAtEachEnd() async throws {
    let (applet, _) = pane()

    _ = try await run("show", ["path": .string(plain.path)], to: applet, scope: wide)
    await listed(applet)

    func image(_ name: String) -> JSONValue { .string(plain.appendingPathComponent(name).path) }

    var reply = try await run("next", to: applet, scope: wide)
    XCTAssertEqual(reply["path"], image("b.png"))

    reply = try await run("previous", to: applet, scope: wide)
    XCTAssertEqual(reply["path"], image("a.png"))

    reply = try await run("previous", to: applet, scope: wide)
    XCTAssertEqual(reply["path"], image("a.png"), "the first image stays")
    XCTAssertEqual(reply["index"], .number(0))

    reply = try await run("last", to: applet, scope: wide)
    XCTAssertEqual(reply["path"], image("c.png"))
    XCTAssertEqual(reply["index"], .number(2))

    reply = try await run("next", to: applet, scope: wide)
    XCTAssertEqual(reply["path"], image("c.png"), "the last image stays")
    XCTAssertEqual(reply["state"], .string("shown"))

    reply = try await run("first", to: applet, scope: wide)
    XCTAssertEqual(reply["path"], image("a.png"))
    XCTAssertEqual(reply["count"], .number(3))
  }

  /// Catches a count that claims to be final while the folder still lists. The scan is held after
  /// its first batch, the reply says partial, and the flag clears once the scan ends.
  func testTheCountIsPartialWhileTheFolderIsStillListing() async throws {
    let gate = OpenGate()
    let (applet, _) = pane(
      scanPace: ScanPace(
        batchSize: 1,
        beforeBatch: { batch in
          if batch == 1 {
            let done = DispatchSemaphore(value: 0)

            Task {
              await gate.wait()
              done.signal()
            }

            done.wait()
          }
        }))

    let held = try await run("show", ["path": .string(plain.path)], to: applet, scope: wide)

    XCTAssertEqual(held["partial"], .bool(true), "\(held)")

    await gate.release()
    await listed(applet)

    let later = try await run("first", to: applet, scope: wide)

    XCTAssertEqual(later["partial"], .bool(false))
    XCTAssertEqual(later["count"], .number(3))
  }

  // MARK: Scope

  /// Catches a step that tells a controller what a folder it may not read holds. The user opened a
  /// folder outside the controller's scope, so every stepping command is refused with the scope
  /// error, and a handle another controller made reads as outside the scope with no path, index, or
  /// count.
  func testAUserOpenedSourceOutsideTheScopeRefusesSteppingAndHidesWhatItShows() async throws {
    let other = outside.appendingPathComponent("more", isDirectory: true)

    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try ImageFixtures.write(ImageFixtures.png(), named: "x.png", in: other)
    try ImageFixtures.write(ImageFixtures.png(), named: "y.png", in: other)

    let (applet, _) = pane()
    let mine = send("show", ["path": .string(path("a.png"))], to: applet)
    let handle = try XCTUnwrap(mine.handle)

    try applet.replaceSource(with: other, startDirectory: other.path)

    let shown = await Harness.eventually { applet.committedName == "x.png" }
    XCTAssertTrue(shown)
    await listed(applet)

    for step in ["next", "previous", "first", "last"] {
      let call = send(step, to: applet)

      XCTAssertEqual(call.result, .failure(ControlDispatcher.unreadable), step)
    }

    let outsiderOnly = try ReadScope(directories: [outside.path])
    let wide = send("wait", ["handle": .number(Double(handle))], to: applet, scope: outsiderOnly)

    await settled(wide)

    XCTAssertEqual(wide.fields["state"], .string("superseded"))

    let user = send("zoom", ["to": .string("fit")], to: applet)
    let zoomed = try XCTUnwrap(user.handle)
    let waited = send(
      "wait", ["handle": .number(Double(zoomed)), "timeout-ms": .number(20_000)], to: applet)

    await settled(waited)

    XCTAssertEqual(waited.fields["state"], .string("done"), "zoom stays a pane command")
    XCTAssertNil(waited.fields["path"])
  }

  /// Catches the outside-scope reply carrying anything but the fact. A controller shows an image in
  /// its scope, and a second controller whose scope holds none of it waits on that handle.
  func testAHandleReadByACallerOutsideItsScopeCarriesNoPathIndexOrCount() async throws {
    let (applet, _) = pane()
    let started = send("show", ["path": .string(path("a.png"))], to: applet)
    let handle = try XCTUnwrap(started.handle)
    let elsewhere = try ReadScope(directories: [outside.path])
    let waited = send(
      "wait", ["handle": .number(Double(handle)), "timeout-ms": .number(20_000)], to: applet,
      scope: elsewhere)

    await settled(waited)

    XCTAssertEqual(
      waited.fields, ["state": .string("shown"), "outside-scope": .bool(true)])
  }

  /// Catches a symlink in an in-scope folder that a user opened reaching a controller. Stepping to
  /// the link shows its image to the user, and the controller learns only that it is outside the
  /// scope, while the images beside it report their paths.
  func testALinkOutOfTheScopeInAFolderTheUserOpenedWithholdsPathIndexAndCount() async throws {
    let (applet, _) = pane()

    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let shown = await Harness.eventually { applet.committedName == "a.png" }
    XCTAssertTrue(shown)
    await listed(applet)

    let link = try await run("last", to: applet)

    XCTAssertEqual(link, ["state": .string("shown"), "outside-scope": .bool(true)])
    XCTAssertEqual(applet.committedName, "link.png", "the user sees the image")

    let back = try await run("previous", to: applet)

    XCTAssertEqual(back["path"], .string(path("c.png")))
  }

  /// Catches a folder a controller opened handing a symlinked member out of the scope to the
  /// pane. Members open through the scope, so the link is skipped like a deleted file, and nothing
  /// from outside is ever shown or told.
  func testAFolderAControllerOpenedNeverOpensALinkedMemberOutsideItsScope() async throws {
    let (applet, host) = pane()

    _ = try await run("show", ["path": .string(folder.path)], to: applet)
    await listed(applet)

    let reply = try await run("last", to: applet)

    XCTAssertNotEqual(applet.committedName, "link.png")
    XCTAssertEqual(reply["state"], .string("superseded"), "the skipped step shows nothing")
    XCTAssertFalse("\(reply)".contains("outside"), "\(reply)")
    XCTAssertNotEqual(reply["path"], .string(outside.appendingPathComponent("o.png").path))
    XCTAssertTrue(host.sent.contains { $0.text.contains("link.png") }, "the skip was said")
  }

  // MARK: Events

  /// Catches an exec driver learning a path, an index, or a count. The pane holds no scope for a
  /// driver, so every `shown` says only that the image is outside the scope, and each event fits
  /// the schema.
  func testADriversShownEventsCarryOnlyTheOutsideScopeFlag() async throws {
    let (applet, _) = pane()
    let recorder = EventRecorder()

    XCTAssertTrue(applet.events.connect(recorder))

    _ = try await run("show", ["path": .string(folder.path)], to: applet)
    await listed(applet)
    _ = try await run("next", to: applet)

    XCTAssertGreaterThanOrEqual(recorder.events.count, 2)

    let declared = try XCTUnwrap(applet.commandSchema.event(named: "shown"))

    for event in recorder.events {
      XCTAssertEqual(event.name, "shown")
      XCTAssertEqual(event.data, .object(["outside-scope": .bool(true)]))

      guard case .object(let fields) = event.data else { return XCTFail("not an object") }

      XCTAssertNoThrow(try declared.arguments.validate(fields, at: "the event"))
    }
  }

  /// Catches a driver flooded with identical events. Its payload never carries the count, so a
  /// listing that grows batch by batch sends nothing after the image's own event, and the next
  /// image sends one more.
  func testADriverGetsOneShownPerImageWhileTheCountGrows() async throws {
    let gate = OpenGate()
    let (applet, _) = pane(
      scanPace: ScanPace(
        batchSize: 1,
        beforeBatch: { batch in
          if batch == 1 {
            let done = DispatchSemaphore(value: 0)

            Task {
              await gate.wait()
              done.signal()
            }

            done.wait()
          }
        }))
    let recorder = EventRecorder()

    applet.events.connect(recorder)

    _ = try await run("show", ["path": .string(plain.path)], to: applet, scope: wide)

    let before = recorder.events.count

    XCTAssertEqual(before, 1)

    await gate.release()
    await listed(applet)

    XCTAssertEqual(recorder.events.count, before, "the count grew and the payload did not")

    _ = try await run("next", to: applet, scope: wide)

    XCTAssertEqual(recorder.events.count, before + 1)
  }

  /// Catches a driver that attaches mid-session hearing nothing until the image changes. The outlet
  /// tells the pane a sink arrived, and the pane sends the image on screen once.
  func testADriverThatAttachesLaterGetsTheImageOnScreen() async throws {
    let (applet, _) = pane()

    _ = try await run("show", ["path": .string(plain.path)], to: applet, scope: wide)

    XCTAssertNil(applet.lastEmitted, "with no driver and no waiting command nothing is built")

    let recorder = EventRecorder()

    applet.events.connect(recorder)
    XCTAssertTrue(recorder.events.isEmpty)

    applet.events.sinkAttached(recorder)

    XCTAssertEqual(recorder.events.count, 1)
    XCTAssertEqual(recorder.events.first?.data, .object(["outside-scope": .bool(true)]))
  }

  // MARK: Zoom

  /// Shows a 1200 by 800 image. Its fit-size backdrop is 600 by 400.
  ///
  /// The fixture folder holds three small neighbors, and the pane prefetches them in the
  /// background, so the budget a test sees depends on how many have landed. `alone` puts the image
  /// in a folder of its own, for a test that counts the budget's bytes.
  private func large(_ applet: ImageViewerApplet, alone: Bool = false) async throws {
    var home: URL = folder

    if alone {
      home = folder.appendingPathComponent("alone", isDirectory: true)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    let url = try ImageFixtures.write(
      ImageFixtures.png(width: 1200, height: 800), named: "big.png", in: home)

    applet.content.backingScaleSource = { 2 }
    _ = try await run("show", ["path": .string(url.path)], to: applet)
  }

  /// Catches a zoom command that does nothing, or a reply that settles before the pane shows
  /// detail. Zoom takes a multiple of actual size or fit, and its reply names what the pane holds.
  func testZoomSetsAScaleThenFitAndEachReplyNamesTheResult() async throws {
    let (applet, _) = pane()

    try await large(applet)

    let zoomed = try await run("zoom", ["scale": .number(1)], to: applet)

    XCTAssertEqual(zoomed["state"], .string("done"))
    XCTAssertEqual(zoomed["fit"], .bool(false))
    XCTAssertEqual(zoomed["scale"]?.doubleValue ?? 0, 1, accuracy: 0.001)
    XCTAssertGreaterThan(applet.tiles.entries.count, 0, "the reply came with detail")

    let fit = try await run("zoom", ["to": .string("fit")], to: applet)

    XCTAssertEqual(fit["fit"], .bool(true))

    let actual = try await run("zoom", ["to": .string("actual")], to: applet)

    XCTAssertEqual(actual["fit"], .bool(false))
  }

  /// Catches a zoom argument that is accepted when it makes no sense. No argument, both, a scale
  /// past the ceiling, and a zoom with no image are all refused with nothing changed.
  func testZoomRefusesBadArgumentsAndAPaneWithNoImage() async throws {
    let (applet, _) = pane()

    XCTAssertEqual(
      send("zoom", ["to": .string("fit")], to: applet).result,
      .failure(AppletCommandError(.refused, "the pane shows no image to zoom")))

    try await large(applet)

    for arguments: [String: JSONValue] in [
      [:], ["to": .string("fit"), "scale": .number(2)], ["scale": .number(500)],
      ["to": .string("fill")],
    ] {
      guard case .failure(let error)? = send("zoom", arguments, to: applet).result else {
        return XCTFail("\(arguments) ran")
      }

      XCTAssertEqual(error.code, .badArgument, "\(arguments)")
    }

    XCTAssertTrue(applet.content.viewport?.isFit == true)
  }

  /// Catches a refused zoom that never reaches the caller. The decode is past the helper's cap, so
  /// the handle fails with the zoom limit and the pane goes back to fit.
  func testAZoomThePaneRefusesFailsTheHandleWithTheZoomLimit() async throws {
    let (applet, _) = panes.make(settings: Harness.settings(maxImageBytes: 2 << 20))

    applet.content.backingScaleSource = { 2 }

    let url = try ImageFixtures.write(
      ImageFixtures.png(width: 1500, height: 1000), named: "wide.png", in: folder)

    _ = try await run("show", ["path": .string(url.path)], to: applet)

    let reply = try await run("zoom", ["scale": .number(1)], to: applet)

    XCTAssertEqual(reply["state"], .string("failed"))
    XCTAssertEqual(reply["code"], .string("zoom-limit"))
    XCTAssertTrue(applet.content.viewport?.isFit == true)
  }

  /// Catches a zoom reply, or a refusal, that tells a caller the size of an image it may not see. At
  /// fit the scale follows from the image's size, and the ceiling follows from its resolution. A
  /// caller outside the scope gets the zoom with `done` alone, and no refusal for any scale.
  func testZoomTellsACallerOutsideTheScopeNothingAboutTheImage() async throws {
    let (applet, _) = pane()

    try await large(applet)

    let elsewhere = try ReadScope(directories: [outside.path])
    for scope in [elsewhere, nil] as [ReadScope?] {
      let given: ReadScope?? = .some(scope)

      for arguments: [String: JSONValue] in [
        ["to": .string("fit")], ["scale": .number(500)], ["scale": .number(1)],
      ] {
        let reply = try await run("zoom", arguments, to: applet, scope: given)

        XCTAssertEqual(reply, ["state": .string("done")], "\(arguments)")
      }
    }

    let inside = try await run("zoom", ["to": .string("fit")], to: applet, scope: wide)

    XCTAssertEqual(inside["fit"], .bool(true), "a caller that may see the image still does")
  }

  /// Catches a zoom that tells a caller outside the scope whether the user's file decodes. A pane
  /// whose file is a problem answers such a caller as a pane with an image does, with a handle that
  /// ends `done`. A caller that may see the file is still refused. A pane with no file of the user's
  /// has nothing to hide, so it is refused for every caller.
  func testZoomAnswersACallerOutsideTheScopeTheSameWithOrWithoutAnImage() async throws {
    let (applet, _) = pane()
    let elsewhere = try ReadScope(directories: [plain.path])
    let refusal = AppletCommandError(.refused, "the pane shows no image to zoom")

    XCTAssertEqual(
      send("zoom", ["to": .string("fit")], to: applet, scope: .some(elsewhere)).result,
      .failure(refusal), "no file of the user's")

    let bad = outside.appendingPathComponent("bad.png")

    try Data("not a picture".utf8).write(to: bad)
    try applet.replaceSource(with: bad, startDirectory: outside.path)

    let failed = await Harness.eventually {
      if case .problem = applet.phase { return true }

      return false
    }
    XCTAssertTrue(failed)

    for scope in [elsewhere, nil] as [ReadScope?] {
      let reply = try await run("zoom", ["scale": .number(2)], to: applet, scope: .some(scope))

      XCTAssertEqual(reply, ["state": .string("done")], "a pane showing a problem")
    }

    XCTAssertEqual(
      send("zoom", ["to": .string("fit")], to: applet, scope: .some(wide)).result,
      .failure(refusal))
  }

  /// Asks for a zoom and then waits on its handle for no time at all. It returns what a `wait` that
  /// gives the pane no time to answer reads.
  private func answerAtOnce(
    _ arguments: [String: JSONValue], on applet: ImageViewerApplet, scope given: ReadScope?
  ) throws -> [String: JSONValue] {
    let started = send("zoom", arguments, to: applet, scope: .some(given))
    let handle = try XCTUnwrap(started.handle, "\(String(describing: started.result))")

    return waitNow(handle, on: applet, scope: given)
  }

  private func waitNow(_ handle: Int, on applet: ImageViewerApplet, scope given: ReadScope?)
    -> [String: JSONValue]
  {
    send(
      "wait", ["handle": .number(Double(handle)), "timeout-ms": .number(0)], to: applet,
      scope: .some(given)
    ).fields
  }

  /// Catches a zoom handle whose state tells a caller outside the scope what the image is. The
  /// handle of such a caller ends `done` before the call returns, so a wait that gives no time reads
  /// the same while tiles are still coming. The helper refuses the second pane's zoom after the
  /// call returned. The handle still reads `done`, the pane goes back to fit, and nothing crashes.
  func testAZoomHandleOfACallerOutsideTheScopeEndsDoneBeforeTheHelperAnswers() async throws {
    let elsewhere: ReadScope? = try ReadScope(directories: [plain.path])
    let (decoded, _) = pane()

    try await large(decoded)

    let first = try answerAtOnce(["scale": .number(1)], on: decoded, scope: elsewhere)

    XCTAssertEqual(first, ["state": .string("done")], "while the tiles are still coming")

    let tiled = await Harness.eventually { !decoded.tiles.entries.isEmpty }
    XCTAssertTrue(tiled, "the zoom still reached the pane")

    let (limited, host) = panes.make(settings: Harness.settings(maxImageBytes: 2 << 20))
    let url = try ImageFixtures.write(
      ImageFixtures.png(width: 1500, height: 1000), named: "wide.png", in: folder)

    limited.content.backingScaleSource = { 2 }
    _ = try await run("show", ["path": .string(url.path)], to: limited)

    let started = send("zoom", ["scale": .number(1)], to: limited, scope: .some(elsewhere))
    let handle = try XCTUnwrap(started.handle)

    XCTAssertEqual(waitNow(handle, on: limited, scope: elsewhere), ["state": .string("done")])

    let refused = await Harness.eventually {
      host.sent.contains { $0.level == .warning && $0.text.contains("zoom limit was reached") }
    }
    XCTAssertTrue(refused, "the helper's refusal arrived after the handle ended")
    XCTAssertEqual(waitNow(handle, on: limited, scope: elsewhere), ["state": .string("done")])
    XCTAssertTrue(limited.content.viewport?.isFit == true, "the pane went back to fit")
  }

  // MARK: Zoom off screen

  /// Starts a wait on `handle` that holds until the handle ends, and returns its reply.
  private func waitLong(_ handle: Int, on applet: ImageViewerApplet) async -> [String: JSONValue] {
    let waited = send(
      "wait", ["handle": .number(Double(handle)), "timeout-ms": .number(20_000)], to: applet)

    await settled(waited)

    return waited.fields
  }

  /// Catches a zoom on a detached pane whose wait hangs until the pane comes back. The pane asks
  /// the helper for one tile and draws nothing. The handle stays pending until that tile arrives,
  /// then ends `done`, and the pane lets the tile go. Reattach brings the detail back.
  func testAZoomOnADetachedStillEndsOnceItsOneTileArrives() async throws {
    let (applet, _) = pane()

    try await large(applet)

    let backdrop = try XCTUnwrap(applet.shot).bytes

    applet.detach()

    let started = send("zoom", ["scale": .number(1)], to: applet)
    let handle = try XCTUnwrap(started.handle)

    XCTAssertEqual(waitNow(handle, on: applet, scope: scope), ["state": .string("pending")])
    XCTAssertEqual(applet.client.tileRegionsOutstanding.count, 1, "one tile is asked for")

    let reply = await waitLong(handle, on: applet)

    XCTAssertEqual(reply["state"], .string("done"))
    XCTAssertEqual(reply["fit"], .bool(false))
    XCTAssertEqual(applet.content.tileCount, 0, "a detached pane draws no tile")
    XCTAssertTrue(applet.tiles.entries.isEmpty, "the tile went once the zoom ended")
    XCTAssertEqual(applet.bitmapBudget.held(by: applet.lease), backdrop)

    applet.reattach()

    let back = await Harness.eventually { applet.content.tileCount > 0 }
    XCTAssertTrue(back, "reattach shows the zoom's detail")
  }

  /// Catches a zoom already running when the pane detaches that never ends. Its first tile is still
  /// on the way, and the handle ends `done` once it arrives off screen.
  func testAZoomStillWaitingForItsTileWhenThePaneDetachesEnds() async throws {
    let (applet, _) = pane()

    try await large(applet)

    let backdrop = try XCTUnwrap(applet.shot).bytes
    let started = send("zoom", ["scale": .number(1)], to: applet)
    let handle = try XCTUnwrap(started.handle)

    XCTAssertFalse(applet.client.tileRegionsOutstanding.isEmpty, "the first tile is on the way")

    applet.detach()

    XCTAssertEqual(waitNow(handle, on: applet, scope: scope), ["state": .string("pending")])

    let reply = await waitLong(handle, on: applet)

    XCTAssertEqual(reply["state"], .string("done"))
    XCTAssertEqual(applet.content.tileCount, 0)
    XCTAssertTrue(applet.tiles.entries.isEmpty)
    XCTAssertEqual(applet.bitmapBudget.held(by: applet.lease), backdrop)
  }

  /// Catches a zoom on a detached animation whose wait hangs, or that throws away the frames the
  /// pane holds. The pane keeps its frames and asks for the frame on screen at the zoom's level.
  /// The handle ends `done` once it arrives, and the pane goes back to its backdrop. Reattach plays
  /// the zoomed frames.
  func testAZoomOnADetachedAnimationEndsOnceOneFrameArrivesAtItsLevel() async throws {
    let (applet, _) = pane()
    let gif = try ImageFixtures.write(
      ImageFixtures.animatedGIF(
        colors: [ImageFixtures.red, ImageFixtures.green, ImageFixtures.blue, ImageFixtures.white],
        delays: [0.06, 0.06, 0.06, 0.06], size: 1200),
      named: "loop.gif", in: folder)

    applet.content.backingScaleSource = { 2 }
    _ = try await run("show", ["path": .string(gif.path)], to: applet)

    let playing = await Harness.eventually { applet.isAnimating && applet.frames.count >= 2 }
    XCTAssertTrue(playing)

    let backdrop = try XCTUnwrap(applet.shot).bytes

    applet.detach()

    let drained = await Harness.eventually { applet.client.outstandingFrames.isEmpty }
    XCTAssertTrue(drained)

    let held = applet.frames.mapValues(\.bytes)
    let started = send("zoom", ["scale": .number(1)], to: applet)
    let handle = try XCTUnwrap(started.handle)

    XCTAssertEqual(applet.frames.mapValues(\.bytes), held, "the held frames stay")
    XCTAssertEqual(waitNow(handle, on: applet, scope: scope), ["state": .string("pending")])
    XCTAssertEqual(
      applet.client.outstandingFrames.map(\.maxPixel), [1200], "one frame at the zoom's level")

    let reply = await waitLong(handle, on: applet)

    XCTAssertEqual(reply["state"], .string("done"))
    XCTAssertNil(applet.zoomLevel)
    XCTAssertTrue(applet.frames.values.allSatisfy { $0.zoomLevel == nil && $0.bytes == 0 })
    XCTAssertEqual(applet.bitmapBudget.held(by: applet.lease), backdrop)

    applet.reattach()

    let sharp = await Harness.eventually {
      applet.isAnimating && applet.zoomLevel == 1200
        && applet.frames.values.contains { $0.zoomLevel == 1200 }
    }
    XCTAssertTrue(sharp, "reattach plays the zoomed frames")
  }

  /// Catches a zoom on a detached pane that ends `done` for a decode the helper refuses, or never
  /// ends. The tile is past the helper's cap, so the handle fails with the zoom limit.
  func testAZoomTheHelperRefusesOnADetachedPaneFailsWithTheZoomLimit() async throws {
    let (applet, _) = panes.make(settings: Harness.settings(maxImageBytes: 2 << 20))

    applet.content.backingScaleSource = { 2 }

    let url = try ImageFixtures.write(
      ImageFixtures.png(width: 1500, height: 1000), named: "wide.png", in: folder)

    _ = try await run("show", ["path": .string(url.path)], to: applet)

    applet.detach()

    let started = send("zoom", ["scale": .number(1)], to: applet)
    let handle = try XCTUnwrap(started.handle)
    let reply = await waitLong(handle, on: applet)

    XCTAssertEqual(reply["state"], .string("failed"))
    XCTAssertEqual(reply["code"], .string("zoom-limit"))
    XCTAssertTrue(applet.content.viewport?.isFit == true)
  }

  /// Catches a zoom wait that hangs when the bitmap budget refuses every tile the zoom needs. The
  /// budget holds the backdrop and nothing more, so each tile is denied. The handle fails with the
  /// zoom limit and the pane goes back to fit. It cannot prove a refusal by the helper, which has
  /// its own test.
  func testAZoomWhoseEveryTileTheBudgetRefusesFailsWithTheZoomLimit() async throws {
    let backdrop = 600 * 400 * 4
    let (applet, _) = panes.make(bitmapBudget: ImageBitmapBudget(limit: 1, floor: backdrop))

    try await large(applet, alone: true)

    XCTAssertEqual(
      applet.bitmapBudget.held(by: applet.lease), backdrop, "the budget holds the backdrop only")

    let started = send("zoom", ["scale": .number(1)], to: applet)
    let handle = try XCTUnwrap(started.handle)
    let reply = await waitLong(handle, on: applet)

    XCTAssertEqual(reply["state"], .string("failed"))
    XCTAssertEqual(reply["code"], .string("zoom-limit"))
    XCTAssertTrue(applet.content.viewport?.isFit == true)
    XCTAssertTrue(applet.tiles.entries.isEmpty)
  }

  /// Catches a partial refusal that fails a zoom which worked. The budget takes some tiles and
  /// refuses the rest, so the handle ends `done` and the pane keeps the zoom.
  func testAZoomWhoseSomeTilesTheBudgetRefusesStillEndsDone() async throws {
    let (applet, _) = panes.make(bitmapBudget: ImageBitmapBudget(limit: 1, floor: 1200 * 800 * 4))

    try await large(applet, alone: true)

    let started = send("zoom", ["scale": .number(1)], to: applet)
    let handle = try XCTUnwrap(started.handle)
    let reply = await waitLong(handle, on: applet)

    XCTAssertEqual(reply["state"], .string("done"))
    XCTAssertEqual(reply["fit"], .bool(false))
    XCTAssertFalse(applet.tiles.entries.isEmpty)
    XCTAssertFalse(applet.tileDenied.isEmpty, "the budget refused some tiles")
  }

  /// Catches a zoom that tells a caller whether a linked image outside its scope decodes. The user
  /// opened a folder in the controller's scope whose one member links to a file outside it. The
  /// pane shows that file, fails on it, or has not opened it yet. A zoom answers `done` in all
  /// three, as a wait that gives no time reads it too.
  func testZoomAnswersTheSameWhetherALinkedImageOutsideTheScopeDecodesFailsOrIsNotOpenYet()
    async throws
  {
    let root = folder.deletingLastPathComponent()
    let garbage = outside.appendingPathComponent("garbage.png")

    try Data("not a picture".utf8).write(to: garbage)

    var answers: [String: [String: JSONValue]] = [:]

    for (state, target) in [
      ("decodes", outside.appendingPathComponent("o.png")), ("fails", garbage),
      ("not open yet", outside.appendingPathComponent("o.png")),
    ] {
      let linked = root.appendingPathComponent(
        "linked-\(state.replacingOccurrences(of: " ", with: "-"))")

      try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        atPath: linked.appendingPathComponent("x.png").path, withDestinationPath: target.path)

      let (applet, _) = pane()
      let given: ReadScope? = try ReadScope(directories: [linked.path])

      try applet.replaceSource(with: linked, startDirectory: linked.path)

      if state != "not open yet" {
        let shown = await Harness.eventually { applet.committedName == "x.png" }
        XCTAssertTrue(shown, state)
      }

      answers[state] = try answerAtOnce(["scale": .number(1)], on: applet, scope: given)
    }

    for (state, answer) in answers {
      XCTAssertEqual(answer, ["state": .string("done")], state)
    }
  }

  /// Catches a failure code that says what is wrong with a file outside the scope. The user opened
  /// a folder in the controller's scope, and one member links to a file outside it that cannot
  /// decode. The controller steps onto it and is told `unreadable`, as for any path outside.
  func testAFailureOnALinkedImageOutsideTheScopeReadsAsUnreadable() async throws {
    try Data("not a picture".utf8).write(to: outside.appendingPathComponent("bad.png"))
    try FileManager.default.createSymbolicLink(
      atPath: folder.appendingPathComponent("zlink.png").path,
      withDestinationPath: outside.appendingPathComponent("bad.png").path)

    let (applet, _) = pane()

    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let shown = await Harness.eventually { applet.committedName == "a.png" }
    XCTAssertTrue(shown)
    await listed(applet)

    let reply = try await run("last", to: applet)

    XCTAssertEqual(reply["state"], .string("failed"))
    XCTAssertEqual(reply["code"], .string("unreadable"))
  }

  // MARK: Handles

  /// Catches a pane that fills with running handles, and a wait that never answers. A newer show
  /// replaces the older one while it still runs, an unknown handle is not found, and a wait that
  /// runs out reads as pending.
  func testANewerShowSupersedesTheOlderAndAnUnfinishedWaitReadsPending() async throws {
    let (applet, _) = pane()
    let first = send("show", ["path": .string(path("a.png"))], to: applet)
    let second = send("show", ["path": .string(path("b.png"))], to: applet)
    let old = try XCTUnwrap(first.handle)
    let new = try XCTUnwrap(second.handle)

    XCTAssertNotEqual(old, new)

    let waited = send("wait", ["handle": .number(Double(old))], to: applet)

    await settled(waited)

    XCTAssertEqual(waited.fields["state"], .string("superseded"))

    XCTAssertEqual(
      send("wait", ["handle": .number(99)], to: applet).result,
      .failure(AppletCommandError(.notFound, "there is no result under that handle")))

    let held = send("wait", ["handle": .number(Double(new)), "timeout-ms": .number(0)], to: applet)

    XCTAssertTrue(
      held.fields["state"] == .string("pending") || held.fields["state"] == .string("shown"))
  }

  /// Catches a different major, or a minor the viewer lacks, running before it is refused.
  func testACommandWrittenForAnotherVersionIsRefusedBeforeAnyEffect() {
    let (applet, _) = pane()

    for version in [AppletSchemaVersion(2, 0), AppletSchemaVersion(1, 1)] {
      guard
        case .failure(let error)? = send(
          "show", ["path": .string(path("a.png"))], to: applet, version: version
        ).result
      else { return XCTFail("\(version) ran") }

      XCTAssertEqual(error.code, .unsupportedVersion)
    }

    XCTAssertEqual(applet.phase, .empty)
  }
}
