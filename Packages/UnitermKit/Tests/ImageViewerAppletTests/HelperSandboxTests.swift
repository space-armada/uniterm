import Foundation
import HelperHost
import ImageIO
import ImageTestSupport
import ImageViewerModel
import ImageWire
import UniformTypeIdentifiers
import XCTest

@testable import ImageViewerApplet

/// Checks the helper against the macOS sandbox. The app cannot prove its own sandbox profile from
/// inside the agent's shell, so `make test-helper-sandbox` runs these against the helper built into
/// the app, named by `UNITERM_IMAGE_HELPER`. Without the variable they run against the unsandboxed
/// package build, which proves the harness and nothing about the profile.
@MainActor
final class HelperSandboxTests: XCTestCase {
  private var folder: URL!

  override func setUp() async throws {
    folder = try ImageFixtures.makeFolder()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private var shippedHelper: URL? {
    ProcessInfo.processInfo.environment["UNITERM_IMAGE_HELPER"].flatMap {
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

  /// Catches a probe that always says denied. Run unsandboxed, the probe opens a file by path, so a
  /// probe that reports denied for the shipped helper is reporting something real. The network line
  /// is not asserted here, since the agent's own sandbox denies connections either way.
  func testTheProbeReportsAFileOpenWhenNothingDeniesIt() throws {
    let file = try ImageFixtures.write(Data("x".utf8), named: "probe.txt", in: folder)
    let result = try probe(ImageFixtures.packageHelper(), path: file.path)

    XCTAssertTrue(result.output.contains("file: opened"), result.output)
    XCTAssertNotEqual(result.status, 0)
  }

  /// Catches a shipped helper that can open a file by path or make a network connection. Its
  /// entitlements hold the App Sandbox and nothing else, so both must be denied and the probe must
  /// exit zero. Run by `make test-helper-sandbox` against the helper in the built app.
  func testTheShippedHelperCannotOpenAFileByPathOrConnect() throws {
    guard let helper = shippedHelper else {
      throw XCTSkip("UNITERM_IMAGE_HELPER names no shipped helper. Run make test-helper-sandbox.")
    }

    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: helper.path), "no helper at \(helper.path)")

    let file = try ImageFixtures.write(Data("x".utf8), named: "probe.txt", in: folder)
    let result = try probe(helper, path: file.path)

    XCTAssertTrue(result.output.contains("file: denied"), result.output)
    XCTAssertTrue(result.output.contains("network: denied"), result.output)
    XCTAssertEqual(result.status, 0)
  }

  /// Catches a type the helper reports but cannot decode under its sandbox, with no message that
  /// names the format. A sample of every type with an encoder goes through the helper, and each
  /// either decodes or fails with a message that names its format. Types with no encoder are
  /// printed, since the test cannot sample them.
  func testEverySampleableReportedTypeDecodesOrNamesItsFormat() async throws {
    let helper = shippedHelper ?? ImageFixtures.packageHelper()
    let client = ImageHelperClient(
      settings: Harness.settings(location: HelperLocation(url: helper)),
      budget: ImageHelperBudget(limit: 8 << 30, floor: 1 << 30))
    let log = EventLog(client)
    defer { client.shutdown() }

    let seed = try openedFile(ImageFixtures.png(), named: "seed.png", in: folder)
    client.open(seed)
    await expectEventually("no hello from \(helper.path)") { client.types != nil }

    let reported = SupportedImageTypes.imageIdentifiers(from: client.types ?? [])
    let encodable = Set(
      (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    var unsampled: [String] = []
    var failures: [String] = []

    for identifier in reported {
      guard encodable.contains(identifier), let type = UTType(identifier) else {
        unsampled.append(identifier)
        continue
      }

      let picture = ImageFixtures.quadrants(width: 32, height: 32)
      let data = NSMutableData()

      guard
        let destination = CGImageDestinationCreateWithData(data, identifier as CFString, 1, nil)
      else {
        unsampled.append(identifier)
        continue
      }

      CGImageDestinationAddImage(destination, picture, nil)

      guard CGImageDestinationFinalize(destination), data.length > 0 else {
        unsampled.append(identifier)
        continue
      }

      let before = log.events.count
      let ext = type.preferredFilenameExtension ?? "img"
      let file = try openedFile(data as Data, named: "sample.\(ext)", in: folder)

      client.open(file)
      await expectEventually("\(identifier) never opened") {
        log.events.dropFirst(before).contains {
          switch $0 {
          case .opened, .failed, .ended: return true
          default: return false
          }
        }
      }

      if log.events.dropFirst(before).contains(where: {
        if case .opened = $0 { return true } else { return false }
      }) {
        client.decode(maxPixel: 0, frame: 0, kind: .still)
        await expectEventually("\(identifier) never decoded") {
          log.events.dropFirst(before).contains {
            switch $0 {
            case .image, .failed, .ended: return true
            default: return false
            }
          }
        }
      }

      let outcome = log.events.dropFirst(before)

      if outcome.contains(where: { if case .image = $0 { return true } else { return false } }) {
        continue
      }

      let name = type.localizedDescription ?? identifier
      let message =
        outcome.compactMap { event -> String? in
          if case .failed(_, _, let text) = event { return text }
          if case .ended(let end, _) = event { return "\(end)" }
          return nil
        }.first ?? "no reply"

      if !message.contains(name) && !message.localizedCaseInsensitiveContains(ext) {
        failures.append("\(identifier): \(message)")
      }

      if client.isRunning == false {
        client.open(seed)
        await expectEventually("the helper never restarted") { client.isRunning }
      }
    }

    print("image helper \(helper.path)")
    print("types with no encoder, not sampled: \(unsampled.sorted().joined(separator: ", "))")
    print("types sampled: \(reported.count - unsampled.count) of \(reported.count)")

    XCTAssertEqual(failures, [], "types that fail without naming their format")
  }
}
