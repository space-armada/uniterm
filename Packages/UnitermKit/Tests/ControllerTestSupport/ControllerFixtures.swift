import ControllerPackage
import CryptoKit
import Foundation

/// The controller fixtures that the app's, the signer's, and the loader's tests share.
///
/// Each expected value here was computed outside the code under test: the digests by `shasum -a
/// 256` over the fixture files, and the signature and fingerprint once by a separate CryptoKit
/// program from the seed below. A reader that changes its interpretation fails all three suites.
///
/// To sign `janet-hello` again after a change to its `controller.json`, run a throwaway program
/// outside the repository. It builds `Curve25519.Signing.PrivateKey(rawRepresentation: seed)`,
/// signs the bytes `"uniterm controller descriptor 1\n"` followed by the descriptor, and prints
/// the SHA-256 of the descriptor, the SHA-256 of the public key, and the base64 of the signature.
/// An Ed25519 signature from CryptoKit differs on every run, so a new signature is a new value.
/// The version and the fingerprint reproduce on every run.
public enum ControllerFixtures {
  public static var root: URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
  }

  public static func package(_ name: String) -> URL {
    root.appendingPathComponent("packages/\(name)", isDirectory: true)
  }

  public static func descriptor(_ name: String) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent("descriptors/\(name).json"))
  }

  /// The synthetic test key's 32-byte seed, the text "uniterm controller test key seed".
  public static let signingSeed = Data("uniterm controller test key seed".utf8)

  public static func signingKey() throws -> InMemorySigningKey {
    try InMemorySigningKey(seed: signingSeed)
  }

  /// What every reader must make of the `janet-hello` package.
  public enum Hello {
    public static let id = "dev.uniterm.fixture.hello"
    public static let name = "Hello Fixture"
    public static let entry = "main.janet"

    public static let files = [
      "lib/greet.janet": "ba3701f34d91051ae697ef082c6c5460ea45a912210584bfd74253aa9e54c503",
      "main.janet": "ee948b2a8a1d46f583949438cf23a7992c324f053661f7b144823c037f48b8e0",
    ]

    public static let permissions: Set<ControllerPermission> = [
      .paneControl, .capability("fs-read"),
    ]

    /// SHA-256 over `controller.json`.
    public static let version = "02b667a076528054cb7e51694a75bec0f40f36638dc152b91d7962427ed435b1"

    /// SHA-256 over the test key's public key.
    public static let keyFingerprint =
      "8601971532c5c63009f117a1d896e5b2b5a9822dc867492885026ef4f0ad09d1"

    public static let publicKeyBase64 = "GjTE9SBNzwk+HDRp0PxFl+e6xqDoT2wvZfyLtkicUoQ="

    /// What the entry prints.
    public static let output = "hello from the fixture controller\n"
  }

  /// A format 0 descriptor with every permission kind that takes no browser scope, which every
  /// reader accepts.
  public static let formatZero = "format-zero"

  /// A format 0 descriptor that holds the two browser kinds.
  public static let formatZeroBrowser = "format-zero-browser"

  /// Descriptors every reader refuses, with a fragment of the reason each one gives.
  public static let rejected: [(name: String, reason: String)] = [
    ("duplicate-key", "appears twice"),
    ("escaped-duplicate-key", "appears twice"),
    ("unknown-field", "unknown field \"trusted\""),
    ("case-alias", "same file on a case-insensitive disk"),
    ("escape-parent", "not a plain relative path"),
    ("escape-absolute", "not a plain relative path"),
    ("dot-alias", "not a plain relative path"),
    ("unicode-alias", "not a plain relative path"),
    ("unknown-permission", "\"everything\" is not one this uniterm knows"),
    ("format-one-pane-control", "format 1 is not one this uniterm reads"),
    ("format-two-versioned", "format 2 is not one this uniterm reads"),
    ("versioned-permission", "the pane-control permission names a version"),
    ("browser-navigation-with-field", "only path-read takes directories"),
    ("host-launch-relative", "executable must be an absolute path"),
    ("duplicate-kind", "pane-control is listed twice"),
    ("native-module-capability", "loads native code"),
    ("newer-format", "format 3 is not one this uniterm reads"),
    ("entry-not-listed", "not among the files"),
    ("boolean-value", "must be a string"),
    ("trailing-data", "something follows"),
    ("uppercase-digest", "64 lowercase hex digits"),
    ("file-and-folder", "is a file, so lib/x.janet cannot be inside it"),
    ("reserved-name", "is reserved"),
    ("byte-order-mark", "a value must be a string"),
  ]

  /// A fresh copy of a fixture package in a temporary folder, which a test may change.
  public static func copy(_ name: String) throws -> URL {
    let target = try temporaryFolder().appendingPathComponent(name, isDirectory: true)

    try FileManager.default.copyItem(at: package(name), to: target)

    return target
  }

  /// A new private folder under the temporary folder.
  public static func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("uc-\(UUID().uuidString.prefix(8))", isDirectory: true)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    return folder
  }
}

/// Writes a controller package for a test: its files, and a descriptor whose digests are computed
/// here with CryptoKit, apart from the package reader.
public struct ControllerPackageBuilder {
  public var id = "dev.uniterm.fixture.built"
  public var name = "Built Fixture"
  public var entryKind = "janet"
  public var entry = "main.janet"
  public var files: [String: Data] = [:]

  /// The descriptor format.
  public var format = ControllerDescriptor.format

  /// Each permission as its JSON object text, such as `{"kind": "pane-control"}`.
  public var permissions: [String] = [#"{"kind": "pane-control"}"#]

  /// Files written to the folder but left out of the descriptor.
  public var unlisted: [String: Data] = [:]

  public init(files: [String: Data] = [:]) {
    self.files = files
  }

  public func descriptorBytes() -> Data {
    let listed = files.keys.sorted().map { path in
      "    \"\(path)\": \"sha256:\(Data(SHA256.hash(data: files[path]!)).map { String(format: "%02x", $0) }.joined())\""
    }

    return Data(
      """
      {
        "format": \(format),
        "id": "\(id)",
        "name": "\(name)",
        "entry": {"kind": "\(entryKind)", "path": "\(entry)"},
        "files": {
      \(listed.joined(separator: ",\n"))
        },
        "permissions": [\(permissions.joined(separator: ", "))]
      }

      """.utf8)
  }

  /// Writes the package into a new folder and returns it.
  @discardableResult
  public func write(signedWith key: (any ControllerSigningKey)? = nil, to folder: URL? = nil)
    throws -> URL
  {
    let root = try folder ?? ControllerFixtures.temporaryFolder().appendingPathComponent("package")
    let manager = FileManager.default

    try manager.createDirectory(at: root, withIntermediateDirectories: true)

    for (path, bytes) in files.merging(unlisted, uniquingKeysWith: { a, _ in a }) {
      let url = root.appendingPathComponent(path)

      try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: url)
    }

    let descriptor = descriptorBytes()

    try descriptor.write(to: root.appendingPathComponent(ControllerDescriptor.fileName))

    if let key {
      try ControllerSignature.sign(descriptor: descriptor, with: key).encoded()
        .write(to: root.appendingPathComponent(ControllerSignature.fileName))
    }

    return root
  }
}
