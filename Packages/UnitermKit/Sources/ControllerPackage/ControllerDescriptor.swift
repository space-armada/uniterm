import CryptoKit
import Foundation
import ScriptWire
import SourceAccess

/// Why a controller package, its descriptor, its signature, or its snapshot was refused. Each case
/// carries text for the user, which names the file or field at fault.
public enum ControllerPackageError: Error, Equatable, CustomStringConvertible, Sendable {
  /// The descriptor or signature is not the strict format this version reads.
  case malformed(String)

  /// The package on disk does not match what its descriptor lists.
  case contents(String)

  /// The signature file is present and does not verify.
  case signature(String)

  /// A script file's `.sig` is present and does not read or verify.
  case fileSignature(String)

  /// A native entry or library loads code from outside the package and the system.
  case loadBoundary(String)

  /// The file system refused a read or a write.
  case io(String)

  /// A script file's declaration is not one this version reads.
  case declaration(String)

  public var description: String {
    switch self {
    case .malformed(let text): return "controller.json: \(text)"
    case .declaration(let text): return "the file's declaration: \(text)"
    case .contents(let text): return text
    case .signature(let text): return "controller.sig: \(text)"
    case .fileSignature(let text): return "the file's .sig: \(text)"
    case .loadBoundary(let text): return text
    case .io(let text): return text
    }
  }
}

/// What a controller runs: a Janet script run by uniterm's own helper, or a native executable.
public enum ControllerEntryKind: String, Sendable, Equatable {
  case janet
  case native
}

/// What a permission grants, apart from its edition: its kind and, for kinds that take one, its
/// scope.
public enum ControllerPermissionKind: Hashable, Sendable {
  /// The controller acts on the panes its run may address, within the pane rules.
  case paneControl

  /// A Janet sandbox capability, by the name `uniterm run --allow` takes. Only a Janet entry may
  /// declare one.
  case capability(String)

  /// The controller reads the clipboard through the typed request.
  case clipboardRead

  /// The controller replaces the clipboard through the typed request.
  case clipboardWrite

  /// A pane of a group the controller's run owns may start this program as its exec driver once
  /// the user chooses Run.
  case hostLaunch(HostLaunchScope)

  /// An applet may read a path inside these directories on the controller's behalf. The scope is
  /// its own type, never a host launch's directory, and a protected location it contains but does
  /// not name is left out.
  case pathRead(ReadScope)

  /// The controller opens browser tabs and navigates them. That is network access signed in as
  /// the user, whatever the controller's own sandbox allows.
  case browserNavigation

  /// The controller reads the addresses and titles of the browser tabs it opened. An address may
  /// carry a token.
  case browserRead

  /// The controller shows the user forms and reads their answers. The power has no scope. It opens
  /// no pane of the controller's own and grants no pane control.
  case askUser

  /// The kind as the descriptor and the policy file spell it.
  public var name: String {
    switch self {
    case .paneControl: return "pane-control"
    case .capability: return "capability"
    case .clipboardRead: return "clipboard-read"
    case .clipboardWrite: return "clipboard-write"
    case .hostLaunch: return "host-launch"
    case .pathRead: return "path-read"
    case .browserNavigation: return "browser-navigation"
    case .browserRead: return "browser-read"
    case .askUser: return "ask-user"
    }
  }

  /// What tells two permissions of one kind apart: a capability's name or a host launch's
  /// executable. A descriptor lists each kind at most once for each of these, so it lists
  /// path-read once, with every directory in one scope.
  public var scopeName: String {
    switch self {
    case .paneControl, .clipboardRead, .clipboardWrite, .pathRead, .browserNavigation,
      .browserRead, .askUser:
      return ""
    case .capability(let name): return name
    case .hostLaunch(let scope): return scope.executable
    }
  }
}

/// The edition of each permission kind this build knows. An edition is internal: only uniterm
/// reads it. It moves when a kind's meaning grows, so an approval made at an older edition no
/// longer covers the kind and the user is asked again. A descriptor never names one.
public struct ControllerPermissionEditions: Hashable, Sendable {
  private let table: [String: Int]

  public init(_ table: [String: Int]) {
    self.table = table
  }

  /// Every kind this build knows, at edition 0.
  public static let current = ControllerPermissionEditions([
    "pane-control": 0, "capability": 0, "clipboard-read": 0, "clipboard-write": 0,
    "host-launch": 0, "path-read": 0, "browser-navigation": 0, "browser-read": 0, "ask-user": 0,
  ])

  /// The kind's edition, or nil when this build does not know the kind.
  public func edition(of kind: String) -> Int? { table[kind] }

  public var kinds: Set<String> { Set(table.keys) }
}

/// A power a controller declares: a kind, with its scope, at one edition of its meaning.
///
/// A descriptor names a kind alone, and a permission always means what the running uniterm says.
/// The edition is recorded with each approval. An approval covers only the edition it was made
/// at, so a kind whose meaning grew asks the user again.
public struct ControllerPermission: Hashable, Sendable, Comparable {
  public let kind: ControllerPermissionKind
  public let edition: Int

  public init(_ kind: ControllerPermissionKind, edition: Int) {
    self.kind = kind
    self.edition = edition
  }

  /// A permission at the edition this build knows for `kind`.
  public init(_ kind: ControllerPermissionKind) {
    self.init(kind, edition: ControllerPermissionEditions.current.edition(of: kind.name) ?? 0)
  }

  public static let paneControl = ControllerPermission(.paneControl)
  public static let clipboardRead = ControllerPermission(.clipboardRead)
  public static let clipboardWrite = ControllerPermission(.clipboardWrite)
  public static let browserNavigation = ControllerPermission(.browserNavigation)
  public static let browserRead = ControllerPermission(.browserRead)
  public static let askUser = ControllerPermission(.askUser)

  public static func capability(_ name: String) -> ControllerPermission {
    ControllerPermission(.capability(name))
  }

  public static func hostLaunch(_ scope: HostLaunchScope) -> ControllerPermission {
    ControllerPermission(.hostLaunch(scope))
  }

  public static func pathRead(_ scope: ReadScope) -> ControllerPermission {
    ControllerPermission(.pathRead(scope))
  }

  /// The kind's name, as the descriptor spells it.
  public var kindName: String { kind.name }

  /// The capability's name, when this is a capability.
  public var capabilityName: String? {
    if case .capability(let name) = kind { return name }

    return nil
  }

  public static func < (lhs: ControllerPermission, rhs: ControllerPermission) -> Bool {
    (lhs.sortKey, lhs.edition) < (rhs.sortKey, rhs.edition)
  }

  private var sortKey: String {
    switch kind {
    case .paneControl: return "0"
    case .capability(let name): return "1" + name
    case .clipboardRead: return "2"
    case .clipboardWrite: return "3"
    case .hostLaunch(let scope):
      return "4" + scope.executable + "\u{0}" + scope.directory + "\u{0}"
        + scope.environmentKeys.joined(separator: ",")
    case .pathRead(let scope):
      return "5" + scope.directories.joined(separator: "\u{0}")
    case .browserNavigation: return "6"
    case .browserRead: return "7"
    case .askUser: return "8"
    }
  }
}

/// A program a controller may have uniterm start as an exec driver: its absolute executable, the
/// folder it may run in or any folder inside it, and the environment keys it may be given.
/// Arguments and environment values are runtime inputs, so a scope never names them.
public struct HostLaunchScope: Hashable, Sendable {
  public let executable: String
  public let directory: String

  /// Sorted, with no key twice.
  public let environmentKeys: [String]

  /// The most environment keys one scope names.
  public static let maxEnvironmentKeys = 64

  /// The longest environment key, in bytes.
  public static let maxKeyBytes = 128

  /// Checks every field. A path must be absolute and plain: no empty, `.`, or `..` component, and
  /// no trailing slash, so one folder has one spelling and no path climbs out of another.
  public init(executable: String, directory: String, environmentKeys: [String]) throws {
    guard Self.isPlainAbsolute(executable), executable != "/" else {
      throw ControllerPackageError.malformed(
        "a host launch's executable must be an absolute path with no '.', '..', or empty "
          + "component")
    }

    guard Self.isPlainAbsolute(directory) else {
      throw ControllerPackageError.malformed(
        "a host launch's directory must be an absolute path with no '.', '..', or empty "
          + "component")
    }

    guard environmentKeys.count <= Self.maxEnvironmentKeys,
      Set(environmentKeys).count == environmentKeys.count,
      environmentKeys.allSatisfy(Self.isEnvironmentKey)
    else {
      throw ControllerPackageError.malformed(
        "a host launch's environment must list at most \(Self.maxEnvironmentKeys) distinct keys "
          + "of letters, digits, and '_' that do not start with a digit")
    }

    self.executable = executable
    self.directory = directory
    self.environmentKeys = environmentKeys.sorted()
  }

  /// True when `path` is `directory` or a folder inside it.
  public func allows(directory path: String) -> Bool {
    guard Self.isPlainAbsolute(path) else { return false }

    if path == directory { return true }

    let prefix = directory == "/" ? "/" : directory + "/"

    return path.hasPrefix(prefix)
  }

  /// `path` with every link in it resolved, or nil when nothing is there. A launch's folder is
  /// compared and entered in this form, so a link inside an approved folder cannot lead a driver
  /// out of it.
  public static func resolved(_ path: String) -> String? {
    guard let pointer = realpath(path, nil) else { return nil }

    defer { free(pointer) }

    return String(cString: pointer)
  }

  static func isPlainAbsolute(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path.utf8.count <= ControllerDescriptor.maxPathBytes else {
      return false
    }

    if path == "/" { return true }

    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)

    return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
      && !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
  }

  static func isEnvironmentKey(_ key: String) -> Bool {
    guard let first = key.utf8.first, key.utf8.count <= maxKeyBytes,
      !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first)
    else { return false }

    return key.utf8.allSatisfy {
      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
        || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "_")
    }
  }
}

/// A controller's `controller.json`, read strictly from its exact bytes.
///
/// The app, the signer, and the helper's loader all read a descriptor through `parse`, so they
/// cannot disagree about what a file means. The version digest is SHA-256 over those bytes. The
/// descriptor lists the digest of every packaged file, so the version digest covers the code too.
public struct ControllerDescriptor: Equatable, Sendable {
  /// The descriptor format this version reads. It is an external version, so it stays 0 until
  /// uniterm's maintainers declare it version 1. A descriptor names each permission by kind alone.
  /// Any other format is refused.
  public static let format = 0

  /// Every format this version reads.
  public static let formats = 0...format

  /// The descriptor's name inside a package.
  public static let fileName = "controller.json"

  public static let maxBytes = 64 * 1024
  public static let maxFiles = 512
  public static let maxFileBytes = 32 * 1024 * 1024
  public static let maxPackageBytes = 128 * 1024 * 1024
  public static let maxIDBytes = 128
  public static let maxNameBytes = 64
  public static let maxPathBytes = 1024
  public static let maxPathDepth = 16
  public static let maxComponentBytes = 255

  /// Capabilities a controller may not declare, since each one loads native code that the
  /// package does not hold and the app cannot check.
  public static let refusedCapabilities: Set<String> = [
    "ffi", "ffi-define", "ffi-jit", "ffi-use", "modules",
  ]

  /// The stable controller ID, such as `dev.example.slides`.
  public let id: String

  /// The name shown to the user. It proves nothing about who wrote the controller.
  public let name: String

  public let entryKind: ControllerEntryKind

  /// The entry's path inside the package.
  public let entryPath: String

  /// Each packaged file's path and SHA-256 digest, sorted by path.
  public let files: [String: Data]

  public let permissions: Set<ControllerPermission>

  /// SHA-256 over the descriptor's exact bytes.
  public let versionDigest: Data

  /// Reads a descriptor. Every rule is checked before it returns, and the first broken one throws.
  public static func parse(_ bytes: Data) throws -> ControllerDescriptor {
    let document: StrictJSON

    do {
      document = try StrictJSONReader.parse(bytes, maxBytes: maxBytes)
    } catch let error as StrictJSONError {
      throw ControllerPackageError.malformed(error.description)
    }

    let fields = try document.members(
      of: "the descriptor", required: ["format", "id", "name", "entry", "files", "permissions"])

    let format = try fields["format"]!.integer("format")

    guard Self.formats.contains(format) else {
      throw ControllerPackageError.malformed(
        "format \(format) is not one this uniterm reads. It reads format \(Self.format) only, so "
          + "rewrite the descriptor for this uniterm or update uniterm.")
    }

    let id = try fields["id"]!.string("id")

    try checkID(id)

    let name = try fields["name"]!.string("name")

    try checkName(name)

    let entry = try fields["entry"]!.members(of: "entry", required: ["kind", "path"])
    let kindText = try entry["kind"]!.string("entry kind")

    guard let kind = ControllerEntryKind(rawValue: kindText) else {
      throw ControllerPackageError.malformed(
        "entry kind \"\(kindText)\" is not janet or native")
    }

    let entryPath = try entry["path"]!.string("entry path")

    try checkPath(entryPath)

    let files = try readFiles(fields["files"]!)

    guard files[entryPath] != nil else {
      throw ControllerPackageError.malformed("the entry \(entryPath) is not among the files")
    }

    if kind == .janet {
      guard entryPath.hasSuffix(".janet") else {
        throw ControllerPackageError.malformed("a Janet entry must be a .janet file")
      }
    }

    let permissions = try ControllerPermissionReader.read(
      fields["permissions"]!, allowsCapabilities: kind == .janet)

    return ControllerDescriptor(
      id: id, name: name, entryKind: kind, entryPath: entryPath, files: files,
      permissions: permissions, versionDigest: Data(SHA256.hash(data: bytes)))
  }

  /// The Janet capabilities the descriptor declares.
  public var capabilities: Set<String> {
    Set(permissions.compactMap(\.capabilityName))
  }

  /// The version digest as lowercase hex.
  public var versionHex: String { versionDigest.hex }

  /// True when `id` is a controller ID a descriptor may name.
  public static func isValidID(_ id: String) -> Bool {
    (try? checkID(id)) != nil
  }

  /// True when `name` is a display name a descriptor may give.
  public static func isValidName(_ name: String) -> Bool {
    (try? checkName(name)) != nil
  }

  /// True when a controller may declare the capability `name`.
  public static func isDeclarableCapability(_ name: String) -> Bool {
    ScriptCapabilityNames.grantable.contains(name) && !refusedCapabilities.contains(name)
  }

  static func checkID(_ id: String) throws {
    let bytes = Array(id.utf8)
    let allowed = { (byte: UInt8) in
      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        || byte == UInt8(ascii: "-")
    }
    let labels = id.split(separator: ".", omittingEmptySubsequences: false)

    guard !bytes.isEmpty, bytes.count <= maxIDBytes, labels.count >= 2,
      labels.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(allowed) })
    else {
      throw ControllerPackageError.malformed(
        "id must be a reverse domain name of lowercase letters, digits, and hyphens, such as "
          + "dev.example.slides, at most \(maxIDBytes) bytes")
    }
  }

  static func checkName(_ name: String) throws {
    let printable = name.unicodeScalars.allSatisfy { scalar in
      !scalar.properties.generalCategory.isControlOrFormat
    }

    guard !name.isEmpty, name.utf8.count <= maxNameBytes, printable,
      name.trimmingCharacters(in: .whitespaces) == name
    else {
      throw ControllerPackageError.malformed(
        "name must be 1 to \(maxNameBytes) bytes of printable text with no edge spaces")
    }
  }

  /// A packaged path is relative and plain: components of ASCII letters, digits, `.`, `_`, and
  /// `-`, each starting with a letter or a digit. Nothing can climb out, name the descriptor, or
  /// spell one file two ways under Unicode normalization.
  static func checkPath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    let plain = components.allSatisfy { component in
      guard let first = component.utf8.first, component.utf8.count <= maxComponentBytes else {
        return false
      }

      let isAlphanumeric = { (byte: UInt8) in
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
          || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
      }

      return isAlphanumeric(first)
        && component.utf8.allSatisfy {
          isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_")
            || $0 == UInt8(ascii: "-")
        }
    }

    guard plain, path.utf8.count <= maxPathBytes, components.count <= maxPathDepth else {
      throw ControllerPackageError.malformed(
        "the path \"\(path.debugDescription.dropFirst().dropLast())\" is not a plain relative path. "
          + "Use components of letters, digits, '.', '_', and '-' that start with a letter or a "
          + "digit, joined by '/'.")
    }

    let reserved = [fileName, ControllerSignature.fileName].map { $0.lowercased() }

    guard !reserved.contains(path.lowercased()) else {
      throw ControllerPackageError.malformed("\(path) is reserved and cannot be a packaged file")
    }
  }

  private static func readFiles(_ value: StrictJSON) throws -> [String: Data] {
    let members = try value.object("files")

    guard !members.isEmpty, members.count <= maxFiles else {
      throw ControllerPackageError.malformed("files must list 1 to \(maxFiles) files")
    }

    var files: [String: Data] = [:]

    // The default macOS file system ignores case, so two paths that differ only by case would be
    // one file there.
    var folded: [String: String] = [:]

    for member in members {
      try checkPath(member.key)

      let key = member.key.lowercased()

      if let earlier = folded[key] {
        throw ControllerPackageError.malformed(
          "\(earlier) and \(member.key) name the same file on a case-insensitive disk")
      }

      folded[key] = member.key
      files[member.key] = try readDigest(member.value, for: member.key)
    }

    for path in files.keys {
      var prefix = ""

      for component in path.split(separator: "/").dropLast() {
        prefix += prefix.isEmpty ? String(component) : "/" + component

        if let file = folded[prefix.lowercased()] {
          throw ControllerPackageError.malformed(
            "\(file) is a file, so \(path) cannot be inside it")
        }
      }
    }

    return files
  }

  private static func readDigest(_ value: StrictJSON, for path: String) throws -> Data {
    let text = try value.string("the digest of \(path)")
    let prefix = "sha256:"
    let hex = text.dropFirst(prefix.count)

    guard text.hasPrefix(prefix), hex.count == 64,
      hex.utf8.allSatisfy({
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }),
      let digest = Data(hex: String(hex))
    else {
      throw ControllerPackageError.malformed(
        "the digest of \(path) must be sha256: and 64 lowercase hex digits")
    }

    return digest
  }
}

extension Unicode.GeneralCategory {
  var isControlOrFormat: Bool {
    switch self {
    case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse,
      .unassigned:
      return true
    default:
      return false
    }
  }
}

extension Data {
  /// Lowercase hex.
  public var hex: String { map { String(format: "%02x", $0) }.joined() }

  /// Nil unless `hex` is an even number of hex digits.
  public init?(hex: String) {
    let digits = Array(hex.utf8)

    guard digits.count % 2 == 0 else { return nil }

    var bytes: [UInt8] = []

    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16)
      else { return nil }

      bytes.append(byte)
    }

    self.init(bytes)
  }
}
