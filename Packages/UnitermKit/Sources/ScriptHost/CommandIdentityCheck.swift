import Foundation

/// What the listener makes of the code identity the bundled command sends right after its hello.
///
/// The app compares the identity with the one it kept for its own command at launch. A mismatch is
/// refused before any call runs, so a bundle replaced under a running app never pairs an old app
/// with a new command. At version 0 both sides name the same version, so the hello cannot tell.
///
/// A program that runs from this app's own command path must present an identity. One that runs
/// from anywhere else is a native controller or another install's command. It may present none,
/// and is admitted as before. When it does present one, the identity must match.
///
/// The check fails closed. The app's own path is always known in a real bundle, so an identity
/// with no path is a broken one and refuses every program. The peer's path comes from a kernel
/// lookup that fails for a peer that is gone. A peer whose path is unknown and that presented no
/// identity is refused, since it cannot be told from a stale command at the app's own path.
struct CommandIdentityCheck: Sendable {
  let helper: any ControllerHelperIdentity

  /// Waits until the command's identity is read, so no connection is admitted before the app knows
  /// its own command. The read starts when the identity is made, at launch.
  func awaitKept() {
    _ = helper.keptCodeDirectoryHash()
  }

  /// The text to refuse with, or nil when the peer is admitted. `presented` is the identity the
  /// peer sent, or nil when it sent none. `peerPath` is the peer's executable, when the system
  /// could name it.
  func refusal(presented: Data?, peerPath: String?) -> String? {
    guard let ownPath = helper.commandPath else {
      return "uniterm does not know where its own command is, so it cannot tell whether the "
        + "program that connected is that command."
    }

    let fromOwnPath = peerPath.map { Self.sameFile($0, ownPath) } ?? false

    guard let presented else {
      guard peerPath != nil else {
        return "uniterm could not tell where the program that connected runs, and it presented no "
          + "code identity, so uniterm cannot tell it from its own command at \(ownPath). "
          + "Relaunch uniterm if this command comes from this app."
      }

      guard fromOwnPath else { return nil }

      return "The uniterm command at \(ownPath) did not present its code identity, so it is not "
        + "the one this running uniterm started with. Relaunch uniterm."
    }

    guard let kept = helper.keptCodeDirectoryHash() else {
      return "uniterm cannot read the signature of its own command at \(ownPath), so it cannot "
        + "tell whether the command that connected is its own."
    }

    guard presented != kept else { return nil }

    if fromOwnPath {
      return "The uniterm command at \(ownPath) is not the one this running uniterm started with. "
        + "The app bundle was replaced while uniterm ran. Relaunch uniterm."
    }

    return "That uniterm command comes from another build than this running uniterm. Run this "
      + "uniterm's own command at \(ownPath) instead."
  }

  /// Whether two paths name one file. The peer's path comes from the kernel with every link
  /// resolved, so the app's own path is resolved the same way.
  private static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
    func resolved(_ path: String) -> String {
      URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    return resolved(lhs) == resolved(rhs)
  }
}
