import CryptoKit
import Darwin
import Foundation
import ScriptWire

/// What a script file declares in its first `(declare-permissions ...)` form, as the command
/// converts it for the app.
///
/// The text is JSON in the shape `{"header": {"id": ..., "name": ...}, "permissions": [...]}`, with
/// the header absent when the file names none. Each permission is spelled as a format 2
/// `controller.json` permission, and the shared permission reader reads the list. The command reads
/// the declaration with Janet's parser and checks it here before it sends it. The app reads it
/// again, since the app trusts nothing the command sends.
public struct FileDeclaration: Equatable, Sendable {
  /// The ID the header names, when the file is meant to be told apart from other files. It follows
  /// a controller ID's rules.
  public let id: String?

  /// The name the header gives. It proves nothing about who wrote the file.
  public let name: String?

  public let permissions: Set<ControllerPermission>

  public init(id: String?, name: String?, permissions: Set<ControllerPermission>) {
    self.id = id
    self.name = name
    self.permissions = permissions
  }

  /// The Janet capabilities the declaration lists.
  public var capabilities: Set<String> {
    Set(permissions.compactMap(\.capabilityName))
  }

  /// Reads a declaration. Every rule is checked before it returns, and the first broken one throws
  /// `ControllerPackageError.declaration` with text that names the problem.
  public static func parse(_ json: String) throws -> FileDeclaration {
    do {
      return try read(json)
    } catch ControllerPackageError.malformed(let text) {
      throw ControllerPackageError.declaration(text)
    } catch let error as StrictJSONError {
      throw ControllerPackageError.declaration(error.description)
    }
  }

  private static func read(_ json: String) throws -> FileDeclaration {
    let document = try StrictJSONReader.parse(
      Data(json.utf8), maxBytes: ScriptProtocol.maxDeclarationBytes)
    let fields = try document.members(
      of: "the declaration", required: ["permissions"], optional: ["header", "typos"])
    let typos = try readTypos(fields["typos"])

    var id: String?
    var name: String?

    if let header = fields["header"] {
      (id, name) = try readHeader(header, typo: typos[1])
    }

    let elements = try fields["permissions"]!.array("the permissions")

    for (index, element) in elements.enumerated() {
      guard case .object(let members) = element else {
        throw ControllerPackageError.malformed("a permission must be a struct")
      }

      guard members.contains(where: { $0.key == "kind" }) else {
        let place = fields["header"] == nil ? index + 1 : index + 2
        let hint = typos[place].map {
          " It has :\($0), which looks like a misspelled :kind."
        }

        throw ControllerPackageError.malformed(
          "permission \(index + 1) has no :kind." + (hint ?? ""))
      }
    }

    let permissions = try ControllerPermissionReader.read(
      fields["permissions"]!, allowsCapabilities: true, subject: .file)

    return FileDeclaration(id: id, name: name, permissions: permissions)
  }

  /// The structs the command's reader marked as holding a misspelled `:kind`, by their place among
  /// the declaration's structs, counted from 1. The command's reader owns the judgment of what
  /// looks misspelled, and this only words the message from it.
  private static func readTypos(_ value: StrictJSON?) throws -> [Int: String] {
    guard let value else { return [:] }

    var found: [Int: String] = [:]

    for element in try value.array("the typos") {
      let fields = try element.members(of: "a typo", required: ["struct", "key"])

      found[try fields["struct"]!.integer("a typo's struct")] = try fields["key"]!.string(
        "a typo's key")
    }

    return found
  }

  private static func readHeader(
    _ header: StrictJSON, typo: String?
  ) throws -> (id: String?, name: String?) {
    let members = try header.object("the header")

    let unknown = members.map(\.key).filter { $0 != "id" && $0 != "name" }.sorted()

    if !unknown.isEmpty, let typo {
      throw ControllerPackageError.malformed(
        "the first struct has no :kind, so it is read as the declaration's header. It has "
          + ":\(typo), which looks like a misspelled :kind. Spell it :kind if this is a "
          + "permission. A header takes only :id and :name.")
    }

    if let other = unknown.first {
      throw ControllerPackageError.malformed(
        "the header takes only :id and :name, and it has :\(other)")
    }

    var id: String?
    var name: String?

    for member in members {
      let text = try member.value.string("the header's :\(member.key)")

      if member.key == "id" {
        try ControllerDescriptor.checkID(text)
        id = text
      } else {
        try ControllerDescriptor.checkName(text)
        name = text
      }
    }

    return (id, name)
  }
}

/// A private copy of one script file, made for one run.
///
/// The app opens the file's resolved path without following a link, requires a regular file within
/// the size cap, and copies it into a new folder while it hashes the bytes it copied. The copy is
/// then read back and checked, and made read-only. The version is the SHA-256 of the whole file.
/// Changing the source at any point cannot change what the run loads.
///
/// Read-only files that the user owns are no barrier to a process of the same user that means
/// harm. The copy keeps ordinary edits out, and nothing more.
public struct DeclaredFileSnapshot: Sendable {
  /// The most bytes a declared file may hold. It is a packaged file's cap.
  public static let maxBytes = ControllerDescriptor.maxFileBytes

  /// The copy's name inside the run's folder.
  public static let fileName = "script.janet"

  /// The run's private folder, which holds the copy.
  public let directory: URL

  /// The SHA-256 of the whole file.
  public let version: Data

  /// The source file's name, for a title when the declaration names none.
  public let sourceName: String

  /// The sidecar signature beside the source, when one is there. It verified over the bytes of
  /// this copy, so a signed snapshot is never signed by a signature that covers other bytes.
  public let signature: ControllerSignature?

  public var file: URL { directory.appendingPathComponent(Self.fileName) }

  public var versionHex: String { version.hex }

  /// Copies the file at `source` into a new folder under `runsRoot`.
  public static func create(from source: String, in runsRoot: URL) throws -> DeclaredFileSnapshot {
    try copy(from: source, in: runsRoot, afterCopying: nil)
  }

  /// `afterCopying` runs once the source is read and before the copy is checked. Only a test passes
  /// one, to change the source at a known point.
  static func copy(
    from source: String, in runsRoot: URL, afterCopying: (() -> Void)?
  ) throws -> DeclaredFileSnapshot {
    guard source.hasPrefix("/") else {
      throw ControllerPackageError.contents("the script file must be named by an absolute path")
    }

    // A path under /dev/fd names a descriptor of the process that opens it, which here is the app.
    // It would copy whatever file the app holds open, and not the file the command meant.
    guard source != "/dev", !source.hasPrefix("/dev/") else {
      throw ControllerPackageError.contents(
        "\(source) is under /dev, which names devices and descriptors and not a file uniterm can copy"
      )
    }

    let input = try openRegularFile(source, what: "the file \(source)", limit: maxBytes)

    defer { close(input) }

    let directory = try ControllerSnapshot.makeRunDirectory(in: runsRoot)

    do {
      let target = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

      guard target >= 0 else {
        throw ControllerPackageError.io("cannot open the snapshot: \(errnoText())")
      }

      defer { close(target) }

      let output = openat(
        target, fileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)

      guard output >= 0 else {
        throw ControllerPackageError.io("cannot write the snapshot: \(errnoText())")
      }

      var hasher = SHA256()
      var total = 0
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)

      do {
        defer { close(output) }

        while true {
          let count = Darwin.read(input, &buffer, buffer.count)

          if count < 0, errno == EINTR { continue }

          guard count >= 0 else {
            throw ControllerPackageError.io("cannot read \(source): \(errnoText())")
          }

          if count == 0 { break }

          total += count

          guard total <= maxBytes else {
            throw ControllerPackageError.contents("\(source) is over \(maxBytes) bytes")
          }

          hasher.update(data: buffer[..<count])

          var offset = 0

          while offset < count {
            let written = buffer.withUnsafeBytes {
              write(output, $0.baseAddress! + offset, count - offset)
            }

            guard written > 0 else {
              throw ControllerPackageError.io("cannot write the snapshot: \(errnoText())")
            }

            offset += written
          }
        }

        guard fchmod(output, 0o400) == 0 else {
          throw ControllerPackageError.io("cannot lock the snapshot: \(errnoText())")
        }
      }

      afterCopying?()

      let version = Data(hasher.finalize())
      let copy = try readFile(
        at: directory.appendingPathComponent(fileName).path, what: "the snapshot",
        limit: maxBytes)

      guard Data(SHA256.hash(data: copy)) == version else {
        throw ControllerPackageError.contents("the snapshot of \(source) does not match its source")
      }

      let signature = try readSignature(besides: source, verifying: copy)

      guard fchmod(target, 0o500) == 0 else {
        throw ControllerPackageError.io("cannot lock the snapshot: \(errnoText())")
      }

      return DeclaredFileSnapshot(
        directory: directory, version: version,
        sourceName: URL(fileURLWithPath: source).lastPathComponent, signature: signature)
    } catch {
      ControllerSnapshot.remove(directory: directory)

      throw error
    }
  }

  /// Reads the app's copy once, for the command. The bytes must hash to `version`, the one the app
  /// verified, or nothing is returned. The command parses and runs these bytes and reads the copy
  /// no more.
  public static func read(at path: String, version: Data) throws -> Data {
    let bytes = try readFile(at: path, what: "the snapshot", limit: maxBytes)

    guard Data(SHA256.hash(data: bytes)) == version else {
      throw ControllerPackageError.contents(
        "uniterm's copy of the script file is not the version uniterm verified")
    }

    return bytes
  }

  /// Reads a script file in place, for signing: a regular file within the size cap, opened without
  /// following a link. The caller resolves the path first.
  public static func bytesForSigning(at path: String) throws -> Data {
    try readFile(at: path, what: "the file \(path)", limit: maxBytes)
  }

  /// Removes the snapshot. Safe to call twice.
  public func remove() {
    ControllerSnapshot.remove(directory: directory)
  }

  /// Reads the `.sig` beside `source` and verifies it over `bytes`.
  ///
  /// The file is opened as the script was: no link followed, a regular file, and the signature's own
  /// size cap.
  ///
  /// A signature that is there and does not read or verify throws a file-signature error, whatever
  /// the reason. A bad signature never leaves a file to run as an unsigned one.
  private static func readSignature(
    besides source: String, verifying bytes: Data
  ) throws -> ControllerSignature? {
    let path = source + ControllerSignature.fileSuffix
    var info = stat()

    guard lstat(path, &info) == 0 else {
      guard errno == ENOENT else {
        throw ControllerPackageError.fileSignature("cannot read \(path): \(errnoText())")
      }

      return nil
    }

    do {
      let signatureBytes = try readFile(
        at: path, what: "the signature \(path)", limit: ControllerSignature.maxBytes)
      let signature = try ControllerSignature.parse(signatureBytes)

      try signature.verify(bytes, as: .scriptFile)

      return signature
    } catch ControllerPackageError.signature(let text) {
      throw ControllerPackageError.fileSignature(text)
    } catch ControllerPackageError.contents(let text) {
      throw ControllerPackageError.fileSignature(text)
    } catch ControllerPackageError.io(let text) {
      throw ControllerPackageError.fileSignature(text)
    }
  }

  private static func openRegularFile(_ path: String, what: String, limit: Int) throws -> Int32 {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)

    guard descriptor >= 0 else {
      switch errno {
      case ENOENT: throw ControllerPackageError.contents("\(path) does not exist")
      case ELOOP:
        throw ControllerPackageError.contents("\(path) is a link, which uniterm will not follow")
      default: throw ControllerPackageError.io("cannot open \(what): \(errnoText())")
      }
    }

    var info = stat()

    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      close(descriptor)

      throw ControllerPackageError.contents(
        "\(path) is not a regular file. A pipe or a device cannot be declared.")
    }

    guard info.st_size <= limit else {
      close(descriptor)

      throw ControllerPackageError.contents("\(path) is over \(limit) bytes")
    }

    return descriptor
  }

  private static func readFile(at path: String, what: String, limit: Int) throws -> Data {
    let descriptor = try openRegularFile(path, what: what, limit: limit)

    defer { close(descriptor) }

    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)

      if count < 0, errno == EINTR { continue }

      guard count >= 0 else {
        throw ControllerPackageError.io("cannot read \(path): \(errnoText())")
      }

      if count == 0 { return bytes }

      bytes.append(contentsOf: buffer[..<count])

      guard bytes.count <= limit else {
        throw ControllerPackageError.contents("\(path) is over \(limit) bytes")
      }
    }
  }
}
