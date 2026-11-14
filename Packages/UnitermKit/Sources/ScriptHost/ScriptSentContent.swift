import Darwin
import Foundation
import ScriptWire

/// Where content a script sends waits for the pane that reads it.
///
/// A script sends bytes and a name, never a path, so what a script may read stays under its own
/// sandbox. The app writes the bytes here, in a folder only the user can enter, and gives the
/// viewer the file. Each instance keeps its own folder, named for its process and the time that
/// process started, so a second instance never removes what the first still shows, and a reused
/// process ID never keeps a dead instance's folder.
///
/// The host removes a file when its pane takes another one or closes, and gives the bytes back to
/// the budget. A launch removes the folders of instances that are gone. A file for a pane that the
/// user changed, with no script involved, stays until a script next sends to that pane or the app
/// quits and relaunches.
public final class ScriptSentContent: @unchecked Sendable {
  /// The most bytes an instance holds before it refuses more.
  public static let defaultBudget = 256 * 1024 * 1024

  private let directory: URL
  private let budget: Int
  private let lock = NSLock()
  private var held = 0

  /// `~/Library/Application Support/uniterm/sent`.
  public static func defaultRoot() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

    return support.appendingPathComponent("uniterm", isDirectory: true)
      .appendingPathComponent("sent", isDirectory: true)
  }

  /// Prepares the folder, removes what instances that have ended left, and starts this instance's
  /// own folder empty. `process` is a parameter so a test stands in for another instance.
  public init(
    root: URL, process: ProcessIdentity = .current,
    budget: Int = ScriptSentContent.defaultBudget
  ) throws {
    self.budget = budget

    try ScriptSocketDirectory.prepare(root)

    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []

    for name in names {
      guard let owner = ProcessIdentity(folderName: name) else { continue }

      if owner == process || !owner.isRunning {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
      }
    }

    directory = root.appendingPathComponent(process.folderName, isDirectory: true)

    try ScriptSocketDirectory.prepare(directory)
  }

  /// A name that is one plain file name. A path, a dot file, and an empty name are the script's
  /// mistake, since the extension is the only thing in a name that means anything.
  public static func checkName(_ name: String) throws {
    let bytes = Array(name.utf8)

    guard !bytes.isEmpty else { throw ScriptCallError.badArgument("the file name is empty") }

    guard bytes.count <= ScriptProtocol.maxFileNameBytes else {
      throw ScriptCallError.badArgument("the file name is too long")
    }

    guard !bytes.contains(0), !bytes.contains(UInt8(ascii: "/")) else {
      throw ScriptCallError.badArgument("the file name must be a name, not a path")
    }

    guard bytes[0] != UInt8(ascii: ".") else {
      throw ScriptCallError.badArgument("the file name must not start with a dot")
    }
  }

  /// Writes `content` under `name` in a folder of its own and returns the file.
  public func write(_ content: Data, named name: String) throws -> URL {
    try Self.checkName(name)

    guard content.count <= ScriptProtocol.maxSendBytes else {
      throw ScriptCallError.badArgument("the content is too large")
    }

    try reserve(content.count)

    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

      let file = folder.appendingPathComponent(name)

      try Self.writeFile(content, to: file)

      return file
    } catch {
      try? FileManager.default.removeItem(at: folder)
      release(content.count)

      throw ScriptCallError.failed("the content could not be saved: \(error.localizedDescription)")
    }
  }

  /// Removes a file this store wrote, and the folder around it.
  public func discard(_ file: URL, size: Int) {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    release(size)
  }

  private func reserve(_ bytes: Int) throws {
    lock.lock()
    defer { lock.unlock() }

    guard held + bytes <= budget else {
      throw ScriptCallError.refused("uniterm holds as much sent content as it allows")
    }

    held += bytes
  }

  private func release(_ bytes: Int) {
    lock.lock()
    held -= bytes
    lock.unlock()
  }

  private static func writeFile(_ content: Data, to file: URL) throws {
    let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)

    guard descriptor >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }

    defer { close(descriptor) }

    var failure: Int32?

    content.withUnsafeBytes { raw in
      var offset = 0

      while offset < raw.count {
        let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)

        if written < 0 {
          if errno == EINTR { continue }

          failure = errno
          return
        }

        offset += written
      }
    }

    if let failure { throw POSIXError(POSIXError.Code(rawValue: failure) ?? .EIO) }
  }
}
