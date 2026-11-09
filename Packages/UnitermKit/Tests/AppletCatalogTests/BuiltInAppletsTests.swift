import AppKit
import AppletCatalog
import AppletKit
import FileRouting
import XCTest

/// Proves the production catalog against the system's real type database. The Info.plist drift
/// check joins it when the app declares document types.
final class BuiltInAppletsTests: XCTestCase {
  /// Catches a declaration that changes without a deliberate edit here. The terminal opens folders
  /// as the owner, the data viewer opens CSV, JSON, and `.xlsx` as the owner, the map viewer
  /// opens GeoJSON as the owner, and the text viewer opens PDF, RTF, and Word as the owner.
  func testTheCatalogIsTheTerminalOpeningFoldersAndTheDataViewerOpeningTables() {
    XCTAssertEqual(
      BuiltInApplets.declarations,
      [
        AppletTypeDeclaration(
          typeID: "terminal", displayName: "Terminal", symbolName: "terminal",
          opens: [OpenedType("public.folder", rank: .owner)]),
        AppletTypeDeclaration(
          typeID: "data-viewer", displayName: "Data Viewer", symbolName: "tablecells",
          opens: [
            OpenedType("public.comma-separated-values-text", rank: .owner),
            OpenedType("public.json", rank: .owner),
            OpenedType("org.openxmlformats.spreadsheetml.sheet", rank: .owner),
          ]),
        AppletTypeDeclaration(
          typeID: "map-viewer", displayName: "Map Viewer", symbolName: "map",
          opens: [OpenedType("public.geojson", rank: .owner)]),
        AppletTypeDeclaration(
          typeID: "browser", displayName: "Browser", symbolName: "safari", opens: []),
        AppletTypeDeclaration(
          typeID: "image-viewer", displayName: "Image Viewer", symbolName: "photo",
          opens: [
            OpenedType("public.image", rank: .owner),
            OpenedType("public.folder", rank: .alternate),
          ]),
        AppletTypeDeclaration(
          typeID: "text-viewer", displayName: "Text Viewer", symbolName: "doc.text",
          opens: [
            OpenedType("com.adobe.pdf", rank: .owner),
            OpenedType("public.rtf", rank: .owner),
            OpenedType("com.microsoft.word.doc", rank: .owner),
            OpenedType("org.openxmlformats.wordprocessingml.document", rank: .owner),
            OpenedType("net.daringfireball.markdown", rank: .owner),
          ]),
      ])
  }

  /// Catches an image that routes anywhere but the image viewer, and a folder that stops routing to
  /// the terminal because the image viewer also declares folders. The viewer's folder claim is an
  /// alternate, so the terminal stays the default.
  func testImagesRouteToTheImageViewerAndFoldersStayWithTheTerminal() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let router = FileRouter(declarations: BuiltInApplets.declarations)
    let png = folder.appendingPathComponent("a.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)

    guard case .open(_, let imageApplet, _, _) = router.decide(png) else {
      return XCTFail("a PNG did not route")
    }

    XCTAssertEqual(imageApplet, "image-viewer")

    guard case .open(_, let folderApplet, _, _) = router.decide(folder) else {
      return XCTFail("a folder did not route")
    }

    XCTAssertEqual(folderApplet, "terminal")
  }

  /// Catches a misspelled symbol name. The system returns no image for a name it lacks, and the
  /// palette row would then show no icon without any error.
  func testEverySymbolNameResolvesToASystemImage() {
    for declaration in BuiltInApplets.declarations {
      XCTAssertNotNil(
        NSImage(systemSymbolName: declaration.symbolName, accessibilityDescription: nil),
        declaration.typeID)
    }
  }

  /// Catches a table file that routes anywhere but the data viewer, or a router that cannot type a
  /// real `.csv`, `.json`, or `.xlsx` file. The file stays in its own folder.
  func testTableFilesRouteToTheDataViewer() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let router = FileRouter(declarations: BuiltInApplets.declarations)

    for (name, type) in [
      ("a.csv", "public.comma-separated-values-text"), ("a.json", "public.json"),
      ("a.xlsx", "org.openxmlformats.spreadsheetml.sheet"),
    ] {
      let file = folder.appendingPathComponent(name)
      try Data("x,y\n1,2\n".utf8).write(to: file)

      XCTAssertEqual(
        router.decide(file),
        .open(file: file, appletTypeID: "data-viewer", startDirectory: folder.path, type: type),
        name)
    }
  }

  /// Catches a GeoJSON file that routes to the data viewer, or plain JSON that routes to the map.
  /// `public.geojson` conforms to `public.json`, so the map's claim is the more specific one. The
  /// files are real, and the type comes from the system.
  func testGeoJSONRoutesToTheMapAndPlainJSONStaysWithTheDataViewer() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let router = FileRouter(declarations: BuiltInApplets.declarations)

    let geo = folder.appendingPathComponent("places.geojson")
    try Data(#"{"type":"FeatureCollection","features":[]}"#.utf8).write(to: geo)

    XCTAssertEqual(
      router.decide(geo),
      .open(
        file: geo, appletTypeID: "map-viewer", startDirectory: folder.path,
        type: "public.geojson"))

    let json = folder.appendingPathComponent("places.json")
    try Data(#"{"type":"FeatureCollection","features":[]}"#.utf8).write(to: json)

    XCTAssertEqual(
      router.decide(json),
      .open(
        file: json, appletTypeID: "data-viewer", startDirectory: folder.path,
        type: "public.json"))
  }

  /// Catches two equal claims, an undeclared type, or a `public.directory` declaration in the
  /// shipped catalog.
  func testTheCatalogPassesTheAuditAgainstTheSystem() {
    XCTAssertEqual(
      CatalogAudit.problems(in: BuiltInApplets.declarations, types: SystemContentTypes()), [])
  }

  /// Catches a folder that routes anywhere but the terminal, started in the folder itself.
  func testAFolderRoutesToTheTerminalAtItself() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let router = FileRouter(declarations: BuiltInApplets.declarations)

    XCTAssertEqual(
      router.decide(folder),
      .open(
        file: folder, appletTypeID: "terminal", startDirectory: folder.path, type: "public.folder")
    )
  }

  /// Catches a package taken for a folder. A bundle conforms to `public.directory` and not to
  /// `public.folder`, so the router refuses it as unsupported.
  func testAPackageIsRefusedAsUnsupported() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let bundle = folder.appendingPathComponent("Thing.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

    let router = FileRouter(declarations: BuiltInApplets.declarations)

    guard case .refused(_, .unsupported(let type)) = router.decide(bundle) else {
      return XCTFail("expected the package to be refused")
    }

    XCTAssertEqual(type, "com.apple.application-bundle")
  }

  private func makeFolder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-catalog-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
