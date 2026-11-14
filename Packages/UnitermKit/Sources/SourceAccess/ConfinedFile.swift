import Darwin
import Foundation

/// Why a file named relative to a folder was not opened.
public enum ConfinedFileError: Error, Equatable, Sendable {
  /// The name is not a relative path the walk accepts.
  case invalidName

  /// A step of the walk left the folder's volume, entered a mount point, or went through a name
  /// that the walk refuses before looking it up.
  case leavesVolume

  /// Symbolic links nested deeper than the walk follows.
  case tooManyLinks

  /// The name leads to something other than a file with data in it.
  case notAFile

  /// The file, or a folder on the way to it, is not there.
  case missing

  case access(SourceAccessError)
}

/// Opens a file named relative to a folder, and never leaves the folder's volume on the way.
///
/// The walk goes one component at a time from the folder. It looks at each entry before it
/// enters it, and it enters nothing whose device differs from the folder's. A mount point has its
/// own device, so a path through `/Volumes` or an automounted `/net` stops at the mount point, and
/// no mount runs. A symbolic link is followed by splicing its target into the walk, so a link
/// gets the same checks as a plain name. A link to an absolute path restarts the walk at the root,
/// where `net`, `Volumes`, and `home` are refused by name before anything looks them up.
///
/// The last component is opened without following a link and judged from the descriptor, as
/// `RegularFile` does, so a device or a pipe is refused.
public enum ConfinedFile {
  /// The folder a walk starts in, and the device every step must stay on.
  public struct Folder: Sendable, Equatable {
    public let path: String
    public let device: dev_t

    /// Reads the folder's device. The folder is the one the user opened a document in, so its own
    /// path is followed as written.
    public static func at(path: String) -> Result<Folder, SourceAccessError> {
      let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)

      guard descriptor >= 0 else { return .failure(.posix(errno, path: path)) }

      defer { Darwin.close(descriptor) }

      var info = stat()

      guard fstat(descriptor, &info) == 0 else { return .failure(.posix(errno, path: path)) }

      return .success(Folder(path: path, device: info.st_dev))
    }
  }

  /// The names a walk at the root refuses before it looks them up. `net` and `home` are automount
  /// points, and `Volumes` holds other volumes' mount points.
  static let refusedRootNames: Set<String> = ["net", "home", "Volumes", "Network"]

  static let maxLinks = 40

  /// Opens `name` read-only. The caller owns the descriptor and closes it.
  public static func open(name: String, in folder: Folder) -> Result<
    (descriptor: Int32, info: RegularFile.Info), ConfinedFileError
  > {
    guard let components = components(of: name) else { return .failure(.invalidName) }

    var rootInfo = stat()

    guard stat("/", &rootInfo) == 0 else { return .failure(.access(.posix(errno, path: "/"))) }

    var directory = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)

    guard directory >= 0 else { return .failure(.access(.posix(errno, path: folder.path))) }

    defer { Darwin.close(directory) }

    var info = stat()

    guard fstat(directory, &info) == 0, info.st_dev == folder.device else {
      return .failure(.leavesVolume)
    }

    var queue = components
    var links = 0

    while !queue.isEmpty {
      let part = queue.removeFirst()
      let isLast = queue.isEmpty

      if part == ".." {
        guard let parent = step(from: directory, to: "..", on: folder.device) else {
          return .failure(.leavesVolume)
        }

        Darwin.close(directory)
        directory = parent
        continue
      }

      if isRoot(directory, rootInfo), refusedRootNames.contains(part) {
        return .failure(.leavesVolume)
      }

      var entry = stat()

      guard fstatat(directory, part, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
        return .failure(
          errno == ENOENT || errno == ENOTDIR ? .missing : .access(.posix(errno, path: part)))
      }

      switch entry.st_mode & S_IFMT {
      case S_IFLNK:
        links += 1

        guard links <= maxLinks else { return .failure(.tooManyLinks) }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlinkat(directory, part, &buffer, Int(PATH_MAX))

        guard length > 0 else { return .failure(.notAFile) }

        let target = String(
          decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)

        guard !target.utf8.contains(0), let spliced = splice(target: target) else {
          return .failure(.invalidName)
        }

        if target.hasPrefix("/") {
          let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)

          guard root >= 0 else { return .failure(.access(.posix(errno, path: "/"))) }

          Darwin.close(directory)
          directory = root
        }

        queue = spliced + queue

      case S_IFDIR:
        guard entry.st_dev == folder.device else { return .failure(.leavesVolume) }

        guard !isLast else { return .failure(.notAFile) }

        guard let next = step(from: directory, to: part, on: folder.device) else {
          return .failure(.leavesVolume)
        }

        Darwin.close(directory)
        directory = next

      default:
        guard isLast else { return .failure(.missing) }

        guard entry.st_dev == folder.device else { return .failure(.leavesVolume) }

        let file = openat(directory, part, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)

        guard file >= 0 else {
          return .failure(.access(.posix(errno, path: part)))
        }

        var opened = stat()

        guard fstat(file, &opened) == 0, opened.st_dev == folder.device else {
          Darwin.close(file)
          return .failure(.leavesVolume)
        }

        switch RegularFile.check(descriptor: file, path: part) {
        case .failure: return .failure(.notAFile)
        case .success(let info): return .success((file, info))
        }
      }
    }

    return .failure(.notAFile)
  }

  /// The path's components, or nil when it is not a relative path the walk accepts. Empty
  /// components and `.` are dropped.
  static func components(of name: String) -> [String]? {
    guard !name.isEmpty, !name.hasPrefix("/"), !name.utf8.contains(0) else { return nil }

    let parts = name.split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { $0 != "." }

    guard !parts.isEmpty, parts.allSatisfy({ $0.utf8.count <= Int(NAME_MAX) }) else { return nil }

    return parts
  }

  private static func splice(target: String) -> [String]? {
    let parts = target.split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { $0 != "." }

    guard parts.allSatisfy({ $0.utf8.count <= Int(NAME_MAX) }) else { return nil }

    return parts
  }

  private static func isRoot(_ descriptor: Int32, _ root: stat) -> Bool {
    var info = stat()

    return fstat(descriptor, &info) == 0 && info.st_ino == root.st_ino && info.st_dev == root.st_dev
  }

  /// Opens the folder `name` inside `directory` when it is on `device`. A link is never followed
  /// here, since the walk handles links itself.
  private static func step(from directory: Int32, to name: String, on device: dev_t) -> Int32? {
    let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

    guard next >= 0 else { return nil }

    var info = stat()

    guard fstat(next, &info) == 0, info.st_dev == device else {
      Darwin.close(next)
      return nil
    }

    return next
  }
}
