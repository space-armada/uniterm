import Foundation
import ScriptWire
import Security

/// The bundled command's own code identity, which it sends the app right after the hello. The app
/// compares it with the hash it kept for its own command at launch.
enum CommandCodeIdentity {
  /// The code directory hash of the running executable, or nil when its signature cannot be read.
  /// It is the same value the app reads from the command's file, so an unmodified copy of the
  /// command matches wherever it sits.
  static func codeDirectoryHash() -> Data? {
    var running: SecCode?

    guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return nil }

    var staticCode: SecStaticCode?

    guard SecCodeCopyStaticCode(running, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }

    var information: CFDictionary?

    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let info = information as? [String: Any],
      let hash = info[kSecCodeInfoUnique as String] as? Data,
      (1...ScriptProtocol.maxIdentityBytes).contains(hash.count)
    else { return nil }

    return hash
  }
}
