import AppKit
import XCTest

/// The pointer in the top-left screen coordinates that XCUI frames use. AppKit measures it from
/// the bottom left of the primary screen.
func screenPointerLocation() -> CGPoint {
  let location = NSEvent.mouseLocation
  let height = NSScreen.screens.first?.frame.height ?? 0

  return CGPoint(x: location.x, y: height - location.y)
}

extension UnitermUITestCase {
  func pointerLocation() -> CGPoint {
    screenPointerLocation()
  }

  /// The part of `target` a person could point at: its frame clipped to `window`. It reads each
  /// frame once, and returns them for the caller's messages.
  private func visibleRect(
    of target: XCUIElement, in window: XCUIElement
  ) -> (visible: CGRect, target: CGRect, window: CGRect) {
    let targetFrame = target.frame
    let windowFrame = window.frame

    return (targetFrame.intersection(windowFrame), targetFrame, windowFrame)
  }

  /// The one way a UI test sends a wheel. A wheel goes to whatever is under the pointer when the
  /// window server delivers it, and on CI one once reached another pane's list while the pointer
  /// was still on its way. So the call settles the pointer on the target's visible part first.
  ///
  /// A pointer already inside the part, by a frame read just now, gets no hover. The wheel goes to
  /// where it stands. Otherwise the pointer hovers at the middle and a poll waits until it is
  /// inside, reading the frame again each time. A wait that never holds fails with a "wheel
  /// settle:" message and the pointer and frames. It never resends an event and never waits on the
  /// wheel's outcome.
  ///
  /// The target must lie within the window. The visible part is its frame clipped to the window
  /// only, so a table spanning its document would aim at the whole window and could settle over
  /// another pane. The call fails on such a target. Pass the enclosing scroll view instead, whose
  /// frame is the visible part. Resolving a large table through XCUI also costs seconds a query.
  ///
  /// The wheel is an `XCUICoordinate.scroll`, so XCUI picks no second point of its own, as an
  /// element's `scroll` does. The coordinates are built from the window, so none of them resolves
  /// the target again.
  ///
  /// `UNITERM_WHEEL_TRACE=1` in the runner's environment logs the pointer, the visible part, and
  /// the time each phase took. See `WheelTrace`.
  func sendWheel(
    deltaY: CGFloat, at target: XCUIElement, in window: XCUIElement,
    timeout: TimeInterval = 2, context: @autoclosure () -> String = ""
  ) {
    WheelTrace.mark("aim start")

    let (first, targetFrame, windowFrame) = visibleRect(of: target, in: window)

    WheelTrace.mark("frames read")

    guard windowFrame.insetBy(dx: -2, dy: -2).contains(targetFrame) else {
      XCTFail(
        "wheel settle: the target overruns the window, so its frame is not its visible part. "
          + "Aim at its enclosing scroll view. target \(targetFrame), window \(windowFrame). "
          + context())
      return
    }

    guard !first.isNull, !first.isEmpty else {
      XCTFail(
        "wheel settle: no visible part to aim at. target \(targetFrame), window \(windowFrame). "
          + context())
      return
    }

    func coordinate(at point: CGPoint) -> XCUICoordinate {
      window.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: point.x - windowFrame.minX, dy: point.y - windowFrame.minY))
    }

    var point = screenPointerLocation()

    if first.contains(point) {
      WheelTrace.mark("pointer already inside")
    } else {
      point = CGPoint(x: first.midX, y: first.midY)
      coordinate(at: point).hover()
      WheelTrace.mark("hovered")

      var latest = first

      let settled = pollUntil(timeout: timeout) {
        latest = visibleRect(of: target, in: window).visible

        return latest.contains(screenPointerLocation())
      }

      WheelTrace.mark("settled")

      guard settled else {
        XCTFail(
          "wheel settle: the pointer never reached the target. aimed at \(point), pointer "
            + "\(screenPointerLocation()), visible part \(latest), target \(target.frame). \(context())"
        )
        return
      }
    }

    let trace = WheelTrace.begin(deltaY: deltaY, point: point, visible: first)
    let wheelPoint = coordinate(at: point)

    wheelPoint.scroll(byDeltaX: 0, deltaY: deltaY)
    trace?.end()
  }
}

/// A local trace of what the runner sees around one wheel. It reads the pointer when the settle
/// ends, right after the wheel is sent, and after the run loop has drained. A global `NSEvent`
/// monitor also records the pointer moves and wheels the system delivers to other processes. The
/// runner's main thread sleeps while a settle polls, so the monitor's callbacks arrive late. Each
/// carries the event's own timestamp, which is what orders it against the marks.
///
/// It prints `WHEELTRACE` lines to the test log. A monitor that sees nothing does not show that
/// XCUI posted nothing, since the runner may not receive its own synthesized events.
@MainActor
final class WheelTrace {
  private static let enabled = ProcessInfo.processInfo.environment["UNITERM_WHEEL_TRACE"] == "1"
  private static var monitor: Any?
  private static var events: [(time: TimeInterval, text: String)] = []

  private let point: CGPoint
  private let started = ProcessInfo.processInfo.systemUptime

  private init(point: CGPoint) {
    self.point = point
  }

  /// Prints the time of a phase boundary, to show where a wheel's seconds go.
  static func mark(_ phase: String) {
    guard enabled else { return }

    emit("phase \(phase) at \(ProcessInfo.processInfo.systemUptime)")
  }

  static func begin(deltaY: CGFloat, point: CGPoint, visible: CGRect) -> WheelTrace? {
    guard enabled else { return nil }

    if monitor == nil {
      monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { event in
        let spot = screenPointerLocation()
        let kind = event.type == .scrollWheel ? "wheel dy=\(event.scrollingDeltaY)" : "move"

        MainActor.assumeIsolated {
          events.append((event.timestamp, "\(kind) pointer-at-callback=\(spot)"))
        }
      }
    }

    let trace = WheelTrace(point: point)

    emit(
      "settled at \(trace.started), pointer \(screenPointerLocation()), wheel aimed at \(point), "
        + "visible \(visible), dy \(deltaY)")

    return trace
  }

  func end() {
    let sent = ProcessInfo.processInfo.systemUptime

    Self.emit("wheel sent at \(sent), pointer \(screenPointerLocation())")
    Self.mark("wheel returned")
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

    let seen = Self.events.filter { $0.time >= started - 0.5 && $0.time <= sent + 0.5 }
    let between = seen.filter { $0.time >= started && $0.time <= sent }

    for event in seen.sorted(by: { $0.time < $1.time }) {
      Self.emit("event at \(event.time): \(event.text)")
    }

    Self.emit(
      "summary: \(between.count) events between settle and wheel, pointer after drain "
        + "\(screenPointerLocation()), aimed \(point)")
    Self.events.removeAll()
  }

  private static func emit(_ line: String) {
    print("WHEELTRACE \(line)")
  }
}
