import Darwin
import Foundation

/// The per-user folder that holds the app's script sockets. Only the user may enter it, so only
/// the user's processes can reach a socket in it.
public enum ScriptSocketDirectory {
  /// `~/Library/Application Support/uniterm/run`.
  public static func defaultDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

    return support.appendingPathComponent("uniterm", isDirectory: true)
      .appendingPathComponent("run", isDirectory: true)
  }

  /// Creates the folder when it is missing, and makes sure it is a real folder that this user owns
  /// and nobody else can enter. A symlink or another user's folder is refused, since a socket
  /// there could be read or replaced by someone else.
  static func prepare(_ directory: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw ScriptListenerError.directory(
        directory.path, Int32(truncatingIfNeeded: (error as NSError).code))
    }

    var info = stat()

    guard lstat(directory.path, &info) == 0 else {
      throw ScriptListenerError.directory(directory.path, errno)
    }

    guard info.st_mode & S_IFMT == S_IFDIR else {
      throw ScriptListenerError.directory(directory.path, ENOTDIR)
    }

    guard info.st_uid == geteuid() else {
      throw ScriptListenerError.directory(directory.path, EPERM)
    }

    guard chmod(directory.path, 0o700) == 0 else {
      throw ScriptListenerError.directory(directory.path, errno)
    }
  }
}
