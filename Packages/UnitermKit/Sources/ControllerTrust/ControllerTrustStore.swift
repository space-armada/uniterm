import AtomicFile
import ControllerPackage
import Darwin
import Foundation

/// What a read of the policy file found.
public struct ControllerTrustState: Sendable, Equatable {
  /// The policies that may cover a run. Empty when the file is missing, unusable, or newer.
  public let policies: [ControllerPolicy]

  /// False when this version must not write the file: it is newer, or cannot be reached. Trust
  /// this version and Trust this identity are then not offered.
  public let writable: Bool

  /// Why the file grants nothing, for the user. Nil when it was read.
  public let notice: String?

  public init(policies: [ControllerPolicy], writable: Bool, notice: String?) {
    self.policies = policies
    self.writable = writable
    self.notice = notice
  }
}

public enum ControllerTrustStoreError: Error, Equatable, Sendable, CustomStringConvertible {
  case readOnly(String)
  case io(String)

  public var description: String {
    switch self {
    case .readOnly(let text), .io(let text): return text
    }
  }
}

/// The controller policy file, `policy.json`, in a folder only the user can read. A script file's
/// approvals live in a policy file of their own, `files.json`, in the same folder. It has its own
/// lock, its own kept-aside copies, its own temporary files, and its own record limit, and neither
/// store reads, counts, or sweeps the other's names. An older build never reads `files.json`, so
/// its controller approvals keep working.
///
/// It holds remembered approvals and nothing else: no key, no connection, no pane. Layout files
/// hold none of it. Every read and every change takes an exclusive lock on the folder's lock file,
/// so two running instances never lose each other's change, and each change rereads the file
/// first. Writes go through the shared atomic writer.
///
/// A file this version cannot read grants nothing. It is moved aside, numbered, before anything is
/// written, so a later write never replaces it and it stays for recovery. A file written in an
/// earlier format is moved aside the same way, with a notice that each approval is given again. A
/// file from a newer version, by its format or by a permission this build does not know, is left
/// where it is, untouched, and this version neither trusts nor writes it.
///
/// Calls block on the lock and the disk, so they belong off the main actor.
public struct ControllerTrustStore: Sendable {
  public let directory: URL

  /// Which approvals the store holds, and so which files it names.
  public let artifact: ControllerArtifact

  /// How many kept-aside files stay. The oldest go first.
  public static let keepAsideLimit = 5

  public init(directory: URL, artifact: ControllerArtifact = .package) {
    self.directory = directory
    self.artifact = artifact
  }

  /// The start of every name the store owns: `policy` for packages and `files` for script files.
  private var baseName: String {
    switch artifact {
    case .package: return "policy"
    case .file: return "files"
    }
  }

  private var subject: String {
    switch artifact {
    case .package: return "controller"
    case .file: return "script file"
    }
  }

  /// `~/Library/Application Support/uniterm/controllers`.
  public static func defaultDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

    return support.appendingPathComponent("uniterm", isDirectory: true)
      .appendingPathComponent("controllers", isDirectory: true)
  }

  public var fileURL: URL { directory.appendingPathComponent("\(baseName).json") }
  private var lockURL: URL { directory.appendingPathComponent("\(baseName).lock") }

  /// The kept-aside files, oldest first.
  public var keptAsideFiles: [URL] { asideEntries().map(\.url) }

  public func read() -> ControllerTrustState {
    do {
      return try locked { try load().state }
    } catch {
      return ControllerTrustState(
        policies: [], writable: false,
        notice: "uniterm cannot read its \(subject) policies, so it remembers no trust: \(error)")
    }
  }

  /// Replaces the policies with what `change` makes of them, and returns the result. The file is
  /// read again under the lock first, so a change another instance made is kept.
  @discardableResult
  public func update(
    _ change: @Sendable ([ControllerPolicy]) -> [ControllerPolicy]
  ) throws(ControllerTrustStoreError) -> [ControllerPolicy] {
    do {
      return try locked {
        let loaded = try load()

        guard loaded.state.writable else {
          throw ControllerTrustStoreError.readOnly(
            loaded.state.notice ?? "uniterm cannot write its \(subject) policies")
        }

        let policies = change(loaded.state.policies)

        guard policies.count <= ControllerPolicyFile.maxPolicies else {
          throw ControllerTrustStoreError.io(
            "uniterm remembers at most \(ControllerPolicyFile.maxPolicies) \(subject) approvals. "
              + "Revoke some in Controllers & Permissions first.")
        }

        let encoded = ControllerPolicyFile.encode(policies)

        // The reader refuses a larger file as broken and moves it aside, which would end every
        // remembered approval. Policies under the count cap can still pass the limit.
        guard encoded.count <= ControllerPolicyFile.maxBytes else {
          throw ControllerTrustStoreError.io(
            "uniterm's \(subject) approvals would not fit in its policy file. "
              + "Revoke some in Controllers & Permissions first.")
        }

        do {
          try AtomicFile.write(encoded, to: fileURL)
        } catch {
          throw ControllerTrustStoreError.io("\(error)")
        }

        return policies
      }
    } catch let error as ControllerTrustStoreError {
      throw error
    } catch {
      throw .io("\(error)")
    }
  }

  // MARK: Reading

  private struct Loaded {
    var state: ControllerTrustState
  }

  /// Reads the file under the lock. An unreadable file is moved aside here.
  private func load() throws -> Loaded {
    let data: Data

    do {
      data = try readBounded()
    } catch CocoaError.fileReadNoSuchFile {
      return Loaded(state: ControllerTrustState(policies: [], writable: true, notice: nil))
    }

    do {
      return Loaded(
        state: ControllerTrustState(
          policies: try ControllerPolicyFile.decode(data, artifact: artifact), writable: true,
          notice: nil))
    } catch .newer(let what) {
      return Loaded(
        state: ControllerTrustState(
          policies: [], writable: false,
          notice:
            "A newer uniterm wrote the \(subject) policy file, with \(what), so this one "
            + "remembers no trust and saves none. The file is left as it is."))
    } catch .older {
      let kept = try moveAside()

      return Loaded(
        state: ControllerTrustState(
          policies: [], writable: true,
          notice:
            "An earlier uniterm wrote the \(subject) policy file, in a format that cannot say what "
            + "each approval covered. Every \(subject) is approved again once, and the next "
            + "approval is saved. The old file was kept as \(kept.lastPathComponent)."))
    } catch {
      let kept = try moveAside()

      return Loaded(
        state: ControllerTrustState(
          policies: [], writable: true,
          notice:
            "The \(subject) policy file could not be used (\(error)), so it grants nothing. It "
            + "was kept as \(kept.lastPathComponent)."))
    }
  }

  /// Reads at most one byte past the format's bound, so a huge file is refused without reading
  /// it all. Only a regular file is read. The open never waits, so a FIFO or a device in the
  /// file's place cannot hold the lock that every other read needs.
  private func readBounded() throws -> Data {
    let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)

    guard descriptor >= 0 else {
      if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }

      throw ControllerTrustStoreError.io(
        "cannot open \(fileURL.path): \(String(cString: strerror(errno)))")
    }

    defer { close(descriptor) }

    var info = stat()

    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw ControllerTrustStoreError.io("\(fileURL.path) is not a regular file")
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    while data.count <= ControllerPolicyFile.maxBytes {
      let count = Darwin.read(descriptor, &buffer, buffer.count)

      if count < 0, errno == EINTR { continue }

      guard count >= 0 else {
        throw ControllerTrustStoreError.io(
          "cannot read \(fileURL.path): \(String(cString: strerror(errno)))")
      }

      if count == 0 { break }

      data.append(contentsOf: buffer[0..<count])
    }

    return data
  }

  // MARK: Kept-aside files

  private var asidePrefix: String { "\(baseName).aside-" }
  private static let asideSuffix = ".json"

  private func asideEntries() -> [(index: Int, url: URL)] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

    return names.compactMap { name in
      guard name.hasPrefix(asidePrefix), name.hasSuffix(Self.asideSuffix) else { return nil }

      let digits = name.dropFirst(asidePrefix.count).dropLast(Self.asideSuffix.count)

      guard let index = Int(digits) else { return nil }

      return (index, directory.appendingPathComponent(name))
    }.sorted { $0.index < $1.index }
  }

  private func moveAside() throws -> URL {
    let next = (asideEntries().last?.index ?? 0) + 1
    let target = directory.appendingPathComponent("\(asidePrefix)\(next)\(Self.asideSuffix)")

    guard rename(fileURL.path, target.path) == 0 else {
      throw ControllerTrustStoreError.io(
        "cannot keep \(fileURL.path) aside: \(String(cString: strerror(errno)))")
    }

    AtomicFile.syncDirectory(directory)

    let entries = asideEntries()

    for entry in entries.prefix(max(0, entries.count - Self.keepAsideLimit)) {
      try? FileManager.default.removeItem(at: entry.url)
    }

    return target
  }

  // MARK: Lock

  /// Runs `body` while holding the folder's lock. The folder is made private first.
  private func locked<T>(_ body: () throws -> T) throws -> T {
    try prepareDirectory()

    let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)

    guard descriptor >= 0 else {
      throw ControllerTrustStoreError.io(
        "cannot open \(lockURL.path): \(String(cString: strerror(errno)))")
    }

    defer { close(descriptor) }

    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else {
        throw ControllerTrustStoreError.io(
          "cannot lock \(lockURL.path): \(String(cString: strerror(errno)))")
      }
    }

    defer { flock(descriptor, LOCK_UN) }

    removeStaleTempFiles()

    return try body()
  }

  private func prepareDirectory() throws {
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw ControllerTrustStoreError.io("cannot make \(directory.path): \(error)")
    }

    // A link in the folder's place would make its target private and keep the policies there.
    var info = stat()

    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw ControllerTrustStoreError.io("\(directory.path) is not a folder")
    }

    guard chmod(directory.path, 0o700) == 0 else {
      throw ControllerTrustStoreError.io(
        "cannot make \(directory.path) private: \(String(cString: strerror(errno)))")
    }
  }

  /// A temp file left by a write that crashed. Only the lock's holder writes, so any temp file
  /// seen under the lock is a leftover.
  private func removeStaleTempFiles() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

    for name in names where name.hasPrefix("\(baseName).json" + AtomicFile.tempMarker) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }
}
