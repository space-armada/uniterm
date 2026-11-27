import ControllerPackage
import ControllerTestSupport
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ScriptRuntime

/// The command's signer and the loader's reading of a snapshot, held to the fixtures the app's own
/// tests use. The signer needs no certificate and no trust root: a key in the user's Keychain is
/// all it reads, and these tests hold their keys in memory.
final class ControllerSignerTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = try ControllerFixtures.temporaryFolder()
    keys = InMemoryKeyStore(keys: ["fixture": try ControllerFixtures.signingKey()])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// The signing keys, held in memory so no test reaches the login Keychain. The fixture key is
  /// in it under "fixture".
  private var keys: InMemoryKeyStore!

  private func keyCommand(_ arguments: String...) -> Int32 {
    ControllerCommands.run(arguments: arguments, environment: [:], keys: keys)
  }

  /// Catches a signer that signs anything but the exact descriptor bytes, or with another key: its
  /// output must carry the fixture key's fingerprint and verify where the app verifies it.
  func testTheSignerSignsTheSharedFixtureWithTheFixtureKey() throws {
    let package = try ControllerFixtures.copy("janet-hello")

    try FileManager.default.removeItem(at: package.appendingPathComponent("controller.sig"))

    XCTAssertEqual(keyCommand("sign", "--key", "fixture", package.path), 0)

    let descriptor = try Data(contentsOf: package.appendingPathComponent("controller.json"))
    let signature = try Data(contentsOf: package.appendingPathComponent("controller.sig"))
    let verified = try VerifiedController(descriptorBytes: descriptor, signatureBytes: signature)

    XCTAssertEqual(verified.identity.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)
    XCTAssertEqual(verified.identity.version, ControllerFixtures.Hello.version)
  }

  /// Catches keygen replacing a key, and a second key that signs as the first. A package signed
  /// with a new key has a new identity, so trust given to the old key never covers it.
  func testANewKeyGivesANewIdentityAndKeygenNeverReplacesAKey() throws {
    let package = try ControllerFixtures.copy("janet-hello")
    XCTAssertEqual(keyCommand("keygen", "new"), 0)

    let first = try keys.key(named: "new").publicKey

    XCTAssertNotEqual(keyCommand("keygen", "new"), 0)
    XCTAssertEqual(try keys.key(named: "new").publicKey, first)

    XCTAssertEqual(keyCommand("sign", "--key", "new", package.path), 0)

    let verified = try VerifiedController(
      descriptorBytes: try Data(contentsOf: package.appendingPathComponent("controller.json")),
      signatureBytes: try Data(contentsOf: package.appendingPathComponent("controller.sig")))

    XCTAssertEqual(verified.identity.controllerID, ControllerFixtures.Hello.id)
    XCTAssertNotEqual(verified.identity.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)
  }

  /// Catches a signer that signs with some other key when the named one is missing, which would
  /// give the package an identity the user never chose. Nothing is written.
  func testAMissingKeySignsNothing() throws {
    let package = try ControllerFixtures.copy("janet-hello")
    let before = try Data(contentsOf: package.appendingPathComponent("controller.sig"))

    XCTAssertNotEqual(keyCommand("sign", "--key", "lost", package.path), 0)
    XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("controller.sig")), before)
  }

  /// Catches a signer that signs a package whose files no longer match their digests, which would
  /// put a signature on a descriptor that describes other code.
  func testTheSignerRefusesAPackageThatDoesNotMatchItsDescriptor() throws {
    let package = try ControllerFixtures.copy("janet-hello")

    try Data("(print :edited)\n".utf8).write(to: package.appendingPathComponent("main.janet"))

    let before = try Data(contentsOf: package.appendingPathComponent("controller.sig"))

    XCTAssertNotEqual(
      keyCommand("sign", "--key", "fixture", package.path), 0)
    XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("controller.sig")), before)
  }

  /// Catches a loader that reads the shared fixture's snapshot differently from the app, or that
  /// loads any of the shared bad descriptors from a snapshot.
  func testTheLoaderReadsTheSharedFixturesAsTheAppDoes() throws {
    let snapshot = try ControllerSnapshot.create(
      from: ControllerFixtures.package("janet-hello").path,
      in: root.appendingPathComponent("runs"))

    defer { snapshot.remove() }

    let loaded = try ControllerSnapshot.load(
      at: snapshot.directory.path,
      version: try XCTUnwrap(Data(hex: ControllerFixtures.Hello.version)))

    XCTAssertEqual(loaded.descriptor.id, ControllerFixtures.Hello.id)
    XCTAssertEqual(loaded.descriptor.entryPath, ControllerFixtures.Hello.entry)
    XCTAssertEqual(loaded.descriptor.permissions, ControllerFixtures.Hello.permissions)
    XCTAssertEqual(
      loaded.files.mapValues { Data(SHA256.hash(data: $0)).hex }, ControllerFixtures.Hello.files)

    for (name, reason) in ControllerFixtures.rejected {
      let folder = root.appendingPathComponent("bad-\(name)")
      let bytes = try ControllerFixtures.descriptor(name)

      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try bytes.write(to: folder.appendingPathComponent("controller.json"))

      XCTAssertThrowsError(
        try ControllerSnapshot.load(at: folder.path, version: Data(SHA256.hash(data: bytes))), name
      ) { error in
        XCTAssertTrue("\(error)".contains(reason), "\(name): \(error)")
      }
    }
  }

  /// Catches a run that starts while a loader variable is set, which would let dyld load code the
  /// package does not hold before the command's own checks, and a run refused over a variable that
  /// dyld never reads.
  func testARunRefusesToStartWhileALoaderVariableIsSet() {
    XCTAssertEqual(ControllerCommands.loaderVariables(in: ["HOME": "/", "PATH": "/bin"]), [])
    XCTAssertEqual(
      ControllerCommands.loaderVariables(
        in: [
          "DYLD_INSERT_LIBRARIES": "x", "DYLD_LIBRARY_PATH": "y",
          "__XPC_DYLD_FRAMEWORK_PATH": "z",
        ]),
      ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"],
      "__XPC_DYLD_ variables, which Xcode sets for an app under test, mean nothing to dyld")

    let package = ControllerFixtures.package("janet-hello").path

    XCTAssertEqual(
      ScriptHelperMain.run(
        arguments: ["uniterm", "run", "--socket", "/nonexistent.sock", package],
        identity: .unchecked, environment: ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]),
      ScriptHelperMain.Exit.usage)
    XCTAssertEqual(
      ScriptHelperMain.run(
        arguments: ["uniterm", "controller", "run", "--socket", "/nonexistent.sock", package],
        identity: .unchecked, environment: ["DYLD_LIBRARY_PATH": "/tmp"]),
      ScriptHelperMain.Exit.usage)
  }

  private func scriptFile(_ text: String, named name: String = "tidy.janet") throws -> URL {
    let file = root.appendingPathComponent(name)

    try Data(text.utf8).write(to: file)

    return file
  }

  /// Catches a file signer that signs other bytes than the file's, with another key, under a
  /// package's domain, or beside the wrong name. The `.sig` it writes must verify as a file
  /// signature over the exact bytes, carry the fixture key's fingerprint, and verify as nothing
  /// else.
  func testTheSignerSignsAFileBesideItAsAFileSignature() throws {
    let text = "(declare-permissions {:id \"dev.example.tidy\"} {:kind :pane-control})\n"
    let file = try scriptFile(text)

    XCTAssertEqual(keyCommand("sign", "--key", "fixture", file.path), 0)

    let sidecar = root.appendingPathComponent("tidy.janet.sig")
    let signature = try ControllerSignature.parse(try Data(contentsOf: sidecar))

    XCTAssertNoThrow(try signature.verify(Data(text.utf8), as: .scriptFile))
    XCTAssertThrowsError(try signature.verify(descriptor: Data(text.utf8)))
    XCTAssertEqual(signature.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
      ["tidy.janet", "tidy.janet.sig"], "a temporary file was left behind")

    let snapshot = try DeclaredFileSnapshot.create(
      from: file.path, in: root.appendingPathComponent("runs"))

    defer { snapshot.remove() }

    XCTAssertEqual(snapshot.signature, signature)
  }

  /// Catches a signer that signs a file the app would refuse, which would leave a signature that
  /// matches nothing. A file with no declaration, one without an `:id`, a bad declaration, and a
  /// missing file or key each write nothing and say why.
  func testTheSignerRefusesAFileThatCouldNotBeTrustedByIdentity() throws {
    let cases: [(String, String)] = [
      ("(print :hi)\n", "first form is not (declare-permissions"),
      ("(declare-permissions {:kind :pane-control})\n", "names no :id"),
      ("(declare-permissions {:name \"Tidy\"})\n", "names no :id"),
      ("(declare-permissions {:id \"Bad ID\"})\n", "id"),
    ]

    for (index, (text, _)) in cases.enumerated() {
      let file = try scriptFile(text, named: "case\(index).janet")

      XCTAssertNotEqual(keyCommand("sign", "--key", "fixture", file.path), 0, text)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: file.path + ".sig"), "signed: \(text)")
    }

    let missing = root.appendingPathComponent("missing.janet").path

    XCTAssertNotEqual(keyCommand("sign", "--key", "fixture", missing), 0)

    let file = try scriptFile("(declare-permissions {:id \"dev.example.tidy\"})\n")

    XCTAssertNotEqual(keyCommand("sign", "--key", "lost", file.path), 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".sig"))
  }

  /// Catches a signer that writes beside the link and not the file. The app reads the `.sig` beside
  /// the resolved path, so a signature beside the link would never be found.
  func testTheSignerWritesBesideTheResolvedFile() throws {
    let file = try scriptFile("(declare-permissions {:id \"dev.example.tidy\"})\n")
    let link = root.appendingPathComponent("link.janet")

    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    XCTAssertEqual(keyCommand("sign", "--key", "fixture", link.path), 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".sig"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: link.path + ".sig"))
  }

  /// Catches a re-sign that leaves the old signature in place when the file changed. After the
  /// second sign, the `.sig` verifies the edited bytes and the first one no longer does.
  func testSigningAgainReplacesTheSignature() throws {
    let one = "(declare-permissions {:id \"dev.example.tidy\"})\n(print :one)\n"
    let two = "(declare-permissions {:id \"dev.example.tidy\"})\n(print :two)\n"
    let file = try scriptFile(one)
    let sidecar = URL(fileURLWithPath: file.path + ".sig")

    XCTAssertEqual(keyCommand("sign", "--key", "fixture", file.path), 0)

    let old = try ControllerSignature.parse(try Data(contentsOf: sidecar))

    try Data(two.utf8).write(to: file)
    XCTAssertEqual(keyCommand("sign", "--key", "fixture", file.path), 0)

    let current = try ControllerSignature.parse(try Data(contentsOf: sidecar))

    XCTAssertNoThrow(try current.verify(Data(two.utf8), as: .scriptFile))
    XCTAssertThrowsError(try current.verify(Data(one.utf8), as: .scriptFile))
    XCTAssertThrowsError(try old.verify(Data(two.utf8), as: .scriptFile))
    XCTAssertNoThrow(try old.verify(Data(one.utf8), as: .scriptFile))
  }
}
