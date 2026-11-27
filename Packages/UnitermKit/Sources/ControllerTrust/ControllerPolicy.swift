import ControllerPackage
import Foundation
import SourceAccess

/// What a remembered approval names: one exact verified version of a controller, or a signing
/// key together with a controller ID, across every version that key signs. A script file has
/// selectors of its own, which never match a package, and a package's never match a file.
public enum ControllerSelector: Hashable, Sendable {
  /// The descriptor's SHA-256 as lowercase hex. It covers the packaged code too.
  case version(controllerID: String, version: String)

  /// The SHA-256 of the signing public key as lowercase hex.
  case identity(controllerID: String, keyFingerprint: String)

  /// The SHA-256 of a whole script file as lowercase hex. A file needs no ID to be trusted by its
  /// version.
  case fileVersion(version: String)

  /// The SHA-256 of the signing public key as lowercase hex, with the ID the file declares.
  case fileIdentity(fileID: String, keyFingerprint: String)

  /// A package's ID, or a signed file's declared ID. An unsigned file has none, so a file version
  /// names the empty string.
  public var controllerID: String {
    switch self {
    case .version(let id, _), .identity(let id, _), .fileIdentity(let id, _): return id
    case .fileVersion: return ""
    }
  }

  public var artifact: ControllerArtifact {
    switch self {
    case .version, .identity: return .package
    case .fileVersion, .fileIdentity: return .file
    }
  }

  /// True when a verified run of `identity` is one this selector names. A selector never matches
  /// on a name, a path, or a digest a peer claims: the identity comes from the app's own reading
  /// of the snapshot.
  public func matches(_ identity: ControllerIdentity) -> Bool {
    guard identity.artifact == artifact else { return false }

    switch self {
    case .version(let id, let version):
      return identity.controllerID == id && identity.version == version

    case .identity(let id, let fingerprint), .fileIdentity(let id, let fingerprint):
      return identity.controllerID == id && identity.keyFingerprint == fingerprint

    case .fileVersion(let version):
      return identity.version == version
    }
  }

  /// The selector's kind as the policy file spells it.
  public var kindName: String {
    switch self {
    case .version, .fileVersion: return "version"
    case .identity, .fileIdentity: return "identity"
    }
  }

  /// The version digest or the key fingerprint.
  public var value: String {
    switch self {
    case .version(_, let version), .fileVersion(let version): return version
    case .identity(_, let fingerprint), .fileIdentity(_, let fingerprint): return fingerprint
    }
  }
}

/// One remembered approval: a selector, and the typed permissions approved for runs it names.
///
/// It holds no connection, process, pane, or window, so it can never restore a live binding. A run
/// it covers still needs its own admission, and gets its pane scope from that run alone.
public struct ControllerPolicy: Hashable, Sendable {
  public let selector: ControllerSelector

  /// The display name the controller gave when the user approved it. It proves nothing.
  public let name: String

  /// The approved ceiling. Arguments and environment values are never part of it.
  public let scopes: Set<ControllerPermission>

  /// When the user approved it, as ISO 8601 text.
  public let approved: String

  /// What a version approval is a version of: a package's ID, a script's declared ID, or else the
  /// script's absolute path. It finds the older versions to offer to replace when the user trusts
  /// a new one. It takes no part in whether the approval covers a run. An identity approval has
  /// none.
  public let versionOf: String?

  public init(
    selector: ControllerSelector, name: String, scopes: Set<ControllerPermission>,
    approved: String, versionOf: String? = nil
  ) {
    self.selector = selector
    self.name = name
    self.scopes = scopes
    self.approved = approved
    self.versionOf = versionOf.flatMap {
      selector.kindName == "version" && Self.isPlainVersionOf($0) ? $0 : nil
    }
  }

  /// Whether text can be stored as what an approval is a version of. The reader refuses any other,
  /// so the constructor drops it, and what is written is always what the reader reads. A path can
  /// hold a control character, and a version entry with no `versionOf` still reads and covers.
  public static func isPlainVersionOf(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= ControllerPolicyFile.maxVersionOfBytes
      && !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
  }

  /// The permissions of `requested` this policy does not cover. Empty means covered.
  public func uncovered(_ requested: Set<ControllerPermission>) -> [ControllerPermission] {
    PermissionContainment.uncovered(requested, by: scopes)
  }
}

/// The semantic comparison of a request with an approval. A request is covered when each of its
/// permissions is the same as, or narrower than, one approved permission at the same edition. A
/// broader scope, another power, or an approval made at another edition is never covered, so a
/// kind whose meaning grew asks the user again.
public enum PermissionContainment {
  public static func uncovered(
    _ requested: Set<ControllerPermission>, by approved: Set<ControllerPermission>
  ) -> [ControllerPermission] {
    let reads = readScopes(in: approved)

    return requested.filter { wanted in
      if case .pathRead(let scope) = wanted.kind {
        return !isCovered(scope, edition: wanted.edition, by: reads)
      }

      return !approved.contains { wanted.isCovered(by: $0) }
    }.sorted()
  }

  /// The path-reading scopes of a set, each with the edition it was approved at.
  private static func readScopes(in permissions: Set<ControllerPermission>) -> [(
    scope: ReadScope, edition: Int
  )] {
    permissions.compactMap { permission in
      guard case .pathRead(let scope) = permission.kind else { return nil }

      return (scope, permission.edition)
    }
  }

  /// A read scope is covered by the union of the approved scopes at its edition, so two approvals
  /// that together hold a request cover it.
  private static func isCovered(
    _ scope: ReadScope, edition: Int, by approved: [(scope: ReadScope, edition: Int)]
  ) -> Bool {
    let usable = approved.filter { $0.edition == edition }

    guard let first = usable.first else { return false }

    let union = usable.dropFirst().reduce(first.scope) { $0.union($1.scope) }

    return scope.isCovered(by: union)
  }

  /// The union of an existing approval and a newly approved request, with nothing the new request
  /// already covers listed twice.
  public static func merged(
    _ existing: Set<ControllerPermission>, with added: Set<ControllerPermission>
  ) -> Set<ControllerPermission> {
    var result = existing

    for permission in added where !result.contains(where: { permission.isCovered(by: $0) }) {
      // Two read scopes of one edition add up to one, so the list never holds the power twice.
      if case .pathRead(let scope) = permission.kind,
        let held = result.first(where: {
          if case .pathRead = $0.kind { return $0.edition == permission.edition }

          return false
        }), case .pathRead(let heldScope) = held.kind
      {
        result.remove(held)
        result.insert(
          ControllerPermission(.pathRead(heldScope.union(scope)), edition: permission.edition))

        continue
      }

      result.insert(permission)
    }

    return result
  }
}

extension ControllerPermission {
  /// True when this permission asks for no more than `approved` allows.
  ///
  /// The kinds and the editions must match, so an approval made at an older edition never covers
  /// a kind whose meaning has grown. A host launch is narrower when it
  /// names the same executable, a directory inside the approved one, and no environment key
  /// beyond the approved keys. A path-reading scope is narrower when its effective scope, with the
  /// protected locations removed, lies inside the approved one. Every other scope must be the same.
  public func isCovered(by approved: ControllerPermission) -> Bool {
    guard kind.name == approved.kind.name, edition == approved.edition else { return false }

    switch (kind, approved.kind) {
    case (.hostLaunch(let wanted), .hostLaunch(let scope)):
      return wanted.executable == scope.executable
        && scope.allows(directory: wanted.directory)
        && Set(wanted.environmentKeys).isSubset(of: Set(scope.environmentKeys))

    case (.pathRead(let wanted), .pathRead(let scope)):
      return wanted.isCovered(by: scope)

    default:
      return kind == approved.kind
    }
  }

  /// How a review and the Controllers & Permissions window name the permission.
  public var displayText: String {
    let text: String

    switch kind {
    case .paneControl:
      text = "Control panes it may address"

    case .capability(let name):
      text = "Janet capability \(name)"

    case .clipboardRead:
      text = "Read the clipboard"

    case .clipboardWrite:
      text = "Replace the clipboard"

    case .hostLaunch(let scope):
      let keys =
        scope.environmentKeys.isEmpty ? "none" : scope.environmentKeys.joined(separator: ", ")

      text =
        "Start \(scope.executable) as a driver, with any arguments, in \(scope.directory) or a "
        + "folder inside it, with environment keys \(keys) and any values"

    case .browserNavigation:
      text =
        "Open and navigate browser tabs, with network access signed in as you, whatever its "
        + "sandbox allows"

    case .browserRead:
      text = "Read the addresses and titles of the browser tabs it opened"

    case .askUser:
      text = "Ask you questions in a Questions pane and read your answers"

    case .pathRead(let scope):
      text =
        "Make applets read files and folders inside \(scope.directories.joined(separator: ", "))"
        + ", leaving out the protected locations it contains"
    }

    return text
  }
}
