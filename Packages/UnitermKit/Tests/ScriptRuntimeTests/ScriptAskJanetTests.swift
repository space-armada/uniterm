import CJanet
import Foundation
import ScriptWire
import XCTest

/// `uniterm/ask` and its helpers, run in the real shim against a host that records each call and
/// answers from a table. They prove how a struct becomes the spec's JSON, which spellings the
/// shim refuses before the app hears of a call, how the result reads back, and that the handle is
/// discarded however the call ends. They cannot prove what the app does with the spec, which
/// `ScriptFormTests` and the form reader's own tests prove.
final class ScriptAskJanetTests: XCTestCase {
  private enum Reply {
    case value(ScriptValue)
    case failure(ScriptFailureKind, String)
    case interrupted
  }

  private final class Host {
    var calls: [ScriptCall] = []
    var answer: (ScriptCall) -> Reply

    init(answer: @escaping (ScriptCall) -> Reply) { self.answer = answer }

    var specs: [String] {
      calls.compactMap {
        if case .openForm(let spec) = $0 { return spec }

        return nil
      }
    }

    var names: [String] {
      calls.map {
        switch $0 {
        case .openForm: return "open"
        case .waitForm: return "wait"
        case .discardForm: return "discard"
        default: return "other"
        }
      }
    }
  }

  private static let callback:
    @convention(c) (
      UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
      UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?,
      UnsafeMutablePointer<CChar>?, Int
    ) -> Int32 = { userdata, request, length, reply, replyLength, error, capacity in
      guard let userdata, let request, let reply, let replyLength else { return 1 }

      let host = Unmanaged<Host>.fromOpaque(userdata).takeUnretainedValue()
      var reader = ByteReader(Data(UnsafeBufferPointer(start: request, count: length)))

      guard let call = try? ScriptCall.decode(from: &reader) else { return 1 }

      host.calls.append(call)

      switch host.answer(call) {
      case .interrupted:
        return Int32(UNITERM_JANET_CALL_INTERRUPTED)

      case .failure(let kind, let text):
        if let error, capacity > 0 { _ = strlcpy(error, text, capacity) }

        return Int32(UNITERM_JANET_APP_FAILURE_BASE) + Int32(kind.rawValue)

      case .value(let value):
        guard let bytes = try? value.encoded(), let memory = malloc(bytes.count) else { return 1 }

        bytes.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        reply.pointee = memory.assumingMemoryBound(to: UInt8.self)
        replyLength.pointee = bytes.count

        return 0
      }
    }

  private static let submitted: ScriptValue = .record([
    "form": .integer(5), "submission": .integer(1), "action": .string("go"),
    "answers": .record(["answer": .string("x"), "n": .integer(3)]),
  ])

  /// A host that opens form 5 and answers the wait with `result`.
  private func host(waiting result: Reply = .value(ScriptAskJanetTests.submitted)) -> Host {
    Host { call in
      switch call {
      case .openForm: return .value(.integer(5))
      case .waitForm: return result
      default: return .value(.null)
      }
    }
  }

  /// Runs `script` with the host. The status is the run's, and the message the failure's.
  private func run(_ script: String, host: Host) -> (status: uniterm_script_status, text: String) {
    var failure = uniterm_script_failure()
    let source = Array(("(import uniterm)\n" + script).utf8)

    let status = withExtendedLifetime(host) {
      var shim = uniterm_host(
        userdata: Unmanaged.passUnretained(host).toOpaque(), post_status: nil,
        call: Self.callback)

      return source.withUnsafeBufferPointer {
        uniterm_janet_run(
          &shim, "ask-test", $0.baseAddress, $0.count, uniterm_janet_default_sandbox, nil, 0,
          &failure)
      }
    }

    let text = withUnsafeBytes(of: failure.message) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }

    return (status, text)
  }

  private func assertRuns(_ script: String, host: Host, line: UInt = #line) {
    let outcome = run(script, host: host)

    XCTAssertEqual(outcome.status, UNITERM_SCRIPT_OK, outcome.text, line: line)
  }

  private func object(_ text: String) throws -> NSDictionary {
    try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary, "not an object")
  }

  // MARK: Conversion

  /// Catches a keyword that reaches the app as something other than its name, a key that loses its
  /// colon, or a text value that changes on the way. A full spec converts to the JSON the strict
  /// reader reads.
  func testAStructWithKeywordKeysAndWordsBecomesTheSpecsJSON() throws {
    let host = host()

    assertRuns(
      """
      (def result (uniterm/ask
        {:title "Deploy"
         :items [{:block :notice :level :warning :text "Production."}
                 {:block :table :rows {"Region" "us-east" "Count" "3"}}
                 {:id :region :text "Which?" :type :choice :choices ["a" "b"] :other true
                  :required true :default "a"}
                 {:id :n :text "How many?" :type :integer :default 3 :validate {:minimum 1}}
                 {:id :f :text "File" :type :file :mode :save :types ["public.json"]}]
         :actions [{:id :deploy :label "Deploy" :role :primary}
                   {:id :cancel :role :cancel}]}))
      (assert (struct? result))
      """, host: host)

    let spec = try object(try XCTUnwrap(host.specs.first))
    let items = try XCTUnwrap(spec["items"] as? [NSDictionary])

    XCTAssertEqual(spec["title"] as? String, "Deploy")
    XCTAssertEqual(
      items[0], ["block": "notice", "level": "warning", "text": "Production."] as NSDictionary)
    XCTAssertEqual(
      items[1],
      ["block": "table", "rows": ["Region": "us-east", "Count": "3"]] as NSDictionary)
    XCTAssertEqual(items[2]["id"] as? String, "region")
    XCTAssertEqual(items[2]["type"] as? String, "choice")
    XCTAssertEqual(items[2]["choices"] as? [String], ["a", "b"])
    XCTAssertEqual(items[2]["other"] as? Bool, true)
    XCTAssertEqual(items[3]["default"] as? Int, 3)
    XCTAssertEqual(items[4]["mode"] as? String, "save")
    XCTAssertEqual(
      spec["actions"] as? [NSDictionary],
      [
        ["id": "deploy", "label": "Deploy", "role": "primary"],
        ["id": "cancel", "role": "cancel"],
      ] as [NSDictionary])
  }

  /// Catches a string accepted where a keyword belongs. Each closed-set word, each id, and each
  /// key spelled as a string refuses the spec before any call, and the error is the structure
  /// that names a refused spec.
  func testAStringWhereAKeywordBelongsRefusesTheSpecBeforeAnyCall() {
    let refused = [
      #"{:items [{:id "a" :text "x" :type :string}]}"#,
      #"{:items [{:id :a :text "x" :type "string"}]}"#,
      #"{:items [{:block "paragraph" :text "x"}]}"#,
      #"{:items [{:block :notice :level "info" :text "x"}]}"#,
      #"{:items [{:id :a :text "x" :type :file :mode "open"}]}"#,
      #"{:items [{:id :a :text "x" :type :string}] :actions [{:id :a :role "primary"}]}"#,
      #"{"items" [{:id :a :text "x" :type :string}]}"#,
      #"{:items [{"id" :a :text "x" :type :string}]}"#,
    ]

    for spec in refused {
      let host = host()

      assertRuns(
        """
        (def [ok failure] (protect (uniterm/ask \(spec))))
        (assert (not ok) "the spec was accepted")
        (assert (= (failure :kind) :bad-argument) (string "the kind was " (failure :kind)))
        (assert (string? (failure :message)))
        """, host: host)

      XCTAssertEqual(host.names, [], spec)
    }
  }

  /// Catches a keyword accepted as text. Text, choices, and string defaults stay strings, so a
  /// keyword in any of them refuses the spec. A table's pair keys stay strings too.
  func testAKeywordWhereTextBelongsRefusesTheSpec() {
    let refused = [
      "{:items [{:id :a :text :hello :type :string}]}",
      "{:items [{:id :a :text \"x\" :type :choice :choices [:a :b]}]}",
      "{:items [{:id :a :text \"x\" :type :string :default :d}]}",
      "{:items [{:block :table :rows {:Region \"x\"}}]}",
      "{:items [{:block :table :rows {\"Region\" :x}}]}",
      "{:title :t :items []}",
    ]

    for spec in refused {
      let host = host()

      assertRuns(
        """
        (def [ok failure] (protect (uniterm/ask \(spec))))
        (assert (not ok) "the spec was accepted")
        (assert (= (failure :kind) :bad-argument))
        """, host: host)

      XCTAssertEqual(host.names, [], spec)
    }
  }

  /// Catches a number written with more digits than it needs, which would make `multipleOf` of
  /// 0.1 reject 0.3 on the app's exact check. Each number is the shortest decimal that reads back
  /// as the same double.
  func testANumberIsTheShortestDecimalThatRoundTrips() throws {
    let host = host()

    assertRuns(
      """
      (uniterm/ask {:items [{:id :a :text "x" :type :number
                             :validate {:multipleOf 0.1 :minimum -2.5 :maximum 1e-7}
                             :default 3}
                            {:id :b :text "y" :type :number :default 123456789012345678}]})
      """, host: host)

    let text = try XCTUnwrap(host.specs.first)

    XCTAssertTrue(text.contains("\"multipleOf\":0.1"), text)
    XCTAssertFalse(text.contains("0.10000000000000001"), text)
    XCTAssertTrue(text.contains("\"minimum\":-2.5"), text)
    XCTAssertTrue(text.contains("\"maximum\":1e-07"), text)
    XCTAssertTrue(text.contains("\"default\":3,") || text.contains("\"default\":3}"), text)

    let spec = try object(text)
    let items = try XCTUnwrap(spec["items"] as? [NSDictionary])
    let validate = try XCTUnwrap(items[0]["validate"] as? NSDictionary)

    XCTAssertEqual(validate["multipleOf"] as? Double, 0.1)
    XCTAssertEqual(items[1]["default"] as? Double, 123_456_789_012_345_680)
  }

  /// Catches a value the converter cannot write reaching the app. A function, a number that is
  /// not finite, and a spec past the wire's size all refuse before a call.
  func testValuesThatCannotBeWrittenRefuseTheSpec() {
    let host = host()

    assertRuns(
      """
      (def big (string/repeat "x" 40000))
      (each spec [{:items [{:id :a :text print :type :string}]}
                  {:items [{:id :a :text "x" :type :number :default math/inf}]}
                  {:items [{:id :a :text big :type :string}]}
                  "not a struct"]
        (def [ok failure] (protect (uniterm/ask spec)))
        (assert (not ok) "a bad spec was accepted")
        (assert (= (failure :kind) :bad-argument) (string (failure :kind) ": " (failure :message))))
      """, host: host)

    XCTAssertEqual(host.names, [])
  }

  // MARK: Results

  /// Catches a result that spells its action as a string, or keys its answers by string. The
  /// result is a struct whose action and outcome are keywords and whose answers are keyed by the
  /// ids as keywords.
  func testTheResultSpellsActionAndOutcomeAsKeywords() {
    assertRuns(
      """
      (def result (uniterm/ask {:items [{:id :answer :text "x" :type :string}]}))
      (assert (= (result :action) :go) (string/format "%q" result))
      (assert (= (result :submission) 1))
      (assert (= (result :form) 5))
      (assert (= ((result :answers) :answer) "x"))
      (assert (= ((result :answers) :n) 3))
      """, host: host())

    assertRuns(
      """
      (def result (uniterm/ask {:items [{:id :a :text "x" :type :string}]}))
      (assert (= (result :outcome) :cancelled))
      (assert (= (result :action) :cancel))
      (assert (nil? (result :answers)))
      """,
      host: host(
        waiting: .value(
          .record([
            "form": .integer(5), "outcome": .string("cancelled"), "action": .string("cancel"),
          ]))))

    assertRuns(
      """
      (def result (uniterm/ask {:items [{:id :a :text "x" :type :string}]}))
      (assert (= (result :outcome) :dismissed))
      """,
      host: host(waiting: .value(.record(["form": .integer(5), "outcome": .string("dismissed")]))))
  }

  // MARK: Discard

  /// Catches a handle left behind. After a result, the helper discards the form. The REPL's next
  /// open-form would otherwise be busy.
  func testTheHandleIsDiscardedAfterAResult() {
    let host = host()

    assertRuns("(uniterm/ask {:items [{:id :a :text \"x\" :type :string}]})", host: host)

    XCTAssertEqual(host.names, ["open", "wait", "discard"])
    XCTAssertEqual(host.calls.last, .discardForm(form: 5))
  }

  /// Catches a handle left behind by an error. A wait that fails raises the failure as it was, and
  /// the handle is discarded first, for each kind a wait can fail with.
  func testTheHandleIsDiscardedWhenTheWaitFailsAndTheFailureIsRaisedAsItWas() {
    for (kind, name) in [
      (ScriptFailureKind.ended, "ended"), (.notFound, "not-found"), (.refused, "refused"),
      (.failed, "failed"),
    ] {
      let host = host(waiting: .failure(kind, "the app said \(name)"))

      assertRuns(
        """
        (def [ok failure] (protect (uniterm/ask {:items [{:id :a :text "x" :type :string}]})))
        (assert (not ok))
        (assert (= (failure :kind) :\(name)) (string/format "%q" failure))
        (assert (= (failure :message) "the app said \(name)"))
        """, host: host)

      XCTAssertEqual(host.names, ["open", "wait", "discard"], name)
    }
  }

  /// Catches a discard that fails and hides the error that mattered. The wait's failure is the one
  /// the script sees, and a discard that also fails changes nothing.
  func testADiscardThatFailsDoesNotHideTheWaitsFailure() {
    let host = Host { call in
      switch call {
      case .openForm: return .value(.integer(5))
      case .waitForm: return .failure(.ended, "the wait ended")
      default: return .failure(.notFound, "no such handle")
      }
    }

    assertRuns(
      """
      (def [ok failure] (protect (uniterm/ask {:items [{:id :a :text "x" :type :string}]})))
      (assert (= (failure :kind) :ended))
      (assert (= (failure :message) "the wait ended"))
      """, host: host)

    XCTAssertEqual(host.names, ["open", "wait", "discard"])

    let again = Host { call in
      switch call {
      case .openForm: return .value(.integer(5))
      case .waitForm: return .value(ScriptAskJanetTests.submitted)
      default: return .failure(.notFound, "no such handle")
      }
    }

    assertRuns(
      "(assert (struct? (uniterm/ask {:items [{:id :a :text \"x\" :type :string}]})))",
      host: again)
  }

  /// Catches a form that is not opened still discarding something, and a refused open leaving a
  /// call behind. A busy refusal raises the kind, and no wait or discard follows.
  func testARefusedOpenRaisesItsKindAndMakesNoOtherCall() {
    let host = Host { _ in .failure(.busy, "a form is open") }

    assertRuns(
      """
      (def [ok failure] (protect (uniterm/ask {:items [{:id :a :text "x" :type :string}]})))
      (assert (= (failure :kind) :busy))
      """, host: host)

    XCTAssertEqual(host.names, ["open"])
  }

  /// Catches an interrupt that raises an error a script can catch, or discards twice. A wait that
  /// an interrupt cut short returns nil, makes no discard of its own since the host already did,
  /// and the script is stopped by the interrupt and not by this return.
  func testAnInterruptedWaitReturnsNilAndLeavesTheDiscardToTheHost() {
    let host = host(waiting: .interrupted)

    assertRuns(
      "(assert (nil? (uniterm/ask {:items [{:id :a :text \"x\" :type :string}]})))", host: host)

    XCTAssertEqual(host.names, ["open", "wait"])
  }

  // MARK: Helpers

  /// Catches a module that the collector frees while the helpers are defined. Defining them runs
  /// Janet code, which can collect, and the module is held only by the shim until it is cached. A
  /// collection forced at that point must leave the module and every helper in it usable.
  func testACollectionWhileTheHelpersAreDefinedLeavesTheModuleIntact() {
    uniterm_janet_set_helper_gc_stress(1)

    defer { uniterm_janet_set_helper_gc_stress(0) }

    assertRuns(
      """
      (each name [uniterm/ask uniterm/ask-confirm uniterm/ask-text uniterm/ask-choose
                  uniterm/ask-number uniterm/ask-color uniterm/ask-file uniterm/post-status]
        (assert (or (function? name) (cfunction? name)) "a helper is not a function"))
      (gccollect)
      (assert (= (uniterm/api-version) 0))
      """, host: host())
  }

  /// Catches a shorthand that asks another question than its flags describe, or one that returns
  /// something other than the answer. Each helper's spec and return value are pinned.
  func testEachHelperAsksItsQuestionAndReturnsTheAnswer() throws {
    func answering(_ value: ScriptValue) -> Host {
      host(
        waiting: .value(
          .record([
            "form": .integer(5), "submission": .integer(1), "action": .string("ok"),
            "answers": .record(["answer": value]),
          ])))
    }

    let text = answering(.string("main"))

    assertRuns(
      """
      (assert (= (uniterm/ask-text "Branch?" :default "main" :pattern "^[a-z]+$") "main"))
      """, host: text)

    let textSpec = try object(try XCTUnwrap(text.specs.first))
    let question = try XCTUnwrap((textSpec["items"] as? [NSDictionary])?.first)

    XCTAssertEqual(question["id"] as? String, "answer")
    XCTAssertEqual(question["type"] as? String, "string")
    XCTAssertEqual(question["required"] as? Bool, true)
    XCTAssertEqual(question["default"] as? String, "main")
    XCTAssertEqual(question["validate"] as? NSDictionary, ["pattern": "^[a-z]+$"] as NSDictionary)

    let choose = answering(.array([.string("a"), .string("b")]))

    assertRuns(
      """
      (assert (deep= (uniterm/ask-choose "Which?" ["a" "b" "c"] :multiple true) @["a" "b"]))
      """, host: choose)

    let multi = try XCTUnwrap(
      (try object(try XCTUnwrap(choose.specs.first))["items"] as? [NSDictionary])?.first)

    XCTAssertEqual(multi["type"] as? String, "multi")
    XCTAssertEqual(multi["choices"] as? [String], ["a", "b", "c"])
    XCTAssertNil(multi["other"])

    let number = answering(.integer(7))

    assertRuns(
      "(assert (= (uniterm/ask-number \"N?\" :integer true :min 1 :max 20) 7))", host: number)

    let numberQuestion = try XCTUnwrap(
      (try object(try XCTUnwrap(number.specs.first))["items"] as? [NSDictionary])?.first)

    XCTAssertEqual(numberQuestion["type"] as? String, "integer")
    XCTAssertEqual(
      numberQuestion["validate"] as? NSDictionary, ["minimum": 1, "maximum": 20] as NSDictionary)

    let color = answering(.string("#ff0000ff"))

    assertRuns("(assert (= (uniterm/ask-color \"Color?\") \"#ff0000ff\"))", host: color)

    let file = answering(.string("/tmp/x.json"))

    assertRuns(
      """
      (assert (= (uniterm/ask-file "File?" :mode :directory :types ["public.json"]) "/tmp/x.json"))
      """, host: file)

    let fileQuestion = try XCTUnwrap(
      (try object(try XCTUnwrap(file.specs.first))["items"] as? [NSDictionary])?.first)

    XCTAssertEqual(fileQuestion["mode"] as? String, "directory")
    XCTAssertEqual(fileQuestion["types"] as? [String], ["public.json"])
  }

  /// Catches a confirm that says Yes for a No, or loses a close. Yes is true, the cancel button is
  /// false, and closing the form is nil, which the command's exit codes 0, 1, and 3 mirror.
  func testAConfirmReturnsTrueFalseOrNil() {
    let yes = host(
      waiting: .value(
        .record([
          "form": .integer(5), "submission": .integer(1), "action": .string("yes"),
          "answers": .record([:]),
        ])))
    let no = host(
      waiting: .value(
        .record(["form": .integer(5), "outcome": .string("cancelled"), "action": .string("no")])))
    let closed = host(
      waiting: .value(.record(["form": .integer(5), "outcome": .string("dismissed")])))

    assertRuns("(assert (= (uniterm/ask-confirm \"Delete?\") true))", host: yes)
    assertRuns("(assert (= (uniterm/ask-confirm \"Delete?\") false))", host: no)
    assertRuns("(assert (nil? (uniterm/ask-confirm \"Delete?\")))", host: closed)
  }

  /// Catches a helper that cancels as an answer. A cancelled or closed question returns nil.
  func testAQuestionTheUserCancelledReturnsNil() {
    assertRuns(
      "(assert (nil? (uniterm/ask-text \"x\")))",
      host: host(
        waiting: .value(
          .record(["form": .integer(5), "outcome": .string("cancelled"), "action": .string("c")]))))
  }

  /// Catches a helper that leaves the handle behind or hides a bad argument. A keyword prompt refuses
  /// before any call, and a multiple choice with an entry of the user's own is refused.
  func testHelpersRefuseBadArgumentsBeforeAnyCall() {
    let host = host()

    assertRuns(
      """
      (each f [(fn [] (uniterm/ask-text :prompt))
               (fn [] (uniterm/ask-choose "x" ["a"] :multiple true :other true))
               (fn [] (uniterm/ask-choose "x" [:a]))]
        (def [ok failure] (protect (f)))
        (assert (not ok))
        (assert (= (failure :kind) :bad-argument) (string/format "%q" failure)))
      """, host: host)

    XCTAssertEqual(host.names, [])
  }
}
