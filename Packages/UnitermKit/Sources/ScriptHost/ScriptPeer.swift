import Darwin
import FileRouting
import Foundation
import ScriptWire

/// Who is on the other end of a connection, as the kernel reports it. The peer cannot change any
/// of it. A later caller identity can build on this record, so it is kept whole.
public struct ScriptPeer: Sendable, Equatable {
  public let uid: uid_t
  public let pid: pid_t

  /// Nil when the kernel gave no audit token.
  public let token: AuditToken?

  public init(uid: uid_t, pid: pid_t, token: AuditToken?) {
    self.uid = uid
    self.pid = pid
    self.token = token
  }

  /// Reads the credentials of the process that connected `descriptor`.
  static func read(descriptor: Int32) throws -> ScriptPeer {
    var credentials = xucred()
    var credentialsSize = socklen_t(MemoryLayout<xucred>.size)

    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsSize) == 0,
      credentials.cr_version == XUCRED_VERSION
    else { throw ScriptListenerError.peer(errno) }

    var pid: pid_t = 0
    var pidSize = socklen_t(MemoryLayout<pid_t>.size)

    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0 else {
      throw ScriptListenerError.peer(errno)
    }

    var token = [UInt8](repeating: 0, count: AuditToken.byteCount)
    var tokenSize = socklen_t(token.count)

    let tokenRead = token.withUnsafeMutableBytes {
      getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, $0.baseAddress, &tokenSize) == 0
    }

    return ScriptPeer(
      uid: credentials.cr_uid, pid: pid,
      token: tokenRead && tokenSize == socklen_t(token.count) ? AuditToken(data: Data(token)) : nil)
  }
}

public enum ScriptListenerError: Error, Equatable, CustomStringConvertible {
  case directory(String, Int32)
  case socket(String, Int32)
  case pathTooLong(String, Int)
  case peer(Int32)

  public var description: String {
    switch self {
    case .directory(let path, let code):
      return "the script folder \(path) is not usable: \(String(cString: strerror(code)))"

    case .socket(let path, let code):
      return "the script socket \(path) did not start: \(String(cString: strerror(code)))"

    case .pathTooLong(let path, let count):
      return
        "the script socket path \(path) is \(count) bytes, and the most is "
        + "\(UnixSocket.maxPathBytes)"

    case .peer(let code):
      return "a peer's credentials could not be read: \(String(cString: strerror(code)))"
    }
  }
}
