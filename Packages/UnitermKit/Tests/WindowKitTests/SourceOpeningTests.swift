import AppKit
import AppletKit
import XCTest

@testable import WindowKit

extension FakeApplet: SourceReplacing {
  func replaceSource(with file: URL, startDirectory: String) throws {
    if let replaceFailure { throw replaceFailure }

    replacedSources.append((file, startDirectory))
  }

  func checkSource(_ file: URL, startDirectory: String) async throws {
    if let replaceFailure { throw replaceFailure }
  }

  // The tests hand `SourceOpening.open` a scripted picker of their own.
  var openPicker: OpenPicker { { _, _ in [] } }
}

private struct Unreadable: LocalizedError {
  var errorDescription: String? { "it is not readable" }
}

/// The pane-local Open that a viewer's command set declares, proven on a fixture applet because no
/// viewer exists yet.
@MainActor
final class SourceOpeningTests: XCTestCase {
  private func scripted(_ answer: [URL], saw: @escaping (OpenPanelRequest) -> Void = { _ in })
    -> OpenPicker
  {
    { request, _ in
      saw(request)
      return answer
    }
  }

  /// Catches a pane-local Open that opens a key of its own, which would shadow Cmd-O, or one that
  /// the terminal could pick up. The command asks for no key and lives in the File menu.
  func testTheCommandAsksForNoKeyAndNeedsASourceTakingApplet() throws {
    let command = AppletCommand.openSource()

    XCTAssertNil(command.key)
    XCTAssertEqual(command.name, "open")
    XCTAssertEqual(command.title, "Open in This Pane\u{2026}")
    XCTAssertTrue(command.listedInPalette)

    XCTAssertTrue(command.isAvailable(FakeApplet()))
    XCTAssertFalse(command.isAvailable(LauncherApplet(directory: nil)))
  }

  /// Catches a command that registers with a key or a different ID than the applet's namespace.
  func testTheRegistryNamespacesItByTheAppletType() {
    let registry = CommandRegistry()
    registry.register(
      AppletCommandSet(typeID: "fake", menuTitle: "Fake", commands: [.openSource()]))

    let command = registry.command("fake.open")
    XCTAssertNotNil(command)
    XCTAssertNil(command?.key)
    XCTAssertEqual(command?.menu?.home, .file)
  }

  /// Catches a pane-local Open that shares its File menu title with uniterm's Open, which routes by
  /// type. An App Shortcuts remap matches by title, so two items with one title cannot be told
  /// apart.
  func testThePaneLocalOpenReadsApartFromEveryFileMenuItem() {
    let registry = CommandRegistry()
    registry.register(
      AppletCommandSet(typeID: "fake", menuTitle: "Fake", commands: [.openSource()]))

    let titles = registry.commands.filter { $0.menu?.home == .file }.map {
      $0.menu?.title ?? $0.title
    }

    XCTAssertEqual(titles.count, Set(titles).count, "\(titles)")
  }

  /// Catches a source replaced from the wrong place: the file's own folder is the start directory,
  /// and a folder starts in itself. The panel starts in the applet's directory and takes one file.
  func testTheChosenFileReplacesTheSourceAndStartsInItsFolder() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-source-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let file = folder.appendingPathComponent("a.txt")
    try Data("x".utf8).write(to: file)

    let applet = FakeApplet()
    applet.currentDirectory = folder.path

    var requests: [OpenPanelRequest] = []

    await SourceOpening.open(applet, picker: scripted([file], saw: { requests.append($0) }))
    await SourceOpening.open(applet, picker: scripted([folder]))

    XCTAssertEqual(
      requests, [OpenPanelRequest(directory: folder, allowsMultipleSelection: false)])
    XCTAssertEqual(applet.replacedSources.map(\.file), [file, folder])
    XCTAssertEqual(applet.replacedSources.map(\.start), [folder.path, folder.path])
  }

  /// Catches a cancelled panel that replaces the source.
  func testCancellingReplacesNothing() async {
    let applet = FakeApplet()

    await SourceOpening.open(applet, picker: scripted([]))

    XCTAssertTrue(applet.replacedSources.isEmpty)
  }

  /// Catches a failed replace that is silent, or one that loses the source the pane had. The
  /// applet's check throws, the pane says why, and nothing was replaced.
  func testAFailedReplaceIsReportedOnThePaneAndKeepsTheOldSource() async throws {
    let fixture = try WindowFixture()
    defer { fixture.cleanUp() }

    let applet = try XCTUnwrap(fixture.log.made.first)
    applet.replaceFailure = Unreadable()

    let file = URL(fileURLWithPath: "/tmp/notes.txt")

    await SourceOpening.open(applet, picker: scripted([file]))

    XCTAssertTrue(applet.replacedSources.isEmpty)

    let last = try XCTUnwrap(fixture.controller.statusCenter.history.last)
    XCTAssertEqual(last.level, .warning, "a file that did not open is content not shown")

    let text = last.text
    XCTAssertTrue(text.contains("notes.txt"))
    XCTAssertTrue(text.contains("it is not readable"))
  }

  /// Catches a pane-local Open that starts a linked folder in its target, or classifies a link by
  /// the link and not its target. The start directory keeps the path as named, and a linked file
  /// starts in the link's own folder, as the router does.
  func testASymlinkKeepsItsPathAndTakesItsKindFromTheTarget() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-links-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    let folder = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let file = folder.appendingPathComponent("a.txt")
    try Data("x".utf8).write(to: file)

    let folderLink = root.appendingPathComponent("folder-link")
    let fileLink = root.appendingPathComponent("file-link.txt")
    try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
    try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)

    let applet = FakeApplet()

    await SourceOpening.open(applet, picker: scripted([folderLink]))
    await SourceOpening.open(applet, picker: scripted([fileLink]))

    XCTAssertEqual(applet.replacedSources.map(\.start), [folderLink.path, root.path])
    XCTAssertEqual(SourceStartDirectory.of(folderLink), folderLink.path)
  }
}
