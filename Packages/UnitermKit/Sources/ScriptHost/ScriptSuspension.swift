import Foundation
import ProcessInspection

/// What the host knows of a controller's process, for pane chrome.
public enum ControllerProcessState: Equatable, Sendable {
  /// A REPL helper that uniterm started. uniterm can suspend and resume it.
  case spawned(SuspensionState)

  /// A program started elsewhere, such as a `uniterm run` in a shell. uniterm only shows when it
  /// is stopped. The shell's own job control resumes it.
  case other(stopped: Bool)
}

extension ScriptHost {
  /// The REPL channel whose helper holds this connection, when the connection is a bound helper.
  func replChannel(forConnection id: UInt64) -> ScriptReplChannel? {
    boundRepls[id]
  }

  /// What the connection's process is doing. A REPL helper reads from its channel, which follows
  /// the process and keeps uniterm's own record. Any other peer reads from its own watch.
  public func controllerProcessState(_ id: UInt64) -> ControllerProcessState {
    if let channel = replChannel(forConnection: id) { return .spawned(channel.suspension) }

    return .other(stopped: stoppedPeers.contains(id))
  }

  /// Stops the REPL helper behind the connection. Nothing else is ever stopped from here.
  public func suspendController(_ id: UInt64) {
    replChannel(forConnection: id)?.suspend()
  }

  /// Continues the REPL helper behind the connection.
  public func resumeController(_ id: UInt64) {
    replChannel(forConnection: id)?.resume()
  }
}
