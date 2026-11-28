import CJanet
import ControllerPackage
import Foundation
import ScriptWire

/// Compares a script file's literal calls into the `uniterm` module with the powers it declares.
///
/// The lint reads the file with Janet's own parser and evaluates nothing. It is best effort and
/// grants nothing. It walks the forms, tracks which names stand for the module, and counts each
/// reference to a module function as a use of that function's power. Anything that can reach a
/// module function without a literal name is reported as able to make any call.
///
/// Known limits: a name bound by `match` or `case` patterns is not seen as a local binding, a
/// file the script imports is not scanned, and a reference through a layout `:exec` is found only
/// inside a direct `request-layout` call.
enum ScriptLint {
  struct Finding: Equatable {
    enum Kind: Equatable {
      case undeclaredPower
      case unusedPower
      case dynamicCall
      case unknownFunction
    }

    let line: Int
    let column: Int
    let kind: Kind
    let message: String
  }

  enum Outcome: Equatable {
    case report(findings: [Finding], suggestion: String?)

    /// The file cannot be linted. The text says why and where.
    case unreadable(String)
  }

  static func lint(_ source: Data) -> Outcome {
    var forms = uniterm_forms()

    defer { uniterm_janet_free_forms(&forms) }

    let status = source.withUnsafeBytes { raw in
      uniterm_janet_parse_forms(
        raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &forms)
    }

    guard status == UNITERM_FORMS_OK else {
      let text = withUnsafeBytes(of: forms.message) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      let position =
        forms.error_line > 0 ? "line \(forms.error_line), column \(forms.error_column): " : ""

      return .unreadable("\(position)\(text)")
    }

    let roots = Form.build(forms)
    var declared: Set<String> = []
    var declarationAt = (line: 1, column: 1)
    var declares = false

    switch DeclaredScript.read(source) {
    case .undeclared:
      break

    case .invalid(let text):
      return .unreadable(text)

    case .declared(let json):
      do {
        let declaration = try FileDeclaration.parse(json)

        declared = Set(declaration.permissions.map(\.kind.name))
        declares = true

        if let first = roots.first { declarationAt = (first.line, first.column) }
      } catch {
        return .unreadable("the declaration is not one uniterm reads: \(error)")
      }
    }

    var walker = Walker(moduleFunctions: Self.moduleFunctions())

    walker.collectImports(roots)
    walker.walk(roots)

    return walker.report(declared: declared, declares: declares, declarationAt: declarationAt)
  }

  static func moduleFunctions() -> [String] {
    var names: [String] = []
    var index = 0

    while let name = uniterm_janet_module_function(index) {
      names.append(String(cString: name))
      index += 1
    }

    return names
  }

  // MARK: Forms

  struct Form {
    enum Kind {
      case symbol, keyword, string, atom, paren, bracket, array, structure, table
    }

    let kind: Kind
    let text: String
    let line: Int
    let column: Int
    var children: [Form]

    var isSequence: Bool { kind == .paren || kind == .bracket || kind == .array }

    var isTuple: Bool { kind == .paren || kind == .bracket }

    func isSymbol(_ name: String) -> Bool { kind == .symbol && text == name }

    /// True when a struct or table inside the form has `name` as a key, spelled as a keyword or as
    /// a string. The layout reader takes either, and a value that happens to be `:name` is not a
    /// key.
    func hasKey(_ name: String) -> Bool {
      if kind == .structure || kind == .table {
        for (index, child) in children.enumerated() where index % 2 == 0 {
          if (child.kind == .keyword || child.kind == .string) && child.text == name { return true }
        }
      }

      return children.contains { $0.hasKey(name) }
    }

    static func build(_ forms: uniterm_forms) -> [Form] {
      var cursor = 0
      var roots: [Form] = []

      for _ in 0..<forms.root_count {
        roots.append(read(forms, &cursor))
      }

      return roots
    }

    private static func read(_ forms: uniterm_forms, _ cursor: inout Int) -> Form {
      let node = forms.nodes[cursor]

      cursor += 1

      let kind: Kind

      switch Int(node.kind) {
      case Int(UNITERM_FORM_SYMBOL.rawValue): kind = .symbol
      case Int(UNITERM_FORM_KEYWORD.rawValue): kind = .keyword
      case Int(UNITERM_FORM_STRING.rawValue): kind = .string
      case Int(UNITERM_FORM_PAREN.rawValue): kind = .paren
      case Int(UNITERM_FORM_BRACKET.rawValue): kind = .bracket
      case Int(UNITERM_FORM_ARRAY.rawValue): kind = .array
      case Int(UNITERM_FORM_STRUCT.rawValue): kind = .structure
      case Int(UNITERM_FORM_TABLE.rawValue): kind = .table
      default: kind = .atom
      }

      var text = ""

      if node.text_length > 0, let base = forms.text {
        text = String(
          decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(base + node.text_offset).assumingMemoryBound(to: UInt8.self),
            count: node.text_length), as: UTF8.self)
      }

      var children: [Form] = []

      for _ in 0..<Int(node.children) {
        children.append(read(forms, &cursor))
      }

      return Form(
        kind: kind, text: text, line: Int(node.line), column: Int(node.column), children: children)
    }
  }

  // MARK: Walking

  /// Names that reach module functions, or any code, without a literal name.
  private static let dynamicNames: Set<String> = [
    "eval", "eval-string", "compile", "run-context", "dofile", "load-image", "unmarshal",
    "require", "import*", "symbol", "keyword", "curenv", "make-env", "env-lookup", "root-env",
    "fiber/getenv", "fiber/setenv", "resolve", "module/cache", "module/paths", "module/loaders",
    "module/find", "module/value", "parse", "parse-all", "parser/new", "parser/clone",
    "parser/consume", "parser/produce", "parser/eof", "parser/flush", "parser/has-more",
    "parser/state", "parser/status", "parser/where", "parser/byte", "parser/error",
    "parser/insert", "parser/trace",
  ]

  private static let loopVerbs: Set<String> = [
    ":in", ":keys", ":pairs", ":range", ":range-to", ":down", ":down-to", ":iterate", ":generate",
  ]

  struct Use {
    let written: String
    let call: ScriptCallKind?
    let name: String
    let line: Int
    let column: Int
  }

  struct Walker {
    let moduleFunctions: [String]
    var prefixes: [String] = []
    var scopes: [Set<String>] = [[]]
    var macroDepth = 0
    var uses: [Use] = []
    var layoutExecs: [(written: String, line: Int, column: Int)] = []
    var dynamic: [(reason: String, line: Int, column: Int)] = []
    var unknown: [(written: String, line: Int, column: Int)] = []

    init(moduleFunctions: [String]) {
      self.moduleFunctions = moduleFunctions
    }

    // MARK: Imports

    /// Finds every `uniterm` import before the walk, so a use that precedes its import is still
    /// resolved. Quoted data is skipped.
    mutating func collectImports(_ forms: [Form]) {
      for form in forms { collectImports(form) }
    }

    private mutating func collectImports(_ form: Form) {
      guard form.isSequence || form.kind == .structure || form.kind == .table else { return }

      if form.kind == .paren, let head = form.children.first, head.kind == .symbol {
        if head.text == "quote" { return }

        if let imported = importedPrefixes(form) {
          prefixes.append(contentsOf: imported)

          return
        }
      }

      for child in form.children { collectImports(child) }
    }

    /// The prefixes a module form gives the `uniterm` module, or nil when the form is not an
    /// import. An import of another module gives an empty list. A path that is not a literal, or
    /// an import whose prefix is given two ways, is recorded as a dynamic finding by the walk.
    private func importedPrefixes(_ form: Form) -> [String]? {
      let head = form.children[0].text
      let arguments = Array(form.children.dropFirst())

      switch head {
      case "use":
        return arguments.contains { Self.moduleName($0) == "uniterm" } ? [""] : []

      case "import", "import*":
        guard let path = arguments.first, let name = Self.moduleName(path, in: head),
          name == "uniterm"
        else { return [] }

        var alias: String?
        var prefix: String?
        var index = 1

        while index + 1 < arguments.count {
          let key = arguments[index]
          let value = arguments[index + 1]

          if key.kind == .keyword, key.text == "as", value.kind == .symbol || value.kind == .string
          {
            alias = value.text + "/"
          } else if key.kind == .keyword, key.text == "prefix", value.kind == .string {
            prefix = value.text
          }

          index += 2
        }

        if alias != nil, prefix != nil { return [] }

        return [prefix ?? alias ?? "uniterm/"]

      default:
        return nil
      }
    }

    /// The module a path form names. The `import` and `use` macros take the name as a symbol or a
    /// string, and the `import*` function takes a string, since a symbol there is a variable.
    private static func moduleName(_ form: Form, in head: String = "import") -> String? {
      if form.kind == .string { return form.text }

      return form.kind == .symbol && head != "import*" ? form.text : nil
    }

    // MARK: Scope

    private func isBound(_ name: String) -> Bool {
      scopes.contains { $0.contains(name) }
    }

    private mutating func bind(_ name: String) {
      scopes[scopes.count - 1].insert(name)
    }

    private mutating func bindPattern(_ pattern: Form) {
      switch pattern.kind {
      case .symbol:
        if !pattern.text.hasPrefix("&") { bind(pattern.text) }

      case .paren, .bracket, .array:
        for child in pattern.children { bindPattern(child) }

      case .structure, .table:
        for (index, child) in pattern.children.enumerated() where index % 2 == 1 {
          bindPattern(child)
        }

      default:
        break
      }
    }

    private mutating func scoped(_ body: (inout Walker) -> Void) {
      scopes.append([])
      body(&self)
      scopes.removeLast()
    }

    // MARK: Walking

    mutating func walk(_ forms: [Form]) {
      for form in forms { walk(form) }
    }

    mutating func walk(_ form: Form) {
      switch form.kind {
      case .symbol:
        reference(form)

      case .keyword, .string, .atom:
        break

      case .bracket, .array, .structure, .table:
        for child in form.children { walk(child) }

      case .paren:
        walkCall(form)
      }
    }

    private mutating func walkCall(_ form: Form) {
      guard let head = form.children.first else { return }

      let arguments = Array(form.children.dropFirst())

      guard head.kind == .symbol, !isBound(head.text) else {
        for child in form.children { walk(child) }

        return
      }

      switch head.text {
      case "quote":
        if macroDepth > 0, let quoted = arguments.first { walkTemplate(quoted) }

      case "quasiquote":
        if let quoted = arguments.first { walkTemplate(quoted) }

      case "declare-permissions", "comment":
        break

      case "import", "use", "import*":
        walkImport(form)

      case "def", "var", "def-", "var-":
        if let value = arguments.last, arguments.count > 1 { walk(value) }
        if let pattern = arguments.first { bindPattern(pattern) }

      case "fn":
        var rest = arguments[...]
        var selfName: Form?

        if let first = rest.first, first.kind == .symbol {
          selfName = first
          rest = rest.dropFirst()
        }

        walkFunction(Array(rest), selfName: selfName, isMacro: false)

      case "defn", "defn-", "defmacro", "defmacro-":
        if let name = arguments.first, name.kind == .symbol { bind(name.text) }

        walkFunction(
          Array(arguments.dropFirst()), selfName: nil, isMacro: head.text.hasPrefix("defmacro"))

      case "do":
        scoped { $0.walk(arguments) }

      case "let":
        walkLet(arguments)

      case "if-let", "when-let":
        walkLet(arguments)

      case "with", "if-with":
        walkWith(arguments)

      case "each", "eachk", "eachp":
        walkEach(arguments)

      case "for":
        walkFor(arguments)

      case "loop", "seq", "catseq", "generate":
        walkLoop(arguments)

      case "try":
        walkTry(arguments)

      case "dyn":
        walkDyn(form, arguments)

      default:
        if resolve(head.text) == "request-layout", form.hasKey("exec") {
          layoutExecs.append((head.text, head.line, head.column))
        }

        for child in form.children { walk(child) }
      }
    }

    private mutating func walkImport(_ form: Form) {
      let head = form.children[0].text
      let arguments = Array(form.children.dropFirst())

      if head == "use" {
        for argument in arguments where Self.moduleName(argument) == nil {
          noteDynamic("a use of a module whose name is computed", at: argument)
        }

        return
      }

      guard let path = arguments.first, let name = Self.moduleName(path, in: head) else {
        noteDynamic("an import of a module whose name is computed", at: form)

        return
      }

      if name == "uniterm" {
        var hasAlias = false
        var hasPrefix = false

        for (index, argument) in arguments.enumerated() where argument.kind == .keyword {
          let value = index + 1 < arguments.count ? arguments[index + 1] : nil

          if argument.text == "as" { hasAlias = true }
          if argument.text == "prefix" { hasPrefix = true }

          if let value, value.kind != .symbol, value.kind != .string {
            noteDynamic("an import of uniterm whose name or prefix is computed", at: value)
          }
        }

        if hasAlias && hasPrefix {
          noteDynamic("an import of uniterm with both :as and :prefix", at: form)
        }
      }
    }

    private mutating func walkTemplate(_ form: Form) {
      switch form.kind {
      case .symbol:
        if macroDepth > 0 { reference(form) }

      case .paren:
        if let head = form.children.first, head.isSymbol("unquote") || head.isSymbol("splice") {
          for child in form.children.dropFirst() { walk(child) }
        } else {
          for child in form.children { walkTemplate(child) }
        }

      case .bracket, .array, .structure, .table:
        for child in form.children { walkTemplate(child) }

      default:
        break
      }
    }

    private mutating func walkFunction(_ rest: [Form], selfName: Form?, isMacro: Bool) {
      guard let position = rest.firstIndex(where: { $0.isTuple }) else {
        for argument in rest { walk(argument) }

        return
      }

      if isMacro { macroDepth += 1 }

      scoped {
        if let selfName { $0.bind(selfName.text) }

        $0.bindPattern(rest[position])

        for argument in rest[(position + 1)...] { $0.walk(argument) }
      }

      if isMacro { macroDepth -= 1 }
    }

    private mutating func bindSequentially(_ bindings: Form) {
      var index = 0

      while index + 1 < bindings.children.count {
        walk(bindings.children[index + 1])
        bindPattern(bindings.children[index])

        index += 2
      }
    }

    private mutating func walkLet(_ arguments: [Form]) {
      guard let bindings = arguments.first, bindings.isTuple else {
        for argument in arguments { walk(argument) }

        return
      }

      scoped {
        $0.bindSequentially(bindings)

        for argument in arguments.dropFirst() { $0.walk(argument) }
      }
    }

    private mutating func walkWith(_ arguments: [Form]) {
      guard let bindings = arguments.first, bindings.isTuple, let name = bindings.children.first
      else {
        for argument in arguments { walk(argument) }

        return
      }

      for child in bindings.children.dropFirst() { walk(child) }

      scoped {
        $0.bindPattern(name)

        for argument in arguments.dropFirst() { $0.walk(argument) }
      }
    }

    private mutating func walkEach(_ arguments: [Form]) {
      guard arguments.count >= 2 else {
        for argument in arguments { walk(argument) }

        return
      }

      walk(arguments[1])

      scoped {
        $0.bindPattern(arguments[0])

        for argument in arguments.dropFirst(2) { $0.walk(argument) }
      }
    }

    private mutating func walkFor(_ arguments: [Form]) {
      guard arguments.count >= 3 else {
        for argument in arguments { walk(argument) }

        return
      }

      walk(arguments[1])
      walk(arguments[2])

      scoped {
        $0.bindPattern(arguments[0])

        for argument in arguments.dropFirst(3) { $0.walk(argument) }
      }
    }

    private mutating func walkLoop(_ arguments: [Form]) {
      guard let clauses = arguments.first, clauses.isTuple else {
        for argument in arguments { walk(argument) }

        return
      }

      scoped {
        var pending: [Form] = []
        var index = 0

        while index < clauses.children.count {
          let clause = clauses.children[index]

          if clause.kind == .keyword, ScriptLint.loopVerbs.contains(":" + clause.text) {
            index += 1

            if index < clauses.children.count { $0.walk(clauses.children[index]) }
            for pattern in pending { $0.bindPattern(pattern) }

            pending = []
          } else if clause.kind == .keyword, clause.text == "let" {
            index += 1

            if index < clauses.children.count { $0.bindSequentially(clauses.children[index]) }
          } else if clause.kind == .keyword {
            index += 1

            if index < clauses.children.count { $0.walk(clauses.children[index]) }
          } else {
            pending.append(clause)
          }

          index += 1
        }

        for argument in arguments.dropFirst() { $0.walk(argument) }
      }
    }

    private mutating func walkTry(_ arguments: [Form]) {
      guard let body = arguments.first else { return }

      walk(body)

      guard arguments.count > 1 else { return }

      let handler = arguments[1]

      guard handler.isTuple, let names = handler.children.first else {
        walk(handler)

        return
      }

      scoped {
        $0.bindPattern(names)

        for child in handler.children.dropFirst() { $0.walk(child) }
      }
    }

    private mutating func walkDyn(_ form: Form, _ arguments: [Form]) {
      if let key = arguments.first, key.kind == .keyword, key.text != "current-env",
        key.text != "env"
      {
        for argument in arguments.dropFirst() { walk(argument) }

        return
      }

      noteDynamic("dyn with a computed key or the environment", at: form)

      for argument in arguments { walk(argument) }
    }

    // MARK: References

    private mutating func noteDynamic(_ reason: String, at form: Form) {
      dynamic.append((reason, form.line, form.column))
    }

    private mutating func reference(_ symbol: Form) {
      let name = symbol.text

      if isBound(name) { return }

      if ScriptLint.dynamicNames.contains(name) {
        noteDynamic("\(name) can reach any function", at: symbol)

        return
      }

      if name == "dyn" {
        noteDynamic("dyn used as a value can reach the environment", at: symbol)

        return
      }

      switch lookup(name) {
      case .function(let function):
        uses.append(
          Use(
            written: name, call: ScriptCallKind.named(function), name: function,
            line: symbol.line, column: symbol.column))

      case .unknown:
        unknown.append((name, symbol.line, symbol.column))

      case .none:
        break
      }
    }

    private enum Lookup {
      case function(String)
      case unknown
      case none
    }

    private func lookup(_ name: String) -> Lookup {
      for prefix in prefixes where name.hasPrefix(prefix) {
        let function = String(name.dropFirst(prefix.count))

        if moduleFunctions.contains(function) { return .function(function) }

        if !prefix.isEmpty, !function.isEmpty { return .unknown }
      }

      return .none
    }

    private func resolve(_ name: String) -> String? {
      guard !isBound(name), case .function(let function) = lookup(name) else { return nil }

      return function
    }

    // MARK: Report

    func report(
      declared: Set<String>, declares: Bool, declarationAt: (line: Int, column: Int)
    ) -> Outcome {
      var findings: [Finding] = []
      var needed: Set<String> = []
      var used: Set<String> = []
      var usesLayout = false
      var usesCommand = false

      for use in uses {
        if use.call == .requestLayout { usesLayout = true }

        if use.call == .sendCommand { usesCommand = true }

        guard let power = use.call?.power ?? ScriptHelperFunctions.power(of: use.name) else {
          continue
        }

        used.insert(power.rawValue)

        guard !declared.contains(power.rawValue) else { continue }

        needed.insert(power.rawValue)

        let reason =
          declares ? "which the file does not declare" : "and the file declares nothing"

        findings.append(
          Finding(
            line: use.line, column: use.column, kind: .undeclaredPower,
            message: "\(use.written) needs \(power.rawValue), \(reason)"))
      }

      for exec in layoutExecs where !declared.contains("host-launch") {
        findings.append(
          Finding(
            line: exec.line, column: exec.column, kind: .undeclaredPower,
            message: "\(exec.written) with :exec needs host-launch, which the file does not "
              + "declare"))
      }

      for call in dynamic {
        findings.append(
          Finding(
            line: call.line, column: call.column, kind: .dynamicCall,
            message: "\(call.reason), so the file could make any call. The lint cannot say which "
              + "declared powers go unused"))
      }

      for function in unknown {
        findings.append(
          Finding(
            line: function.line, column: function.column, kind: .unknownFunction,
            message: "\(function.written) is not a function uniterm offers"))
      }

      if dynamic.isEmpty {
        for kind in declared.sorted() where kind != "capability" {
          // A path-read or browser power is used by a command, whose arguments may name a path or
          // an address. A layout may carry a seed URL. The lint cannot see either schema, so a
          // file that sends any command or layout may use them.
          let isUsed =
            switch kind {
            case "host-launch": usesLayout
            case "path-read", "browser-read": usesCommand
            case "browser-navigation": usesCommand || usesLayout
            default: used.contains(kind)
            }

          if !isUsed {
            findings.append(
              Finding(
                line: declarationAt.line, column: declarationAt.column, kind: .unusedPower,
                message: "the file declares \(kind) but never uses it"))
          }
        }
      }

      findings.sort { ($0.line, $0.column, $0.message) < ($1.line, $1.column, $1.message) }

      var suggestion: String?

      if !declares, !needed.isEmpty {
        let list = needed.sorted().map { "{:kind :\($0)}" }.joined(separator: " ")

        suggestion = "add (declare-permissions \(list)) as the file's first form"
      }

      return .report(findings: findings, suggestion: suggestion)
    }
  }
}
