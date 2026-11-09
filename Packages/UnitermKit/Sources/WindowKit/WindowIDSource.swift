import AppletKit
import Foundation

/// Hands out the IDs that scripts use to name windows.
///
/// An ID is a random epoch drawn once per launch, in the high bits, and a counter that only grows,
/// in the low 16. The whole ID is below 2^53, so a Janet number holds it exactly. The ID never
/// reads the clock, so a clock that moves backwards between launches cannot repeat one. Nothing is
/// saved, and a restored window gets a new ID.
///
/// When the counter runs out, the source draws a new epoch that no earlier epoch of this launch
/// used. Tests inject the draw to stand in for a second launch.
public struct WindowIDSource {
  static let epochBits = 37
  static let counterBits = 16

  private static let epochMask: UInt64 = (1 << UInt64(epochBits)) - 1
  private static let counterLimit: UInt64 = (1 << UInt64(counterBits)) - 1

  private let draw: () -> UInt64
  private var epoch: UInt64
  private var counter: UInt64 = 0

  /// Every epoch this launch used. Zero is never an epoch, so no ID is a bare counter.
  private var used: Set<UInt64> = [0]

  public init(draw: @escaping () -> UInt64 = { .random(in: 1...((1 << 37) - 1)) }) {
    self.draw = draw
    epoch = 0
    epoch = fresh()
  }

  /// The next ID of this launch. No two calls return the same one.
  mutating func next() -> UInt64 {
    if counter >= Self.counterLimit {
      epoch = fresh()
      counter = 0
    }

    counter += 1

    return epoch << UInt64(Self.counterBits) | counter
  }

  /// An epoch this launch has not used. A source that keeps drawing a used one is probed from its
  /// last draw instead, so the search ends.
  private mutating func fresh() -> UInt64 {
    var candidate = draw() & Self.epochMask

    for _ in 0..<8 where used.contains(candidate) {
      candidate = draw() & Self.epochMask
    }

    while used.contains(candidate) {
      candidate = (candidate + 1) & Self.epochMask
    }

    used.insert(candidate)

    return candidate
  }
}

/// Maps the tabs of one window to the small integers scripts name them by.
///
/// An applet's tab ID has 128 bits, which a Janet number cannot hold. A tab gets its number the
/// first time a script sees it. Numbers only grow and an entry is never reused, so a number that
/// names a closed tab names nothing, never another tab.
struct ScriptTabNumbers {
  private var numbers: [AppletTabID: UInt64] = [:]
  private var tabs: [UInt64: AppletTabID] = [:]
  private var last: UInt64 = 0

  mutating func number(for tab: AppletTabID) -> UInt64 {
    if let known = numbers[tab] { return known }

    last += 1
    numbers[tab] = last
    tabs[last] = tab

    return last
  }

  func tab(for number: UInt64) -> AppletTabID? {
    tabs[number]
  }
}
