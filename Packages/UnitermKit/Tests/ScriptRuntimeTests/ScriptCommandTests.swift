import CJanet
import Darwin
import Foundation
import ScriptWire
import XCTest

@testable import ScriptRuntime

/// The command's own rules, with no app and no process: where it may run from, what it parses,
/// which address it picks, and which capabilities it grants.
///
/// They prove each rule on fake bundles and plain arguments. They cannot prove the real bundle's
/// layout, which `ScriptRunUITests` checks against the built app.
final class ScriptCommandTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ut-\(UUID().uuidString.prefix(8))", isDirectory: true)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// A bundle laid out as Xcode builds one, with a main executable named in its Info.plist.
  private func makeBundle(named name: String = "uniterm", mainExecutable: Bool = true) throws
    -> URL
  {
    let bundle = root.appendingPathComponent("\(name).app", isDirectory: true)
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)

    for folder in ["MacOS", "Helpers"] {
      try FileManager.default.createDirectory(
        at: contents.appendingPathComponent(folder), withIntermediateDirectories: true)
    }

    let plist: [String: Any] = ["CFBundleExecutable": name]

    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))

    if mainExecutable {
      let main = contents.appendingPathComponent("MacOS/\(name)")

      try Data("main".utf8).write(to: main)
      XCTAssertEqual(chmod(main.path, 0o755), 0)
    }

    let helper = contents.appendingPathComponent("Helpers/uniterm")

    try Data("helper".utf8).write(to: helper)
    XCTAssertEqual(chmod(helper.path, 0o755), 0)

    return helper
  }

  private func refusal(_ path: URL) -> String? {
    ScriptCommandLocation.refusal(forResolved: ScriptCommandLocation.realpath(path.path))
  }

  /// Catches a command that refuses its own bundle, or accepts a copy. The bundle's helper passes.
  /// A copy beside the bundle, in a folder, or in a bundle with no main executable is refused with
  /// a message to reinstall.
  func testOnlyTheHelperInsideARealBundleIsTheBundlesOwn() throws {
    let helper = try makeBundle()

    XCTAssertNil(refusal(helper))

    let copy = root.appendingPathComponent("uniterm")

    try FileManager.default.copyItem(at: helper, to: copy)

    XCTAssertNotNil(refusal(copy))
    XCTAssertTrue(refusal(copy)?.contains("Reinstall") == true, refusal(copy) ?? "")

    let loose = root.appendingPathComponent("Contents/Helpers", isDirectory: true)

    try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: helper, to: loose.appendingPathComponent("uniterm"))

    XCTAssertNotNil(
      refusal(loose.appendingPathComponent("uniterm")), "a folder named like a bundle passed")

    let hollow = try makeBundle(named: "hollow", mainExecutable: false)

    XCTAssertNotNil(refusal(hollow), "a bundle with no main executable passed")
  }

  /// Catches a symlink on `PATH` being judged by where it sits instead of where it leads. A link
  /// into the bundle passes. A link to a copy is refused.
  func testALinkIsJudgedByWhereItLeads() throws {
    let helper = try makeBundle()
    let good = root.appendingPathComponent("good-link")
    let copy = root.appendingPathComponent("copy")
    let bad = root.appendingPathComponent("bad-link")

    try FileManager.default.createSymbolicLink(at: good, withDestinationURL: helper)
    try FileManager.default.copyItem(at: helper, to: copy)
    try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: copy)

    XCTAssertNil(refusal(good))
    XCTAssertNotNil(refusal(bad))
    XCTAssertNotNil(ScriptCommandLocation.refusal(forResolved: nil))
  }

  /// Catches the check being skipped by the shipped command. This process is neither a bundle's
  /// helper nor a link to one, so a command that insists must refuse it with its own status.
  func testACommandThatInsistsRefusesToRunFromOutsideABundle() {
    XCTAssertEqual(
      ScriptHelperMain.run(arguments: ["uniterm", "run", "--help"], identity: .bundle),
      ScriptHelperMain.Exit.notBundleCommand)
    XCTAssertEqual(
      ScriptHelperMain.run(arguments: ["uniterm", "run", "--help"], identity: .unchecked),
      ScriptHelperMain.Exit.ok)
  }

  func testTheCommandLineParsesFlagsInAnyOrderAndLeavesTheScriptsArgumentsAlone() {
    typealias Invocation = ScriptHelperMain.Invocation

    XCTAssertEqual(
      Invocation.parse([
        "run", "--allow", "fs-read", "--socket", "/s", "--allow", "net-connect", "a.janet",
        "--allow",
        "x", "-h",
      ]),
      .run(
        Invocation(
          allowed: ["fs-read", "net-connect"], socket: "/s", script: "a.janet",
          arguments: ["--allow", "x", "-h"])))

    XCTAssertEqual(
      Invocation.parse(["run", "a.janet"]),
      .run(Invocation(allowed: [], socket: nil, script: "a.janet", arguments: [])))
    XCTAssertEqual(Invocation.parse(["run", "-h"]), .help)
    XCTAssertEqual(Invocation.parse(["--help"]), .help)

    for bad in [
      [], ["walk"], ["run"], ["run", "--allow"], ["run", "--socket"], ["run", "--nope", "a"],
      ["run", "--allow", "fs-read"],
    ] {
      guard case .usage = Invocation.parse(bad) else { return XCTFail("\(bad) was accepted") }
    }
  }

  /// Catches an address that comes from the wrong place. The flag beats the variable, and the
  /// variable beats the well-known address. An empty value is not a value. With neither, a home
  /// folder without a socket is reported as no app, and a regular file there is no socket.
  func testTheAddressComesFromTheFlagThenTheVariableThenTheWellKnownAddress() throws {
    typealias Address = ScriptHelperMain.Address

    let variable = [ScriptHelperMain.addressVariable: "/from/variable"]

    XCTAssertEqual(
      try Address.resolve(socket: "/from/flag", environment: variable, home: nil).path,
      "/from/flag")
    XCTAssertEqual(
      try Address.resolve(socket: nil, environment: variable, home: nil).path, "/from/variable")
    XCTAssertEqual(
      try Address.resolve(socket: "", environment: variable, home: nil).path, "/from/variable")

    let empty = [ScriptHelperMain.addressVariable: ""]

    XCTAssertThrowsError(try Address.resolve(socket: nil, environment: empty, home: nil))
    XCTAssertThrowsError(try Address.resolve(socket: nil, environment: [:], home: root.path)) {
      XCTAssertTrue("\($0)".contains("no uniterm is reachable"), "\($0)")
    }

    let directory = ScriptAddressDirectory.make(under: root)

    try Data().write(to: directory.appendingPathComponent("uniterm.sock"))

    XCTAssertThrowsError(try Address.resolve(socket: nil, environment: [:], home: root.path)) {
      XCTAssertTrue("\($0)".contains("no uniterm is reachable"), "\($0)")
    }
  }

  /// Catches a grant that clears too much or too little, and a name that Janet would not accept.
  /// The bits are written out here, not read from the code under test.
  func testACapabilityClearsOnlyItsOwnBitsAndUnknownNamesAreRefused() throws {
    let none = try ScriptCapabilities.denied(granting: [])
    let read = try ScriptCapabilities.denied(granting: ["fs-read"])
    let files = try ScriptCapabilities.denied(granting: ["fs"])
    let several = try ScriptCapabilities.denied(granting: ["fs-read", "net-connect", "env"])

    XCTAssertEqual(none & 64, 64, "file reads are denied by default")
    XCTAssertEqual(read, none & ~64)
    XCTAssertEqual(files, none & ~(32 | 64 | 1024))
    XCTAssertEqual(several, none & ~(64 | 4 | 256))
    XCTAssertEqual(try ScriptCapabilities.denied(granting: ["fs-read", "fs-read"]), read)

    for name in ["all", "nonsense", "FS-READ", "", "fs_read"] {
      XCTAssertThrowsError(try ScriptCapabilities.denied(granting: [name]), name) { error in
        XCTAssertEqual(error as? ScriptCapabilities.UnknownName, .init(name: name))
      }
    }
  }

  /// Catches an `--allow` that reads like a grant and does nothing. A name the default sandbox
  /// already leaves open is refused, and every other name Janet accepts is a real grant. The usage
  /// text lists both sets, so the lists must match what the sandbox does.
  func testAllowRefusesWhatIsAlwaysAllowedAndGrantsTheRest() throws {
    let none = try ScriptCapabilities.denied(granting: [])

    for name in ScriptCapabilities.alwaysAllowed {
      XCTAssertThrowsError(try ScriptCapabilities.denied(granting: [name]), name) { error in
        XCTAssertEqual(error as? ScriptCapabilities.AlreadyAllowed, .init(name: name))
      }
    }

    for name in ScriptCapabilities.grantable {
      XCTAssertNotEqual(
        try ScriptCapabilities.denied(granting: [name]), none, "--allow \(name) grants nothing")
    }

    for name in ["net", "subprocess", "ffi"] {
      XCTAssertTrue(ScriptCapabilities.grantable.contains(name), "\(name) is open by default")
    }

    XCTAssertTrue(ScriptHelperMain.usageText.contains("subprocess"))
    XCTAssertTrue(ScriptHelperMain.usageText.contains("hrtime"))
  }
}

private enum ScriptAddressDirectory {
  /// The folder under a fake home that holds the well-known address.
  static func make(under home: URL) -> URL {
    let directory = home.appendingPathComponent(
      "Library/Application Support/uniterm/run", isDirectory: true)

    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    return directory
  }

  /// Catches a cap that the helper's allocator and the app's kill margin disagree on. The app sizes
  /// its margin from the wire's number, and the allocator enforces the shim's. They must be the
  /// same 1 GiB.
  func testTheAllocatorsCapIsTheWiresCap() {
    XCTAssertEqual(uniterm_janet_memory_cap(), UInt64(ScriptProtocol.helperMemoryCap))
    XCTAssertEqual(UInt64(ScriptProtocol.helperMemoryCap), UInt64(UNITERM_JANET_DEFAULT_MEMORY_CAP))
  }

  /// Catches a `--memory-cap` that leaks into a script's own arguments or is read from anywhere but
  /// right after `run`.
  func testTheMemoryCapFlagIsReadOnlyRightAfterRun() {
    var arguments = ["uniterm", "run", "script.janet", "--memory-cap", "5"]

    XCTAssertNil(ScriptHelperMain.takeMemoryCap(from: &arguments))
    XCTAssertEqual(arguments, ["uniterm", "run", "script.janet", "--memory-cap", "5"])

    var bad = ["uniterm", "run", "--memory-cap", "nonsense", "script.janet"]

    XCTAssertNotNil(ScriptHelperMain.takeMemoryCap(from: &bad))
  }
}
