import Foundation
import ScriptWire

/// One helper's connection to the app, after its hello was accepted.
///
/// The main actor holds a connection to answer its calls. It never blocks on the peer. A reply is
/// queued for the connection's own writer, and the writer may block on a peer that does not read.
/// The queue is bounded by messages and by bytes. A peer that lets it fill is disconnected, so a
/// peer that never reads cannot grow the app's memory.
public final class ScriptConnection: @unchecked Sendable, Identifiable {
  /// How many calls one connection may have waiting for an answer. The reader stops reading until
  /// one is answered, so a peer that floods calls cannot grow the app's queue.
  static let maxInFlight = 8

  /// The most replies that may wait for the writer. A helper runs one call at a time, so a well
  /// behaved one never has more than one waiting.
  static let maxQueuedMessages = 64

  /// The most bytes that may wait for the writer. It holds sixteen of the largest replies.
  static let maxQueuedBytes = 1 << 20

  public let id: UInt64
  public let peer: ScriptPeer

  let socket: FramedSocket
  let slots = DispatchSemaphore(value: maxInFlight)

  private let writer: DispatchQueue
  private let lock = NSLock()
  private let onOverflow: @Sendable (ScriptConnection) -> Void
  private var closed = false
  private var queuedMessages = 0
  private var queuedBytes = 0

  init(
    id: UInt64, peer: ScriptPeer, socket: FramedSocket,
    onOverflow: @escaping @Sendable (ScriptConnection) -> Void = { _ in }
  ) {
    self.id = id
    self.peer = peer
    self.socket = socket
    self.onOverflow = onOverflow
    self.writer = DispatchQueue(label: "uniterm.script.writer.\(id)")
  }

  /// What waits for the writer now, for the tests.
  var queued: (messages: Int, bytes: Int) {
    lock.lock()
    defer { lock.unlock() }

    return (queuedMessages, queuedBytes)
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

  /// Queues a message for the peer. A message that would pass either bound ends the connection
  /// instead, since the peer has stopped reading. Nothing waits in the queue after that.
  func send(_ message: ScriptAppMessage) {
    let frame = message.frame()

    lock.lock()

    guard !closed else {
      lock.unlock()

      return
    }

    guard queuedMessages < Self.maxQueuedMessages,
      queuedBytes + frame.count <= Self.maxQueuedBytes
    else {
      lock.unlock()

      close()
      onOverflow(self)

      return
    }

    queuedMessages += 1
    queuedBytes += frame.count
    lock.unlock()

    writer.async { [self] in
      defer {
        lock.lock()
        queuedMessages -= 1
        queuedBytes -= frame.count
        lock.unlock()
      }

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
