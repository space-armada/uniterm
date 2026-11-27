import ControllerPackage
import Foundation
import SourceAccess

/// Why a policy file was not read. Either way it authorizes nothing.
public enum ControllerPolicyFileError: Error, Equatable, Sendable, CustomStringConvertible {
  /// The file is not the format this version reads: broken JSON, an unknown field, a scope this
  /// version cannot read, or a value out of bounds.
  case unreadable(String)

  /// An earlier uniterm wrote the file, in a format that did not record an edition with each
  /// approval. It cannot be told apart from an approval at an edition this build knows, so it
  /// grants nothing. The number is the format it was written in.
  case older(Int)

  /// A newer uniterm wrote the file: a newer format, or a well-formed permission whose kind this
  /// build does not know or whose edition is above this build's. Its meanings may be broader than
  /// this build can tell, so it is left as it is. The text names what is newer.
  case newer(String)

  public var description: String {
    switch self {
    case .unreadable(let text): return "the policy file cannot be read: \(text)"
    case .older(let format): return "the policy file is format \(format), from an earlier uniterm"
    case .newer(let what): return "the policy file has \(what), from a newer uniterm"
    }
  }
}

/// The controller policy file's format: strict JSON, one document, format 2.
///
/// ```json
/// {
///   "format": 2,
///   "policies": [
///     {
///       "approved": "2026-11-11T10:00:00Z",
///       "name": "Slides",
///       "scopes": [{"edition": 0, "kind": "pane-control"}, {"edition": 0, "kind": "clipboard-read"}],
///       "selector": {"controller": "dev.example.slides", "kind": "version", "version": "..."}
///     }
///   ]
/// }
/// ```
///
/// Each scope is spelled as a descriptor spells the permission, with its kind and scope, and adds
/// the edition the approval was made at. The reader is as strict as the descriptor's: a repeated
/// key or an unknown field refuses the whole file as broken. A kind this build does not know, or an
/// edition above the one it knows, refuses the file as newer, so a meaning a later build adds is
/// never read as a narrower one here, and the file is kept for the build that wrote it. An edition
/// below this build's reads, and covers nothing.
///
/// Format 1 recorded a permission version where this format records an edition. A format 1 file is
/// set aside, and each approval is given again once.
public enum ControllerPolicyFile {
  public static let format = 2
  public static let maxBytes = 1 << 20
  public static let maxPolicies = 256

  /// Reads the policy file of `artifact`. A package's file holds package selectors and a script
  /// file's holds file selectors. A selector of the other kind makes the file unreadable, so the
  /// two stores can never be read as each other's.
  public static func decode(
    _ bytes: Data, artifact: ControllerArtifact = .package,
    editions: ControllerPermissionEditions = .current
  ) throws(ControllerPolicyFileError) -> [ControllerPolicy] {
    do {
      return try read(bytes, artifact: artifact, editions: editions)
    } catch let error as ControllerPolicyFileError {
      throw error
    } catch let error as StrictJSONError {
      throw .unreadable(error.description)
    } catch ControllerPackageError.malformed(let text) {
      throw .unreadable(text)
    } catch {
      throw .unreadable("\(error)")
    }
  }

  private static func read(
    _ bytes: Data, artifact: ControllerArtifact, editions: ControllerPermissionEditions
  ) throws -> [ControllerPolicy] {
    let document = try StrictJSONReader.parse(bytes, maxBytes: maxBytes)

    guard case .object(let top) = document else {
      throw ControllerPolicyFileError.unreadable("the file must hold one object")
    }

    // The format is read on its own first, so a newer file is told apart from a broken one
    // whatever else it holds.
    if case .integer(let format)? = top.first(where: { $0.key == "format" })?.value,
      format > Self.format
    {
      throw ControllerPolicyFileError.newer("format \(format)")
    }

    if case .integer(let format)? = top.first(where: { $0.key == "format" })?.value,
      (1..<Self.format).contains(format)
    {
      throw ControllerPolicyFileError.older(format)
    }

    let fields = try document.members(of: "the file", required: ["format", "policies"])

    guard try fields["format"]!.integer("format") == Self.format else {
      throw ControllerPolicyFileError.unreadable("the format must be \(Self.format)")
    }

    let entries = try fields["policies"]!.array("policies")

    guard entries.count <= maxPolicies else {
      throw ControllerPolicyFileError.unreadable("it holds more than \(maxPolicies) policies")
    }

    var policies: [ControllerPolicy] = []
    var selectors = Set<ControllerSelector>()

    for entry in entries {
      let policy = try readPolicy(entry, artifact: artifact, editions: editions)

      guard selectors.insert(policy.selector).inserted else {
        throw ControllerPolicyFileError.unreadable("a selector is listed twice")
      }

      policies.append(policy)
    }

    return policies
  }

  private static func readPolicy(
    _ value: StrictJSON, artifact: ControllerArtifact, editions: ControllerPermissionEditions
  ) throws -> ControllerPolicy {
    let fields = try value.members(
      of: "a policy", required: ["selector", "name", "scopes", "approved"])

    let name = try fields["name"]!.string("a policy's name")

    guard ControllerDescriptor.isValidName(name) else {
      throw ControllerPolicyFileError.unreadable("a policy's name is not a controller name")
    }

    let approved = try fields["approved"]!.string("a policy's approval time")

    guard approved.utf8.count <= 64, ISO8601DateFormatter().date(from: approved) != nil else {
      throw ControllerPolicyFileError.unreadable("a policy's approval time is not ISO 8601")
    }

    var scopes = Set<ControllerPermission>()

    for scope in try fields["scopes"]!.array("a policy's scopes") {
      guard scopes.insert(try readScope(scope, editions: editions)).inserted else {
        throw ControllerPolicyFileError.unreadable("a scope is listed twice")
      }
    }

    return ControllerPolicy(
      selector: try readSelector(fields["selector"]!, artifact: artifact), name: name,
      scopes: scopes,
      approved: approved)
  }

  private static func readSelector(
    _ value: StrictJSON, artifact: ControllerArtifact
  ) throws -> ControllerSelector {
    guard case .object(let members) = value,
      case .string(let kind)? = members.first(where: { $0.key == "kind" })?.value
    else {
      throw ControllerPolicyFileError.unreadable("a selector needs a kind")
    }

    guard kind == "version" || kind == "identity" else {
      throw ControllerPolicyFileError.unreadable("the selector kind \"\(kind)\" is unknown")
    }

    let valueKey = kind == "version" ? "version" : "key"
    let idKey = artifact == .package ? "controller" : "id"
    let wantsID = artifact == .package || kind == "identity"
    let fields = try value.members(
      of: "a selector", required: wantsID ? ["kind", idKey, valueKey] : ["kind", valueKey])
    let digest = try fields[valueKey]!.string("a selector's \(valueKey)")

    guard isDigest(digest) else {
      throw ControllerPolicyFileError.unreadable(
        "a selector's \(valueKey) must be 64 lowercase hex digits")
    }

    guard wantsID else { return .fileVersion(version: digest) }

    let id = try fields[idKey]!.string("a selector's \(idKey)")

    guard ControllerDescriptor.isValidID(id) else {
      throw ControllerPolicyFileError.unreadable("a selector's \(idKey) is not a controller ID")
    }

    switch (artifact, kind) {
    case (.package, "version"): return .version(controllerID: id, version: digest)
    case (.package, _): return .identity(controllerID: id, keyFingerprint: digest)
    case (.file, _): return .fileIdentity(fileID: id, keyFingerprint: digest)
    }
  }

  private static func readScope(
    _ value: StrictJSON, editions: ControllerPermissionEditions
  ) throws -> ControllerPermission {
    guard case .object(let members) = value,
      case .string(let kind)? = members.first(where: { $0.key == "kind" })?.value
    else {
      throw ControllerPolicyFileError.unreadable("a scope needs a kind")
    }

    // The kind and edition are read before the fields, since a newer build's kind may carry
    // fields this one does not know. Such a file is newer, not broken.
    guard case .integer(let edition)? = members.first(where: { $0.key == "edition" })?.value else {
      throw ControllerPolicyFileError.unreadable("a scope needs a whole-number edition")
    }

    guard let known = editions.edition(of: kind) else {
      throw ControllerPolicyFileError.newer("the kind \(kind)")
    }

    guard edition <= known else {
      throw ControllerPolicyFileError.newer("\(kind) edition \(edition)")
    }

    guard edition >= 0 else {
      throw ControllerPolicyFileError.unreadable("a scope's edition cannot be negative")
    }

    let fields: [String: StrictJSON]

    switch kind {
    case "capability":
      fields = try value.members(of: "a capability scope", required: ["kind", "edition", "name"])

    case "host-launch":
      fields = try value.members(
        of: "a host-launch scope",
        required: ["kind", "edition", "executable", "directory", "environment"])

    case "path-read":
      fields = try value.members(
        of: "a path-read scope", required: ["kind", "edition", "directories"])

    default:
      fields = try value.members(of: "a \(kind) scope", required: ["kind", "edition"])
    }

    let permission: ControllerPermissionKind

    switch kind {
    case "pane-control":
      permission = .paneControl

    case "clipboard-read":
      permission = .clipboardRead

    case "clipboard-write":
      permission = .clipboardWrite

    case "browser-navigation":
      permission = .browserNavigation

    case "browser-read":
      permission = .browserRead

    case "ask-user":
      permission = .askUser

    case "capability":
      let name = try fields["name"]!.string("a capability's name")

      guard ControllerDescriptor.isDeclarableCapability(name) else {
        throw ControllerPolicyFileError.unreadable("\(name) is not a capability a controller holds")
      }

      permission = .capability(name)

    case "path-read":
      do {
        permission = .pathRead(
          try ReadScope(
            approved: try fields["directories"]!.array("a read scope's directories").map {
              try $0.string("a read scope's directory")
            }))
      } catch let error as ReadScopeError {
        throw ControllerPolicyFileError.unreadable(error.description)
      }

    default:
      permission = .hostLaunch(
        try HostLaunchScope(
          executable: try fields["executable"]!.string("a host launch's executable"),
          directory: try fields["directory"]!.string("a host launch's directory"),
          environmentKeys: try fields["environment"]!.array("a host launch's environment").map {
            try $0.string("an environment key")
          }))
    }

    return ControllerPermission(permission, edition: edition)
  }

  private static func isDigest(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  /// The file's bytes for `policies`, sorted so one set of policies has one spelling.
  public static func encode(_ policies: [ControllerPolicy]) -> Data {
    let entries = policies.sorted { sortKey($0) < sortKey($1) }.map { policy -> JSONText in
      .object([
        ("approved", .string(policy.approved)),
        ("name", .string(policy.name)),
        ("scopes", .array(policy.scopes.sorted().map(scopeText))),
        ("selector", selectorText(policy.selector)),
      ])
    }

    let document = JSONText.object([
      ("format", .integer(Self.format)), ("policies", .array(entries)),
    ])

    return Data((document.rendered(indent: "") + "\n").utf8)
  }

  private static func sortKey(_ policy: ControllerPolicy) -> String {
    "\(policy.selector.controllerID)\u{0}\(policy.selector.kindName)\u{0}\(policy.selector.value)"
  }

  private static func selectorText(_ selector: ControllerSelector) -> JSONText {
    switch selector {
    case .version(let id, let version):
      return .object([
        ("controller", .string(id)), ("kind", .string("version")), ("version", .string(version)),
      ])

    case .identity(let id, let fingerprint):
      return .object([
        ("controller", .string(id)), ("key", .string(fingerprint)), ("kind", .string("identity")),
      ])

    case .fileVersion(let version):
      return .object([("kind", .string("version")), ("version", .string(version))])

    case .fileIdentity(let id, let fingerprint):
      return .object([
        ("id", .string(id)), ("key", .string(fingerprint)), ("kind", .string("identity")),
      ])
    }
  }

  private static func scopeText(_ permission: ControllerPermission) -> JSONText {
    var members: [(String, JSONText)] = [("kind", .string(permission.kindName))]

    switch permission.kind {
    case .paneControl, .clipboardRead, .clipboardWrite, .browserNavigation, .browserRead,
      .askUser:
      break

    case .capability(let name):
      members.append(("name", .string(name)))

    case .hostLaunch(let scope):
      members += [
        ("directory", .string(scope.directory)),
        ("environment", .array(scope.environmentKeys.map(JSONText.string))),
        ("executable", .string(scope.executable)),
      ]

    case .pathRead(let scope):
      members.append(("directories", .array(scope.directories.map(JSONText.string))))
    }

    members.append(("edition", .integer(permission.edition)))

    return .object(members.sorted { $0.0 < $1.0 })
  }
}

/// The few JSON shapes the policy file writes, rendered with a fixed layout.
private indirect enum JSONText {
  case string(String)
  case integer(Int)
  case array([JSONText])
  case object([(String, JSONText)])

  func rendered(indent: String) -> String {
    let inner = indent + "  "

    switch self {
    case .string(let text):
      return Self.quoted(text)

    case .integer(let number):
      return String(number)

    case .array(let elements):
      guard !elements.isEmpty else { return "[]" }

      return "[\n" + elements.map { inner + $0.rendered(indent: inner) }.joined(separator: ",\n")
        + "\n" + indent + "]"

    case .object(let members):
      guard !members.isEmpty else { return "{}" }

      return "{\n"
        + members.map { inner + Self.quoted($0.0) + ": " + $0.1.rendered(indent: inner) }
        .joined(separator: ",\n") + "\n" + indent + "}"
    }
  }

  /// Escapes the quote, the backslash, and every control character, so the strict reader reads
  /// back the same text.
  static func quoted(_ text: String) -> String {
    var result = "\""

    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      default:
        if scalar.value < 0x20 {
          result += String(format: "\\u%04x", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }

    return result + "\""
  }
}
