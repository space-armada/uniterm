import ControllerPackage
import Foundation
import SourceAccess
import XCTest

@testable import ScriptRuntime

/// The command's reading of a file's first form, with Janet's own parser and no app.
///
/// Each case is source text and what the reader makes of it. The reader evaluates nothing, so
/// none of these files runs.
final class DeclaredScriptTests: XCTestCase {
  private func read(_ source: String) -> DeclaredScript.Reading {
    DeclaredScript.read(Data(source.utf8))
  }

  private func declaration(
    _ source: String, file: StaticString = #filePath, line: UInt = #line
  ) throws -> FileDeclaration {
    guard case .declared(let json) = read(source) else {
      XCTFail("the source was not read as a declaration", file: file, line: line)

      throw CocoaError(.fileReadCorruptFile)
    }

    return try FileDeclaration.parse(json)
  }

  private func assertInvalid(
    _ source: String, saying fragment: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    switch read(source) {
    case .invalid(let text):
      XCTAssertTrue(text.contains(fragment), text, file: file, line: line)

    case .declared(let json):
      // The permission reader refuses what the command's reader passes through to it.
      XCTAssertThrowsError(try FileDeclaration.parse(json), file: file, line: line) { error in
        XCTAssertTrue("\(error)".contains(fragment), "\(error)", file: file, line: line)
      }

    case .undeclared:
      XCTFail("the source was read as undeclared: \(source)", file: file, line: line)
    }
  }

  // MARK: Reading

  /// Catches a declaration read as something other than what it says, with a shebang line,
  /// comments, and blank lines before it and every literal the form allows.
  func testAValidDeclarationIsReadWithOnlyAShebangAndCommentsBeforeIt() throws {
    let declared = try declaration(
      """
      #!/usr/bin/env -S uniterm run
      # a comment with (declare-permissions) and a } in it

      (declare-permissions {:id "dev.example.tidy" :name "Tidy"}
        {:kind :pane-control}
        {:kind :clipboard-read}
        {:kind :capability :name :fs-read}
        {:kind :host-launch :executable "/usr/bin/git" :directory "/Users/me/src"
         :environment ["HOME" "PATH"]})

      (print "declare-permissions in a string")
      """)

    XCTAssertEqual(declared.id, "dev.example.tidy")
    XCTAssertEqual(declared.name, "Tidy")
    XCTAssertEqual(declared.permissions.count, 4)
    XCTAssertEqual(declared.capabilities, ["fs-read"])
  }

  /// Catches a path-read declaration lost on the way from Janet: its directories must reach the
  /// shared reader as the scope the file named.
  func testAPathReadDeclarationCarriesItsDirectories() throws {
    let declared = try declaration(
      """
      (declare-permissions {:kind :path-read :directories ["/tmp/b" "/tmp/a"]})
      """)

    XCTAssertEqual(
      declared.permissions, [.pathRead(try ReadScope(directories: ["/tmp/a", "/tmp/b"]))])
  }

  /// Catches a browser declaration refused or changed on the way from Janet: both kinds are read at
  /// version 1, and neither takes a field.
  func testBrowserDeclarationsAreReadAtVersionOneAndTakeNoField() throws {
    let declared = try declaration(
      """
      (declare-permissions {:kind :browser-navigation} {:kind :browser-read})
      """)

    XCTAssertEqual(declared.permissions, [.browserNavigation, .browserRead])

    XCTAssertThrowsError(
      try declaration(
        "(declare-permissions {:kind :browser-read :version 2})"))
    XCTAssertThrowsError(
      try declaration(
        "(declare-permissions {:kind :browser-navigation :directories [\"/tmp\"]})"))
  }

  /// Catches the ask power refused or changed on the way from Janet: it reads at edition 0 and
  /// takes no field.
  func testAnAskUserDeclarationIsReadAtEditionZeroAndTakesNoField() throws {
    let declared = try declaration(
      "(declare-permissions {:kind :pane-control} {:kind :ask-user})")

    XCTAssertEqual(declared.permissions, [.paneControl, .askUser])

    for refused in [
      "(declare-permissions {:kind :ask-user :version 2})",
      "(declare-permissions {:kind :ask-user :name \"x\"})",
      "(declare-permissions {:kind :ask-user :directories [\"/tmp\"]})",
    ] {
      switch read(refused) {
      case .invalid: break
      case .declared(let json): XCTAssertThrowsError(try FileDeclaration.parse(json), refused)
      default: XCTFail("\(refused) was read as a valid declaration")
      }
    }
  }

  /// Catches an empty declaration being treated as no declaration, and a file with only a header.
  func testAnEmptyDeclarationAndAHeaderOnlyDeclarationAreDeclarations() throws {
    XCTAssertTrue(try declaration("(declare-permissions)").permissions.isEmpty)

    let named = try declaration(#"(declare-permissions {:name "x"})"#)

    XCTAssertEqual(named.name, "x")
    XCTAssertTrue(named.permissions.isEmpty)
  }

  /// Catches a file that is not declared being refused or read as declared: a plain script, an
  /// empty file, a first form with a syntax error, and a first form that merely looks like data.
  func testAFileWhoseFirstFormIsNotADeclarationIsUndeclared() {
    for source in [
      "(print 1)", "", "# only a comment\n", "(def x {:a 1 :a 2})\n(print x)",
      "(declare-permissions {:kind :pane-control", "{:kind :pane-control}",
      "(import uniterm)\n(print (declare-permissions-count))",
    ] {
      XCTAssertEqual(read(source), .undeclared, source)
    }
  }

  // MARK: The one declaration, first

  /// Catches a second declaration, a declaration after another form, and one nested in an
  /// earlier form, each of which must not be read as the file's declaration.
  func testASecondOrALateDeclarationIsRefusedWithAMessageNamingIt() {
    assertInvalid(
      "(declare-permissions)\n(print 1)\n(declare-permissions)\n", saying: "appears again")
    assertInvalid(
      "(print 1)\n(declare-permissions {:kind :pane-control})\n",
      saying: "must be the first form of the file")
    assertInvalid(
      "(do (declare-permissions))\n", saying: "must be the first form of the file")
    assertInvalid(
      "(def x [1 (declare-permissions)])\n", saying: "must be the first form of the file")
    assertInvalid(
      "(print 1)\n(defn f [] {:a (declare-permissions)})\n",
      saying: "must be the first form of the file")
  }

  /// Catches an undeclared script refused for merely mentioning the name. A parameter list, a
  /// quoted form, quasiquoted data, a docstring, and a bracketed list that starts with the name
  /// are data and not declarations, so each file stays undeclared and runs as it did.
  func testMentioningTheNameIsNotADeclaration() {
    for source in [
      "(defn f [declare-permissions] declare-permissions)\n(print 1)\n",
      "(print 1)\n(def data '(declare-permissions {:kind :pane-control}))\n",
      "(print 1)\n(def data ~(declare-permissions ,(+ 1 2)))\n",
      "(defn f \"Call (declare-permissions) never.\" [] 1)\n",
      "(print 1)\n(def data [declare-permissions {:kind :pane-control}])\n",
    ] {
      XCTAssertEqual(read(source), .undeclared, source)
    }

    assertInvalid(
      "(print 1)\n(defn f [] (declare-permissions {:kind :pane-control}))\n",
      saying: "must be the first form of the file")
  }

  /// Catches a near miss that runs as an ordinary call, which would leave the file undeclared and
  /// the typo unnoticed.
  func testANearMissOfTheFormNameSaysTheDeclarationMustComeFirst() {
    for typo in [
      "declare-permission", "declare-permisions", "declare-permissons", "Declare-Permissions",
      "declare_permissions", "declare-perms", "declare-permissionz",
    ] {
      assertInvalid("(\(typo) {:kind :pane-control})\n", saying: "must come first")
    }

    XCTAssertEqual(read("(declare (print 1))"), .undeclared)
    XCTAssertEqual(read("(defn declare-things [] 1)"), .undeclared)
  }

  /// Catches a bracketed form read as the declaration.
  func testABracketedDeclarationIsRefused() {
    assertInvalid("[declare-permissions {:kind :pane-control}]", saying: "parenthesized")
  }

  // MARK: Literal data

  /// Catches a value that is not literal data being read: a symbol, a call, a quasiquote, an
  /// unquote, a quote, and the words nil, true, and false.
  func testAValueThatIsNotLiteralDataIsRefused() {
    for (source, fragment) in [
      ("{:kind pane-control}", "the symbol pane-control"),
      ("{:kind :pane-control :version (+ 1 0)}", "parenthesized form"),
      ("{:kind :pane-control :version ~1}", "parenthesized form"),
      ("{:kind :pane-control :version ,x}", "parenthesized form"),
      ("{:kind :pane-control :version 'x}", "parenthesized form"),
      ("{:kind :pane-control :version true}", "true"),
      ("{:kind :pane-control :version false}", "false"),
      ("{:kind :pane-control :version nil}", "nil as a key or a value"),
      ("{:kind :pane-control :version @{}}", "a table"),
      ("{:kind :pane-control :version @[1]}", "an array"),
      (#"{:kind :pane-control :version @"x"}"#, "a buffer"),
    ] {
      assertInvalid("(declare-permissions \(source))", saying: fragment)
    }

    assertInvalid("(declare-permissions :pane-control)", saying: "holds only structs")
    assertInvalid("(declare-permissions (+ 1 2))", saying: "holds only structs")
  }

  /// Catches what Janet's parser would merge or drop: a repeated key, a nil key, and a nil value.
  /// The struct that reaches the form no longer shows them, so only the parser's state can. The
  /// cases put the closing brace after a token, a string, and a nested struct, since the state
  /// differs for each.
  func testAStructJanetWouldMergeOrDropIsRefused() {
    for source in [
      "{:kind :pane-control :kind :pane-control :version 1}",
      "{:kind :pane-control :version 1 :version 2}",
      "{:kind :pane-control :version 1 :version 1}",
      #"{:kind :host-launch :version 1 :executable "/a" :executable "/b"}"#,
      "{:kind :pane-control :version 1 :extra {:a 1 :a 2}}",
      "{:kind :pane-control :version 1 nil 1}",
      "{nil nil :kind :pane-control :version 1}",
      "{:kind :pane-control :version 1 :extra nil}",
      "{:kind :pane-control :version nil}",
    ] {
      assertInvalid("(declare-permissions \(source))", saying: "Janet would")
    }

    assertInvalid(
      "(declare-permissions {:kind :pane-control :version 1 :version 2})", saying: "repeats a key")
    assertInvalid(
      "(declare-permissions {:kind :pane-control :version 1 :extra nil})",
      saying: "nil as a key or a value")
    assertInvalid(
      #"(declare-permissions {:id "a.b" :id "c.d"})"#, saying: "repeats a key")
    assertInvalid(
      "(declare-permissions {:kind :pane-control :version 1 :x {:a 1 :a 2}})",
      saying: "repeats a key")
  }

  /// Catches the duplicate check refusing a plain script's first form, which is not a declaration
  /// and may hold any struct Janet reads.
  func testTheDuplicateCheckOnlyBindsADeclaration() {
    XCTAssertEqual(read("(def x {:a 1 :a 2 nil 3})\n(print x)"), .undeclared)
  }

  /// Catches a version or a number that is not a whole number being read, and a field of the
  /// wrong type: a string where a keyword goes, and the reverse.
  func testNumbersAndFieldTypesAreChecked() {
    assertInvalid(
      "(declare-permissions {:kind :pane-control :version 1.5})", saying: "whole number")
    assertInvalid(
      "(declare-permissions {:kind :pane-control :version -1})", saying: "whole number")
    assertInvalid(
      "(declare-permissions {:kind :pane-control :version 1e12})", saying: "whole number")
    assertInvalid(
      #"(declare-permissions {:kind "pane-control"})"#,
      saying: ":kind takes a keyword")
    assertInvalid(
      "(declare-permissions {:id :dev.example.tidy})", saying: ":id takes a string")
    assertInvalid(
      #"(declare-permissions {:kind :capability :name "fs-read"})"#,
      saying: ":name takes a keyword")
    assertInvalid(
      #"(declare-permissions {:kind :host-launch :executable "/a" :directory "/b" :environment ("HOME")})"#,
      saying: "parenthesized form")
    assertInvalid(
      #"(declare-permissions {:kind :host-launch :executable "/a" :directory "/b" :environment [:HOME]})"#,
      saying: "a list of strings")
    assertInvalid(
      "(declare-permissions {:kind :pane-control :version 1.0})", saying: "names a :version")
  }

  /// Catches kinds this version does not know and a named version being read, which the app
  /// refuses with the same words.
  func testUnknownKindsNamedVersionsAndRepeatsReachTheSharedReader() {
    assertInvalid(
      "(declare-permissions {:kind :everything})", saying: "not a permission kind")
    assertInvalid(
      "(declare-permissions {:kind :pane-control :version 2})", saying: "names a :version")
    assertInvalid(
      "(declare-permissions {:kind :pane-control} {:kind :pane-control})",
      saying: "listed twice")

    for native in ["ffi", "ffi-define", "ffi-jit", "ffi-use", "modules"] {
      assertInvalid(
        "(declare-permissions {:kind :capability :name :\(native)})",
        saying: "cannot declare \(native)")
    }
  }

  /// Catches a token that does not read, just before a closing brace, leaving the parser with an
  /// error that its next byte trips over. Janet's own error and position are the run's to report,
  /// so the reader leaves the file undeclared.
  func testATokenThatDoesNotReadBeforeABraceLeavesTheParseErrorToTheRun() {
    XCTAssertEqual(
      read("(declare-permissions {:kind :pane-control :version 1x})\n(print 1)\n"), .undeclared)
    XCTAssertEqual(read("(def x {:a 1x})\n(print x)\n"), .undeclared)
  }

  /// Catches a misspelled :kind that the header's own field types hide. A header takes strings,
  /// and the permission it really is holds keywords, so the types must not speak first. An :id
  /// is a header's own key and is never taken for a misspelled :kind.
  func testAMisspelledKindOnACapabilityIsNamedBeforeTheHeaderTypesAreChecked() throws {
    assertInvalid(
      "(declare-permissions {:kynd :capability :name :fs-read})",
      saying: "misspelled :kind")

    let named = try declaration(
      #"(declare-permissions {:id "dev.example.tidy" :name "Tidy"} {:kind :pane-control})"#
    )

    XCTAssertEqual(named.id, "dev.example.tidy")
    assertInvalid(
      #"(declare-permissions {:id :dev.example.tidy :name "Tidy"})"#, saying: ":id takes a string")
  }

  /// Catches a permission whose misspelled :kind is read as the header.
  func testAMisspelledKindReadsAsTheHeaderAndIsNamed() {
    assertInvalid(
      "(declare-permissions {:kynd :pane-control})", saying: "misspelled :kind")
    assertInvalid(
      "(declare-permissions {:kind :clipboard-read} {:kidn :pane-control})",
      saying: "permission 2 has no :kind")
  }

  /// Catches text that is not valid UTF-8 or holds a NUL reaching the app, and a file that nests
  /// forms deeper than the reader walks.
  func testTextThatCannotTravelAndFormsTooDeepAreRefused() {
    var bytes = Data("(declare-permissions {:name \"".utf8)

    bytes.append(contentsOf: [0xFF, 0xFE])
    bytes.append(Data("\"})".utf8))

    guard case .invalid(let text) = DeclaredScript.read(bytes) else {
      return XCTFail("invalid UTF-8 was read")
    }

    XCTAssertTrue(text.contains("not UTF-8"), text)
    assertInvalid(#"(declare-permissions {:name "a\0b"})"#, saying: "NUL")

    let deep = String(repeating: "(", count: 600) + String(repeating: ")", count: 600)

    assertInvalid("(print 1)\n\(deep)\n", saying: "nests forms more than")
  }

  /// Catches a declaration too large for the wire being truncated and read.
  func testADeclarationOverTheWireBoundIsRefused() {
    let permissions = [String](
      repeating: "{:kind :capability :name :fs-read}", count: 2000)
    let source = "(declare-permissions \(permissions.joined(separator: " ")))"

    guard case .invalid(let text) = read(source) else {
      return XCTFail("an oversize declaration was read")
    }

    XCTAssertFalse(text.isEmpty)
  }

  /// Catches a file with a syntax error after a valid declaration being refused by the reader,
  /// which leaves the run to report it.
  func testASyntaxErrorAfterTheDeclarationIsLeftToTheRun() throws {
    XCTAssertEqual(
      try declaration("(declare-permissions)\n(print \"unterminated").permissions, [])
  }
}
