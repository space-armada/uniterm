import Darwin
import Foundation

/// Where the app listens, as the app and the command both compute it.
///
/// The folder is `~/Library/Application Support/uniterm/run`. The command finds the home folder
/// from the user database, never from `HOME`, so no inherited state decides where it connects.
public enum ScriptAddress {
  /// The address of the first instance to start, which the command uses when nothing names another.
  public static let wellKnownName = "uniterm.sock"

  /// The lock that tells a live owner of the well-known address from a stale socket file.
  public static let lockName = "uniterm.lock"

  /// The current user's home folder, from the user database. Nil when the database has none.
  public static func homeDirectory() -> String? {
    guard let entry = getpwuid(geteuid()), let home = entry.pointee.pw_dir else { return nil }

    let path = String(cString: home)

    return path.isEmpty ? nil : path
  }

  /// The folder that holds the app's sockets and its lock, for a home folder.
  public static func directory(home: String) -> String {
    (home as NSString).appendingPathComponent("Library/Application Support/uniterm/run")
  }

  public static func wellKnownPath(home: String) -> String {
    (directory(home: home) as NSString).appendingPathComponent(wellKnownName)
  }

  /// True when `path` is a socket this user owns, and not a link to one. The command checks the
  /// well-known address with it before connecting, so it never talks to another user's socket.
  public static func isOwnSocket(path: String) -> Bool {
    var info = stat()

    guard lstat(path, &info) == 0 else { return false }

    return info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == geteuid()
  }
}
