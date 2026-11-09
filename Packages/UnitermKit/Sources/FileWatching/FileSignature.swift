import Darwin
import Foundation

/// What a path holds at one moment: whether a file is there, which one, and how big and how
/// recently written. A watcher compares signatures to tell a change to the watched file from a
/// change to its neighbors.
public struct FileSignature: Equatable, Sendable {
  public let exists: Bool
  let device: Int64
  let inode: UInt64
  let size: Int64
  let seconds: Int
  let nanoseconds: Int

  public static let missing = FileSignature(
    exists: false, device: 0, inode: 0, size: 0, seconds: 0, nanoseconds: 0)

  /// The signature of what `path` names, with symbolic links followed. A path that cannot be read
  /// is missing.
  public static func of(path: String) -> FileSignature {
    var info = stat()

    guard stat(path, &info) == 0 else { return .missing }

    return FileSignature(
      exists: true, device: Int64(info.st_dev), inode: UInt64(info.st_ino),
      size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec,
      nanoseconds: info.st_mtimespec.tv_nsec)
  }

  /// True when `other` names a different file than this one does.
  func isSameFile(as other: FileSignature) -> Bool {
    exists == other.exists && device == other.device && inode == other.inode
  }
}
