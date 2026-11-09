import Darwin
import Foundation

/// The Unix-domain socket address both sides use. An address is a filesystem path, and `sun_path`
/// holds 104 bytes on macOS.
public enum UnixSocket {
  /// The longest path that fits, with its terminator.
  public static let maxPathBytes = 103

  /// Calls `body` with the address for `path`. Throws when the path does not fit.
  public static func withAddress<Result>(
    path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
  ) throws -> Result {
    let bytes = Array(path.utf8)

    guard bytes.count <= maxPathBytes else {
      throw WireError.badValue(
        "the socket path is \(bytes.count) bytes, and the most is \(maxPathBytes)")
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.enumerated() {
        buffer[index] = byte
      }
    }

    let length = socklen_t(MemoryLayout<sockaddr_un>.size)

    return try withUnsafePointer(to: &address) { pointer in
      try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        try body(generic, length)
      }
    }
  }

  /// Connects to the listener at `path`. The socket is close-on-exec and never raises SIGPIPE.
  public static func connect(path: String) throws -> FramedSocket {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)

    guard descriptor >= 0 else { throw WireError.io(errno) }

    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

    do {
      try withAddress(path: path) { address, length in
        guard Darwin.connect(descriptor, address, length) == 0 else {
          throw WireError.io(errno)
        }
      }
    } catch {
      Darwin.close(descriptor)
      throw error
    }

    return FramedSocket(descriptor: descriptor)
  }
}
