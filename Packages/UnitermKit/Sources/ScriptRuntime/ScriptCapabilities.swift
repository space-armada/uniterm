import CJanet
import Foundation

/// The capabilities a run may be granted, by the names Janet's own `sandbox` accepts.
///
/// A script starts with every one denied. Each `--allow` clears the bits of one name. The bits
/// never go back, and Janet's sandbox cannot be widened once it is applied.
enum ScriptCapabilities {
  struct UnknownName: Error, Equatable, CustomStringConvertible {
    let name: String

    var description: String {
      if name == "all" {
        return "--allow all is not a capability. Name the capabilities the script needs."
      }

      return
        "--allow does not know the capability \"\(name)\". Use a name Janet's sandbox accepts, "
        + "such as fs-read."
    }
  }

  /// A name that Janet accepts but the default sandbox already allows, so granting it does
  /// nothing. It is refused, since `--allow` must never read like a grant that is not one.
  struct AlreadyAllowed: Error, Equatable, CustomStringConvertible {
    let name: String

    var description: String {
      "--allow \(name) grants nothing, since scripts may always use \(name). "
        + "Run uniterm run --help for the names that can be granted."
    }
  }

  /// The names a script may always use. The default sandbox leaves them open.
  static let alwaysAllowed = ["asm", "compile", "exit", "hrtime", "locale", "unmarshal"]

  /// The names `--allow` can grant. The default sandbox denies each one.
  static let grantable = [
    "chroot", "env", "ffi", "ffi-define", "ffi-jit", "ffi-use", "fs", "fs-read", "fs-temp",
    "fs-write", "modules", "net", "net-connect", "net-listen", "sandbox", "signal", "subprocess",
    "threads",
  ]

  /// The bits that stay denied once every name in `granted` is allowed.
  static func denied(granting granted: [String]) throws -> UInt32 {
    var denied = uniterm_janet_default_sandbox

    for name in granted {
      var flags: UInt32 = 0

      guard uniterm_janet_capability_flags(name, &flags) == 0 else {
        throw UnknownName(name: name)
      }

      guard flags & uniterm_janet_default_sandbox != 0 else { throw AlreadyAllowed(name: name) }

      denied &= ~flags
    }

    return denied
  }
}
