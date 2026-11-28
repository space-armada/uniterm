// swift-tools-version: 6.2

import Foundation
import PackageDescription

// The terminal surface module is the only target that may depend on GhosttyKit. The path is fixed.
// scripts/build-ghostty.sh points it at the current keyed artifact.
let ghosttyKitPath = "Frameworks/GhosttyKit.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

if !FileManager.default.fileExists(atPath: packageRoot.appending(path: ghosttyKitPath).path) {
  fatalError(
    "GhosttyKit.xcframework is missing at Packages/UnitermKit/\(ghosttyKitPath). Run `make build`.")
}

let package = Package(
  name: "UnitermKit",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "ProcessInspection", targets: ["ProcessInspection"]),
    .library(name: "ThemeCore", targets: ["ThemeCore"]),
    .library(name: "Theme", targets: ["Theme"]),
    .library(name: "Preferences", targets: ["Preferences"]),
    .library(name: "PaneModel", targets: ["PaneModel"]),
    .library(name: "LayoutKit", targets: ["LayoutKit"]),
    .library(name: "WindowKit", targets: ["WindowKit"]),
    .library(name: "SettingsKit", targets: ["SettingsKit"]),
    .library(name: "TerminalSurface", targets: ["TerminalSurface"]),
    .library(name: "StatusKit", targets: ["StatusKit"]),
    .library(name: "AppletKit", targets: ["AppletKit"]),
    .library(name: "TerminalApplet", targets: ["TerminalApplet"]),
    .library(name: "FileRouting", targets: ["FileRouting"]),
    .library(name: "AppletCatalog", targets: ["AppletCatalog"]),
    .library(name: "SourceAccess", targets: ["SourceAccess"]),
    .library(name: "FileWatching", targets: ["FileWatching"]),
    .library(name: "TableData", targets: ["TableData"]),
    .library(name: "DataViewerApplet", targets: ["DataViewerApplet"]),
    .library(name: "GeoData", targets: ["GeoData"]),
    .library(name: "MapViewerApplet", targets: ["MapViewerApplet"]),
    .library(name: "PlaceSearch", targets: ["PlaceSearch"]),
    .library(name: "BrowserModel", targets: ["BrowserModel"]),
    .library(name: "BrowserApplet", targets: ["BrowserApplet"]),
    .library(name: "HelperWire", targets: ["HelperWire"]),
    .library(name: "HelperHost", targets: ["HelperHost"]),
    .library(name: "DocumentWire", targets: ["DocumentWire"]),
    .library(name: "DocumentDecoding", targets: ["DocumentDecoding"]),
    .library(name: "TextViewerModel", targets: ["TextViewerModel"]),
    .library(name: "TextViewerApplet", targets: ["TextViewerApplet"]),
    .library(name: "ImageDecoding", targets: ["ImageDecoding"]),
    .library(name: "ImageViewerApplet", targets: ["ImageViewerApplet"]),
    .library(name: "ScriptWire", targets: ["ScriptWire"]),
    .library(name: "ScriptRuntime", targets: ["ScriptRuntime"]),
    .library(name: "ScriptHost", targets: ["ScriptHost"]),
    .library(name: "ReplApplet", targets: ["ReplApplet"]),
    .library(name: "QuestionsApplet", targets: ["QuestionsApplet"]),
    .library(name: "ExecDriver", targets: ["ExecDriver"]),
    // Only a debug build of the app registers the fixtures, behind UNITERM_TEST_APPLETS.
    .library(name: "AppletFixtures", targets: ["AppletFixtures"]),
  ],
  dependencies: [
    // The first third-party Swift package. Only TableData uses it. The version is exact, and
    // Package.resolved is committed beside this file and in the Xcode workspace.
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
  ],
  targets: [
    // Process info helpers with no dependencies. It reads process identity and ancestry through
    // sysctl, which works on setuid root processes, and signals a process only while it is the one
    // a caller recorded. TerminalSurface, TerminalApplet, ScriptHost, and BrowserApplet use it, and
    // so do the ProcessTestSupport, ScriptTestSupport, ScriptHostTests, BrowserAppletTests,
    // ExecDriverTests, and TerminalSurfaceTests test targets.
    .target(name: "ProcessInspection"),
    // Writes a private file so a crash leaves the old one or the new one. The layout store and the
    // controller policy store both use it. It has no dependencies.
    .target(name: "AtomicFile"),
    // The palette's tokens, flavors, color values, and color math, with no AppKit. GeoData reads the
    // accent set from it. Theme adds the AppKit colors and re-exports it, so `import Theme` still
    // sees every name.
    .target(name: "ThemeCore"),
    .target(name: "Theme", dependencies: ["ThemeCore"]),
    .target(name: "Preferences"),
    .target(name: "StatusKit"),
    .target(
      name: "AppletKit",
      dependencies: ["ProcessInspection", "SourceAccess", "StatusKit", "Theme"]),
    .target(name: "PaneModel"),
    .target(name: "LayoutKit", dependencies: ["AppletKit", "AtomicFile", "PaneModel"]),
    .target(name: "FileRouting", dependencies: ["AppletKit"]),
    // An applet's exec driver: the JSON-lines wire, the bounded pipes, and the child process. It
    // reads and writes on threads of its own and hops to the main thread with bounded batches.
    .target(name: "ExecDriver", dependencies: ["AppletKit", "ProcessInspection", "StatusKit"]),
    .target(
      name: "WindowKit",
      dependencies: [
        "Theme", "Preferences", "AppletKit", "StatusKit", "PaneModel", "LayoutKit", "FileRouting",
        "GeoData", "PlaceSearch", "ScriptHost", "ScriptWire", "ExecDriver", "ControllerPackage",
        "ControllerTrust", "SourceAccess", "BrowserModel", "QuestionForm", "QuestionsApplet",
        "ProcessInspection",
      ]),
    .target(name: "SettingsKit", dependencies: ["Preferences"]),
    .binaryTarget(name: "GhosttyKit", path: ghosttyKitPath),
    .target(
      name: "TerminalSurface",
      dependencies: ["GhosttyKit", "ProcessInspection", "Theme"],
      // ghostty.h is an umbrella header that leaves out the headers beside it in the xcframework.
      // The artifact stays as Ghostty built it, so the warning is silenced here.
      swiftSettings: [.unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"])],
      // The static library needs the C++ runtime and the system frameworks that Ghostty's own
      // app links. A binary target carries no link settings.
      linkerSettings: [
        .linkedLibrary("c++"),
        .linkedFramework("Carbon"),
        .linkedFramework("Metal"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("CoreText"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("IOSurface"),
        .linkedFramework("AppKit"),
      ]),
    .target(
      name: "TerminalApplet",
      dependencies: [
        "AppletKit", "ProcessInspection", "SourceAccess", "StatusKit", "TerminalSurface", "Theme",
      ]),
    // Reaching a file for a viewer: the stored path and bookmark, and the errors for a missing,
    // protected, or irregular file. It has no AppKit, so the table and map targets share it.
    .target(name: "SourceAccess"),
    // Watching one file for change: the file and its folder, bursts merged on an injected clock,
    // and a look at a path that is gone. The map and text viewers share it.
    .target(name: "FileWatching"),
    .target(
      name: "TableData",
      dependencies: ["SourceAccess", .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
    .target(
      name: "DataViewerApplet",
      dependencies: ["AppletKit", "SourceAccess", "StatusKit", "TableData", "Theme"]),
    // The map's pure model. It has no AppKit and no MapKit, so the region and style rules test
    // without a map view.
    .target(name: "GeoData", dependencies: ["ThemeCore"]),
    // Finding and naming places through Apple Maps, and the search field the launcher and the map
    // share. Every service sits behind a protocol, so tests never reach the network.
    .target(name: "PlaceSearch", dependencies: ["GeoData", "Theme"]),
    .target(
      name: "MapViewerApplet",
      dependencies: [
        "AppletKit", "FileWatching", "GeoData", "PlaceSearch", "SourceAccess", "StatusKit", "Theme",
      ]),
    // The browser's pure rules: which URL schemes load from which source, where a scheme-less
    // address goes, and the description payload. It has no AppKit and no WebKit, so the policy
    // tests without a web view.
    .target(name: "BrowserModel"),
    .target(
      name: "BrowserApplet",
      dependencies: [
        "AppletKit", "BrowserModel", "Preferences", "ProcessInspection", "StatusKit", "Theme",
      ]),
    // What every helper's wire shares: frame headers, the framed socket with descriptor passing,
    // big-endian field coding, and zero-filled page buffers. It has no AppKit.
    .target(name: "HelperWire"),
    // What the app shares in supervising any helper: where the executable is, spawning and reaping
    // it, reading its footprint, and the rules that tell a hung helper from a slow one.
    .target(name: "HelperHost", dependencies: ["HelperWire"]),
    // The image helper's decode-only wire format: the protocol version, the named output color
    // spaces, the messages, and the checks on sizes. It has no AppKit and no ImageIO, so the app
    // and the helper share one codec and the fuzzers can reach it alone.
    .target(name: "ImageWire", dependencies: ["HelperWire"]),
    // The helper side of image viewing. It is the only code that calls ImageIO.
    .target(name: "ImageDecoding", dependencies: ["ImageWire"]),
    // A thin main over ImageDecoding, so the supervisor's tests can run a helper without the App
    // Sandbox. The shipped helper is the Xcode target of the same name.
    .executableTarget(name: "ImageDecoderHelper", dependencies: ["ImageDecoding"]),
    // The image viewer's pure rules: folder listing and order, the request scheduler, the
    // budgets, and fit math. It has no AppKit and no ImageIO.
    .target(name: "ImageViewerModel", dependencies: ["AppletKit", "ImageWire", "SourceAccess"]),
    .target(
      name: "ImageViewerApplet",
      dependencies: [
        "AppletKit", "HelperHost", "ImageViewerModel", "ImageWire", "SourceAccess", "StatusKit",
        "Theme",
      ]),
    // The document helper's decode-only wire format: the protocol version, the messages, the
    // reader kinds, and the checks on a reply. It has no AppKit, so the app and the helper share
    // one codec and the fuzzers can reach it alone.
    .target(name: "DocumentWire", dependencies: ["HelperWire"]),
    // The helper side of RTF and Word. It is the only code that calls the system document readers.
    .target(name: "DocumentDecoding", dependencies: ["DocumentWire"]),
    // A thin main over DocumentDecoding, so the supervisor's tests can run a helper without the
    // App Sandbox. The shipped helper is the Xcode target of the same name.
    .executableTarget(name: "DocumentDecoderHelper", dependencies: ["DocumentDecoding"]),
    // The text viewer's pure rules: the description, the format rule, and the caps.
    .target(name: "TextViewerModel", dependencies: ["AppletKit", "DocumentWire"]),
    .target(
      name: "TextViewerApplet",
      dependencies: [
        "AppletKit", "BrowserApplet", "DocumentWire", "FileWatching", "HelperHost", "SourceAccess",
        "StatusKit", "TextViewerModel", "Theme",
      ],
      resources: [.copy("Resources/web")]),
    // Embedded Janet, vendored from the release janet.pin names, and the small C shim that is the
    // only code that calls it. Only the script helper targets may depend on it, so Janet never
    // links into the app. scripts/check-janet-isolation.sh enforces that.
    //
    // The vendored source is not edited, so its own deprecation warning is silenced here instead.
    // Unbuilt holds Janet's line editor, vendored from the same release. Its own file is not
    // compiled. uniterm_janet_line.c includes it with `main` renamed away, so the REPL reaches the
    // editor's history without any edit to the vendored source.
    .target(
      name: "CJanet", exclude: ["Unbuilt"],
      cSettings: [.headerSearchPath("."), .unsafeFlags(["-Wno-deprecated-declarations"])]),
    // The wire between the app and a script helper: the protocol version, the host calls a script
    // makes, and their replies. It has no AppKit and no Janet, so the app and the helper share one
    // codec and the fuzzers can reach it alone.
    .target(name: "ScriptWire", dependencies: ["HelperWire"]),
    // A controller package's descriptor, signature, snapshot, and native load check. The app,
    // the signer, and the helper's loader all read packages through it, so they read one meaning
    // from the same bytes. It has no AppKit and no Janet.
    .target(name: "ControllerPackage", dependencies: ["ScriptWire", "SourceAccess"]),
    // Remembered controller approvals: the selectors, the typed scopes and how one covers another,
    // and the private policy file. It has no AppKit, so the app's admission and the fuzzers share
    // one reading of the file.
    .target(
      name: "ControllerTrust", dependencies: ["AtomicFile", "ControllerPackage", "SourceAccess"]),
    // The Questions applet's form: the spec a script sends, its strict reader and caps, the
    // validation of answers, the `pattern` dialect, and the result shapes. It has no AppKit and
    // no Janet, so the app, the helper, and the fuzzers read one meaning from the same bytes.
    .target(name: "QuestionForm", dependencies: ["ControllerPackage", "ScriptWire"]),
    // The helper side of scripting. It owns the one Janet VM of its process, on its main thread.
    .target(name: "ScriptRuntime", dependencies: ["CJanet", "ControllerPackage", "ScriptWire"]),
    // A thin main over ScriptRuntime, so tests can run a helper without the hardened runtime. The
    // shipped command is the Xcode target UnitermCLI.
    .executableTarget(name: "ScriptHelper", dependencies: ["ScriptRuntime"]),
    // The app side of scripting: the listener, the peers, and the dispatch of their calls. It
    // never imports Janet.
    .target(
      name: "ScriptHost",
      dependencies: [
        "ControllerPackage", "ControllerTrust", "FileRouting", "HelperHost", "PaneModel",
        "Preferences", "ProcessInspection", "QuestionForm", "ScriptWire", "SourceAccess",
        "StatusKit",
      ]),
    // The REPL applet. It hosts a terminal session whose child is the REPL helper, and binds the
    // helper's control channel to its pane through the script host. It never imports Janet.
    .target(
      name: "ReplApplet",
      dependencies: [
        "AppletKit", "ProcessInspection", "ScriptHost", "ScriptWire", "StatusKit",
        "TerminalSurface",
        "Theme",
      ]),
    // The Questions applet: the pane that shows the forms programs ask, a tab for each requester.
    // It draws the requester's header itself and holds no script, wire, or Janet code. A host
    // opens a form through its in-process API and hears the outcome through a callback.
    .target(
      name: "QuestionsApplet",
      dependencies: ["AppletKit", "QuestionForm", "StatusKit", "Theme"]),
    .target(
      name: "AppletCatalog",
      dependencies: [
        "AppletKit", "BrowserApplet", "DataViewerApplet", "ImageViewerApplet", "MapViewerApplet",
        "QuestionsApplet", "ReplApplet", "TerminalApplet", "TextViewerApplet",
      ]),
    .testTarget(name: "StatusKitTests", dependencies: ["StatusKit"]),
    .testTarget(
      name: "FileRoutingTests", dependencies: ["FileRouting", "AppletKit", "DefaultsTestSupport"]),
    .testTarget(
      name: "AppletCatalogTests",
      dependencies: [
        "AppletCatalog", "FileRouting", "AppletKit", "WindowKit", "BrowserApplet", "Preferences",
        "BrowserTestSupport", "TerminalApplet", "ReplApplet", "DataViewerApplet", "MapViewerApplet",
        "ImageViewerApplet", "TextViewerApplet", "QuestionsApplet", "DefaultsTestSupport",
      ]),
    // Ends a test process whose `swift test` is gone, so a hung test cannot outlive a cancelled
    // run. Every test target links into one bundle, so one test target's dependency guards all.
    .target(name: "TestProcessGuard", path: "Tests/TestProcessGuard"),
    // A defaults suite per test that deletes its preference file too, so test runs stop piling up
    // files in ~/Library/Preferences.
    .target(name: "DefaultsTestSupport", path: "Tests/DefaultsTestSupport"),
    .testTarget(name: "DefaultsTestSupportTests", dependencies: ["DefaultsTestSupport"]),
    // Test support. It builds ZIP archives for the tests of both targets that read workbooks, and
    // holds the seeded generator the table and map fuzzers share.
    .target(name: "TableTestSupport", path: "Tests/TableTestSupport"),
    // The recording host the applet tests share, so each applet's tests read one set of deliveries.
    .target(
      name: "AppletTestSupport", dependencies: ["AppletKit", "StatusKit"],
      path: "Tests/AppletTestSupport"),
    // Hosted slide, notes, and chart applets with real command and event schemas. The exec wire
    // and shared dispatch are tested against them, and a debug app can register them.
    .target(
      name: "AppletFixtures", dependencies: ["AppletKit", "SourceAccess", "Theme"],
      path: "Tests/AppletFixtures"),
    // The perl driver the exec tests run, with a mode for each way a driver behaves or misbehaves.
    .target(
      name: "ExecTestSupport", path: "Tests/ExecTestSupport", resources: [.copy("Fixtures")]),
    // The one place tests record the test process as a terminal session root, for the script
    // host's tests and the REPL applet's.
    .target(
      name: "ScriptTestSupport", dependencies: ["PaneModel", "ProcessInspection", "ScriptHost"],
      path: "Tests/ScriptTestSupport"),
    // The one way a package test signals a process that something other than the test reaps. It
    // signals only the process whose pid and start time the test recorded.
    .target(
      name: "ProcessTestSupport", dependencies: ["ProcessInspection"],
      path: "Tests/ProcessTestSupport"),
    // A local HTTP server for the browser's tests, so a web view loads real pages from a real
    // socket and no test reaches the network.
    .target(name: "BrowserTestSupport", path: "Tests/BrowserTestSupport"),
    // The controller packages, keys, and descriptors that the app's, the signer's, and the
    // loader's tests share, so all three are held to one reading of the same bytes.
    .target(
      name: "ControllerTestSupport", dependencies: ["ControllerPackage"],
      path: "Tests/ControllerTestSupport", resources: [.copy("Fixtures")]),
    // A native controller for the tests: it connects to the app and makes one call. It speaks the
    // wire through ScriptWire, so it links no Janet.
    .executableTarget(
      name: "ControllerNativeFixture", dependencies: ["ScriptWire"],
      path: "Tests/ControllerNativeFixture"),
    .testTarget(
      name: "ControllerPackageTests",
      dependencies: [
        "ControllerNativeFixture", "ControllerPackage", "ControllerTestSupport", "ScriptWire",
        "SourceAccess", "TableTestSupport",
      ]),
    .testTarget(
      name: "ControllerTrustTests",
      dependencies: [
        "AtomicFile", "ControllerPackage", "ControllerTrust", "ControllerTestSupport",
        "SourceAccess", "TableTestSupport",
      ]),
    // JavaScriptCore is linked here only. It is the reference the pattern translator is
    // compared against, and the app never loads it.
    .testTarget(
      name: "QuestionFormTests",
      dependencies: ["ControllerPackage", "QuestionForm", "ScriptWire", "TableTestSupport"],
      linkerSettings: [.linkedFramework("JavaScriptCore")]),
    .testTarget(
      name: "QuestionsAppletTests",
      dependencies: [
        "QuestionsApplet", "QuestionForm", "AppletKit", "StatusKit", "Theme", "AppletTestSupport",
      ]),
    .testTarget(name: "TableDataTests", dependencies: ["TableData", "TableTestSupport"]),
    .testTarget(
      name: "DataViewerAppletTests",
      dependencies: [
        "DataViewerApplet", "TableData", "AppletKit", "StatusKit", "Theme", "TableTestSupport",
        "AppletTestSupport",
      ]),
    .testTarget(name: "SourceAccessTests", dependencies: ["SourceAccess"]),
    .testTarget(name: "FileWatchingTests", dependencies: ["FileWatching"]),
    .testTarget(name: "GeoDataTests", dependencies: ["GeoData", "ThemeCore"]),
    .testTarget(name: "PlaceSearchTests", dependencies: ["PlaceSearch", "GeoData", "Theme"]),
    .testTarget(
      name: "MapViewerAppletTests",
      dependencies: [
        "MapViewerApplet", "FileWatching", "GeoData", "AppletKit", "PlaceSearch", "SourceAccess",
        "StatusKit",
        "Theme", "TableTestSupport", "AppletTestSupport", "ExecDriver", "ScriptWire",
      ]),
    .testTarget(name: "BrowserModelTests", dependencies: ["BrowserModel"]),
    // Generates image files in code for the image tests, and finds the unsandboxed helper that
    // SwiftPM builds beside the test bundle.
    .target(name: "ImageTestSupport", path: "Tests/ImageTestSupport"),
    .testTarget(name: "ImageWireTests", dependencies: ["ImageWire", "TableTestSupport"]),
    .testTarget(
      name: "ImageDecodingTests",
      dependencies: ["ImageDecoding", "ImageWire", "ImageTestSupport"]),
    .testTarget(
      name: "ImageViewerModelTests",
      dependencies: [
        "ImageViewerModel", "ImageWire", "SourceAccess", "ImageTestSupport", "AppletKit",
      ]),
    .testTarget(
      name: "ImageViewerAppletTests",
      dependencies: [
        "ImageViewerApplet", "ImageViewerModel", "ImageWire", "ImageDecoding", "ImageDecoderHelper",
        "HelperHost", "AppletKit",
        "StatusKit", "Theme", "SourceAccess", "AppletTestSupport", "ImageTestSupport",
      ]),
    .testTarget(
      name: "BrowserAppletTests",
      dependencies: [
        "BrowserApplet", "BrowserModel", "AppletKit", "Preferences", "ProcessInspection",
        "ProcessTestSupport", "StatusKit", "Theme", "BrowserTestSupport", "AppletTestSupport",
      ]),
    // Generates document files in code for the text viewer's tests, and finds the unsandboxed
    // helper that SwiftPM builds beside the test bundle.
    .target(
      name: "DocumentTestSupport", dependencies: ["TableTestSupport"],
      path: "Tests/DocumentTestSupport"),
    .testTarget(name: "HelperHostTests", dependencies: ["HelperHost"]),
    .testTarget(
      name: "DocumentDecodingTests",
      dependencies: ["DocumentDecoding", "DocumentWire", "DocumentTestSupport"]),
    .testTarget(name: "DocumentWireTests", dependencies: ["DocumentWire", "TableTestSupport"]),
    .testTarget(name: "TextViewerModelTests", dependencies: ["TextViewerModel", "AppletKit"]),
    .testTarget(
      name: "TextViewerAppletTests",
      dependencies: [
        "TextViewerApplet", "TextViewerModel", "DocumentWire", "DocumentDecoderHelper",
        "HelperHost", "SourceAccess", "FileWatching",
        "BrowserApplet", "AppletKit", "StatusKit", "Theme", "AppletTestSupport",
        "DocumentTestSupport", "TableTestSupport", "BrowserTestSupport", "ProcessTestSupport",
      ]),
    .testTarget(name: "ScriptWireTests", dependencies: ["ScriptWire", "TableTestSupport"]),
    // Holds the shim's reply reader against crafted bytes, so it reaches the Janet C target.
    .testTarget(
      name: "ScriptRuntimeTests",
      dependencies: [
        "ScriptRuntime", "ScriptWire", "CJanet", "ControllerPackage", "ControllerTestSupport",
        "SourceAccess",
      ]),
    .testTarget(
      name: "ScriptHostTests",
      dependencies: [
        "ControllerNativeFixture", "ControllerPackage", "ControllerTestSupport", "FileRouting",
        "Preferences", "ProcessInspection", "ProcessTestSupport", "ScriptHost", "ScriptWire",
        "ScriptHelper", "ScriptTestSupport", "SourceAccess", "StatusKit", "DefaultsTestSupport",
      ],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "ReplAppletTests",
      dependencies: [
        "ReplApplet", "AppletKit", "ScriptHost", "ScriptWire", "StatusKit", "TerminalSurface",
        "WindowKit", "Preferences", "AppletTestSupport", "ScriptTestSupport", "DefaultsTestSupport",
        "ProcessInspection", "ScriptHelper",
      ]),
    .testTarget(name: "PaneModelTests", dependencies: ["PaneModel"]),
    .testTarget(name: "ProcessInspectionTests", dependencies: ["ProcessInspection"]),
    .testTarget(
      name: "ProcessTestSupportTests",
      dependencies: ["ProcessTestSupport", "ProcessInspection"]),
    .testTarget(
      name: "AppletKitTests",
      dependencies: ["AppletKit", "AppletTestSupport", "AppletFixtures", "SourceAccess"]),
    .testTarget(
      name: "ExecDriverTests",
      dependencies: [
        "ExecDriver", "AppletKit", "AppletFixtures", "StatusKit", "TableTestSupport",
        "ExecTestSupport", "ProcessInspection", "ProcessTestSupport",
      ]),
    .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit", "AppletKit", "PaneModel"]),
    .testTarget(
      name: "TerminalAppletTests",
      dependencies: [
        "TerminalApplet", "AppletKit", "StatusKit", "TerminalSurface", "Theme", "WindowKit",
        "Preferences", "AppletTestSupport", "ScriptHost", "ScriptWire", "DefaultsTestSupport",
      ]),
    .testTarget(
      name: "SettingsKitTests", dependencies: ["SettingsKit", "Preferences", "DefaultsTestSupport"]),
    .testTarget(name: "ThemeTests", dependencies: ["Theme"]),
    .testTarget(name: "PreferencesTests", dependencies: ["Preferences", "DefaultsTestSupport"]),
    .testTarget(
      name: "TerminalSurfaceTests",
      dependencies: ["TerminalSurface", "Theme", "ProcessInspection", "ProcessTestSupport"]),
    .testTarget(
      name: "WindowKitTests",
      dependencies: [
        "WindowKit", "Theme", "Preferences", "StatusKit", "AppletKit", "PaneModel", "LayoutKit",
        "FileRouting", "GeoData", "PlaceSearch", "ScriptHost", "ScriptWire", "ScriptTestSupport",
        "AppletFixtures", "ExecDriver", "ExecTestSupport", "ScriptHelper", "ControllerPackage",
        "ControllerTrust", "TestProcessGuard", "TextViewerApplet", "SourceAccess",
        "MapViewerApplet", "BrowserApplet", "BrowserModel", "BrowserTestSupport", "QuestionForm",
        "QuestionsApplet", "DefaultsTestSupport", "ProcessTestSupport", "ProcessInspection",
      ]),
  ],
  swiftLanguageModes: [.v6],
  cLanguageStandard: .c99
)

// The Swift 6.3.3 optimizer aborts in its CopyPropagation pass on some functions, such as
// StatusQueue.present and HistoryPanelView.tableView(_:viewFor:row:). Which functions trip it is not
// predictable, so the pass is off for every Swift target in an optimized build. Remove this once
// the toolchain no longer crashes. `swift build -c release` is the check.
for target in package.targets where target.type != .binary {
  target.swiftSettings =
    (target.swiftSettings ?? [])
    + [
      .unsafeFlags(
        ["-Xllvm", "-sil-disable-pass=copy-propagation"], .when(configuration: .release))
    ]
}
