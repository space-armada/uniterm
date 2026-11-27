import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a file could not be turned into an image source.
struct SourceFailure: Error {
  var kind: Failure
  var text: String

  enum Failure {
    case unsupported
    case unreadable
    case limit
  }
}

/// A file mapped read-only from a descriptor the app passed. The helper re-checks that the
/// descriptor is a regular file, since it cannot trust the app's check any more than the app
/// trusts the helper.
final class FileMapping {
  let data: Data
  private let descriptor: Int32

  /// The largest file the helper maps.
  static let maxBytes = 1 << 30

  init(descriptor: Int32) throws {
    self.descriptor = descriptor

    var info = stat()

    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(descriptor)
      throw SourceFailure(kind: .unreadable, text: "The file is not a regular file.")
    }

    let size = Int(info.st_size)

    guard size > 0 else {
      Darwin.close(descriptor)
      throw SourceFailure(kind: .unreadable, text: "The file is empty.")
    }

    guard size <= Self.maxBytes else {
      Darwin.close(descriptor)
      throw SourceFailure(kind: .limit, text: "The file is larger than the decoder will map.")
    }

    guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), base != MAP_FAILED
    else {
      Darwin.close(descriptor)
      throw SourceFailure(kind: .unreadable, text: "The file could not be read.")
    }

    data = Data(bytesNoCopy: base, count: size, deallocator: .unmap)
  }

  deinit {
    Darwin.close(descriptor)
  }
}

extension UTType {
  /// What a message calls the format, with no noun. A message adds its own, as "This PNG image".
  /// The localized description is not used, since it often ends in the same noun.
  var formatName: String {
    preferredFilenameExtension?.uppercased() ?? identifier
  }
}
