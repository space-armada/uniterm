import Darwin
import Foundation

/// Why a capped read stopped.
public enum FileReadError: Error, Equatable, Sendable {
  case access(SourceAccessError)

  /// The file is larger than the viewer reads. `bytes` is its size, or the count read when the
  /// file grew while it was read.
  case tooLarge(path: String, bytes: Int, limit: Int)
}

/// The one way a viewer opens a file by path and decides it holds data.
///
/// The open is non-blocking, so a named pipe never stalls the caller. The file is judged from the
/// descriptor with `fstat`, which follows symlinks, so a swap between a check and the open cannot
/// slip a pipe or a device past it. A symlink to `/dev/zero` is a device and is refused.
public enum RegularFile {
  /// What `fstat` says of a regular file.
  public struct Info: Sendable, Equatable {
    public let size: Int
    public let modified: timespec

    public static func == (lhs: Info, rhs: Info) -> Bool {
      lhs.size == rhs.size && lhs.modified.tv_sec == rhs.modified.tv_sec
        && lhs.modified.tv_nsec == rhs.modified.tv_nsec
    }
  }

  /// Opens `path` read-only. The caller owns the descriptor and closes it.
  public static func open(path: String) -> Result<
    (descriptor: Int32, info: Info), SourceAccessError
  > {
    let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)

    guard descriptor >= 0 else { return .failure(.posix(errno, path: path)) }

    return check(descriptor: descriptor, path: path).map { (descriptor, $0) }
  }

  /// Takes ownership of `descriptor`. It is kept when it is a regular file, and closed otherwise.
  public static func check(descriptor: Int32, path: String) -> Result<Info, SourceAccessError> {
    var info = stat()

    guard fstat(descriptor, &info) == 0 else {
      let code = errno
      Darwin.close(descriptor)

      return .failure(.posix(code, path: path))
    }

    guard info.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(descriptor)

      return .failure(
        .notARegularFile(path: path, kind: SourceAccessError.kind(of: info.st_mode)))
    }

    return .success(Info(size: Int(info.st_size), modified: info.st_mtimespec))
  }

  /// Opens `path` and reads it whole. A file whose size passes `limit` is refused before it is
  /// read. The bytes actually read are counted against the limit too, since a file can grow, and a
  /// size from `fstat` can be wrong.
  public static func readAll(path: String, limit: Int) -> Result<Data, FileReadError> {
    switch open(path: path) {
    case .failure(let error):
      return .failure(.access(error))

    case .success(let opened):
      defer { Darwin.close(opened.descriptor) }

      return read(descriptor: opened.descriptor, path: path, size: opened.info.size, limit: limit)
    }
  }

  /// Reads an opened regular file to its end, counting the bytes against `limit`.
  public static func read(descriptor: Int32, path: String, size: Int, limit: Int) -> Result<
    Data, FileReadError
  > {
    guard size <= limit else {
      return .failure(.tooLarge(path: path, bytes: size, limit: limit))
    }

    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 1 << 16)

    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }

      if count < 0 {
        if errno == EINTR { continue }

        return .failure(.access(.posix(errno, path: path)))
      }

      if count == 0 { break }

      data.append(contentsOf: chunk[0..<count])

      if data.count > limit {
        return .failure(.tooLarge(path: path, bytes: data.count, limit: limit))
      }
    }

    return .success(data)
  }
}
