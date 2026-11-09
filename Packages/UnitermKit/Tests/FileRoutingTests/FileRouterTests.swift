import AppletKit
import Darwin
import FileRouting
import XCTest

/// Proves the match rule with fixture applets and a fixture type graph. It cannot prove that the
/// system's own conformance data agrees with the graph, which the catalog tests check against the
/// real database.
final class FileRouterTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = try makeTemporaryDirectory()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  private func file(_ name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url
  }

  private func openedApplet(_ decision: RouteDecision) -> String? {
    if case .open(_, let id, _, _) = decision { return id }

    return nil
  }

  private let data = applet("data", [("public.text", .owner)])
  private let table = applet("table", [("com.example.json", .alternate)])
  private let map = applet("map", [("com.example.geojson", .alternate)])

  // MARK: Markdown

  private static let markdownParents = [
    "net.daringfireball.markdown": ["public.text"], "com.unknown.md": ["public.text"],
  ]

  /// Catches a router that refuses a `.md` file because another app's type won the extension. The
  /// file's own type is `com.unknown.md`, which does not conform to Markdown. The system also
  /// registers the Markdown type for `md`, so the file routes to the viewer through it. The
  /// decision keeps the file's own type. It cannot prove which type Launch Services picks on a
  /// given machine.
  func testAMarkdownFileTypedByAnotherAppRoutesThroughTheExtensionsTypes() throws {
    let viewer = applet("viewer", [("net.daringfireball.markdown", .owner)])
    let types = FixtureTypes(
      parents: Self.markdownParents, byExtension: ["md": "com.unknown.md"],
      registered: ["md": ["com.unknown.md", "net.daringfireball.markdown"]])
    let url = try file("README.md")

    XCTAssertEqual(
      FileRouter(declarations: [viewer], types: types).decide(url),
      .open(
        file: url, appletTypeID: "viewer", startDirectory: directory.path, type: "com.unknown.md"))
  }

  /// Catches a router that lets extension types outrank the file's own type. The preferred type
  /// matches the text applet, so the Markdown viewer that the extension also names does not win.
  func testAMatchingPreferredTypeWinsOverTheExtensionsTypes() throws {
    let viewer = applet("viewer", [("net.daringfireball.markdown", .owner)])
    let text = applet("text", [("public.text", .alternate)])
    let types = FixtureTypes(
      parents: Self.markdownParents, byExtension: ["md": "com.unknown.md"],
      registered: ["md": ["com.unknown.md", "net.daringfireball.markdown"]])

    let router = FileRouter(declarations: [viewer, text], types: types)

    XCTAssertEqual(openedApplet(router.decide(try file("a.md"))), "text")
  }

  /// Catches a router that routes by extension types with its own rules. Two extension types match
  /// different applets, and the more specific one wins, as for any file.
  func testExtensionTypesUseTheSameSpecificityRule() throws {
    let types = FixtureTypes(
      parents: ["com.example.geojson": ["com.example.json"], "com.example.json": ["public.text"]],
      byExtension: ["geo": "com.unknown.geo"],
      registered: ["geo": ["com.unknown.geo", "com.example.json", "com.example.geojson"]])
    let router = FileRouter(declarations: [data, table, map], types: types)

    XCTAssertEqual(openedApplet(router.decide(try file("a.geo"))), "map")
  }

  /// Catches a router that opens a file whose extension types match no applet, or that loses the
  /// file's preferred type from the refusal.
  func testExtensionTypesThatMatchNothingStillRefuseNamingThePreferredType() throws {
    let viewer = applet("viewer", [("net.daringfireball.markdown", .owner)])
    let types = FixtureTypes(
      parents: Self.markdownParents, byExtension: ["md": "com.unknown.md"],
      registered: ["md": ["com.unknown.md", "com.other.md"]])
    let url = try file("a.md")

    XCTAssertEqual(
      FileRouter(declarations: [viewer], types: types).decide(url),
      .refused(file: url, .unsupported(type: "com.unknown.md")))
  }

  /// Catches a fallback that runs for a file with no extension. Such a file has no extension types
  /// to consider, so it is refused as before.
  func testAFileWithNoExtensionIsRefusedAsBefore() throws {
    let viewer = applet("viewer", [("net.daringfireball.markdown", .owner)])
    let types = FixtureTypes(
      parents: Self.markdownParents, byExtension: ["": "com.unknown.md"],
      registered: ["": ["net.daringfireball.markdown"]])
    let url = try file("README")

    XCTAssertEqual(
      FileRouter(declarations: [viewer], types: types).decide(url),
      .refused(file: url, .unsupported(type: "com.unknown.md")))
  }

  /// Catches a fallback that disturbs a saved choice. The choice is keyed on the preferred type,
  /// which matches a claim, so it still decides and the extension types are never consulted.
  func testASavedChoiceForTheExactPreferredTypeStillWins() throws {
    let viewer = applet("viewer", [("public.text", .owner)])
    let other = applet("other", [("public.text", .alternate)])
    let types = FixtureTypes(
      parents: Self.markdownParents, byExtension: ["md": "com.unknown.md"],
      registered: ["md": ["net.daringfireball.markdown"]])
    let router = FileRouter(
      declarations: [viewer, other], types: types, savedChoices: ["com.unknown.md": "other"])

    XCTAssertEqual(openedApplet(router.decide(try file("a.md"))), "other")
  }

  /// Catches a router that sends unsupported-looking files through the viewer's own import. The
  /// Markdown-typed file still routes with no extension types registered at all.
  func testAMarkdownTypedFileRoutesWithoutExtensionTypes() throws {
    let viewer = applet("viewer", [("net.daringfireball.markdown", .owner)])
    let types = FixtureTypes(
      parents: Self.markdownParents, byExtension: ["md": "net.daringfireball.markdown"])

    XCTAssertEqual(
      openedApplet(FileRouter(declarations: [viewer], types: types).decide(try file("a.md"))),
      "viewer")
  }

  // MARK: Matching

  /// Catches a router that lets rank beat specificity. The map is only an alternate, but its type
  /// is more specific than the owner's, so the map wins.
  func testTheMoreSpecificMatchWinsOverRank() throws {
    let router = FileRouter(declarations: [data, table, map], types: FixtureTypes.standard())

    XCTAssertEqual(openedApplet(router.decide(try file("a.geojson"))), "map")
  }

  /// Catches a router that ignores rank between matches of the same type. Two applets declare the
  /// notes type, and the owner wins.
  func testRankDecidesBetweenMatchesThatAreNotNested() throws {
    let notes = applet("notes", [("com.example.notes", .alternate)])
    let owner = applet("owner", [("com.example.notes", .owner)])
    let router = FileRouter(declarations: [notes, owner], types: FixtureTypes.standard())

    XCTAssertEqual(openedApplet(router.decide(try file("a.notes"))), "owner")
  }

  /// Catches a silent tiebreak. Two equal claims, which a test forbids in the catalog, ask the user
  /// at run time instead of picking the first.
  func testAnEqualTieAsksAndNeverPicks() throws {
    let one = applet("one", [("public.text", .owner)])
    let two = applet("two", [("public.text", .owner)])
    let router = FileRouter(declarations: [one, two], types: FixtureTypes.standard())

    guard case .choose(_, let candidates, _, _) = router.decide(try file("a.txt")) else {
      return XCTFail("expected a choice")
    }

    XCTAssertEqual(candidates.map(\.typeID), ["one", "two"])
  }

  /// Catches a router that routes a file nothing declares, or a message that omits the file or its
  /// type.
  func testAFileNoAppletDeclaresIsRefusedByNameAndType() throws {
    let router = FileRouter(declarations: [map], types: FixtureTypes.standard())
    let url = try file("a.bin")

    guard case .refused(_, let refusal) = router.decide(url) else {
      return XCTFail("expected a refusal")
    }

    XCTAssertEqual(refusal, .unsupported(type: "public.data"))

    let message = refusal.message(for: url)
    XCTAssertTrue(message.contains("a.bin"))
    XCTAssertTrue(message.contains("public.data"))
  }

  // MARK: Saved choices

  /// Catches a saved choice that rank or specificity can overrule.
  func testASavedChoiceForTheExactTypeOverridesSpecificityAndRank() throws {
    let router = FileRouter(
      declarations: [data, table, map], types: FixtureTypes.standard(),
      savedChoices: ["com.example.geojson": "data"])

    XCTAssertEqual(openedApplet(router.decide(try file("a.geojson"))), "data")
  }

  /// Catches a saved choice that moves a conforming type. A choice for json must not move geojson
  /// away from the map.
  func testASavedChoiceNeverRoutesATypeThatConformsToIt() throws {
    let router = FileRouter(
      declarations: [data, table, map], types: FixtureTypes.standard(),
      savedChoices: ["com.example.json": "data"])

    XCTAssertEqual(openedApplet(router.decide(try file("a.geojson"))), "map")
    XCTAssertEqual(openedApplet(router.decide(try file("a.json"))), "data")
  }

  /// Catches a router that follows a saved choice to an applet that is gone, or to one that no
  /// longer declares the type. Either falls back to the rank for that open.
  func testASavedChoiceForAMissingOrNonDeclaringAppletFallsBackToRank() throws {
    let url = try file("a.geojson")

    let missing = FileRouter(
      declarations: [data, table, map], types: FixtureTypes.standard(),
      savedChoices: ["com.example.geojson": "gone"])
    XCTAssertEqual(openedApplet(missing.decide(url)), "map")

    let other = applet("other", [("com.example.notes", .owner)])
    let nonDeclaring = FileRouter(
      declarations: [data, table, map, other], types: FixtureTypes.standard(),
      savedChoices: ["com.example.geojson": "other"])
    XCTAssertEqual(openedApplet(nonDeclaring.decide(url)), "map")
    XCTAssertNil(nonDeclaring.savedAppletTypeID(forType: "com.example.geojson"))
  }

  // MARK: Refusing special files

  /// Catches an open of a FIFO. Opening one with no writer blocks forever, so the test would hang
  /// on a regression. The type system must never be asked, since resolving a type can open.
  func testAFIFOIsRefusedWithoutOpeningOrAskingForItsType() throws {
    let fifo = directory.appendingPathComponent("pipe.txt")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

    let types = FixtureTypes.standard()
    let router = FileRouter(declarations: [data], types: types)

    guard case .refused(_, let refusal) = router.decide(fifo) else {
      return XCTFail("expected a refusal")
    }

    XCTAssertEqual(refusal, .special(kind: "a FIFO"))
    XCTAssertEqual(types.lookups, 0)
  }

  /// Catches a router that opens a device node. The device keeps its kind in the refusal.
  func testADeviceNodeIsRefusedWithoutAskingForItsType() {
    let types = FixtureTypes.standard()
    let router = FileRouter(declarations: [data], types: types)

    guard case .refused(_, let refusal) = router.decide(URL(fileURLWithPath: "/dev/null")) else {
      return XCTFail("expected a refusal")
    }

    XCTAssertEqual(refusal, .special(kind: "a device"))
    XCTAssertEqual(types.lookups, 0)
  }

  /// Catches a symlink to a FIFO slipping through, since only the link was checked.
  func testASymlinkToAFIFOIsRefused() throws {
    let fifo = directory.appendingPathComponent("pipe")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

    let link = directory.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)

    let router = FileRouter(declarations: [data], types: FixtureTypes.standard())

    guard case .refused(_, let refusal) = router.decide(link) else {
      return XCTFail("expected a refusal")
    }

    XCTAssertEqual(refusal, .special(kind: "a FIFO"))
  }

  func testAMissingPathAndADanglingLinkAreRefusedAsMissing() throws {
    let router = FileRouter(declarations: [data], types: FixtureTypes.standard())
    let link = directory.appendingPathComponent("dangling.txt")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: directory.appendingPathComponent("nowhere"))

    for url in [directory.appendingPathComponent("absent.txt"), link] {
      guard case .refused(_, let refusal) = router.decide(url) else {
        return XCTFail("expected a refusal")
      }

      XCTAssertEqual(refusal, .missing)
    }
  }

  // MARK: Start directory

  /// Catches a start directory taken from anywhere but the request: a file starts in its own
  /// folder, and a folder starts in itself.
  func testStartDirectoryComesFromTheFileOrTheFolderItself() throws {
    let folderApp = applet("terminal", [("public.folder", .owner)])
    let router = FileRouter(declarations: [data, folderApp], types: FixtureTypes.standard())

    let nested = directory.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let inner = nested.appendingPathComponent("a.txt")
    try Data("x".utf8).write(to: inner)

    guard case .open(_, "data", let fileStart, _) = router.decide(inner) else {
      return XCTFail("expected the data applet")
    }

    XCTAssertEqual(fileStart, nested.path)

    guard case .open(_, "terminal", let folderStart, _) = router.decide(nested) else {
      return XCTFail("expected the terminal")
    }

    XCTAssertEqual(folderStart, nested.path)
  }

  // MARK: Off the main thread

  /// Catches type and file-system work on the main thread, which a slow volume would stall. A
  /// regression that calls the blocking path from the main actor fails here.
  @MainActor
  func testTypeResolutionRunsOffTheMainThread() async throws {
    let types = FixtureTypes.standard()
    let router = FileRouter(declarations: [data], types: types)

    let decisions = await router.decisions(for: [try file("a.txt"), try file("b.txt")])

    XCTAssertEqual(decisions.count, 2)
    XCTAssertEqual(types.lookups, 2)
    XCTAssertFalse(types.lookedUpOnMainThread)
  }

  // MARK: Candidates

  /// Catches a chooser list that omits an applet declaring the type, or that puts the likeliest
  /// last.
  func testCandidatesListEveryDeclaringAppletWithTheLikeliestFirst() {
    let router = FileRouter(declarations: [data, table, map], types: FixtureTypes.standard())

    XCTAssertEqual(
      router.candidates(forType: "com.example.geojson").map(\.typeID), ["map", "data", "table"])
    XCTAssertEqual(router.candidates(forType: "com.example.notes").map(\.typeID), ["data"])
  }
}
