import Darwin
import Foundation

/// Puts the `uniterm` command where a shell finds it, as a symlink into the app bundle.
///
/// The link is never a copy. The command in the bundle always matches the app, and the command
/// refuses to run from anywhere else. This type holds only the file-system work. The save panel
/// that picks the place belongs to the app.
public struct ScriptCommandInstaller: Sendable {
  public enum InstallError: Error, Equatable, CustomStringConvertible {
    /// The bundle holds no command to link to.
    case commandMissing(String)

    /// Something that is not a symlink sits at the chosen place. It is never replaced.
    case occupied(String, kind: String)

    /// The app runs from a place that will not last, so a link to it would dangle. Gatekeeper
    /// translocation and a read-only disk image are the cases.
    case unstableLocation(String)

    /// The place's folder or the link could not be made.
    case failed(String, String)

    public var description: String {
      switch self {
      case .commandMissing(let path):
        return "The uniterm app has no command to install. It should be at \(path)."

      case .occupied(let path, let kind):
        return
          "\(path) is already \(kind), so uniterm left it alone. Choose another name, or "
          + "remove it yourself first."

      case .unstableLocation(let path):
        return
          "uniterm is running from \(path), which will not be there after it quits. Move uniterm "
          + "to the Applications folder, open it from there, and install the command again."

      case .failed(let path, let reason):
        return "uniterm could not install the command at \(path): \(reason)"
      }
    }
  }

  public struct Installed: Equatable, Sendable {
    public let link: URL

    /// True when the place held a symlink, which the install replaced.
    public let replaced: Bool

    /// False when the folder is not one of the usual places on a shell's `PATH`.
    public let onPath: Bool

    /// What to tell the user.
    public var message: String {
      var text = replaced ? "Updated the uniterm command at \(link.path)." : ""

      if text.isEmpty { text = "Installed the uniterm command at \(link.path)." }

      if !onPath {
        text +=
          " \(link.deletingLastPathComponent().path) is not one of the usual folders on PATH. "
          + "Add it to your shell's PATH to run uniterm by name."
      }

      return text
    }
  }

  /// The command inside the bundle that a link points to.
  public let command: URL
  private let home: URL
  private let isReadOnly: @Sendable (String) -> Bool

  /// Runs after the installer has looked at the place and before it changes it. Only a test sets
  /// it, to put something in the place at that moment.
  var beforeCommit: @Sendable () -> Void = {}

  /// `isReadOnly` says whether a path is on a read-only volume. A test replaces it.
  public init(
    command: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
    isReadOnly: @escaping @Sendable (String) -> Bool = ScriptCommandInstaller.onReadOnlyVolume
  ) {
    self.command = command
    self.home = home
    self.isReadOnly = isReadOnly
  }

  public static func onReadOnlyVolume(_ path: String) -> Bool {
    var info = statfs()

    return statfs(path, &info) == 0 && info.f_flags & UInt32(MNT_RDONLY) != 0
  }

  /// True when the command's path says the app was translocated or sits on a read-only volume.
  /// Both disappear, so a link to the command would dangle after the app quits.
  var runsFromAnUnstableLocation: Bool {
    command.path.contains("/AppTranslocation/") || isReadOnly(command.path)
  }

  /// `Contents/Helpers/uniterm` inside a bundle.
  public static func command(in bundle: URL) -> URL {
    bundle.appendingPathComponent("Contents/Helpers/uniterm", isDirectory: false)
  }

  /// The folder the save panel opens in.
  public var defaultDirectory: URL {
    home.appendingPathComponent(".local/bin", isDirectory: true)
  }

  /// The folders that an interactive shell on macOS usually has on `PATH`, or that a user who made
  /// one almost always has added. The app's own environment is scrubbed, so it cannot read the
  /// real `PATH`. A folder outside the list may still be on the path, and the user is told only
  /// that it might not be.
  var usualPathFolders: [String] {
    [
      "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin", "/usr/bin", "/bin",
      home.appendingPathComponent(".local/bin").path, home.appendingPathComponent("bin").path,
    ]
  }

  /// Makes the folder the panel opens in, so the panel can start there.
  public func prepareDefaultDirectory() {
    try? FileManager.default.createDirectory(
      at: defaultDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
  }

  /// Links `link` to the command. An existing symlink is replaced, in one step, so a shell never
  /// finds the place empty. A regular file, a folder, or anything else is refused and untouched.
  ///
  /// The place is claimed with `renamex_np`, so a file that appears after the look is never
  /// replaced. An empty place uses `RENAME_EXCL`. A symlink uses `RENAME_SWAP`, which puts the
  /// old entry at the temporary name. When that entry is not a symlink, the swap is undone.
  public func install(at link: URL) throws -> Installed {
    guard FileManager.default.isExecutableFile(atPath: command.path) else {
      throw InstallError.commandMissing(command.path)
    }

    guard !runsFromAnUnstableLocation else { throw InstallError.unstableLocation(command.path) }

    let directory = link.deletingLastPathComponent()

    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    } catch {
      throw InstallError.failed(link.path, error.localizedDescription)
    }

    let temporary = directory.appendingPathComponent(".uniterm-install-\(getpid())").path

    unlink(temporary)

    guard symlink(command.path, temporary) == 0 else {
      throw InstallError.failed(link.path, String(cString: strerror(errno)))
    }

    var replaced = false

    defer { unlink(temporary) }

    // A second pass covers a place that changed between the look and the claim.
    for _ in 0..<2 {
      var info = stat()
      let exists = lstat(link.path, &info) == 0

      if exists { try refuseUnlessSymlink(info, at: link) }

      beforeCommit()

      if !exists {
        if renamex_np(temporary, link.path, UInt32(RENAME_EXCL)) == 0 { break }

        guard errno == EEXIST else { throw InstallError.failed(link.path, errnoText()) }

        continue
      }

      if renamex_np(temporary, link.path, UInt32(RENAME_SWAP)) == 0 {
        var old = stat()

        guard lstat(temporary, &old) == 0, old.st_mode & S_IFMT == S_IFLNK else {
          _ = renamex_np(temporary, link.path, UInt32(RENAME_SWAP))

          throw InstallError.occupied(link.path, kind: kindOf(temporary: temporary, link: link))
        }

        replaced = true

        break
      }

      guard errno == ENOENT else { throw InstallError.failed(link.path, errnoText()) }
    }

    var final = stat()

    guard lstat(link.path, &final) == 0, final.st_mode & S_IFMT == S_IFLNK,
      (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == command.path
    else { throw InstallError.failed(link.path, "the place changed while the link was made") }

    let folder = directory.standardizedFileURL.path

    return Installed(link: link, replaced: replaced, onPath: usualPathFolders.contains(folder))
  }

  private func refuseUnlessSymlink(_ info: stat, at link: URL) throws {
    switch info.st_mode & S_IFMT {
    case S_IFLNK: return
    case S_IFDIR: throw InstallError.occupied(link.path, kind: "a folder")
    case S_IFREG: throw InstallError.occupied(link.path, kind: "a file")
    default: throw InstallError.occupied(link.path, kind: "in use")
    }
  }

  /// After an undone swap, the entry that was refused sits at the link again.
  private func kindOf(temporary: String, link: URL) -> String {
    var info = stat()

    guard lstat(link.path, &info) == 0 else { return "in use" }

    switch info.st_mode & S_IFMT {
    case S_IFDIR: return "a folder"
    case S_IFREG: return "a file"
    default: return "in use"
    }
  }

  private func errnoText() -> String { String(cString: strerror(errno)) }
}
