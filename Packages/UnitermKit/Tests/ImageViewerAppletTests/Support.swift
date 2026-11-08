import AppKit
import AppletTestSupport
import Foundation
import HelperHost
import ImageTestSupport
import ImageViewerModel
import ImageWire
import XCTest

@testable import ImageViewerApplet

/// Settings that point a client at the unsandboxed helper SwiftPM builds beside the tests. The
/// times are short so a limit is reached in a fraction of a second. The helper is a real process,
/// so a wait for its events polls, since nothing else says when another process has answered.
@MainActor
enum Harness {
  static func settings(
    location: HelperLocation? = nil, timeBound: Duration = .seconds(10),
    footprintCap: Int = ImageHelperPolicy.perHelperCap, maxImageBytes: Int = 512 << 20
  ) -> HelperSettings {
    HelperSettings(
      location: location ?? HelperLocation(url: ImageFixtures.packageHelper()),
      timeBound: timeBound, probeInterval: .milliseconds(40), pongGrace: .milliseconds(500),
      footprintCap: footprintCap, maxImageBytes: maxImageBytes)
  }

  /// Polls until `condition` holds or `seconds` pass. Returns whether it held.
  static func eventually(
    seconds: Double = 20, _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while ContinuousClock.now < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }

  /// A script that stands in for a helper. It writes `frame` to the socket and then waits.
  static func scriptHelper(writing octal: String) throws -> HelperLocation {
    let path = NSTemporaryDirectory() + "uniterm-fake-helper-\(UUID().uuidString)"
    let script = "#!/bin/sh\nprintf '\(octal)' >&3\nexec /bin/sleep 30\n"

    try script.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)

    return HelperLocation(url: URL(fileURLWithPath: path))
  }
}

/// Collects a client's events in order.
@MainActor
final class EventLog {
  private(set) var events: [HelperEvent] = []

  init(_ client: ImageHelperClient) {
    client.onEvent = { [weak self] in self?.events.append($0) }
  }

  func first<T>(_ match: (HelperEvent) -> T?) -> T? {
    for event in events {
      if let found = match(event) { return found }
    }

    return nil
  }

  var ended: HelperEnd? {
    first { if case .ended(let end, _) = $0 { return end } else { return nil } }
  }

  var opened: SourceInfo? {
    first { if case .opened(let info) = $0 { return info } else { return nil } }
  }

  var images: [ImageHeader] {
    events.compactMap {
      if case .image(_, let header, _) = $0 { return header } else { return nil }
    }
  }
}

/// A scratch folder and a file opened from it, for a test that talks to a client directly.
@MainActor
func openedFile(_ data: Data, named name: String = "a.png", in folder: URL) throws
  -> OpenedImageFile
{
  let url = try ImageFixtures.write(data, named: name, in: folder)

  guard case .success(.file(let file)) = SourceOpener.open(path: url.path) else {
    throw XCTSkip("the fixture did not open")
  }

  return file
}

/// Waits for `condition` and fails the test with `message` when it never holds.
@MainActor
func expectEventually(
  _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
  _ condition: @MainActor () -> Bool
) async {
  let held = await Harness.eventually(condition)

  XCTAssertTrue(held, message, file: file, line: line)
}

/// A slideshow clock that waits until a test calls `tick`. The slideshow's own sleep suspends here,
/// so a test advances time by hand and never waits in real time.
@MainActor
final class ManualSleeper {
  private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

  /// The durations the slideshow asked to wait, oldest first.
  private(set) var requested: [Duration] = []

  var waitingCount: Int { waiters.count }

  func sleep(_ duration: Duration) async throws {
    requested.append(duration)

    let id = UUID()

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          waiter.resume(throwing: CancellationError())
          return
        }

        waiters[id] = waiter
      }
    } onCancel: {
      Task { @MainActor in
        self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
      }
    }
  }

  /// Ends every wait in progress, as five seconds passing would.
  func tick() {
    let ready = waiters

    waiters = [:]

    for waiter in ready.values { waiter.resume() }
  }
}

/// Builds panes for the tests that step through folders. It keeps them so each one is closed.
@MainActor
final class PaneFactory {
  let folder: URL
  private(set) var applets: [ImageViewerApplet] = []

  init(folder: URL) {
    self.folder = folder
  }

  func closeAll() {
    for applet in applets { applet.close() }
  }

  func make(
    settings: HelperSettings? = nil, scanPace: ScanPace = ScanPace(),
    sleeper: ManualSleeper? = nil, startDirectory: String? = nil,
    helperBudget: ImageHelperBudget = ImageHelperBudget(limit: 8 << 30, floor: 1 << 30),
    bitmapBudget: ImageBitmapBudget = ImageBitmapBudget(limit: 1 << 30, floor: 256 << 20)
  ) -> (ImageViewerApplet, RecordingHost) {
    let applet = ImageViewerApplet(
      startDirectory: startDirectory ?? folder.path, settings: settings ?? Harness.settings(),
      helperBudget: helperBudget, bitmapBudget: bitmapBudget, scanPace: scanPace,
      slideshowSleep: Self.sleep(sleeper))

    return prepare(applet)
  }

  func restored(
    _ record: ImageViewerDescription, scanPace: ScanPace = ScanPace(),
    sleeper: ManualSleeper? = nil
  ) throws -> (ImageViewerApplet, RecordingHost) {
    let applet = try ImageViewerApplet(
      restoring: record.appletDescription(), settings: Harness.settings(),
      helperBudget: ImageHelperBudget(limit: 8 << 30, floor: 1 << 30),
      bitmapBudget: ImageBitmapBudget(limit: 1 << 30, floor: 256 << 20), scanPace: scanPace,
      slideshowSleep: Self.sleep(sleeper))

    return prepare(applet)
  }

  private static func sleep(_ sleeper: ManualSleeper?) -> SlideshowSleep {
    guard let sleeper else { return ImageViewerApplet.realSleep }

    return { try await sleeper.sleep($0) }
  }

  private func prepare(_ applet: ImageViewerApplet) -> (ImageViewerApplet, RecordingHost) {
    let host = RecordingHost()

    applet.host = host
    applet.view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
    applet.view.layoutSubtreeIfNeeded()
    applets.append(applet)

    return (applet, host)
  }
}

/// Holds an async operation until a test lets it go.
actor OpenGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }

    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    isOpen = true

    for waiter in waiters { waiter.resume() }

    waiters = []
  }
}
