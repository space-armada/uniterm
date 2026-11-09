import Darwin
import Foundation
import ScriptWire

/// The socket files in the app's per-user folder: binding one, holding the well-known address, and
/// removing what a crashed instance left.
enum ScriptSocketFiles {
  /// Binds and listens at `path`, replacing a file already there. The caller must know the file is
  /// stale, since this process owns the path.
  static func bindListening(path: String) throws -> Int32 {
    let length = path.utf8.count

    guard length <= UnixSocket.maxPathBytes else {
      throw ScriptListenerError.pathTooLong(path, length)
    }

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)

    guard descriptor >= 0 else { throw ScriptListenerError.socket(path, errno) }

    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    unlink(path)

    do {
      try UnixSocket.withAddress(path: path) { address, size in
        guard bind(descriptor, address, size) == 0 else {
          throw ScriptListenerError.socket(path, errno)
        }
      }

      guard chmod(path, 0o600) == 0 else { throw ScriptListenerError.socket(path, errno) }
      guard listen(descriptor, 16) == 0 else { throw ScriptListenerError.socket(path, errno) }
    } catch {
      Darwin.close(descriptor)
      unlink(path)

      throw error
    }

    return descriptor
  }

  /// The well-known address, held for as long as this value lives.
  ///
  /// The lock file's lock is what makes the address mean something. A process that holds the lock
  /// is the live owner. When the lock is free, any socket file at the address belongs to a process
  /// that is gone, so it is replaced. A later instance never gets the lock while the owner lives,
  /// so it never touches the address.
  struct WellKnown {
    let path: String
    let descriptor: Int32
    let lock: Int32

    /// Takes the lock and binds the address. Returns nil when another instance holds the lock. The
    /// lock descriptor is close-on-exec, so a program the app starts never inherits the lock.
    static func claim(directory: URL) throws -> WellKnown? {
      let lockPath = directory.appendingPathComponent(ScriptAddress.lockName).path
      let path = directory.appendingPathComponent(ScriptAddress.wellKnownName).path
      let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)

      guard lock >= 0 else { throw ScriptListenerError.directory(lockPath, errno) }

      var info = stat()

      guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid()
      else {
        Darwin.close(lock)

        throw ScriptListenerError.directory(lockPath, EPERM)
      }

      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        let code = errno

        Darwin.close(lock)

        if code == EWOULDBLOCK { return nil }

        throw ScriptListenerError.directory(lockPath, code)
      }

      do {
        return WellKnown(path: path, descriptor: try bindListening(path: path), lock: lock)
      } catch {
        Darwin.close(lock)

        throw error
      }
    }

    /// Removes the address while the lock is still held, then lets go of the lock. The order means
    /// a new owner can never have its own address removed by this one.
    func release() {
      unlink(path)
      Darwin.close(lock)
    }
  }

  /// True when a socket file named for `pid` cannot be that process's. The process is gone, or it
  /// started after the file was made.
  static func isStale(pid: pid_t, birth: Int, startTime: (pid_t) -> Int?) -> Bool {
    guard let started = startTime(pid) else { return true }

    return birth < started
  }

  /// Removes the `<pid>.sock` files that earlier instances left behind. A file of this process, of
  /// a running process that made it, or that is not a socket of this user, stays.
  ///
  /// The file name carries only the process ID, so the process's start time decides whether a
  /// reused ID is the file's own owner. A file made before the process started is not its.
  @discardableResult
  static func removeStaleSockets(
    in directory: URL, current: pid_t = getpid(),
    startTime: (pid_t) -> Int? = ProcessIdentity.startTime(of:)
  ) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return []
    }

    var removed: [String] = []

    for name in names {
      let stem = String(name.dropLast(5))

      guard name.hasSuffix(".sock"), let pid = pid_t(stem), String(pid) == stem, pid != current
      else { continue }

      let path = directory.appendingPathComponent(name).path
      var info = stat()

      guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid()
      else { continue }

      let birth = Int(info.st_birthtimespec.tv_sec)

      if isStale(pid: pid, birth: birth, startTime: startTime) {
        unlink(path)
        removed.append(name)
      }
    }

    return removed
  }
}
