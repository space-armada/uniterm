import AppKit
import AppletKit
import FileRouting
import PaneModel
import Preferences
import StatusKit
import XCTest

@testable import WindowKit

private let finder = SenderIdentity(
  pid: 100, pidVersion: 1, signingIdentifier: "com.apple.finder", teamIdentifier: nil,
  isPlatformBinary: true, isAppleAnchored: true, opener: "Finder")

private func stranger(_ index: Int = 0) -> SenderIdentity {
  SenderIdentity(
    pid: Int32(200 + index), pidVersion: 1, signingIdentifier: "com.example.launcher\(index)",
    teamIdentifier: "TEAM", isPlatformBinary: false, isAppleAnchored: false, opener: nil)
}

/// A type system that fails the test when it is asked about a path. A refused open must not look
/// up the type of a path, so it must not reach this.
private final class WatchedTypes: ContentTypeSystem, @unchecked Sendable {
  private let real = SystemContentTypes()
  private let lock = NSLock()
  private var asked: [URL] = []

  var lookups: [URL] {
    lock.withLock { asked }
  }

  func identifier(of url: URL) -> String? {
    lock.withLock { asked.append(url) }
    return real.identifier(of: url)
  }

  func identifiers(forExtension ext: String) -> [String] {
    real.identifiers(forExtension: ext)
  }

  func conforms(_ identifier: String, to other: String) -> Bool {
    real.conforms(identifier, to: other)
  }

  func isKnown(_ identifier: String) -> Bool { real.isKnown(identifier) }
}

@MainActor
private final class OpenFixture {
  let suite = "uniterm-launch-open-\(UUID().uuidString)"
  let defaults: UserDefaults
  let windows: WindowSet
  let coordinator: LaunchOpenCoordinator
  let types = WatchedTypes()
  let directory: URL

  init() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-launch-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    defaults = UserDefaults(suiteName: suite)!

    let store = SettingsStore(defaults: defaults)
    let appearance = AppearanceController(store: store)

    let makeApplet: AppletFactory = { _, _ in FakeApplet() }

    windows = WindowSet(
      visibleFrame: { _ in NSRect(x: 0, y: 0, width: 4000, height: 3000) },
      makeRoutedController: { identifier, applet in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingWith: applet,
          makeApplet: makeApplet
        ).detachFromRealScreen()
      },
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          makeApplet: makeApplet
        ).detachFromRealScreen()
      })

    let declarations = [
      AppletTypeDeclaration(
        typeID: "terminal", displayName: "Terminal", symbolName: "terminal",
        opens: [OpenedType("public.folder", rank: .owner)])
    ]

    let box = FactoryBox()

    let factories: [String: AppletSourceFactory] = [
      "terminal": { file, start in
        box.entries.append((file, start))
        let applet = FakeApplet()
        applet.currentDirectory = start
        return applet
      }
    ]

    self.box = box

    let opener = RoutedOpener(
      windows: windows, declarations: declarations, factories: factories, types: types,
      store: SavedChoiceStore(defaults: defaults))

    let holder = Holder()
    self.holder = holder

    coordinator = LaunchOpenCoordinator(
      windows: windows, opener: opener,
      now: { holder.clock },
      openFallbackWindow: {
        holder.fallbackWindows += 1
        _ = try? holder.windows?.open()
      })

    holder.windows = windows
  }

  let box: FactoryBox
  let holder: Holder

  func cleanUp() {
    for controller in windows.controllers { controller.window?.close() }

    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }

  func folder(_ name: String) throws -> URL {
    let url = directory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Ends the launch as the app does, with a window open, then closes the window. The next open
  /// then arrives in a running app that has no window.
  func finishLaunchAndCloseEveryWindow() throws {
    _ = try windows.open()
    coordinator.launchFinished()

    for controller in windows.controllers { controller.window?.close() }
  }

  /// Lets the coordinator's task run to its end.
  func settle() async {
    for _ in 0..<50 {
      await Task.yield()
    }
  }
}

@MainActor
private final class FactoryBox {
  var entries: [(file: URL, start: String)] = []
}

@MainActor
private final class Holder {
  var fallbackWindows = 0
  var clock: TimeInterval = 0
  weak var windows: WindowSet?
}

@MainActor
final class LaunchOpenCoordinatorTests: XCTestCase {
  private func makeFixture() throws -> OpenFixture {
    let fixture = try OpenFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func messages(_ fixture: OpenFixture) -> [String] {
    fixture.windows.controllers.flatMap { $0.statusCenter.history.map(\.text) }
  }

  // MARK: Authority

  /// Catches a refused open that still looks at its paths. The sender is a stranger, so the type
  /// system is never asked about the folder, nothing is made, and the user is told who was
  /// refused. A looked-up path would raise privacy prompts for a program the user never approved.
  func testARefusedOpenTouchesNothingAndNamesTheSender() async throws {
    let fixture = try makeFixture()
    let window = try fixture.windows.open()
    fixture.coordinator.launchFinished()

    fixture.coordinator.receive([try fixture.folder("a")], from: stranger())
    await fixture.settle()

    XCTAssertTrue(fixture.types.lookups.isEmpty)
    XCTAssertTrue(fixture.box.entries.isEmpty)
    XCTAssertEqual(window.paneIDs.count, 1)
    XCTAssertTrue(messages(fixture).contains { $0.contains("com.example.launcher0") })
  }

  /// Catches an unidentified sender that gets through. A sender that exited cannot be identified.
  func testAnUnidentifiedSenderIsRefusedBeforeAnyPathIsTouched() async throws {
    let fixture = try makeFixture()
    _ = try fixture.windows.open()
    fixture.coordinator.launchFinished()

    fixture.coordinator.receive([try fixture.folder("a")], from: nil)
    await fixture.settle()

    XCTAssertTrue(fixture.types.lookups.isEmpty)
    XCTAssertTrue(fixture.box.entries.isEmpty)
    XCTAssertTrue(messages(fixture).contains { $0.contains("unidentified") })
  }

  /// Catches a refusal that is not bounded. A loop of a thousand refusals from a thousand senders,
  /// all inside one interval, leaves one message in the history.
  func testALoopOfRefusedOpensPostsOneMessage() async throws {
    let fixture = try makeFixture()
    let window = try fixture.windows.open()
    fixture.coordinator.launchFinished()

    for index in 0..<1000 {
      fixture.coordinator.receive([URL(fileURLWithPath: "/x")], from: stranger(index))
    }

    await fixture.settle()

    XCTAssertEqual(window.statusCenter.history.count, 1)
    XCTAssertTrue(fixture.types.lookups.isEmpty)
  }

  // MARK: Placement

  /// Catches a Finder open that lands in a window other than the one that was key last. The first
  /// window is key last, though the second is newer. The folder splits beside the first window's
  /// focused pane and starts there.
  func testAFinderFolderOpensBesideTheFocusedPaneOfTheMostRecentlyKeyWindow() async throws {
    let fixture = try makeFixture()
    let first = try fixture.windows.open()
    let second = try fixture.windows.open()
    fixture.windows.noteKey(first)
    fixture.coordinator.launchFinished()

    let folder = try fixture.folder("project")
    fixture.coordinator.receive([folder], from: finder)
    await fixture.settle()

    XCTAssertEqual(first.paneIDs.count, 2)
    XCTAssertEqual(second.paneIDs.count, 1)
    XCTAssertEqual(fixture.box.entries.map(\.start), [folder.path])
    XCTAssertEqual(fixture.windows.controllers.count, 2)
  }

  /// Catches a Finder open that reaches the window set with no window open. It opens one window
  /// that holds only the routed terminal.
  func testAFolderWithNoWindowOpensARoutedOnlyWindow() async throws {
    let fixture = try makeFixture()
    try fixture.finishLaunchAndCloseEveryWindow()

    fixture.coordinator.receive([try fixture.folder("project")], from: finder)
    await fixture.settle()

    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(fixture.windows.controllers[0].paneIDs.count, 1)
    XCTAssertEqual(fixture.box.entries.count, 1)
    XCTAssertEqual(fixture.holder.fallbackWindows, 0)
  }

  /// Catches a package that opens as a folder. Through the Launch Services path, a bundle is
  /// refused as an unsupported type and no pane opens.
  func testAPackageIsRefusedThroughTheLaunchServicesPath() async throws {
    let fixture = try makeFixture()
    let window = try fixture.windows.open()
    fixture.coordinator.launchFinished()

    let bundle = try fixture.folder("Thing.app")
    try Data("x".utf8).write(to: bundle.appendingPathComponent("note.txt"))
    fixture.coordinator.receive([bundle], from: finder)
    await fixture.settle()

    XCTAssertTrue(fixture.box.entries.isEmpty)
    XCTAssertEqual(window.paneIDs.count, 1)
    XCTAssertFalse(messages(fixture).isEmpty)
  }

  // MARK: Cold launch

  /// Catches an open that runs before layout restore ends. It waits, reports itself pending so the
  /// layout opens no default window, and runs when the launch finishes.
  func testAnOpenBeforeRestoreWaitsAndThenReplays() async throws {
    let fixture = try makeFixture()

    fixture.coordinator.receive([try fixture.folder("project")], from: finder)
    await fixture.settle()

    XCTAssertTrue(fixture.coordinator.hasPending)
    XCTAssertTrue(fixture.windows.controllers.isEmpty)
    XCTAssertTrue(fixture.box.entries.isEmpty)

    fixture.coordinator.launchFinished()
    await fixture.settle()

    XCTAssertFalse(fixture.coordinator.hasPending)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(fixture.windows.controllers[0].paneIDs.count, 1)
    XCTAssertEqual(fixture.box.entries.count, 1, "one terminal, and no other shell")
    XCTAssertEqual(fixture.holder.fallbackWindows, 0)
  }

  /// Catches a refused cold-launch open that leaves the app with no window. A refusal is not
  /// pending, so the layout opens its default window, and the message waits for it.
  func testARefusedOpenBeforeRestoreIsNotPending() throws {
    let fixture = try makeFixture()

    fixture.coordinator.receive([try fixture.folder("a")], from: stranger())

    XCTAssertFalse(fixture.coordinator.hasPending)
  }

  /// Catches a launch that ends with no window when every waiting open fails. The fallback opens
  /// one.
  func testAWindowOpensWhenTheReplayLeavesNone() async throws {
    let fixture = try makeFixture()
    let missing = fixture.directory.appendingPathComponent("gone", isDirectory: true)

    fixture.coordinator.receive([missing], from: finder)
    fixture.coordinator.launchFinished()
    await fixture.settle()

    XCTAssertEqual(fixture.holder.fallbackWindows, 1)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
  }

  /// Catches a fallback that opens a shell window after a warm open that failed with no window.
  /// Only the launch replay opens one.
  func testAFailedWarmOpenWithNoWindowOpensNoShell() async throws {
    let fixture = try makeFixture()
    try fixture.finishLaunchAndCloseEveryWindow()
    await fixture.settle()

    fixture.coordinator.receive(
      [fixture.directory.appendingPathComponent("gone", isDirectory: true)], from: finder)
    await fixture.settle()

    XCTAssertEqual(fixture.holder.fallbackWindows, 0)
    XCTAssertTrue(fixture.windows.controllers.isEmpty)
  }

  // MARK: Several files

  /// Catches a batch that gives up when one file fails. The good folders open one pane each, and
  /// the bad one is one summary message.
  func testABatchOpensOnePanePerFileAndSummarizesFailures() async throws {
    let fixture = try makeFixture()
    _ = try fixture.windows.open()
    fixture.coordinator.launchFinished()

    let good = [try fixture.folder("a"), try fixture.folder("b")]
    let bad = fixture.directory.appendingPathComponent("missing", isDirectory: true)

    fixture.coordinator.receive(good + [bad], from: finder)
    await fixture.settle()

    XCTAssertEqual(fixture.box.entries.count, 2)
    XCTAssertEqual(fixture.windows.controllers.flatMap(\.paneIDs).count, 3)
    XCTAssertEqual(messages(fixture).filter { $0.contains("missing") }.count, 1)
  }

  /// A web URL is not a local file. It is dropped with one message and the files beside it open.
  func testNonFileURLsAreDroppedWithOneMessage() async throws {
    let fixture = try makeFixture()
    _ = try fixture.windows.open()
    fixture.coordinator.launchFinished()

    fixture.coordinator.receive(
      [URL(string: "https://example.com")!, try fixture.folder("a")], from: finder)
    await fixture.settle()

    XCTAssertEqual(fixture.box.entries.count, 1)
    XCTAssertEqual(messages(fixture).filter { $0.contains("not local files") }.count, 1)
  }
}
