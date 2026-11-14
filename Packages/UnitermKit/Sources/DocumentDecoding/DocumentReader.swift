import AppKit
import Darwin
import DocumentWire
import Foundation

/// Why a descriptor could not become a document.
struct DocumentFailure: Error {
  var kind: DocumentFailureKind
  var text: String
}

/// A file mapped read-only from a descriptor the app passed. The helper checks again that it is a
/// regular file, since it trusts the app's check no more than the app trusts the helper's.
final class MappedDocument {
  let data: Data
  private let descriptor: Int32

  /// The largest file the helper maps.
  static let maxBytes = 1 << 30

  init(descriptor: Int32) throws {
    self.descriptor = descriptor

    var info = stat()

    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(descriptor)
      throw DocumentFailure(kind: .unreadable, text: "The file is not a regular file.")
    }

    let size = Int(info.st_size)

    guard size > 0 else {
      Darwin.close(descriptor)
      throw DocumentFailure(kind: .unreadable, text: "The file is empty.")
    }

    guard size <= Self.maxBytes else {
      Darwin.close(descriptor)
      throw DocumentFailure(kind: .limit, text: "The file is larger than the reader will map.")
    }

    guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), base != MAP_FAILED
    else {
      Darwin.close(descriptor)
      throw DocumentFailure(kind: .unreadable, text: "The file could not be read.")
    }

    data = Data(bytesNoCopy: base, count: size, deallocator: .unmap)
  }

  deinit {
    Darwin.close(descriptor)
  }
}

/// Reads a document with the system reader the app named and archives the sanitized result.
enum DocumentReader {
  static func documentType(for kind: DocumentKind) -> NSAttributedString.DocumentType {
    switch kind {
    case .rtf: return .rtf
    case .word97: return .docFormat
    case .wordXML: return .officeOpenXML
    }
  }

  static func read(_ file: MappedDocument, kind: DocumentKind) throws -> (
    archive: Data, images: [RawImage]
  ) {
    let source: NSAttributedString

    do {
      source = try NSAttributedString(
        data: file.data, options: [.documentType: documentType(for: kind)],
        documentAttributes: nil)
    } catch {
      throw DocumentFailure(kind: .unreadable, text: "The document could not be read.")
    }

    let sanitized = DocumentSanitizer.sanitize(source)

    let archive: Data

    do {
      archive = try NSKeyedArchiver.archivedData(
        withRootObject: sanitized.string, requiringSecureCoding: true)
    } catch {
      throw DocumentFailure(kind: .unreadable, text: "The document could not be packed.")
    }

    guard archive.count <= DocumentProtocol.maxArchiveBytes else {
      throw DocumentFailure(kind: .limit, text: "The document is larger than the reader will send.")
    }

    return (archive, sanitized.images)
  }
}
