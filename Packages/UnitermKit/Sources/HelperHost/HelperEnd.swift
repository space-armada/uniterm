import Foundation

/// Why a helper stopped. A pane words each one, and only some offer a retry.
public enum HelperEnd: Equatable, Sendable {
  /// The process died or exited. A retry may work, since the cause was one file or one fault.
  case crashed(String)

  /// The process stopped answering pings, so it hung. A retry may work.
  case unresponsive

  /// The work ran past the time bound while the helper still answered. That is a limit, so a
  /// retry would repeat it.
  case overranTimeBound

  /// The helper's footprint passed the per-helper cap. That is a limit.
  case overFootprint

  /// The helper sent bytes the app refused.
  case misbehaved(String)

  case versionMismatch

  /// The helper could not be started.
  case unavailable(String)

  /// True when trying again is likely to behave differently.
  public var offersRetry: Bool {
    switch self {
    case .crashed, .unresponsive, .misbehaved: return true
    case .overranTimeBound, .overFootprint, .versionMismatch, .unavailable: return false
    }
  }
}
