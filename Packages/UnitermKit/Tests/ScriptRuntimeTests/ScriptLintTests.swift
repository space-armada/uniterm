import Foundation
import ScriptWire
import XCTest

@testable import ScriptRuntime

/// The lint's reading of a file, with Janet's own parser and no app. Each case is source text and
/// the findings the lint makes of it. The lint evaluates nothing, so none of these files runs.
///
/// These cases prove what the lint reports for a literal call, an alias, a prefix, a macro, a
/// shadowing binding, and each way to reach a call without its name. They cannot prove that a
/// file the lint calls clean is accepted at run time. The call boundary decides that.
final class ScriptLintTests: XCTestCase {
  private func declaration(_ kinds: [String]) -> String {
    let permissions = kinds.map { "{:kind :\($0)}" }.joined(separator: "\n  ")

    return "(declare-permissions\n  \(permissions))\n"
  }

  private func findings(
    _ source: String, file: StaticString = #filePath, line: UInt = #line
  ) -> [ScriptLint.Finding] {
    let outcome = ScriptLint.lint(Data(source.utf8))

    guard case .report(let found, _) = outcome else {
      XCTFail("the lint could not read the source: \(outcome)", file: file, line: line)

      return []
    }

    return found
  }

  private func summary(_ found: [ScriptLint.Finding]) -> [String] {
    found.map { "\($0.line):\($0.column) \($0.kind) \($0.message)" }
  }

  private struct Case {
    let name: String
    let source: String
    let kinds: [ScriptLint.Finding.Kind]
    let fragments: [String]
  }

  // MARK: Powers

  /// Catches a call reported against the wrong power, a declared power reported unused while a
  /// call uses it, and a power the file never uses going unreported.
  func testLiteralCallsAreComparedWithTheDeclaration() {
    let cases = [
      Case(
        name: "all declared and used",
        source: declaration(["pane-control", "clipboard-read"])
          + "(import uniterm)\n(uniterm/list-windows)\n(uniterm/read-clipboard)\n",
        kinds: [], fragments: []),
      Case(
        name: "an undeclared clipboard read",
        source: declaration(["pane-control"])
          + "(import uniterm)\n(uniterm/list-windows)\n(uniterm/read-clipboard)\n",
        kinds: [.undeclaredPower],
        fragments: ["uniterm/read-clipboard needs clipboard-read"]),
      Case(
        name: "an undeclared write",
        source: declaration(["clipboard-read"])
          + "(import uniterm)\n(uniterm/write-clipboard \"x\")\n(uniterm/read-clipboard)\n",
        kinds: [.undeclaredPower], fragments: ["needs clipboard-write"]),
      Case(
        name: "a declared power that is never used",
        source: declaration(["pane-control", "clipboard-write"])
          + "(import uniterm)\n(uniterm/send {:pane 1} \"a.csv\" \"x\")\n",
        kinds: [.unusedPower], fragments: ["declares clipboard-write but never uses it"]),
      Case(
        name: "an undeclared ask helper",
        source: declaration(["pane-control"])
          + "(import uniterm)\n(uniterm/list-windows)\n(uniterm/ask-text \"Name?\")\n",
        kinds: [.undeclaredPower], fragments: ["uniterm/ask-text needs ask-user"]),
      Case(
        name: "a declared ask used through ask and a helper",
        source: declaration(["ask-user"])
          + "(import uniterm)\n(uniterm/ask {:items []})\n(uniterm/ask-confirm \"Sure?\")\n",
        kinds: [], fragments: []),
      Case(
        name: "posting status needs no power",
        source: declaration([]) + "(import uniterm)\n(uniterm/post-status :info \"hi\")\n",
        kinds: [], fragments: []),
      Case(
        name: "api-version needs no power",
        source: declaration([]) + "(import uniterm)\n(print (uniterm/api-version))\n",
        kinds: [], fragments: []),
      Case(
        name: "post-status does not use pane control",
        source: declaration(["pane-control"])
          + "(import uniterm)\n(uniterm/post-status :info \"hi\")\n",
        kinds: [.unusedPower], fragments: ["declares pane-control but never uses it"]),
      Case(
        name: "a name uniterm does not offer",
        source: declaration([]) + "(import uniterm)\n(uniterm/nope)\n",
        kinds: [.unknownFunction], fragments: ["uniterm/nope is not a function uniterm offers"]),
      Case(
        name: "calls inside a nested structure",
        source: declaration([])
          + "(import uniterm)\n(def table @{:r [uniterm/read-clipboard] :w {:f uniterm/write-clipboard}})\n",
        kinds: [.undeclaredPower, .undeclaredPower], fragments: []),
      Case(
        name: "quoted calls and text are data",
        source: declaration([])
          + "(import uniterm)\n(def a '(uniterm/read-clipboard))\n(def b \"uniterm/send\")\n"
          + "# uniterm/write-clipboard\n",
        kinds: [], fragments: []),
    ]

    for item in cases {
      let found = findings(item.source)

      XCTAssertEqual(found.map(\.kind), item.kinds, "\(item.name): \(summary(found))")

      for fragment in item.fragments {
        XCTAssertTrue(
          found.contains { $0.message.contains(fragment) }, "\(item.name): \(summary(found))")
      }
    }
  }

  /// Catches a finding that points at the wrong place. A call is reported at the form that holds
  /// it, and an unused power at the declaration.
  func testFindingsCarryTheirLineAndColumn() {
    let found = findings(
      declaration(["clipboard-write"]) + "(import uniterm)\n\n  (uniterm/read-clipboard)\n")

    XCTAssertEqual(found.map(\.line), [1, 5])
    XCTAssertEqual(found.map(\.column), [1, 3])
  }

  /// Catches a capability reported as unused. Its uses are Janet's own functions, which the lint
  /// does not see.
  func testADeclaredCapabilityIsNeverReportedUnused() {
    let source =
      "(declare-permissions {:kind :capability :name :fs-read})\n(print \"hi\")\n"

    XCTAssertEqual(summary(findings(source)), [])
  }

  // MARK: Names

  /// Catches a name form the lint misses: a prefix, an alias, a bare use, and a file that imports
  /// the module twice.
  func testEveryWayToNameTheModuleIsResolved() {
    let cases = [
      Case(
        name: "import with a prefix alias",
        source: "(import uniterm :as u)\n(u/read-clipboard)\n",
        kinds: [.undeclaredPower], fragments: ["u/read-clipboard needs clipboard-read"]),
      Case(
        name: "import with a prefix string",
        source: "(import uniterm :prefix \"ut-\")\n(ut-read-clipboard)\n",
        kinds: [.undeclaredPower], fragments: ["ut-read-clipboard needs"]),
      Case(
        name: "use",
        source: "(use uniterm)\n(read-clipboard)\n",
        kinds: [.undeclaredPower], fragments: ["read-clipboard needs clipboard-read"]),
      Case(
        name: "a string module name",
        source: "(import \"uniterm\" :as u)\n(u/write-clipboard \"x\")\n",
        kinds: [.undeclaredPower], fragments: ["u/write-clipboard needs clipboard-write"]),
      Case(
        name: "an import that follows its use",
        source: "(defn f [] (u/read-clipboard))\n(import uniterm :as u)\n",
        kinds: [.undeclaredPower], fragments: []),
      Case(
        name: "an alias of a function",
        source: "(import uniterm)\n(def f uniterm/read-clipboard)\n(f)\n(f)\n",
        kinds: [.undeclaredPower], fragments: ["uniterm/read-clipboard needs"]),
      Case(
        name: "the function passed as a value",
        source: "(import uniterm :as u)\n(map u/write-clipboard [\"a\"])\n",
        kinds: [.undeclaredPower], fragments: ["u/write-clipboard needs"]),
      Case(
        name: "another module is not uniterm",
        source: "(import json)\n(json/send 1)\n(def u/send 1)\n",
        kinds: [], fragments: []),
      Case(
        name: "the other prefix is not bound",
        source: "(import uniterm :as u)\n(uniterm/read-clipboard)\n",
        kinds: [], fragments: []),
    ]

    for item in cases {
      let found = findings(item.source)

      XCTAssertEqual(found.map(\.kind), item.kinds, "\(item.name): \(summary(found))")

      for fragment in item.fragments {
        XCTAssertTrue(
          found.contains { $0.message.contains(fragment) }, "\(item.name): \(summary(found))")
      }
    }
  }

  /// Catches a local binding that shares a module function's name being reported as a call.
  func testALocalBindingThatShadowsAModuleFunctionIsNotACall() {
    let cases = [
      "(use uniterm)\n(defn f [send] (send 1))\n",
      "(use uniterm)\n(let [send print] (send 1))\n",
      "(use uniterm)\n(each send [print] (send 1))\n",
      "(use uniterm)\n(def {:a send} {:a print})\n(send 1)\n",
      "(use uniterm)\n(defn send [x] x)\n(send 1)\n",
      "(import uniterm :as u)\n(def u/read-clipboard 1)\n(print u/read-clipboard)\n",
      "(use uniterm)\n(loop [send :in [print]] (send 1))\n",
      "(use uniterm)\n(try (error 1) ([send] (send 1)))\n",
      "(use uniterm)\n(fn [send] (send 1))\n",
    ]

    for source in cases {
      XCTAssertEqual(summary(findings(source)), [], source)
    }

    XCTAssertEqual(
      findings("(use uniterm)\n(defn f [send] (send 1))\n(send 2)\n").map(\.kind),
      [.undeclaredPower], "a binding ends with its scope")
  }

  // MARK: Dynamic calls

  /// Catches a way to reach a module function without its name that the lint reports as nothing.
  /// Each also stops the lint from claiming a declared power is unused.
  func testAnythingThatReachesACallWithoutItsNameCouldMakeAnyCall() {
    let dynamic = [
      "(eval '(+ 1 2))",
      "(eval-string \"(uniterm/read-clipboard)\")",
      "(compile '(+ 1 2))",
      "(def s (symbol \"uniterm/\" \"read-clipboard\"))",
      "(def k (keyword \"read-clipboard\"))",
      "(dyn :current-env)",
      "(dyn k)",
      "(get (curenv) 'uniterm/send)",
      "(require \"uniterm\")",
      "(import* name)",
      "(import ,name)",
      "(module/cache \"uniterm\")",
      "(dofile \"x.janet\")",
      "(resolve 'x)",
      "(map eval [1])",
      "(fiber/getenv (fiber/current))",
      "(unmarshal b)",
      "(use ,m)",
    ]

    for line in dynamic {
      let source =
        declaration(["clipboard-read"]) + "(import uniterm)\n(def name 1)(def k 1)\n" + line + "\n"
      let found = findings(source)

      XCTAssertTrue(found.contains { $0.kind == .dynamicCall }, "\(line): \(summary(found))")
      XCTAssertFalse(found.contains { $0.kind == .unusedPower }, "\(line): \(summary(found))")
      XCTAssertTrue(
        found.contains { $0.message.contains("could make any call") }, "\(line): \(summary(found))")
    }
  }

  /// Catches a harmless use of dyn, and of names that only look dynamic, being reported.
  func testOrdinaryUsesOfDynAndNearbyNamesAreNotDynamic() {
    let source = """
      (import uniterm)
      (def args (dyn :args))
      (def s (string "a" "b"))
      (print (keyword? :a) (symbol? 'a))
      (apply print [1 2])
      """

    XCTAssertEqual(summary(findings(source)), [])
  }

  // MARK: Macros

  /// Catches a macro whose expansion reaches a call going unseen. A literal mention resolves, and a
  /// name built in the macro is a dynamic call.
  func testAMacroThatMentionsACallIsResolvedAndOneThatBuildsANameIsDynamic() {
    let literal = findings(
      "(import uniterm)\n(defmacro paste [] ~(uniterm/write-clipboard \"x\"))\n(paste)\n")

    XCTAssertEqual(literal.map(\.kind), [.undeclaredPower])
    XCTAssertTrue(literal[0].message.contains("clipboard-write"))

    let quoted = findings("(import uniterm)\n(defmacro paste [] '(uniterm/read-clipboard))\n")

    XCTAssertEqual(quoted.map(\.kind), [.undeclaredPower])

    let built = findings(
      "(import uniterm)\n(defmacro call [n] ~(,(symbol \"uniterm/\" n)))\n(call \"read-clipboard\")\n"
    )

    XCTAssertTrue(built.contains { $0.kind == .dynamicCall }, "\(summary(built))")

    let passed = findings(
      "(import uniterm)\n(defmacro twice [f] ~(do (,f) (,f)))\n(twice uniterm/read-clipboard)\n")

    XCTAssertEqual(passed.map(\.kind), [.undeclaredPower])
  }

  /// Catches template text outside a macro being reported as a call. It is data until a macro
  /// returns it, and a macro is checked above.
  func testTemplateTextOutsideAMacroIsData() {
    let found = findings(
      "(import uniterm)\n(def t ~(uniterm/read-clipboard ,(uniterm/write-clipboard \"x\")))\n")

    XCTAssertEqual(found.count, 1, "\(summary(found))")
    XCTAssertTrue(found[0].message.contains("write-clipboard"))
  }

  // MARK: Path reading

  /// Catches a declared path-read power reported unused in a file that sends a command, and one
  /// that sends none going unreported. A command is the only call whose argument can name a path.
  func testPathReadIsUsedByASentCommandAndUnusedOtherwise() {
    let declared =
      "(declare-permissions {:kind :pane-control}\n"
      + "  {:kind :path-read :directories [\"/tmp\"]})\n"
    let sends =
      "(import uniterm)\n(uniterm/send-command p \"fixture-paths\" [0 0] \"read-file\" {})\n"

    XCTAssertEqual(summary(findings(declared + sends)), [])

    let idle = findings(declared + "(import uniterm)\n(uniterm/list-windows)\n")

    XCTAssertEqual(idle.map(\.kind), [.unusedPower])
    XCTAssertTrue(idle[0].message.contains("path-read"))
  }

  // MARK: Asking

  /// Catches a form call that needs no declaration, a declared ask power reported unused in a file
  /// that opens a form, and one that never asks going unreported. Each form call needs ask-user,
  /// and holding it gives no pane control, so a file that only asks declares nothing else.
  func testAskUserIsUsedByTheFormCallsAndNeededByThem() {
    let declared = "(declare-permissions {:kind :ask-user})\n"

    for call in [
      "(uniterm/open-form \"{}\")", "(uniterm/wait-form 1)", "(uniterm/discard-form 1)",
    ] {
      XCTAssertEqual(summary(findings(declared + "(import uniterm)\n" + call)), [], call)

      let undeclared = findings("(declare-permissions)\n(import uniterm)\n" + call)

      XCTAssertEqual(undeclared.map(\.kind), [.undeclaredPower], call)
      XCTAssertTrue(undeclared[0].message.contains("ask-user"), undeclared[0].message)
    }

    let idle = findings(declared + "(import uniterm)\n(uniterm/post-status :info \"x\")\n")

    XCTAssertEqual(idle.map(\.kind), [.unusedPower])
    XCTAssertTrue(idle[0].message.contains("ask-user"))
  }

  // MARK: Browser powers

  /// Catches a declared browser power reported unused in a file that uses it, and one that uses
  /// neither going unreported. Navigation is used by a command or a layout, and read by a command.
  func testBrowserPowersAreUsedByCommandsAndLayoutsAndUnusedOtherwise() {
    let declared =
      "(declare-permissions {:kind :pane-control}\n"
      + "  {:kind :browser-navigation} {:kind :browser-read})\n"
    let sends =
      "(import uniterm)\n(uniterm/send-command p \"browser\" [0 0] \"open\" {})\n"
    let lays = "(import uniterm)\n(uniterm/request-layout p {:open :browser})\n"

    XCTAssertEqual(summary(findings(declared + sends)), [])

    let layoutOnly = findings(declared + lays)

    XCTAssertEqual(layoutOnly.map(\.kind), [.unusedPower], "read is not used by a layout")
    XCTAssertTrue(layoutOnly[0].message.contains("browser-read"))

    let idle = findings(declared + "(import uniterm)\n(uniterm/list-windows)\n")

    XCTAssertEqual(idle.count, 2)
    XCTAssertEqual(Set(idle.map(\.kind)), [.unusedPower])
  }

  // MARK: Layout

  /// Catches a layout that launches a program without declaring it, and a declared host launch
  /// reported unused while a layout call exists.
  func testALayoutWithAnExecNeedsAHostLaunch() {
    let layout =
      "(import uniterm)\n(uniterm/request-layout p {:open :x :exec {:argv [\"ls\"]}})\n"

    XCTAssertEqual(
      findings(declaration(["pane-control"]) + layout).map(\.kind), [.undeclaredPower])
    XCTAssertTrue(
      findings(declaration(["pane-control"]) + layout)[0].message.contains("host-launch"))

    let declared =
      "(declare-permissions {:kind :pane-control}\n"
      + "  {:kind :host-launch :executable \"/bin/ls\" :directory \"/tmp\" :environment []})\n"

    XCTAssertEqual(summary(findings(declared + layout)), [])

    XCTAssertEqual(
      findings(declared + "(import uniterm)\n(uniterm/list-windows)\n").map(\.kind),
      [.unusedPower])
  }

  /// Catches a launch the lint misses because the layout spells `exec` as a string key, and a
  /// value that is only the word `:exec` being taken for a launch.
  func testExecIsFoundAsAStructKeyInEitherSpellingAndNotAsAValue() {
    let call = { (layout: String) in
      "(declare-permissions {:kind :pane-control})\n(import uniterm)\n"
        + "(uniterm/request-layout p \(layout))\n"
    }

    for layout in [
      "{:open :x :exec {:argv [\"ls\"]}}", "{:open :x \"exec\" {:argv [\"ls\"]}}",
      "{:children [{:open :x :exec {:argv [\"ls\"]}}]}",
    ] {
      let found = findings(call(layout))

      XCTAssertEqual(found.map(\.kind), [.undeclaredPower], "\(layout): \(summary(found))")
      XCTAssertTrue(found[0].message.contains("host-launch"), layout)
    }

    for layout in ["{:open :x :title :exec}", "{:open :x :title \"exec\"}", "{:open :x}"] {
      XCTAssertEqual(summary(findings(call(layout))), [], layout)
    }
  }

  /// Catches parse and the parser functions, which turn text into code, passing as ordinary names.
  func testParsingTextIntoCodeCouldMakeAnyCall() {
    let sources = [
      "(import uniterm)\n(defmacro m [] (parse \"(uniterm/send p 1 2)\"))\n(m)\n",
      "(def forms (parse-all \"(1)\"))\n",
      "(def p (parser/new))\n",
      "(map parser/produce [])\n",
    ]

    for source in sources {
      let found = findings(source)

      XCTAssertTrue(found.contains { $0.kind == .dynamicCall }, "\(source): \(summary(found))")
    }
  }

  /// Catches a call inside a comment form being counted. The form expands to nothing, unless the
  /// file binds its own comment.
  func testACommentFormIsDataUnlessTheFileShadowsIt() {
    XCTAssertEqual(
      summary(
        findings(
          "(import uniterm)\n(comment (uniterm/read-clipboard) (eval 1) (use ,x))\n")), [])

    XCTAssertEqual(
      findings("(import uniterm)\n(defn comment [& x] x)\n(comment (uniterm/read-clipboard))\n")
        .map(\.kind), [.undeclaredPower])
  }

  // MARK: Undeclared files

  /// Catches an undeclared file passing as clean, and the suggestion missing the powers its
  /// calls need.
  func testAFileWithNoDeclarationReportsEveryPowerAndSuggestsTheForm() throws {
    let source =
      "(import uniterm)\n(uniterm/list-windows)\n(uniterm/read-clipboard)\n(uniterm/send {} \"a\" \"b\")\n"

    guard case .report(let found, let suggestion) = ScriptLint.lint(Data(source.utf8)) else {
      return XCTFail("the lint could not read the source")
    }

    XCTAssertEqual(found.count, 3)
    XCTAssertTrue(found.allSatisfy { $0.message.contains("declares nothing") })
    XCTAssertEqual(
      suggestion,
      "add (declare-permissions {:kind :clipboard-read} "
        + "{:kind :pane-control}) as the file's first form")

    guard case .report(let none, let noSuggestion) = ScriptLint.lint(Data("(print 1)\n".utf8))
    else { return XCTFail() }

    XCTAssertEqual(none, [])
    XCTAssertNil(noSuggestion)
  }

  // MARK: Unreadable files

  /// Catches a file that does not parse, or whose declaration fails to read, passing as clean.
  func testAFileThatDoesNotParseOrDeclareOnlyReportsWhy() {
    let cases: [(String, String)] = [
      ("(print 1", "line"),
      (
        "(declare-permissions {:kind :pane-control :kind :pane-control})",
        "repeats a key"
      ),
      ("(declare-permissions {:kind :nope})", "not a permission kind"),
      ("(print 1)\n(declare-permissions)\n", "must be the first form"),
      ("(declare-permissions {:kind :capability :name :ffi})", "ffi"),
    ]

    for (source, fragment) in cases {
      guard case .unreadable(let text) = ScriptLint.lint(Data(source.utf8)) else {
        XCTFail("the lint read \(source)")

        continue
      }

      XCTAssertTrue(text.contains(fragment), "\(source): \(text)")
    }
  }

  /// Catches a parser that merges a file's nesting into a crash. The lint refuses it by name.
  func testAFileNestedTooDeeplyIsRefused() {
    let source = String(repeating: "(", count: 600) + String(repeating: ")", count: 600)

    guard case .unreadable(let text) = ScriptLint.lint(Data(source.utf8)) else {
      return XCTFail("the lint read a file nested 600 deep")
    }

    XCTAssertTrue(text.contains("levels deep"), text)
  }

  // MARK: The shared table

  /// Catches the module and the shared table drifting apart. A function the module offers without
  /// a row would lint as a name with no power, and a row without a function would never match. The
  /// form helpers are the functions with no call of their own, and each has a power in the helper
  /// table.
  func testTheModulesFunctionsAreTheSharedTablesCallsPlusApiVersionAndTheHelpers() {
    let module = Set(ScriptLint.moduleFunctions())
    let table = Set(ScriptCallKind.allCases.map(\.janetName))

    XCTAssertEqual(
      module.subtracting(table), Set(["api-version"] + ScriptHelperFunctions.powers.keys))
    XCTAssertEqual(table.subtracting(module), [])
    XCTAssertEqual(ScriptLint.moduleFunctions().count, module.count, "a name is listed twice")
  }
}
