import ControllerPackage
import Foundation
import XCTest

@testable import ScriptRuntime

/// A seeded mutation fuzzer for the command's declaration reader and the lint, which run Janet's
/// parser over a file's bytes. Each input is a valid or near-valid file with bytes flipped, cut,
/// or inserted.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated file traps the reader or reads out of bounds, that a file reads the
/// same way twice, and that a declaration the reader passes is one the shared reader either reads
/// or refuses. It cannot prove that a refusal names the right fault, which the reader's own tests
/// hold.
final class DeclaredScriptFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0xDEC1
  }

  private struct Generator {
    var state: UInt64

    mutating func next() -> UInt64 {
      state = state &+ 0x9E37_79B9_7F4A_7C15

      var value = state

      value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
      value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB

      return value ^ (value >> 31)
    }
  }

  private let corpus = [
    """
    #!/usr/bin/env -S uniterm run
    # comment
    (declare-permissions {:id "dev.example.tidy" :name "Tidy"}
      {:kind :pane-control}
      {:kind :capability :name :fs-read}
      {:kind :host-launch :executable "/usr/bin/git" :directory "/tmp"
       :environment ["HOME" "PATH"]}
      {:kind :path-read :directories ["/tmp" "/tmp/x"]})
    (print "ok")
    """,
    "(declare-permissions {:kind :pane-control :kind :pane-control})\n",
    "(declare-permissions {:kind :clipboard-read :version nil})\n(print 1)\n",
    "(print 1)\n(declare-permissions)\n",
    "(declare-permisions {:kind :pane-control})\n",
    "(def x {:a 1 :b @[1 2 3] :c @{:d \"e\"}})\n(print x)\n",
    "(declare-permissions {:kynd :pane-control})\n",
  ].map { [UInt8]($0.utf8) }

  /// Catches a mutated file that traps the reader, or whose second reading differs from its first.
  func testMutatedFilesReadWithoutTrapping() {
    var random = Generator(state: seed)

    for iteration in 0..<iterations {
      var bytes = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<Int(random.next() % 5) { mutate(&bytes, using: &random) }

      let data = Data(bytes)
      let reading = DeclaredScript.read(data)

      XCTAssertEqual(DeclaredScript.read(data), reading, "seed \(seed), iteration \(iteration)")

      if case .declared(let json) = reading {
        _ = try? FileDeclaration.parse(json)
      }
    }
  }

  private let lintCorpus = [
    """
    (declare-permissions {:kind :pane-control})
    (import uniterm :as u)
    (defmacro m [x] ~(do (u/send ,x "a" "b")))
    (use uniterm)
    (defn f [send] (each p [1 2] (loop [i :range [0 3] :let [q i]] (u/open-tab p))))
    (try (eval '(print 1)) ([err] (read-clipboard)))
    """,
    "(import uniterm)\n(def {:a x :b [y z]} @{:c uniterm/write-clipboard})\n(let [a 1] (a))\n",
  ].map { [UInt8]($0.utf8) }

  /// Catches a mutated file that traps the lint, overruns its form arrays, or lints differently
  /// the second time.
  func testMutatedFilesLintWithoutTrapping() {
    var random = Generator(state: seed ^ 0x11A7)

    for iteration in 0..<iterations {
      var bytes = (lintCorpus + corpus)[
        Int(random.next() % UInt64(lintCorpus.count + corpus.count))]

      for _ in 0..<Int(random.next() % 5) { mutate(&bytes, using: &random) }

      let data = Data(bytes)

      XCTAssertEqual(
        ScriptLint.lint(data), ScriptLint.lint(data), "seed \(seed), iteration \(iteration)")
    }
  }

  private static let punctuation = Array("(){}[]\"@~',;#\\ \n:".utf8)

  private func mutate(_ bytes: inout [UInt8], using random: inout Generator) {
    guard !bytes.isEmpty else { return }

    let at = Int(random.next() % UInt64(bytes.count))

    switch random.next() % 6 {
    case 0: bytes[at] ^= UInt8(truncatingIfNeeded: random.next())
    case 1: bytes[at] = Self.punctuation[Int(random.next() % UInt64(Self.punctuation.count))]
    case 2: bytes.removeSubrange(at..<min(bytes.count, at + 1 + Int(random.next() % 8)))
    case 3: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
    case 4:
      let chunk = Array(bytes[at..<min(bytes.count, at + 1 + Int(random.next() % 24))])

      bytes.insert(contentsOf: chunk, at: at)

    default: bytes.append(contentsOf: [UInt8](repeating: 0x7D, count: Int(random.next() % 8)))
    }
  }
}
