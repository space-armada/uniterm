import Darwin
import Foundation

/// The helper's watchdog thread. It watches the connection to the app while the VM thread runs a
/// script, so a script stuck in a loop still ends when the app goes away.
///
/// The thread never reads the socket. Its kqueue only reports that the descriptor changed, and the
/// VM thread alone consumes frames. When the app closes its end, the thread says why and ends the
/// process, since nothing else in the helper can run while the script holds the VM.
///
/// Ctrl-C and the app's stop request belong to this thread too. Each is one more event source on
/// the same queue, handled in `run`.
final class ScriptWatchdog: @unchecked Sendable {
  /// What the watchdog does when the app's end of the connection closes. It must not return. The
  /// default says why and ends the process.
  typealias Hangup = @Sendable () -> Never

  private let queue: Int32
  private let descriptor: Int32
  private let hangup: Hangup
  private let lock = NSLock()
  private var finished = false

  /// Starts the thread, or returns nil when the system gives no kqueue or refuses the watch. A
  /// helper without a watchdog still runs, and still ends when it next reads the connection.
  static func start(watching descriptor: Int32, onHangup: @escaping Hangup) -> ScriptWatchdog? {
    let queue = kqueue()

    guard queue >= 0 else { return nil }

    _ = fcntl(queue, F_SETFD, FD_CLOEXEC)

    // EV_CLEAR makes the event edge-triggered. A reply the VM thread has not read yet then does
    // not wake the thread again and again.
    var change = kevent(
      ident: UInt(descriptor), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR),
      fflags: 0, data: 0, udata: nil)

    guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
      Darwin.close(queue)

      return nil
    }

    let watchdog = ScriptWatchdog(queue: queue, descriptor: descriptor, hangup: onHangup)
    let thread = Thread { watchdog.run() }

    thread.name = "uniterm.script.watchdog"
    thread.stackSize = 256 * 1024
    thread.start()

    return watchdog
  }

  private init(queue: Int32, descriptor: Int32, hangup: @escaping Hangup) {
    self.queue = queue
    self.descriptor = descriptor
    self.hangup = hangup
  }

  /// Says that the script is over and the helper is closing the connection itself, so the watchdog
  /// does not report that as the app quitting.
  func finish() {
    lock.lock()
    finished = true
    lock.unlock()
  }

  private var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }

    return finished
  }

  private func run() {
    var events = Array(repeating: kevent(), count: 4)

    while true {
      let count = kevent(queue, nil, 0, &events, Int32(events.count), nil)

      if count < 0 {
        if errno == EINTR { continue }

        return
      }

      for event in events.prefix(Int(count)) where event.ident == UInt(descriptor) {
        guard event.flags & UInt16(EV_EOF) != 0, !isFinished else { continue }

        hangup()
      }
    }
  }
}
