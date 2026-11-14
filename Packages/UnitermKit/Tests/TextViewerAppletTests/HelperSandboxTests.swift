import AppKit
import DocumentTestSupport
import DocumentWire
import HelperHost
import XCTest

@testable import TextViewerApplet
@testable import TextViewerModel

/// Checks the helper against the macOS sandbox. The app cannot prove its own sandbox profile from
/// inside the agent's shell, so `make test-helper-sandbox` runs these against the helper built into
/// the app, named by `UNITERM_DOCUMENT_HELPER`. Without the variable the shipped-helper tests skip,
/// and the harness test runs against the unsandboxed package build.
///
/// The sandbox profile is the App Sandbox alone, with no file, network, or exception entitlement.
/// The readers need whatever system services the sandbox allows by default. If a reader needs a
/// service the profile denies, the decode test names the format that failed.
@MainActor
final class HelperSandboxTests: XCTestCase {
  private var shippedHelper: URL? {
    ProcessInfo.processInfo.environment["UNITERM_DOCUMENT_HELPER"].flatMap {
      $0.isEmpty ? nil : URL(fileURLWithPath: $0)
    }
  }

  private func probe(_ helper: URL, path: String) throws -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = helper
    process.arguments = ["--probe-sandbox", path]
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// Catches a probe that always says denied. Run unsandboxed, the probe opens a file by path.
  func testTheProbeReportsAFileOpenWhenNothingDeniesIt() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("probe.txt", Data("x".utf8))
    let result = try probe(DocumentFixtures.packageHelper(), path: file.path)

    XCTAssertTrue(result.output.contains("file: opened"), result.output)
    XCTAssertNotEqual(result.status, 0)
  }

  /// Catches a shipped helper that can open a file by path or make a network connection. Its
  /// entitlements hold the App Sandbox and nothing else.
  func testTheShippedHelperCannotOpenAFileByPathOrConnect() throws {
    guard let helper = shippedHelper else {
      throw XCTSkip(
        "UNITERM_DOCUMENT_HELPER names no shipped helper. Run make test-helper-sandbox.")
    }

    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: helper.path), "no helper at \(helper.path)")

    let scratch = try Scratch(self)
    let file = try scratch.write("probe.txt", Data("x".utf8))
    let result = try probe(helper, path: file.path)

    XCTAssertTrue(result.output.contains("file: denied"), result.output)
    XCTAssertTrue(result.output.contains("network: denied"), result.output)
    XCTAssertEqual(result.status, 0)
  }

  /// Catches a reader that cannot run under the helper's sandbox. RTF, Word 97, and Word XML each
  /// decode a sample through the helper, with a heading and a link, and the text comes back.
  func testEveryReaderDecodesUnderTheShippedSandbox() async throws {
    guard let helper = shippedHelper else {
      throw XCTSkip(
        "UNITERM_DOCUMENT_HELPER names no shipped helper. Run make test-helper-sandbox.")
    }

    let scratch = try Scratch(self)
    let cases: [(String, Data, DocumentKind)] = [
      ("rtf", try DocumentFixtures.rtf(body: "sandbox text", heading: "Title"), .rtf),
      ("doc", try DocumentFixtures.doc(body: "sandbox text", heading: "Title"), .word97),
      ("docx", try DocumentFixtures.docx(body: "sandbox text", heading: "Title"), .wordXML),
      ("rtf with a link", try DocumentFixtures.rtfWithLink("https://example.com"), .rtf),
      ("rtf with a table", DocumentFixtures.rtfWithTable(rows: 2, columns: 2), .rtf),
    ]

    for (name, data, kind) in cases {
      let file = try scratch.write("sample.\(name.replacingOccurrences(of: " ", with: "-"))", data)
      let opened = try OpenedDocumentFile.open(path: file.path).get()
      let job = DocumentHelperJob(
        settings: Harness.settings(location: HelperLocation(url: helper)))

      let result = await job.run(kind: kind, file: opened)

      switch result {
      case .success(let reply):
        let decoded = try await DocumentReplyDecoder.decode(reply, limits: .standard).get()

        XCTAssertGreaterThan(decoded.text.length, 0, name)

      case .failure(let end):
        XCTFail("\(name) did not decode under the sandbox: \(end)")
      }
    }
  }
}
