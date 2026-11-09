import Darwin
import Foundation
import ScriptWire

/// The helper's watchdog thread. It owns every read from the connection to the app, so the app
/// always hears from the helper, however busy the VM thread is.
///
/// The VM thread may be in a loop, in a long call into C that no interrupt reaches, or waiting for
/// a reply. None of that stops this thread. It does four jobs:
///
/// - It hands each reply to the VM thread through the session's mailbox.
/// - It answers each ping with a pong, so the app can tell a busy helper from a hung one.
/// - It carries out the app's stop request by signalling the VM thread, which takes the same gated
///   path as Ctrl-C.
/// - When the app closes the connection, it says why and ends the process, since nothing else in
///   the helper can run while the VM thread is stuck.
final class ScriptWatchdog: @unchecked Sendable {
  /// What the watchdog does when the app's end of the connection closes. It must not return. The
  /// default says why and ends the process.
  typealias Hangup = @Sendable () -> Never

  private let session: ScriptSession
  private let hangup: Hangup
  private let stop: @Sendable () -> Void
  private let lock = NSLock()
  private var finished = false

  /// Starts the thread. It reads from `session` until the connection ends. `onStop` runs on the
  /// thread for each stop request, and `onHangup` runs when the app closes its end.
  static func start(
    reading session: ScriptSession, onStop: @escaping @Sendable () -> Void = {},
    onHangup: @escaping Hangup
  ) -> ScriptWatchdog {
    let watchdog = ScriptWatchdog(session: session, hangup: onHangup, stop: onStop)
    let thread = Thread { watchdog.run() }

    session.beginDispatching()

    thread.name = "uniterm.script.watchdog"
    thread.stackSize = 256 * 1024
    thread.start()

    return watchdog
  }

  private init(
    session: ScriptSession, hangup: @escaping Hangup, stop: @escaping @Sendable () -> Void
  ) {
    self.session = session
    self.hangup = hangup
    self.stop = stop
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
    defer { session.dispatcherDidEnd() }

    while true {
      do {
        switch try session.readForDispatcher() {
        case .ping(let nonce):
          try? session.sendPong(nonce)

        case .stop:
          stop()

        case .reply(let id, let result):
          guard session.deliver(.reply(id: id, result: result)) else {
            ScriptSession.endHelper("the app sent a reply nobody asked for", flushingOutput: false)
          }

        case .hello, .attachRefused, .history:
          ScriptSession.endHelper(
            "the app sent a message the helper does not expect now", flushingOutput: false)
        }
      } catch WireError.closed {
        guard !isFinished else { return }

        hangup()
      } catch {
        guard !isFinished else { return }

        ScriptSession.endHelper(
          "the connection to uniterm failed: \(error)", flushingOutput: false)
      }
    }
  }
}
