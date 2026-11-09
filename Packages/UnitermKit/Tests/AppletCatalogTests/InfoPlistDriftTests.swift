import AppletCatalog
import AppletKit
import FileRouting
import Foundation
import XCTest

final class InfoPlistDriftTests: XCTestCase {
  private func loadPlist() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("App/Info.plist")

    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(plist as? [String: Any])
  }

  private var declarations: [AppletTypeDeclaration] { BuiltInApplets.declarations }

  /// Catches an Info.plist that loses the web-content exception, so plain `http` pages stop loading
  /// in the browser. It also catches an app-wide exception in its place, which would let
  /// uniterm's own network traffic fall back to plain HTTP. Loopback is exempt from the transport
  /// rules already, so no test can show the key's effect on a named host. The plist is the app's
  /// real one.
  func testPlainHTTPIsAllowedInWebContentAndNowhereElse() throws {
    let security = try XCTUnwrap(try loadPlist()["NSAppTransportSecurity"] as? [String: Any])

    XCTAssertEqual(Set(security.keys), ["NSAllowsArbitraryLoadsInWebContent"])
    XCTAssertEqual(security["NSAllowsArbitraryLoadsInWebContent"] as? Bool, true)
  }

  /// Catches camera or microphone usage strings arriving without real capture support. With them,
  /// WebKit exposes the native API and asks macOS first, measured in the running app, so a page
  /// could raise a system prompt for capture the browser denies. The plist is the app's real one.
  func testTheAppDeclaresNoCameraOrMicrophoneUse() throws {
    let plist = try loadPlist()

    XCTAssertNil(plist["NSCameraUsageDescription"])
    XCTAssertNil(plist["NSMicrophoneUsageDescription"])
  }

  /// Catches `LSFileQuarantineEnabled` in the app's Info.plist. It applies to the whole process, so
  /// every file the terminal's shells create would be quarantined. The browser marks each finished
  /// download on its own. The plist is the app's real one.
  func testTheAppDoesNotQuarantineEveryFileItWrites() throws {
    let plist = try loadPlist()

    XCTAssertNil(plist["LSFileQuarantineEnabled"])
    XCTAssertFalse(plist.keys.contains { $0.localizedCaseInsensitiveContains("quarantine") })
  }

  /// Catches an applet that declares a type the app never registers with Launch Services, a type
  /// registered with no applet behind it, a rank above Alternate that would displace another app,
  /// and a role other than Viewer. The plist is the app's real one.
  ///
  /// The plist rank is always Alternate, whatever rank the applet declares, so a change to a
  /// declared rank is not drift by design.
  func testTheAppsDocumentTypesMatchTheAppletDeclarations() throws {
    let plist = try loadPlist()

    XCTAssertEqual(DocumentTypeManifest.problems(in: plist, declarations: declarations), [])

    for entry in DocumentTypeManifest.documentTypes(in: plist) {
      XCTAssertEqual(entry["CFBundleTypeRole"] as? String, "Viewer")
    }
  }

  /// Catches a plist whose imports disagree with the catalog. The audit takes its table from the
  /// plist, so a declared type that the system lacks must be imported there with a conformance.
  func testTheCatalogAuditPassesAgainstThePlistsImportedTypes() throws {
    let imported = DocumentTypeManifest.importedTypes(in: try loadPlist())

    XCTAssertEqual(
      CatalogAudit.problems(
        in: declarations, types: SystemContentTypes(), imported: imported), [])
  }

  /// Catches a Markdown import that drops an extension or its conformance. A `.md` file can type as
  /// another app's `com.unknown.md`, which does not conform to Markdown, and the router then finds
  /// no viewer for it. The import tells Launch Services that uniterm's Markdown type owns the
  /// extensions. Whether the system prefers it over another app's claim depends on the machine, and
  /// no test can prove that.
  func testTheMarkdownTypeIsImportedWithItsExtensions() throws {
    let plist = try loadPlist()
    let entries = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
    let markdown = try XCTUnwrap(
      entries.first { $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" })
    let tags = try XCTUnwrap(markdown["UTTypeTagSpecification"] as? [String: Any])

    XCTAssertEqual(markdown["UTTypeConformsTo"] as? [String], ["public.plain-text"])
    XCTAssertEqual(
      Set(tags["public.filename-extension"] as? [String] ?? []),
      ["md", "markdown", "mdown", "mkd", "mkdn"])
    XCTAssertEqual(tags["public.mime-type"] as? String, "text/markdown")
  }

  // MARK: The checker can fail

  private func entry(types: [String], rank: String?) -> [String: Any] {
    var entry: [String: Any] = [
      "CFBundleTypeName": "Test", "LSItemContentTypes": types,
    ]

    if let rank { entry["LSHandlerRank"] = rank }

    return entry
  }

  private var allDeclared: [String] {
    declarations.flatMap { $0.opens.map(\.identifier) }
  }

  func testAnOwnerRankIsReported() {
    let plist: [String: Any] = [
      "CFBundleDocumentTypes": [entry(types: allDeclared, rank: "Owner")]
    ]

    XCTAssertEqual(
      DocumentTypeManifest.problems(in: plist, declarations: declarations),
      [.rankNotAlternate(entry: "Test", rank: "Owner")])
  }

  func testAMissingRankIsReported() {
    let plist: [String: Any] = [
      "CFBundleDocumentTypes": [entry(types: allDeclared, rank: nil)]
    ]

    XCTAssertEqual(
      DocumentTypeManifest.problems(in: plist, declarations: declarations),
      [.rankNotAlternate(entry: "Test", rank: nil)])
  }

  func testADeclaredTypeWithNoEntryAndAnEntryWithNoApplet() {
    let plist: [String: Any] = [
      "CFBundleDocumentTypes": [entry(types: ["public.png"], rank: "Alternate")]
    ]

    XCTAssertEqual(
      DocumentTypeManifest.problems(in: plist, declarations: declarations),
      [
        .undeclared(type: "com.adobe.pdf"),
        .undeclared(type: "com.microsoft.word.doc"),
        .undeclared(type: "net.daringfireball.markdown"),
        .undeclared(type: "org.openxmlformats.spreadsheetml.sheet"),
        .undeclared(type: "org.openxmlformats.wordprocessingml.document"),
        .undeclared(type: "public.comma-separated-values-text"),
        .undeclared(type: "public.folder"), .undeclared(type: "public.geojson"),
        .undeclared(type: "public.image"), .undeclared(type: "public.json"),
        .undeclared(type: "public.rtf"),
        .unclaimed(type: "public.png"),
      ])
  }

  func testAPlistWithNoDocumentTypesReportsEveryDeclaredType() {
    XCTAssertEqual(
      DocumentTypeManifest.problems(in: [:], declarations: declarations),
      [
        .undeclared(type: "com.adobe.pdf"),
        .undeclared(type: "com.microsoft.word.doc"),
        .undeclared(type: "net.daringfireball.markdown"),
        .undeclared(type: "org.openxmlformats.spreadsheetml.sheet"),
        .undeclared(type: "org.openxmlformats.wordprocessingml.document"),
        .undeclared(type: "public.comma-separated-values-text"),
        .undeclared(type: "public.folder"), .undeclared(type: "public.geojson"),
        .undeclared(type: "public.image"),
        .undeclared(type: "public.json"),
        .undeclared(type: "public.rtf"),
      ])
  }

  /// Catches an import read wrongly. The table maps each imported identifier to its conformances.
  func testImportedTypesAreReadWithTheirConformances() {
    let plist: [String: Any] = [
      "UTImportedTypeDeclarations": [
        ["UTTypeIdentifier": "org.example.geo", "UTTypeConformsTo": ["public.json"]],
        ["UTTypeIdentifier": "org.example.bare"],
      ]
    ]

    XCTAssertEqual(
      DocumentTypeManifest.importedTypes(in: plist),
      ["org.example.geo": ["public.json"], "org.example.bare": []])
  }
}
