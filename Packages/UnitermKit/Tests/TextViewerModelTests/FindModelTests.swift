import XCTest

@testable import TextViewerModel

final class FindModelTests: XCTestCase {
  private func found(_ text: String, _ query: String) -> [String] {
    let ns = text as NSString

    return (FindMatching.search(in: text, for: query)?.ranges ?? []).map { ns.substring(with: $0) }
  }

  /// Catches a rule that differs from the one the other engines follow: case and diacritics fold, a
  /// sharp s and a ligature fold as Foundation folds them, and an unrelated letter does not match.
  func testMatchingFoldsCaseAndDiacriticsTheWayFoundationDoes() {
    XCTAssertEqual(found("Café cafe CAFÉ", "cafe"), ["Café", "cafe", "CAFÉ"])
    XCTAssertEqual(found("cafe", "CAFÉ"), ["cafe"])
    XCTAssertEqual(found("e\u{301}", "e"), ["e\u{301}"])
    XCTAssertEqual(found("Straße", "STRASSE"), ["Straße"])
    XCTAssertEqual(found("ﬁne", "fine"), ["ﬁne"])
    XCTAssertEqual(found("ΣΊΣΥΦΟΣ", "σίσυφος"), ["ΣΊΣΥΦΟΣ"])
    XCTAssertEqual(found("æ ø", "ae"), [])
  }

  /// Catches overlapping matches, which would count "aa" twice in "aaa", and a cap that is not
  /// reported.
  func testMatchesDoNotOverlapAndAreCappedWithAFlag() throws {
    XCTAssertEqual(found("aaa", "aa"), ["aa"])

    let text = String(repeating: "x ", count: FindMatching.maxMatches + 5)
    let outcome = try XCTUnwrap(FindMatching.search(in: text, for: "x"))

    XCTAssertEqual(outcome.ranges.count, FindMatching.maxMatches)
    XCTAssertTrue(outcome.capped)
    XCTAssertFalse(try XCTUnwrap(FindMatching.search(in: "x x", for: "x")).capped)
  }

  /// Catches a search that cannot be stopped, and an empty query that matches everything.
  func testAnEmptyQueryFindsNothingAndACancelledSearchReturnsNil() {
    XCTAssertEqual(
      FindMatching.search(in: "abc", for: ""), FindMatching.Outcome(ranges: [], capped: false))
    XCTAssertNil(FindMatching.search(in: "a a a", for: "a", isCancelled: { true }))
    XCTAssertEqual(
      FindMatching.prepared(String(repeating: "q", count: 900))?.count, FindMatching.maxQueryLength)
  }

  /// Catches a step that lands outside the matches, or one that does not wrap.
  func testSteppingWrapsAndStartsAtEitherEndWithNoCurrentMatch() {
    var state = FindState()

    XCTAssertNil(state.stepTarget(forward: true))

    state.matchCount = 3

    XCTAssertEqual(state.stepTarget(forward: true), 0)
    XCTAssertEqual(state.stepTarget(forward: false), 2)

    state.current = 2

    XCTAssertEqual(state.stepTarget(forward: true), 0)

    state.current = 0

    XCTAssertEqual(state.stepTarget(forward: false), 2)
  }

  /// Catches a status line that claims a total while a search still runs or was capped.
  func testTheStatusLineSaysWhatIsKnown() {
    var state = FindState()

    XCTAssertEqual(state.status, "")

    state.query = "a"
    state.isSearching = true

    XCTAssertEqual(state.status, "Searching\u{2026}")

    state.isSearching = false

    XCTAssertEqual(state.status, "No matches")

    state.matchCount = 1

    XCTAssertEqual(state.status, "1 match")

    state.matchCount = 12
    state.current = 2

    XCTAssertEqual(state.status, "3 of 12")

    state.capped = true
    state.matchCount = 10_000

    XCTAssertEqual(state.status, "3 of 10,000+")
  }

  /// Catches an outline walk that loops on a cycle, runs past the entry cap, or follows a chain
  /// deeper than the depth cap, and a list that does not say it was cut.
  func testFlatteningStopsAtACycleTheEntryCapAndTheDepthCap() {
    final class Node: Hashable {
      var children: [Node] = []

      static func == (lhs: Node, rhs: Node) -> Bool { lhs === rhs }

      func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    func flatten(_ root: Node) -> Contents {
      Contents.flatten(
        root: root, children: { $0.children }, identity: { $0 },
        entry: { _, depth in
          ContentsEntry(level: depth + 1, title: "t", target: .text(characterIndex: 0))
        })
    }

    let root = Node()
    let child = Node()
    root.children = [child]
    child.children = [root, child]

    let cyclic = flatten(root)

    XCTAssertEqual(cyclic.entries.count, 1)
    XCTAssertEqual(cyclic.cut, .repeated)

    let wide = Node()
    wide.children = (0..<(Contents.maxEntries + 50)).map { _ in Node() }

    let capped = flatten(wide)

    XCTAssertEqual(capped.entries.count, Contents.maxEntries)
    XCTAssertEqual(capped.cut, .entryCap)

    let top = Node()
    var tail = top

    for _ in 0..<(Contents.maxDepth + 10) {
      let next = Node()
      tail.children = [next]
      tail = next
    }

    let deep = flatten(top)

    XCTAssertEqual(deep.entries.count, Contents.maxDepth)
    XCTAssertEqual(deep.cut, .depthCap)
    XCTAssertNotEqual(deep.cutMessage, capped.cutMessage)

    let plain = Node()
    plain.children = [Node(), Node()]

    XCTAssertFalse(flatten(plain).wasCut)
  }
}
