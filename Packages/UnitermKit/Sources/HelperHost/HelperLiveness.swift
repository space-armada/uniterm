import Foundation

/// The rules that tell a hung helper from a slow one, a busy one from an idle one, and one past
/// its footprint cap from one within it. It holds no clock and no process, so the caller feeds it
/// the time and the footprint and acts on the verdict.
///
/// A helper that stops answering pings is hung and offers a retry. One that answers past the time
/// bound is working on something too large, which is a limit and offers none.
public struct HelperLiveness: Sendable {
  public var timeBound: Duration
  public var pongGrace: Duration
  public var footprintCap: Int

  private var busySince: ContinuousClock.Instant?
  private var nonce: UInt32 = 0
  private var pingOutstanding: (nonce: UInt32, since: ContinuousClock.Instant)?
  private var lastPong: ContinuousClock.Instant?

  public init(timeBound: Duration, pongGrace: Duration, footprintCap: Int) {
    self.timeBound = timeBound
    self.pongGrace = pongGrace
    self.footprintCap = footprintCap
  }

  public enum Verdict: Equatable, Sendable {
    case healthy
    case sendPing(UInt32)
    case end(HelperEnd)
  }

  public var isBusy: Bool { busySince != nil }

  /// Work began. The pings and pongs of earlier work are forgotten.
  public mutating func markBusy(now: ContinuousClock.Instant = .now) {
    busySince = now
    pingOutstanding = nil
    lastPong = nil
  }

  public mutating func markIdle() {
    busySince = nil
    pingOutstanding = nil
  }

  /// The helper answered a ping. A pong for any other nonce is ignored.
  public mutating func pong(_ value: UInt32, now: ContinuousClock.Instant = .now) {
    guard pingOutstanding?.nonce == value else { return }

    pingOutstanding = nil
    lastPong = now
  }

  /// One look at a busy helper. `footprint` is nil when it cannot be read.
  public mutating func probe(footprint: Int?, now: ContinuousClock.Instant = .now) -> Verdict {
    guard let busySince else { return .healthy }

    if let footprint, footprint > footprintCap { return .end(.overFootprint) }

    if let outstanding = pingOutstanding, now - outstanding.since > pongGrace {
      return .end(.unresponsive)
    }

    if now - busySince > timeBound, let ponged = lastPong, ponged > busySince,
      now - ponged < pongGrace
    {
      return .end(.overranTimeBound)
    }

    guard pingOutstanding == nil else { return .healthy }

    nonce &+= 1
    pingOutstanding = (nonce, now)

    return .sendPing(nonce)
  }
}
