import Darwin
import Foundation
import SourceAccess

/// A regular file opened read-only. It owns the descriptor, which the helper receives.
public final class OpenedImageFile: @unchecked Sendable {
  public let descriptor: Int32
  public let path: String
  public let modified: Double
  public let size: Int

  fileprivate init(descriptor: Int32, path: String, modified: Double, size: Int) {
    self.descriptor = descriptor
    self.path = path
    self.modified = modified
    self.size = size
  }

  deinit {
    Darwin.close(descriptor)
  }

  public var name: String { (path as NSString).lastPathComponent }
}

/// A folder opened by descriptor. Listing it and opening its files go through that descriptor, so
/// replacing the path afterwards changes neither.
public final class OpenedFolder: @unchecked Sendable {
  public let path: String
  private let descriptor: Int32

  fileprivate init(descriptor: Int32, path: String) {
    self.descriptor = descriptor
    self.path = path
  }

  deinit {
    Darwin.close(descriptor)
  }

  /// The images of the folder in `sort` order. Hidden files and subfolders are left out, and a
  /// file is an image when `types` says its name is one.
  public func list(supporting types: SupportedImageTypes, sort: ImageSort) -> Result<
    [ListedImage], SourceAccessError
  > {
    var images: [ListedImage] = []

    let result = scan(
      supporting: types, batchSize: 256, isCancelled: { false },
      deliver: { images.append(contentsOf: $0) })

    return result.map { FolderListing.sorted(images, by: sort) }
  }

  /// Reads the folder and hands the images over in batches of up to `batchSize`, in the order the
  /// disk gives them. A scan of a large folder reports as it goes, so the caller can show an image
  /// before the scan ends. It stops early when `isCancelled` says so.
  public func scan(
    supporting types: SupportedImageTypes, batchSize: Int, isCancelled: () -> Bool,
    deliver: ([ListedImage]) -> Void
  ) -> Result<Void, SourceAccessError> {
    let copy = dup(descriptor)

    guard copy >= 0, let stream = fdopendir(copy) else {
      let code = errno

      if copy >= 0 { Darwin.close(copy) }

      return .failure(.posix(code, path: path))
    }

    defer { closedir(stream) }

    rewinddir(stream)

    var batch: [ListedImage] = []

    var failure: Int32 = 0

    while true {
      errno = 0

      guard let entry = readdir(stream) else {
        failure = errno
        break
      }

      if isCancelled() { return .success(()) }

      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }

      guard !name.hasPrefix("."), types.supports(fileName: name) else { continue }

      var info = stat()

      guard fstatat(descriptor, name, &info, 0) == 0, info.st_mode & S_IFMT == S_IFREG else {
        continue
      }

      batch.append(ListedImage(name: name, modified: Self.seconds(info.st_mtimespec)))

      if batch.count >= batchSize {
        deliver(batch)
        batch = []
      }
    }

    if !batch.isEmpty { deliver(batch) }

    return failure == 0 ? .success(()) : .failure(.posix(failure, path: path))
  }

  /// Opens the file named `name` in this folder. A name with a slash is refused.
  public func openFile(named name: String) -> Result<OpenedImageFile, SourceAccessError> {
    let full = (path as NSString).appendingPathComponent(name)

    guard !name.contains("/"), !name.isEmpty else { return .failure(.missing(path: full)) }

    let file = openat(descriptor, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC)

    guard file >= 0 else { return .failure(.posix(errno, path: full)) }

    return SourceOpener.regularFile(descriptor: file, path: full)
  }

  static func seconds(_ time: timespec) -> Double {
    Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
  }
}

public enum OpenedSource: Sendable {
  case file(OpenedImageFile)
  case folder(OpenedFolder)
}

/// Opens what the user named. It runs off the main thread.
public enum SourceOpener {
  /// Opens `path` read-only and non-blocking, so a named pipe never blocks the caller, then
  /// decides what it is from the descriptor. The path is never checked first, so a swap between a
  /// check and the open cannot slip a pipe or a device past the check.
  public static func open(path: String) -> Result<OpenedSource, SourceAccessError> {
    let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)

    guard descriptor >= 0 else { return .failure(.posix(errno, path: path)) }

    var info = stat()

    guard fstat(descriptor, &info) == 0 else {
      let code = errno
      Darwin.close(descriptor)

      return .failure(.posix(code, path: path))
    }

    if info.st_mode & S_IFMT == S_IFDIR {
      return .success(.folder(OpenedFolder(descriptor: descriptor, path: path)))
    }

    return regularFile(descriptor: descriptor, path: path).map { .file($0) }
  }

  /// Takes ownership of `descriptor`. It is kept when it is a regular file, and closed otherwise.
  public static func regularFile(descriptor: Int32, path: String) -> Result<
    OpenedImageFile, SourceAccessError
  > {
    switch RegularFile.check(descriptor: descriptor, path: path) {
    case .failure(let error):
      return .failure(error)

    case .success(let info):
      return .success(
        OpenedImageFile(
          descriptor: descriptor, path: path, modified: OpenedFolder.seconds(info.modified),
          size: info.size))
    }
  }
}
