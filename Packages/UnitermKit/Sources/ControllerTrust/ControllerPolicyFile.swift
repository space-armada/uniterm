import ControllerPackage
import Foundation
import SourceAccess

/// Why a policy file was not read. Either way it authorizes nothing.
public enum ControllerPolicyFileError: Error, Equatable, Sendable, CustomStringConvertible {
  /// Nothing can tell where the file's entries begin and end: it is not JSON, it is not one
  /// object, a member repeats at its top, or it lacks the members every format has.
  case unreadable(String)

  /// An earlier uniterm wrote the file, in a format that did not record an edition with each
  /// approval or an artifact kind with each entry. Its approvals cannot be told apart from
  /// approvals at an edition this build knows, so it grants nothing. The store moves it into the
  /// `retired` folder. The number is the format it was written in.
  case older(Int)

  /// A newer uniterm wrote the file, in a newer format. Its meanings may be broader than this
  /// build can tell, so it is left as it is. The text names the format.
  case newer(String)

  /// The file is over the bound the format fixes. A real set of approvals never reaches it, so the
  /// file looks damaged. It is left as it is, and grants nothing.
  case tooLarge

  public var description: String {
    switch self {
    case .unreadable(let text): return "the policy file cannot be read: \(text)"
    case .older(let format): return "the policy file is format \(format), from an earlier uniterm"
    case .newer(let what): return "the policy file has \(what), from a newer uniterm"
    case .tooLarge:
      return "the policy file is over \(ControllerPolicyFile.maxBytes) bytes, so it looks damaged"
    }
  }
}

/// One entry this build cannot read, exactly as the file spells it. It grants nothing, and every
/// save writes it back byte for byte, so the build that can read it finds it again.
public struct ControllerKeptEntry: Hashable, Sendable {
  public let bytes: [UInt8]

  public init(bytes: [UInt8]) {
    self.bytes = bytes
  }
}

/// A top-level member of the file that this build does not know, kept as written.
public struct ControllerKeptMember: Hashable, Sendable {
  public let key: [UInt8]
  public let value: [UInt8]

  public init(key: [UInt8], value: [UInt8]) {
    self.key = key
    self.value = value
  }
}

/// What a policy file holds: the approvals this build reads in full, and what it keeps unread.
public struct ControllerPolicyDocument: Equatable, Sendable {
  public var policies: [ControllerPolicy]
  public var kept: [ControllerKeptEntry]
  public var members: [ControllerKeptMember]

  public init(
    policies: [ControllerPolicy] = [], kept: [ControllerKeptEntry] = [],
    members: [ControllerKeptMember] = []
  ) {
    self.policies = policies
    self.kept = kept
    self.members = members
  }
}

/// The controller policy file's format: strict JSON, one document, format 3.
///
/// ```json
/// {
///   "format": 3,
///   "policies": [
///     {
///       "approved": "2026-11-11T10:00:00Z",
///       "artifact": "package",
///       "name": "Slides",
///       "scopes": [{"edition": 0, "kind": "pane-control"}, {"edition": 0, "kind": "clipboard-read"}],
///       "selector": {"controller": "dev.example.slides", "kind": "version", "version": "..."},
///       "versionOf": "dev.example.slides"
///     }
///   ]
/// }
/// ```
///
/// One file holds every remembered approval. Each entry names its artifact kind, so a selector
/// matches only runs of its own kind. A version approval also names what it is a version of: a
/// package's ID, a script's declared ID, or else the script's absolute path. That finds older
/// versions to offer to replace, and takes no part in whether an approval covers a run.
///
/// Each scope is spelled as a descriptor spells the permission, with its kind and scope, and adds
/// the edition the approval was made at.
///
/// The reader is lenient between entries and strict within one. An entry is one this build reads in
/// full or one it cannot read, whatever the reason: an unknown artifact, selector, or permission
/// kind, an edition above this build's, a value that fails a check, an unknown field, or a key
/// repeated at any depth inside it. An entry it cannot read is kept byte for byte, grants nothing,
/// and is counted. It is never read in part, so no approval is acted on with a scope dropped. A
/// fault that stops the reader telling where entries begin and end sets the whole file aside. An
/// edition below this build's reads, and covers nothing.
///
/// The bound is 4 MiB and no count. It is part of the format, so a build with a smaller bound
/// cannot move a larger file aside, and a later change to it is a new format.
///
/// Formats 1 and 2 recorded a permission version, or an edition, with no artifact kind, and kept
/// script files in a file of their own. They are moved into the `retired` folder beside the store,
/// and each approval is given again once.
public enum ControllerPolicyFile {
  public static let format = 3
  public static let maxBytes = 4 << 20

  /// The longest `versionOf` text, in bytes. A path can be long, and no system accepts one past it.
  public static let maxVersionOfBytes = 4096

  /// Reads the approvals the file holds. An entry this build cannot read is not among them.
  public static func decode(
    _ bytes: Data, editions: ControllerPermissionEditions = .current
  ) throws(ControllerPolicyFileError) -> [ControllerPolicy] {
    try read(bytes, editions: editions).policies
  }

  /// Reads the whole file: the approvals it reads in full, and what it keeps unread. It throws
  /// only when no entry can be told from another.
  public static func read(
    _ data: Data, editions: ControllerPermissionEditions = .current
  ) throws(ControllerPolicyFileError) -> ControllerPolicyDocument {
    try read(data, editions: editions, makeFormatter: { ISO8601DateFormatter() })
  }

  /// `makeFormatter` is the seam that counts the date parser's setup. A read calls it at most once,
  /// and only when an approval time is not the plain spelling, so setup never grows with the
  /// number of entries.
  static func read(
    _ data: Data, editions: ControllerPermissionEditions,
    makeFormatter: @escaping () -> ISO8601DateFormatter
  ) throws(ControllerPolicyFileError) -> ControllerPolicyDocument {
    guard data.count <= maxBytes else { throw .tooLarge }

    let bytes = [UInt8](data)
    let members: [PolicyFileScanner.Member]

    do {
      members = try PolicyFileScanner.members(of: bytes)
    } catch {
      throw .unreadable("\(error)")
    }

    var named: [String: PolicyFileScanner.Member] = [:]

    for member in members {
      let key = keyText(bytes[member.key])

      guard named.updateValue(member, forKey: key) == nil else {
        throw key == "format" || key == "policies"
          ? .unreadable("the member \(key) appears twice")
          : .unreadable("a member at the top of the file appears twice")
      }
    }

    guard let formatMember = named["format"] else { throw .unreadable("the file has no format") }

    guard
      case .integer(let number)? = try? StrictJSONReader.parse(
        Data(bytes[formatMember.value]), maxBytes: maxBytes)
    else { throw .unreadable("the format must be a whole number") }

    if number > Self.format { throw .newer("format \(number)") }

    if (1..<Self.format).contains(number) { throw .older(number) }

    guard number == Self.format else { throw .unreadable("the format must be \(Self.format)") }

    guard let policiesMember = named["policies"] else {
      throw .unreadable("the file has no policies")
    }

    let ranges: [Range<Int>]

    do {
      ranges = try PolicyFileScanner.elements(of: policiesMember.value, in: bytes)
    } catch {
      throw .unreadable("\(error)")
    }

    var outside = 0

    for range in ranges {
      guard String(validating: bytes[outside..<range.lowerBound], as: UTF8.self) != nil else {
        throw .unreadable("the file is not UTF-8")
      }

      outside = range.upperBound
    }

    guard String(validating: bytes[outside...], as: UTF8.self) != nil else {
      throw .unreadable("the file is not UTF-8")
    }

    var document = ControllerPolicyDocument()
    let dates = ApprovalTimes(make: makeFormatter)

    for range in ranges {
      if let policy = try? readPolicy(Array(bytes[range]), editions: editions, dates: dates) {
        document.policies.append(policy)
      } else {
        document.kept.append(ControllerKeptEntry(bytes: Array(bytes[range])))
      }
    }

    for member in members {
      let key = keyText(bytes[member.key])

      guard key != "format", key != "policies" else { continue }

      document.members.append(
        ControllerKeptMember(
          key: Array(bytes[member.key]), value: Array(bytes[member.value])))
    }

    return document
  }

  /// A key as text for comparison. A key this reader cannot decode compares by its raw bytes, so
  /// two such keys are still told apart.
  private static func keyText(_ token: ArraySlice<UInt8>) -> String {
    if case .string(let text)? = try? StrictJSONReader.parse(Data(token), maxBytes: maxBytes) {
      return text
    }

    return "\u{0}" + token.map { String($0, radix: 16) }.joined(separator: ".")
  }

  /// Reads one entry on its own bytes, with the strict reader.
  private static func readPolicy(
    _ bytes: [UInt8], editions: ControllerPermissionEditions, dates: ApprovalTimes
  ) throws -> ControllerPolicy {
    let value = try StrictJSONReader.parse(Data(bytes), maxBytes: maxBytes)
    let fields = try value.members(
      of: "a policy", required: ["selector", "artifact", "name", "scopes", "approved"],
      optional: ["versionOf"])

    let artifactName = try fields["artifact"]!.string("a policy's artifact")

    guard let artifact = ControllerArtifact(rawValue: artifactName) else {
      throw ControllerPolicyFileError.unreadable("the artifact kind \"\(artifactName)\" is unknown")
    }

    let name = try fields["name"]!.string("a policy's name")

    guard ControllerDescriptor.isValidName(name) else {
      throw ControllerPolicyFileError.unreadable("a policy's name is not a controller name")
    }

    let approved = try fields["approved"]!.string("a policy's approval time")

    guard approved.utf8.count <= 64, isPlainTime(approved) || dates.accepts(approved)
    else {
      throw ControllerPolicyFileError.unreadable("a policy's approval time is not ISO 8601")
    }

    var scopes = Set<ControllerPermission>()

    for scope in try fields["scopes"]!.array("a policy's scopes") {
      guard scopes.insert(try readScope(scope, editions: editions)).inserted else {
        throw ControllerPolicyFileError.unreadable("a scope is listed twice")
      }
    }

    let selector = try readSelector(fields["selector"]!, artifact: artifact)
    var versionOf: String?

    if let text = fields["versionOf"] {
      guard selector.kindName == "version" else {
        throw ControllerPolicyFileError.unreadable("only a version approval is a version of")
      }

      let of = try text.string("a policy's versionOf")

      guard ControllerPolicy.isPlainVersionOf(of) else {
        throw ControllerPolicyFileError.unreadable("a policy's versionOf is not a plain name")
      }

      versionOf = of
    }

    return ControllerPolicy(
      selector: selector, name: name, scopes: scopes, approved: approved, versionOf: versionOf)
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
    // fields this one does not know. Either way the whole entry is one this build cannot read.
    guard case .integer(let edition)? = members.first(where: { $0.key == "edition" })?.value else {
      throw ControllerPolicyFileError.unreadable("a scope needs a whole-number edition")
    }

    guard let known = editions.edition(of: kind) else {
      throw ControllerPolicyFileError.unreadable("the kind \(kind) is unknown")
    }

    guard edition <= known else {
      throw ControllerPolicyFileError.unreadable("\(kind) edition \(edition) is above this build's")
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

  /// The date parser, made the first time a read meets an approval time in another spelling and
  /// kept for the rest of that read.
  private final class ApprovalTimes {
    private let make: () -> ISO8601DateFormatter
    private var formatter: ISO8601DateFormatter?

    init(make: @escaping () -> ISO8601DateFormatter) {
      self.make = make
    }

    func accepts(_ text: String) -> Bool {
      let parser = formatter ?? make()

      formatter = parser

      return parser.date(from: text) != nil
    }
  }

  /// True for the spelling uniterm writes, `2026-11-11T10:00:00Z`, with a year from 1000, a day up
  /// to the 28th, and a clock time that exists. Every such text is a date the formatter accepts,
  /// so the formatter, which costs about 25 microseconds a call, is left for any other spelling.
  /// The test pins the two to each other.
  static func isPlainTime(_ text: String) -> Bool {
    let bytes = Array(text.utf8)

    guard bytes.count == 20 else { return false }

    func number(_ range: Range<Int>) -> Int? {
      var total = 0

      for byte in bytes[range] {
        guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }

        total = total * 10 + Int(byte - UInt8(ascii: "0"))
      }

      return total
    }

    guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
      bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"),
      bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "Z"),
      let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
      let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
    else { return false }

    return year >= 1000 && (1...12).contains(month) && (1...28).contains(day) && hour < 24
      && minute < 60 && second < 60
  }

  private static func isDigest(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }

  /// The file's bytes for `policies`, sorted so one set of entries has one spelling. Every kept
  /// entry and member is written back exactly as it was read.
  public static func encode(
    _ policies: [ControllerPolicy], kept: [ControllerKeptEntry] = [],
    members: [ControllerKeptMember] = []
  ) -> Data {
    var rows: [(key: [String], bytes: [UInt8])] = policies.map { policy in
      let text = JSONText.object(
        [
          ("approved", .string(policy.approved)),
          ("artifact", .string(policy.selector.artifact.rawValue)),
          ("name", .string(policy.name)),
          ("scopes", .array(policy.scopes.sorted().map(scopeText))),
          ("selector", selectorText(policy.selector)),
        ] + (policy.versionOf.map { [("versionOf", JSONText.string($0))] } ?? []))

      return (sortKey(policy), Array(text.rendered(indent: "    ").utf8))
    }

    for entry in kept { rows.append((keptSortKey(entry), entry.bytes)) }

    rows.sort { lhs, rhs in
      lhs.key == rhs.key
        ? lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
        : lhs.key.lexicographicallyPrecedes(rhs.key)
    }

    var out = Array("{\n  \"format\": \(Self.format),\n  \"policies\": [".utf8)

    if rows.isEmpty {
      out += Array("]".utf8)
    } else {
      out += Array("\n".utf8)

      for (index, row) in rows.enumerated() {
        out += Array("    ".utf8) + row.bytes + Array((index == rows.count - 1 ? "\n" : ",\n").utf8)
      }

      out += Array("  ]".utf8)
    }

    let extra = members.sorted { $0.key.lexicographicallyPrecedes($1.key) }

    for member in extra {
      out += Array(",\n  ".utf8) + member.key + Array(": ".utf8) + member.value
    }

    out += Array("\n}\n".utf8)

    return Data(out)
  }

  /// The order of the file: by ID, selector kind, and value, then artifact kind. Two entries that
  /// share a selector are ordered by their bytes, so one set of entries has one spelling.
  private static func sortKey(_ policy: ControllerPolicy) -> [String] {
    [
      policy.selector.controllerID, policy.selector.kindName, policy.selector.value,
      policy.selector.artifact.rawValue,
    ]
  }

  /// Where an entry this build cannot read sorts. It reads no meaning from the entry. It takes the
  /// strings a selector would hold, when the entry has them, so the entry sits beside the
  /// approvals that share its selector.
  private static func keptSortKey(_ entry: ControllerKeptEntry) -> [String] {
    guard
      case .object(let members)? = try? StrictJSONReader.parse(
        Data(entry.bytes), maxBytes: maxBytes)
    else { return ["", "", "", ""] }

    func string(_ members: [(key: String, value: StrictJSON)], _ keys: [String]) -> String {
      for key in keys {
        if case .string(let text)? = members.first(where: { $0.key == key })?.value {
          return text
        }
      }

      return ""
    }

    var selector: [(key: String, value: StrictJSON)] = []

    if case .object(let inner)? = members.first(where: { $0.key == "selector" })?.value {
      selector = inner
    }

    return [
      string(selector, ["controller", "id"]), string(selector, ["kind"]),
      string(selector, ["version", "key"]), string(members, ["artifact"]),
    ]
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
