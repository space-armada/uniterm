import Darwin
import Foundation
import QuestionForm
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// A form asked from the REPL, which the user stops with Ctrl-C. The REPL's helper holds the
/// definitions, so the stop must discard the form and keep them. They cannot prove the REPL pane.
@MainActor
final class ScriptAskReplTests: XCTestCase {
  private var directory: URL!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    windows = FakeWindowAPI()

    let center = StatusCenter()

    host = ScriptHost(
      listener: try ScriptListener.startWithoutCommandIdentityForTests(directory: directory),
      issueProducer: { center.requestProducer(kind: .script, name: $0) }, windows: windows,
      reaper: .inert)
    host.start()

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  /// Catches a stop that leaves the form open, which would make the REPL's next ask busy, or one
  /// that loses the REPL's definitions. Ctrl-C during a wait discards the form and returns to the
  /// prompt with the definitions intact, and the next ask opens.
  func testCtrlCDuringAnAskDiscardsTheFormAndKeepsTheDefinitions() async throws {
    let channel = openTestRepl(host: host, history: [])
    let events = ReplEvents(channel)
    let repl = try ReplProcess(
      address: channel.launch.address,
      environment: [ScriptProtocol.replTokenVariable: channel.launch.token])

    expect(await waitUntil { events.attachedProcess != nil })

    repl.write("(def kept 41)\n")
    repl.write("(uniterm/ask-text \"Name?\")\n")

    expect(await waitUntil { self.windows.askedForms.count == 1 }, repl.standardError)

    let key = try XCTUnwrap(windows.askedForms.first?.requester.key)

    repl.sendInterrupt()

    expect(await waitUntil { !self.windows.hasOpenForm(requester: key) }, "the form stayed open")
    expect(await waitUntil { self.host.forms.isEmpty }, "the handle stayed")

    repl.write("(+ kept 1)\n")

    expect(await repl.waitForOutput("42\n"), repl.standardOutput + repl.standardError)

    repl.write("(uniterm/ask-text \"Again?\")\n")

    expect(
      await waitUntil { self.windows.askedForms.count == 2 },
      "the next ask was refused: \(repl.standardError)")

    channel.end()
  }
}
