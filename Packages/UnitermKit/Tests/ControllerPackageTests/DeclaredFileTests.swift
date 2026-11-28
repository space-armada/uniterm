import ControllerTestSupport
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ControllerPackage

/// A script file's declaration and its private copy: what the shared reader refuses, how the two
/// readers of a permission list agree, and what nothing done to the source can change.
final class DeclaredFileTests: XCTestCase {
  private var folder: URL!
  private var runs: URL!

  override func setUpWithError() throws {
    folder = try ControllerFixtures.temporaryFolder()
    runs = folder.appendingPathComponent("runs")
  }

  override func tearDown() {
    ControllerSnapshot.removeStale(in: runs)
  }

  private func parse(_ permissions: String, header: String? = nil, typos: String? = nil) throws
    -> FileDeclaration
  {
    try FileDeclaration.parse(
      #"{\#(header.map { #""header":\#($0),"# } ?? "")\#(typos.map { #""typos":[\#($0)],"# } ?? "")"permissions":[\#(permissions)]}"#
    )
  }

  private func refusal(
    _ permissions: String, header: String? = nil, typos: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    do {
      _ = try parse(permissions, header: header, typos: typos)

      XCTFail("the declaration was read", file: file, line: line)

      return ""
    } catch {
      return "\(error)"
    }
  }

  // MARK: Declarations

  /// Catches a declaration read as something other than what it says: the header's ID and name,
  /// and each kind of permission with its scope.
  func testAValidDeclarationReadsEachKindAndTheHeader() throws {
    let declaration = try parse(
      """
      {"kind":"pane-control"},{"kind":"clipboard-read"},
      {"kind":"clipboard-write"},{"kind":"capability","name":"fs-read"},
      {"kind":"host-launch","executable":"/usr/bin/git","directory":"/Users/me/src",
       "environment":["PATH","HOME"]}
      """,
      header: #"{"id":"dev.example.tidy","name":"Tidy"}"#)

    XCTAssertEqual(declaration.id, "dev.example.tidy")
    XCTAssertEqual(declaration.name, "Tidy")
    XCTAssertEqual(declaration.capabilities, ["fs-read"])
    XCTAssertEqual(
      declaration.permissions,
      [
        .paneControl, .clipboardRead, .clipboardWrite, .capability("fs-read"),
        .hostLaunch(
          try HostLaunchScope(
            executable: "/usr/bin/git", directory: "/Users/me/src",
            environmentKeys: ["HOME", "PATH"])),
      ])

    let empty = try parse("")

    XCTAssertNil(empty.id)
    XCTAssertNil(empty.name)
    XCTAssertTrue(empty.permissions.isEmpty)
  }

  /// Catches a package and a file reading one permission list two ways. The same array goes
  /// through the descriptor's entry and the file's, and both return the same set.
  func testThePackageAndTheFileShareOnePermissionReader() throws {
    let text = """
      [{"kind":"pane-control"},{"kind":"capability","name":"fs-read"},
       {"kind":"clipboard-write"}]
      """
    let value = try StrictJSONReader.parse(Data(text.utf8), maxBytes: 4096)

    for subject in [ControllerPermissionReader.Subject.controller, .file] {
      XCTAssertEqual(
        try ControllerPermissionReader.read(
          value, allowsCapabilities: true, subject: subject),
        [.paneControl, .capability("fs-read"), .clipboardWrite])
    }

    for kind in ["ffi", "ffi-define", "ffi-jit", "ffi-use", "modules"] {
      let refused = try StrictJSONReader.parse(
        Data(#"[{"kind":"capability","name":"\#(kind)"}]"#.utf8), maxBytes: 4096)

      for subject in [ControllerPermissionReader.Subject.controller, .file] {
        XCTAssertThrowsError(
          try ControllerPermissionReader.read(
            refused, allowsCapabilities: true, subject: subject), kind
        ) { error in
          XCTAssertTrue("\(error)".contains("cannot declare \(kind)"), "\(error)")
        }
      }
    }
  }

  /// Catches a declaration that grants what a descriptor would refuse: an unknown kind or
  /// version, a kind listed twice, a native capability, and a field a kind does not take.
  func testEachBrokenPermissionIsRefusedWithAMessageNamingIt() {
    XCTAssertTrue(
      refusal(#"{"kind":"everything"}"#).contains(
        ":everything is not a permission kind"))
    XCTAssertTrue(
      refusal(#"{"kind":"pane-control","version":2}"#).contains(
        ":pane-control names a :version"))
    XCTAssertTrue(
      refusal(#"{"kind":"pane-control"},{"kind":"pane-control"}"#)
        .contains("pane-control is listed twice"))
    XCTAssertTrue(
      refusal(
        #"{"kind":"capability","name":"fs-read"},{"kind":"capability","name":"fs-read"}"#
      ).contains("capability is listed twice"))

    for native in ["ffi", "ffi-define", "ffi-jit", "ffi-use", "modules"] {
      XCTAssertTrue(
        refusal(#"{"kind":"capability","name":"\#(native)"}"#).contains(
          "a script file cannot declare \(native)"), native)
    }

    XCTAssertTrue(
      refusal(#"{"kind":"pane-control","name":"x"}"#).contains("takes no name"))
    XCTAssertTrue(
      refusal(#"{"kind":"pane-control","version":0}"#).contains(":pane-control names a :version"))
    XCTAssertTrue(
      refusal(#"{"kind":"pane-control","executable":"/x"}"#).contains(
        "only host-launch takes"))
  }

  /// Catches the same capability at two scopes being read as a repeat, and two host launches of
  /// one executable being read as two permissions. The duplicate key is the kind and its scope.
  func testTheDuplicateKeyIsTheKindAndItsScope() throws {
    let two = try parse(
      """
      {"kind":"capability","name":"fs-read"},
      {"kind":"capability","name":"fs-write"}
      """)

    XCTAssertEqual(two.capabilities, ["fs-read", "fs-write"])

    let launch = { (directory: String) in
      #"{"kind":"host-launch","executable":"/usr/bin/git","directory":"\#(directory)","environment":[]}"#
    }

    XCTAssertTrue(
      refusal("\(launch("/a")),\(launch("/b"))").contains("host-launch is listed twice"))
  }

  /// Catches a permission whose misspelled :kind reads as the header, and one that has no :kind at
  /// all. The message names the likely typo.
  func testAMisspelledKindIsNamedAsTheLikelyTypo() {
    let header = refusal(
      "", header: #"{"kynd":"pane-control","version":1}"#, typos: #"{"struct":1,"key":"kynd"}"#)

    XCTAssertTrue(header.contains("misspelled :kind"), header)
    XCTAssertTrue(header.contains(":kynd"), header)

    let later = refusal(
      #"{"kind":"pane-control"},{"kidn":"clipboard-read","version":1}"#,
      typos: #"{"struct":2,"key":"kidn"}"#)

    XCTAssertTrue(later.contains("permission 2 has no :kind"), later)
    XCTAssertTrue(later.contains(":kidn, which looks like a misspelled :kind"), later)

    let unrelated = refusal("", header: #"{"color":"red"}"#)

    // The hint comes from the command's reader. Without it the message does not guess.
    let unmarked = refusal("", header: #"{"kynd":"x"}"#)

    XCTAssertFalse(unmarked.contains("misspelled"), unmarked)

    XCTAssertTrue(unrelated.contains("takes only :id and :name"), unrelated)
    XCTAssertFalse(unrelated.contains("misspelled"), unrelated)
  }

  /// Catches a header that breaks a controller's ID or name rules, and text that is not a
  /// declaration at all.
  func testTheHeaderFollowsTheControllersIDAndNameRules() {
    XCTAssertTrue(refusal("", header: #"{"id":"Not An ID"}"#).contains("reverse domain name"))
    XCTAssertTrue(refusal("", header: #"{"name":" padded "}"#).contains("no edge spaces"))
    XCTAssertThrowsError(try FileDeclaration.parse("not json"))
    XCTAssertThrowsError(try FileDeclaration.parse(#"{"permissions":[],"extra":1}"#))
    XCTAssertThrowsError(try FileDeclaration.parse(#"{"permissions":[],"permissions":[]}"#))
    XCTAssertThrowsError(try FileDeclaration.parse(#"{"permissions":[3]}"#))
  }

  // MARK: Snapshots

  private func write(_ text: String, named name: String = "script.janet") throws -> URL {
    let file = folder.appendingPathComponent(name)

    try Data(text.utf8).write(to: file)

    return file
  }

  private func mode(_ url: URL) -> mode_t {
    var info = stat()

    _ = lstat(url.path, &info)

    return info.st_mode & 0o777
  }

  /// Catches a version that is not the SHA-256 of the whole file, a copy that is writable, and a
  /// copy that differs from the source. The digest was computed outside the code under test.
  func testTheCopyHoldsTheWholeFileReadOnlyAndTheVersionIsItsDigest() throws {
    let text = "(declare-permissions {:kind :pane-control})\n(print :ran)\n"
    let source = try write(text)
    let made = try DeclaredFileSnapshot.create(from: source.path, in: runs)

    XCTAssertEqual(
      made.versionHex, "687547e1c963f8097c23ed1982b20f9293fcd6430656017ad3a78af1c477b4a9")
    XCTAssertEqual(try Data(contentsOf: made.file), Data(text.utf8))
    XCTAssertEqual(mode(made.file), 0o400)
    XCTAssertEqual(mode(made.directory), 0o500)
    XCTAssertEqual(made.sourceName, "script.janet")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: made.directory.path), ["script.janet"])

    made.remove()

    XCTAssertFalse(FileManager.default.fileExists(atPath: made.directory.path))
    made.remove()
  }

  /// Catches a copy that follows its source after the copy was made. The source is rewritten and
  /// deleted, and the copy and its version stay.
  func testChangingTheSourceAfterwardChangesNothingTheCopyHolds() throws {
    let source = try write("(print :one)\n")
    let made = try DeclaredFileSnapshot.copy(
      from: source.path, in: runs,
      afterCopying: { try? Data("(print :two)\n".utf8).write(to: source) })

    XCTAssertEqual(try Data(contentsOf: made.file), Data("(print :one)\n".utf8))

    try Data("(print :three)\n".utf8).write(to: source)
    try FileManager.default.removeItem(at: source)

    XCTAssertEqual(try Data(contentsOf: made.file), Data("(print :one)\n".utf8))
    XCTAssertEqual(
      made.version, Data(SHA256.hash(data: Data("(print :one)\n".utf8))))
  }

  /// Catches a read of the copy that parses bytes other than the version the app sent.
  func testReadingTheCopyChecksItsHashFirst() throws {
    let made = try DeclaredFileSnapshot.create(
      from: try write("(print :one)\n").path, in: runs)

    XCTAssertEqual(
      try DeclaredFileSnapshot.read(at: made.file.path, version: made.version),
      Data("(print :one)\n".utf8))

    XCTAssertThrowsError(
      try DeclaredFileSnapshot.read(at: made.file.path, version: Data(repeating: 1, count: 32))
    ) { error in
      XCTAssertTrue("\(error)".contains("not the version uniterm verified"), "\(error)")
    }
  }

  private func assertRefused(
    _ path: String, saying fragment: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try DeclaredFileSnapshot.create(from: path, in: runs), file: file, line: line
    ) { error in
      XCTAssertTrue("\(error)".contains(fragment), "\(error)", file: file, line: line)
    }

    let left = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []

    XCTAssertEqual(left, [], "a refused file left a folder", file: file, line: line)
  }

  /// Catches a copy made of something that is not a regular file of a size the caps allow: a
  /// pipe, a device, a link, a folder, a relative path, and a file one byte over the cap.
  func testAPipeADeviceALinkAFolderAndAnOversizeFileAreRefused() throws {
    let fifo = folder.appendingPathComponent("pipe")

    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    assertRefused(fifo.path, saying: "is not a regular file")
    assertRefused("/dev/null", saying: "is under /dev")
    assertRefused(folder.path, saying: "is not a regular file")

    // The app opens this path itself, so it would copy a file the app holds open.
    for path in ["/dev/fd/0", "/dev/fd/63", "/dev/stdin", "/dev"] {
      assertRefused(path, saying: "is under /dev")
    }

    let target = try write("(print :ran)\n")
    let link = folder.appendingPathComponent("link.janet")

    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    assertRefused(link.path, saying: "is a link")
    assertRefused("script.janet", saying: "absolute path")
    assertRefused(folder.appendingPathComponent("missing.janet").path, saying: "does not exist")

    let big = folder.appendingPathComponent("big.janet")

    XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))

    let handle = try FileHandle(forWritingTo: big)

    try handle.truncate(atOffset: UInt64(DeclaredFileSnapshot.maxBytes) + 1)
    try handle.close()
    assertRefused(big.path, saying: "is over \(DeclaredFileSnapshot.maxBytes) bytes")
  }

  /// Catches the cap being a different size from a packaged file's.
  func testTheCapMatchesAPackagedFilesCap() {
    XCTAssertEqual(DeclaredFileSnapshot.maxBytes, ControllerDescriptor.maxFileBytes)
  }

  // MARK: Signatures

  private func sign(
    _ source: URL, as subject: ControllerSignature.Subject = .scriptFile,
    with key: InMemorySigningKey? = nil
  ) throws -> ControllerSignature {
    let signature = try ControllerSignature.sign(
      try Data(contentsOf: source), as: subject, with: try key ?? ControllerFixtures.signingKey())

    try signature.encoded().write(to: URL(fileURLWithPath: source.path + ".sig"))

    return signature
  }

  /// Catches a file signature that verifies where a package's does, and the other way round. The
  /// domain lines differ, so the same key over the same bytes gives two signatures that each verify
  /// for their own subject only.
  func testAFileSignatureNeverVerifiesAPackageAndAPackageSignatureNeverVerifiesAFile() throws {
    let bytes = Data("(declare-permissions {:id \"dev.example.a\"})\n".utf8)
    let key = try ControllerFixtures.signingKey()
    let file = try ControllerSignature.sign(bytes, as: .scriptFile, with: key)
    let package = try ControllerSignature.sign(descriptor: bytes, with: key)

    XCTAssertNotEqual(file.signature, package.signature)
    XCTAssertNoThrow(try file.verify(bytes, as: .scriptFile))
    XCTAssertNoThrow(try package.verify(descriptor: bytes))

    XCTAssertThrowsError(try file.verify(descriptor: bytes))
    XCTAssertThrowsError(try package.verify(bytes, as: .scriptFile)) { error in
      XCTAssertTrue("\(error)".contains("the file was changed"), "\(error)")
    }

    XCTAssertEqual(
      ControllerSignature.Subject.scriptFile.domain, Data("uniterm script file 1\n".utf8))
    XCTAssertEqual(
      ControllerSignature.Subject.descriptor.domain,
      Data("uniterm controller descriptor 1\n".utf8))
  }

  /// Catches a snapshot that drops the signature beside the file, or reads it as another file's.
  /// The fingerprint is the fixture key's, and a file with no `.sig` is unsigned.
  func testASnapshotCarriesTheSignatureThatVerifiedOverItsBytes() throws {
    let source = try write("(declare-permissions {:id \"dev.example.a\"})\n(print :ran)\n")

    XCTAssertNil(try DeclaredFileSnapshot.create(from: source.path, in: runs).signature)

    let signature = try sign(source)
    let made = try DeclaredFileSnapshot.create(from: source.path, in: runs)

    XCTAssertEqual(made.signature, signature)
    XCTAssertEqual(made.signature?.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: made.directory.path), ["script.janet"])
  }

  /// Catches a present `.sig` that falls back to an unsigned file. Each way a signature can be
  /// wrong refuses the file and leaves no folder: edited bytes, a package's signature, text that
  /// is not a signature, a signature over the cap, and a link.
  func testASignatureThatDoesNotVerifyRefusesTheFile() throws {
    let source = try write("(declare-permissions {:id \"dev.example.a\"})\n(print :one)\n")
    let sidecar = URL(fileURLWithPath: source.path + ".sig")

    _ = try sign(source)
    try Data("(declare-permissions {:id \"dev.example.a\"})\n(print :two)\n".utf8).write(to: source)
    assertRefused(source.path, saying: "the file was changed after it was signed")

    _ = try sign(source, as: .descriptor)
    assertRefused(source.path, saying: "the file was changed after it was signed")

    try Data("not json".utf8).write(to: sidecar)
    assertRefused(source.path, saying: "the file's .sig")

    try Data(repeating: 0x20, count: ControllerSignature.maxBytes + 1).write(to: sidecar)
    assertRefused(source.path, saying: "is over \(ControllerSignature.maxBytes) bytes")
    assertFileSignatureError(source.path)

    try FileManager.default.removeItem(at: sidecar)

    let elsewhere = try write("{}", named: "elsewhere.sig")

    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: elsewhere)
    assertRefused(source.path, saying: "is a link")
    assertFileSignatureError(source.path)

    try FileManager.default.removeItem(at: elsewhere)
    assertRefused(source.path, saying: "is a link")
    assertFileSignatureError(source.path)

    try FileManager.default.removeItem(at: sidecar)
    try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
    assertRefused(source.path, saying: "is not a regular file")
    assertFileSignatureError(source.path)
  }

  /// Every way a `.sig` can fail surfaces as the file-signature error, so callers handle one case.
  private func assertFileSignatureError(
    _ path: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try DeclaredFileSnapshot.create(from: path, in: runs), file: file, line: line
    ) { error in
      guard case ControllerPackageError.fileSignature = error else {
        return XCTFail("not a file-signature error: \(error)", file: file, line: line)
      }
    }
  }

  /// Catches a signature verified over the source as it stood at the start and not over the bytes
  /// copied. The source is rewritten while it is copied, so the copy is the old bytes, and a
  /// signature over the new bytes must refuse.
  func testTheSignatureIsCheckedAgainstTheBytesCopied() throws {
    let old = "(declare-permissions {:id \"dev.example.a\"})\n(print :one)\n"
    let new = "(declare-permissions {:id \"dev.example.a\"})\n(print :two)\n"
    let source = try write(new)

    _ = try sign(source)
    try Data(old.utf8).write(to: source)

    XCTAssertThrowsError(
      try DeclaredFileSnapshot.copy(
        from: source.path, in: runs, afterCopying: { try? Data(new.utf8).write(to: source) })
    ) { error in
      XCTAssertTrue("\(error)".contains("the file was changed"), "\(error)")
    }
  }
}
