import AppKit
import AppletKit
import AppletTestSupport
import BrowserApplet
import Darwin
import DocumentTestSupport
import FileWatching
import HelperHost
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

final class Scratch {
  let url: URL

  init(_ test: XCTestCase) throws {
    url = try DocumentFixtures.makeFolder().resolvingSymlinksInPath()

    let folder = url
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
  }

  @discardableResult
  func write(_ name: String, _ data: Data) throws -> URL {
    try DocumentFixtures.write(data, named: name, in: url)
  }
}

/// Records the links a pane opens, and opens nothing.
@MainActor
final class RecordingOpener: URLOpening {
  private(set) var opened: [URL] = []

  func applicationName(toOpen url: URL) -> String? { "Test" }

  func open(_ url: URL) -> Bool {
    opened.append(url)

    return true
  }
}

@MainActor
enum Harness {
  /// Settings that point a pane at the unsandboxed helper SwiftPM builds beside the tests. The
  /// times are short so a limit is reached in a fraction of a second.
  static func settings(
    location: HelperLocation? = nil, limits: TextViewerLimits = .standard
  ) -> DocumentHelperSettings {
    DocumentHelperSettings(
      location: location ?? HelperLocation(url: DocumentFixtures.packageHelper()),
      limits: limits, probeInterval: .milliseconds(40), pongGrace: .milliseconds(500))
  }

  /// A watch that never fires inside a test and never looks for a missing path, so a pane that a
  /// test leaves open cannot reload or poll after its folder is deleted. A test that needs the
  /// watch asks for `fastWatch`.
  static let silentWatch = WatchPolicy(
    settle: 600, ceiling: 600, watchesFolder: true, retryLimit: nil, retryInterval: 600)

  /// A watch whose windows are a fraction of a second.
  static let fastWatch = WatchPolicy(
    settle: 0.05, ceiling: 0.4, watchesFolder: true, retryLimit: nil, retryInterval: 0.05)

  static func applet(
    startDirectory: String? = nil, settings: DocumentHelperSettings = settings(),
    opener: RecordingOpener = RecordingOpener(), watching: WatchPolicy = silentWatch
  ) -> TextViewerApplet {
    let applet = TextViewerApplet(
      startDirectory: startDirectory, settings: settings, opener: opener)

    applet.watchPolicy = watching

    return applet
  }

  static func restored(
    _ description: TextViewerDescription, settings: DocumentHelperSettings = settings(),
    opener: RecordingOpener = RecordingOpener(), watching: WatchPolicy = silentWatch
  ) throws -> TextViewerApplet {
    let applet = try TextViewerApplet(
      restoring: description.appletDescription(), settings: settings, opener: opener)

    applet.watchPolicy = watching

    return applet
  }

  /// Polls until `condition` holds or `seconds` pass. The helper is a real process, so a wait for
  /// its reply polls, since nothing else says when another process has answered.
  static func eventually(seconds: Double = 20, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while ContinuousClock.now < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }

  static func settled(_ applet: TextViewerApplet) async -> Bool {
    await eventually {
      switch applet.content.body {
      case .pdf, .text, .markdown: return true
      case .message(let text, _, _): return text != "Opening\u{2026}"
      }
    }
  }

  static func message(_ applet: TextViewerApplet) -> String? {
    if case .message(let text, _, _) = applet.content.body { return text }

    return nil
  }

  static func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
  }
}
