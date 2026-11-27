import AtomicFile
import ControllerPackage
import Darwin
import Foundation

/// What a read of the policy file found.
public struct ControllerTrustState: Sendable, Equatable {
  /// The policies that may cover a run. Empty when the file is missing, unusable, or newer.
  public let policies: [ControllerPolicy]

  /// False when this version must not write the file: it is newer or over the bound, or cannot be
  /// reached. Trust this version and Trust this identity are then not offered.
  public let writable: Bool

  /// Why the file grants nothing, for the user. Nil when it was read.
  public let notice: String?

  /// How many entries the file holds that this build cannot read. They grant nothing here, and a
  /// save writes each one back as it was.
  public let unreadable: Int

  public init(
    policies: [ControllerPolicy], writable: Bool, notice: String?, unreadable: Int = 0
  ) {
    self.policies = policies
    self.writable = writable
    self.notice = notice
    self.unreadable = unreadable
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

/// What a change did to the store: the readable policies before it and after it.
public struct ControllerTrustChange: Sendable, Equatable {
  public let before: [ControllerPolicy]
  public let after: [ControllerPolicy]

  /// The selectors the change took out, in the order they were listed.
  public var removedSelectors: [ControllerSelector] {
    let kept = Set(after.map(\.selector))
    var seen = Set<ControllerSelector>()

    return before.map(\.selector).filter { !kept.contains($0) && seen.insert($0).inserted }
  }
}

/// The controller policy file, `policy.json`, in a folder only the user can read. It holds every
/// remembered approval, whatever it is an approval of: a package, a script file, and the kinds
/// later builds add. Each entry names its artifact kind.
///
/// It holds remembered approvals and nothing else: no key, no connection, no pane. Layout files
/// hold none of it. Every read and every change takes an exclusive lock on the folder's lock file,
/// so two running instances never lose each other's change, and each change rereads the file
/// first. Writes go through the shared atomic writer.
///
/// An entry this build cannot read is kept. It grants nothing, and every save writes it back byte
/// for byte, so a newer build finds it again and a build that does read it sees what the other
/// wrote. A file this version cannot tell entries in, such as one that is not JSON, grants nothing
/// and is moved aside, numbered, before anything is written, so a later write never replaces it.
/// A file from a newer format, or over the format's bound, is left where it is, untouched, and
/// this version neither trusts nor writes it.
///
/// The stores of earlier builds are retired. A `policy.json` in an earlier format, and every file
/// of an earlier store such as `files.json`, with its lock and kept-aside copies, are moved into
/// the `retired` folder. An empty file in this format is written at once. Retiring never prunes an
/// earlier retired copy, and never counts toward the kept-aside copies of `policy.json`. Each
/// approval is given again once, and the notice says so the first time only.
///
/// Calls block on the lock and the disk, so they belong off the main actor.
public struct ControllerTrustStore: Sendable {
  public let directory: URL

  /// The permission editions this build knows. A test stands in for a build of another age.
  public let editions: ControllerPermissionEditions

  /// How many kept-aside files stay. The oldest go first.
  public static let keepAsideLimit = 5

  /// The earlier stores that sit beside `policy.json`, by the start of each store's file names.
  /// `files` held script-file approvals.
  public static let retiredStores = ["files"]

  private let retiring: [String]

  public init(
    directory: URL, editions: ControllerPermissionEditions = .current,
    retiring: [String] = ControllerTrustStore.retiredStores
  ) {
    self.directory = directory
    self.editions = editions
    self.retiring = retiring
  }

  private var baseName: String { "policy" }

  /// `~/Library/Application Support/uniterm/controllers`.
  public static func defaultDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

    return support.appendingPathComponent("uniterm", isDirectory: true)
      .appendingPathComponent("controllers", isDirectory: true)
  }

  public var fileURL: URL { directory.appendingPathComponent("\(baseName).json") }
  private var lockURL: URL { directory.appendingPathComponent("\(baseName).lock") }

  /// Where the files of earlier stores go.
  public var retiredDirectory: URL {
    directory.appendingPathComponent("retired", isDirectory: true)
  }

  /// The kept-aside files, oldest first.
  public var keptAsideFiles: [URL] { asideEntries().map(\.url) }

  public func read() -> ControllerTrustState {
    do {
      return try locked { try load(announce: true).state }
    } catch {
      return ControllerTrustState(
        policies: [], writable: false,
        notice: "uniterm cannot read its controller policies, so it remembers no trust: \(error)")
    }
  }

  /// Replaces the policies with what `change` makes of them, and returns what it did. The file is
  /// read again under the lock first, so a change another instance made is kept. Every entry this
  /// build cannot read is written back unchanged.
  @discardableResult
  public func update(
    _ change: @Sendable ([ControllerPolicy]) -> [ControllerPolicy]
  ) throws(ControllerTrustStoreError) -> ControllerTrustChange {
    do {
      return try locked {
        let loaded = try load(announce: false)

        guard loaded.state.writable else {
          throw ControllerTrustStoreError.readOnly(
            loaded.state.notice ?? "uniterm cannot write its controller policies")
        }

        let policies = change(loaded.state.policies)
        let encoded = ControllerPolicyFile.encode(
          policies, kept: loaded.document.kept, members: loaded.document.members)

        // The reader refuses a larger file, which would end every remembered approval. The size
        // counts the kept entries too. No count of approvals comes near it, so a file this large
        // looks damaged.
        guard encoded.count <= ControllerPolicyFile.maxBytes else {
          throw ControllerTrustStoreError.io(
            "uniterm did not save the approval. \(fileURL.path) would pass "
              + "\(ControllerPolicyFile.maxBytes) bytes, which real approvals never reach, so the "
              + "file looks damaged. It was left as it is.")
        }

        do {
          try AtomicFile.write(encoded, to: fileURL)
        } catch {
          throw ControllerTrustStoreError.io("\(error)")
        }

        return ControllerTrustChange(before: loaded.state.policies, after: policies)
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
    var document = ControllerPolicyDocument()
  }

  /// Reads the file under the lock. An unreadable file is moved aside here, and so is an earlier
  /// store. A caller that returns the state's notice to the user passes `announce`. Only then is
  /// the reapproval notice marked as shown, so a change that drops the state leaves it for a read.
  private func load(announce: Bool) throws -> Loaded {
    let retired = try retireEarlierStores()
    let data: Data

    do {
      data = try readBounded()
    } catch CocoaError.fileReadNoSuchFile {
      return try fresh(retiredAny: retired, announce: announce)
    }

    do {
      let document = try ControllerPolicyFile.read(data, editions: editions)
      let notice =
        retired || hasRetiredFiles ? reapprovalNotice(announce: announce) : nil

      return Loaded(
        state: ControllerTrustState(
          policies: document.policies, writable: true, notice: notice,
          unreadable: document.kept.count),
        document: document)
    } catch .newer(let what) {
      return Loaded(
        state: ControllerTrustState(
          policies: [], writable: false,
          notice:
            "A newer uniterm wrote the controller policy file, with \(what), so this one "
            + "remembers no trust and saves none. The file is left as it is."))
    } catch .tooLarge {
      return Loaded(
        state: ControllerTrustState(
          policies: [], writable: false,
          notice:
            "The controller policy file is over \(ControllerPolicyFile.maxBytes) bytes, which "
            + "real approvals never reach, so it looks damaged. It grants nothing, and it is left "
            + "as it is at \(fileURL.path)."))
    } catch .older(let format) {
      let kept = try retire(fileURL.lastPathComponent)

      return try fresh(
        retiredAny: true, announce: announce,
        extra:
          "The old file, format \(format), was kept as retired/\(kept.lastPathComponent).")
    } catch {
      let kept = try moveAside()

      return Loaded(
        state: ControllerTrustState(
          policies: [], writable: true,
          notice:
            "The controller policy file could not be used (\(error)), so it grants nothing. It "
            + "was kept as \(kept.lastPathComponent)."))
    }
  }

  /// An empty file in this format, written at once when an earlier store was retired, so no build
  /// keeps retiring another's file.
  private func fresh(retiredAny: Bool, announce: Bool, extra: String? = nil) throws -> Loaded {
    guard retiredAny else {
      return Loaded(state: ControllerTrustState(policies: [], writable: true, notice: nil))
    }

    do {
      try AtomicFile.write(ControllerPolicyFile.encode([]), to: fileURL)
    } catch {
      throw ControllerTrustStoreError.io("\(error)")
    }

    let notice = [reapprovalNotice(announce: announce), extra].compactMap { $0 }.joined(
      separator: " ")

    return Loaded(
      state: ControllerTrustState(
        policies: [], writable: true, notice: notice.isEmpty ? nil : notice))
  }

  /// Whether an earlier store was retired by a load that did not announce it. The notice is owed
  /// until the marker says it was shown.
  private var hasRetiredFiles: Bool {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: retiredDirectory.path)) ?? []

    return names.contains { $0 != ".notified" }
  }

  /// The notice that every approval is given again once. It shows the first time an earlier store
  /// is retired. An older build that writes its file again does not bring it back.
  private func reapprovalNotice(announce: Bool) -> String? {
    let marker = retiredDirectory.appendingPathComponent(".notified")

    guard !FileManager.default.fileExists(atPath: marker.path) else { return nil }

    if announce { try? Data().write(to: marker) }

    return "An earlier uniterm wrote its controller and script file approvals in a format that "
      + "cannot say what each one covered. Every controller and script file is approved again "
      + "once, and the next approval is saved."
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

  // MARK: Retired stores

  /// Moves the files of every earlier store into the retired folder. Returns whether any moved.
  /// Nothing in the folder is ever removed or replaced, so a later retiring never prunes an earlier
  /// one, and the kept-aside copies of `policy.json` stay out of it.
  private func retireEarlierStores() throws -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    var moved = false

    for name in names.sorted() where retiring.contains(where: { name.hasPrefix($0 + ".") }) {
      _ = try retire(name)
      moved = true
    }

    return moved
  }

  /// Moves one file of this folder into the retired folder under a name that is not yet taken, and
  /// returns where it went.
  private func retire(_ name: String) throws -> URL {
    do {
      try FileManager.default.createDirectory(
        at: retiredDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw ControllerTrustStoreError.io("cannot make \(retiredDirectory.path): \(error)")
    }

    var target = retiredDirectory.appendingPathComponent(name)
    var number = 1
    var info = stat()

    while lstat(target.path, &info) == 0 {
      number += 1
      target = retiredDirectory.appendingPathComponent("\(name).\(number)")
    }

    let source = directory.appendingPathComponent(name)

    guard rename(source.path, target.path) == 0 else {
      throw ControllerTrustStoreError.io(
        "cannot retire \(source.path): \(String(cString: strerror(errno)))")
    }

    AtomicFile.syncDirectory(directory)

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
