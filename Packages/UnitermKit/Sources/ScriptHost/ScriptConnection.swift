import Foundation
import ScriptWire

/// One helper's connection to the app, after its hello was accepted.
///
/// The main actor holds a connection to answer its calls. It never blocks on the peer. A reply is
/// queued for the connection's own writer, and the writer may block on a peer that does not read.
public final class ScriptConnection: @unchecked Sendable, Identifiable {
  /// How many calls one connection may have waiting for an answer. The reader stops reading until
  /// one is answered, so a peer that floods calls cannot grow the app's queue.
  static let maxInFlight = 8

  public let id: UInt64
  public let peer: ScriptPeer

  let socket: FramedSocket
  let slots = DispatchSemaphore(value: maxInFlight)

  private let writer: DispatchQueue
  private let lock = NSLock()
  private var closed = false

  init(id: UInt64, peer: ScriptPeer, socket: FramedSocket) {
    self.id = id
    self.peer = peer
    self.socket = socket
    self.writer = DispatchQueue(label: "uniterm.script.writer.\(id)")
  }

  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }

    return closed
  }

  /// Answers a call. Safe from any thread, and never blocks the caller.
  public func reply(id: UInt32, result: ScriptResult) {
    slots.signal()
    send(.reply(id: id, result: result))
  }

  /// Queues a message for the peer. The queue is unbounded for now, and holds one small reply for
  /// each call the peer has waiting, at most `maxInFlight`.
  func send(_ message: ScriptAppMessage) {
    let frame = message.frame()

    writer.async { [self] in
      guard !isClosed else { return }

      do {
        try socket.send(frame)
      } catch {
        close()
      }
    }
  }

  /// Ends the connection for both sides. Safe to call twice.
  public func close() {
    lock.lock()

    let wasOpen = !closed

    closed = true
    lock.unlock()

    guard wasOpen else { return }

    socket.shutdownAndClose()

    for _ in 0..<Self.maxInFlight {
      slots.signal()
    }
  }
}
