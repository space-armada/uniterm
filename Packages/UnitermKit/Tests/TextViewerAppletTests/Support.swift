import AppKit
import AppletKit
import AppletTestSupport
import BrowserApplet
import Darwin
import DocumentTestSupport
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

  static func applet(
    startDirectory: String? = nil, settings: DocumentHelperSettings = settings(),
    opener: RecordingOpener = RecordingOpener()
  ) -> TextViewerApplet {
    TextViewerApplet(startDirectory: startDirectory, settings: settings, opener: opener)
  }

  static func restored(
    _ description: TextViewerDescription, settings: DocumentHelperSettings = settings(),
    opener: RecordingOpener = RecordingOpener()
  ) throws -> TextViewerApplet {
    try TextViewerApplet(
      restoring: description.appletDescription(), settings: settings, opener: opener)
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
      case .pdf, .text: return true
      case .message(let text, _): return text != "Opening\u{2026}"
      }
    }
  }

  static func message(_ applet: TextViewerApplet) -> String? {
    if case .message(let text, _) = applet.content.body { return text }

    return nil
  }

  static func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
  }
}
