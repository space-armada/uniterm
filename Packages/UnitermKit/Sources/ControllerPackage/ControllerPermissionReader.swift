import Foundation
import ScriptWire
import SourceAccess

/// The one reader of a permission list. A controller's `controller.json` and a script file's
/// declaration both hold one, so a package and a file cannot disagree about which kinds, fields,
/// and scopes are allowed.
public enum ControllerPermissionReader {
  /// What declares the permissions. It only changes how a refusal is worded.
  public enum Subject: Sendable {
    case controller
    case file

    func unknownKind(_ kind: String) -> String {
      switch self {
      case .controller:
        return "the permission kind \"\(kind)\" is not one this uniterm knows"

      case .file:
        return ":\(kind) is not a permission kind this uniterm knows"
      }
    }

    /// A permission names its kind alone. The running uniterm decides what the kind means.
    func namedVersion(_ kind: String) -> String {
      switch self {
      case .controller:
        return "the \(kind) permission names a version. A permission names its kind alone, since "
          + "it means what the running uniterm says. Remove \"version\""

      case .file:
        return ":\(kind) names a :version. A permission names its kind alone, since it means "
          + "what the running uniterm says. Remove :version"
      }
    }

    func refusedNativeCode(_ name: String) -> String {
      switch self {
      case .controller:
        return "a controller cannot declare \(name), since it loads native code from outside the "
          + "package"

      case .file:
        return "a script file cannot declare \(name), since it loads native code from outside the "
          + "snapshot an approval binds to"
      }
    }
  }

  /// Reads a `permissions` array. Every rule is checked, and the first broken one throws
  /// `ControllerPackageError.malformed`. A caller that is not a descriptor words the error for its
  /// own file.
  ///
  /// `allowsCapabilities` is false for a native entry, which declares no Janet capability.
  public static func read(
    _ value: StrictJSON, allowsCapabilities: Bool, subject: Subject = .controller,
    editions: ControllerPermissionEditions = .current
  ) throws -> Set<ControllerPermission> {
    var permissions = Set<ControllerPermission>()
    var listed = Set<String>()

    for element in try value.array("permissions") {
      let fields = try element.members(
        of: "a permission", required: ["kind"],
        optional: [
          "name", "executable", "directory", "environment", "directories", "version",
        ])
      let permissionKind = try fields["kind"]!.string("a permission's kind")

      guard let edition = editions.edition(of: permissionKind) else {
        throw ControllerPackageError.malformed(subject.unknownKind(permissionKind))
      }

      guard fields["version"] == nil else {
        throw ControllerPackageError.malformed(subject.namedVersion(permissionKind))
      }

      let launchFields: Set<String> = ["executable", "directory", "environment"]

      guard permissionKind == "host-launch" || launchFields.isDisjoint(with: fields.keys) else {
        throw ControllerPackageError.malformed(
          "only host-launch takes an executable, a directory, or an environment")
      }

      guard permissionKind == "path-read" || fields["directories"] == nil else {
        throw ControllerPackageError.malformed("only path-read takes directories")
      }

      if permissionKind != "capability", fields["name"] != nil {
        throw ControllerPackageError.malformed("\(permissionKind) takes no name")
      }

      let permissionValue: ControllerPermissionKind

      switch permissionKind {
      case "pane-control":
        permissionValue = .paneControl

      case "clipboard-read":
        permissionValue = .clipboardRead

      case "clipboard-write":
        permissionValue = .clipboardWrite

      case "browser-navigation":
        permissionValue = .browserNavigation

      case "browser-read":
        permissionValue = .browserRead

      case "ask-user":
        permissionValue = .askUser

      case "host-launch":
        guard let executable = fields["executable"], let directory = fields["directory"],
          let environment = fields["environment"]
        else {
          throw ControllerPackageError.malformed(
            "host-launch needs an executable, a directory, and an environment list")
        }

        permissionValue = .hostLaunch(
          try HostLaunchScope(
            executable: try executable.string("a host launch's executable"),
            directory: try directory.string("a host launch's directory"),
            environmentKeys: try environment.array("a host launch's environment").map {
              try $0.string("an environment key")
            }))

      case "path-read":
        guard let directories = fields["directories"] else {
          throw ControllerPackageError.malformed("path-read needs a list of directories")
        }

        do {
          permissionValue = .pathRead(
            try ReadScope(
              directories: try directories.array("a read scope's directories").map {
                try $0.string("a read scope's directory")
              }))
        } catch let error as ReadScopeError {
          throw ControllerPackageError.malformed(error.description)
        }

      default:
        guard allowsCapabilities else {
          throw ControllerPackageError.malformed("only a Janet entry declares capabilities")
        }

        guard let nameValue = fields["name"] else {
          throw ControllerPackageError.malformed("a capability needs a name")
        }

        let name = try nameValue.string("a capability's name")

        guard ScriptCapabilityNames.grantable.contains(name) else {
          throw ControllerPackageError.malformed(
            "\(name) is not a capability uniterm run --allow can grant")
        }

        guard !ControllerDescriptor.refusedCapabilities.contains(name) else {
          throw ControllerPackageError.malformed(
            subject.refusedNativeCode(name))
        }

        permissionValue = .capability(name)
      }

      // A kind is listed once, or once for each capability name or host launch executable.
      guard listed.insert(permissionKind + "\u{0}" + permissionValue.scopeName).inserted else {
        throw ControllerPackageError.malformed("\(permissionKind) is listed twice")
      }

      permissions.insert(ControllerPermission(permissionValue, edition: edition))
    }

    return permissions
  }
}
