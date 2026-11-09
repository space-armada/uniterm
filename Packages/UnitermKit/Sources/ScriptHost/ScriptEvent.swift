import Foundation
import ScriptWire

/// Why the listener turned a peer away.
public enum ScriptRefusal: Sendable, Equatable {
  /// The peer runs as another user.
  case otherUser(uid: uid_t)

  /// The peer's protocol version is not this app's. The user is told to relaunch uniterm.
  case versionMismatch(found: UInt16)

  /// The peer sent bytes the protocol does not allow, or none in time.
  case protocolViolation(String)

  /// The app already serves as many peers as it allows.
  case tooManyConnections

  /// The peer stopped reading replies, so the app ended the connection.
  case peerNotReading

  /// What the user is told.
  public var text: String {
    switch self {
    case .otherUser(let uid):
      return "A program run by another user (\(uid)) tried to script uniterm."
    case .versionMismatch: return ScriptProtocol.mismatchText
    case .protocolViolation(let detail): return "A script connection broke the protocol: \(detail)"
    case .tooManyConnections: return "Too many scripts are connected to uniterm."
    case .peerNotReading: return "A script stopped reading uniterm's replies and was disconnected."
    }
  }
}

/// What the listener hands to the main actor, in order. Every event is already decoded and
/// checked.
public enum ScriptEvent: Sendable {
  case begun(ScriptConnection, name: String)
  case request(ScriptConnection, id: UInt32, call: ScriptCall)
  case closed(ScriptConnection)
  case refused(ScriptPeer?, ScriptRefusal)
}
