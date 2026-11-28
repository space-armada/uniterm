import HelperWire
import ScriptHost
import ScriptWire

/// What the window tests share to drive a real scripting host from a raw peer in the test process.
enum ScriptPeer {
  /// Connects to the host and completes the hello exchange. The caller sends the next message,
  /// such as a begin or an attach, and closes the socket.
  static func hello(to address: String) async throws -> FramedSocket {
    let peer = try UnixSocket.connect(path: address)

    try peer.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())
    _ = try await Task.detached {
      try peer.readFrame(limit: ScriptAppMessage.bodyLimit(type:))
    }.value

    return peer
  }

  /// Waits for something the host does on its own turn, such as a binding that lands after a
  /// message. It polls in real time for up to four seconds and returns either way, so the caller's
  /// assertion reports a miss.
  @MainActor
  static func settle(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}
