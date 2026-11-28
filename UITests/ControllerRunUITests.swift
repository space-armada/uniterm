import CryptoKit
import XCTest

/// Runs a controller package in the real app: the bundled command, from the first pane's terminal,
/// asks the app to admit the package, then runs its Janet entry from the app's verified snapshot.
///
/// What only the real app shows is the bundle's own command passing the app's code check, which a
/// package test can only stand in for with a copy it signs itself. The package tests prove the
/// loader, the snapshot, and the refusals one by one.
@MainActor
final class ControllerRunUITests: UnitermUITestCase {
  /// Catches a bundled command the app does not recognize as its own, and a package changed after
  /// its descriptor was written that runs anyway.
  func testTheBundledCommandRunsAVerifiedPackageAndNotAChangedOne() throws {
    let command = try bundledCommand()
    let package = scratch + "-package"
    let main = Data("(import ./lib/words)\n(print (words/greeting))\n".utf8)
    let words = Data("(defn greeting [] \"controller ran\")\n".utf8)

    try FileManager.default.createDirectory(
      atPath: package + "/lib", withIntermediateDirectories: true)
    try main.write(to: URL(fileURLWithPath: package + "/main.janet"))
    try words.write(to: URL(fileURLWithPath: package + "/lib/words.janet"))
    try write(
      """
      {
        "format": 0,
        "id": "dev.uniterm.uitest.controller",
        "name": "UI Test Controller",
        "entry": {"kind": "janet", "path": "main.janet"},
        "files": {
          "lib/words.janet": "sha256:\(Self.digest(words))",
          "main.janet": "sha256:\(Self.digest(main))"
        },
        "permissions": []
      }

      """, to: package + "/controller.json")

    let app = launchApp()

    _ = waitForTerminal(in: app)

    let shell = scratch + "-controller.sh"
    let output = scratch + "-controller.out"
    let errors = scratch + "-controller.err"
    let status = scratch + "-controller.status"

    try write(
      """
      attempts=0
      while [ $attempts -lt 100 ]; do
        "\(command)" run --socket "\(testSocket)" "\(package)" > "\(output)" 2> "\(errors)"
        code=$?
        [ $code -ne 69 ] && break
        attempts=$((attempts + 1))
        sleep 0.1
      done
      echo "exit=$code" > "\(status)"
      printf '(print "changed")\\n' > "\(package)/main.janet"
      "\(command)" run --socket "\(testSocket)" "\(package)" > "\(output).changed" \
        2> "\(errors).changed"
      echo "exit=$?" > "\(status).changed"
      """, to: shell)

    defer {
      for path in [shell, output, errors, status] {
        for suffix in ["", ".changed"] {
          try? FileManager.default.removeItem(atPath: path + suffix)
        }
      }

      try? FileManager.default.removeItem(atPath: package)
    }

    runInTerminal(shell, in: app)

    let result = try XCTUnwrap(waitForFile(status), "the shell never ran the package")
    let errorText = (try? String(contentsOfFile: errors, encoding: .utf8)) ?? ""

    XCTAssertEqual(result, "exit=0\n", errorText)
    XCTAssertEqual(try String(contentsOfFile: output, encoding: .utf8), "controller ran\n")

    let changed = try XCTUnwrap(waitForFile(status + ".changed"), "the second run never ended")
    let changedErrors = (try? String(contentsOfFile: errors + ".changed", encoding: .utf8)) ?? ""

    XCTAssertNotEqual(changed, "exit=0\n")
    XCTAssertEqual(try String(contentsOfFile: output + ".changed", encoding: .utf8), "")
    XCTAssertTrue(changedErrors.contains("does not match"), changedErrors)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
