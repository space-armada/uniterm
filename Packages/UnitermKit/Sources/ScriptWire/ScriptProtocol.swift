import Foundation
@_exported import HelperWire

/// What the protocol version and its sizes mean for both sides. A mismatch is refused before any
/// call runs.
///
/// The hello is one message with one field, in every version. A peer built against another
/// version can therefore always read the other's hello, and the refusal names the version.
///
/// The protocol is an external version. It is 0 and stays 0 until uniterm's maintainers declare it
/// version 1. At 0 a change lands in place, and nothing promises that an older program still
/// runs. A program's message is read with its old meaning or refused, never read under a new
/// meaning. Programs built for the versions that counted breaking revisions before this reset, 1
/// through 14, are refused at the hello.
///
/// A decoder refuses a message tag, a call tag, an enumerated value, or trailing bytes it does not
/// know, by name, and the text says to rebuild the program or update uniterm. A change of meaning
/// takes a new tag. A positional field has no name, so a field whose meaning changes takes a new
/// message tag, and the old tag goes into `ScriptRetiredNames`.
///
/// The bundled `uniterm` command and its REPL send their code identity right after the hello, and
/// before `begin` or `attach`. A program built against this library on its own sends none.
public enum ScriptProtocol {
  public static let version: UInt16 = 0

  /// What the user is told when the two sides name different versions. It names both and says how
  /// to fix either side. It never says to relaunch uniterm, since the identity check catches a
  /// command that comes from another build of this bundle. It never picks a remedy by comparing
  /// the numbers, since a program from before the reset names a version above this one.
  public static func versionMismatchText(program: UInt16, uniterm: UInt16) -> String {
    "The program speaks ScriptWire version \(program), and this uniterm speaks version "
      + "\(uniterm). \(ScriptRetiredNames.advice)"
  }

  /// The longest code identity the bundled command may present, in bytes. A code directory hash is
  /// 20 bytes today.
  public static let maxIdentityBytes = 64

  /// The largest body any message may declare. The reader checks it before it allocates.
  public static let maxControlBody = 64 * 1024

  /// The most clipboard text one typed clipboard call reads or writes, in UTF-8 bytes. A larger
  /// clipboard is refused, never cut.
  public static let maxClipboardBytes = 32 * 1024

  /// The size of a controller's version digest, a SHA-256.
  public static let versionDigestBytes = 32

  /// The longest script name a peer may announce, in UTF-8 bytes.
  public static let maxNameBytes = 128

  /// The most bytes of JSON one file declaration may hold. It leaves room in the control frame for
  /// the message's own header.
  public static let maxDeclarationBytes = 32 * 1024

  /// The longest status text a script may post, in UTF-8 bytes. It matches the host function's own
  /// check in the Janet shim.
  public static let maxStatusBytes = 2048

  /// The longest failure message a reply may carry, in UTF-8 bytes.
  public static let maxFailureBytes = 512

  /// The largest ID a script may hold. A Janet number is a double, so every ID below this value is
  /// an exact integer in it.
  public static let maxID: UInt64 = (1 << 53) - 1

  /// The longest applet kind a script may name, in UTF-8 bytes.
  public static let maxKindBytes = 32

  /// The longest applet command name a script may send, in UTF-8 bytes.
  public static let maxCommandNameBytes = 64

  /// The most bytes of JSON one applet command's arguments may hold. It leaves room in the control
  /// frame for the rest of the call.
  public static let maxCommandArgumentBytes = 32 * 1024

  /// The most bytes of JSON one layout request may hold. It leaves room in the control frame for
  /// the rest of the call.
  public static let maxLayoutBytes = 32 * 1024

  /// The largest major or minor of a command schema version a script may name.
  public static let maxSchemaVersion: UInt32 = 1 << 31 - 1

  /// The most bytes of JSON one form spec may hold. It leaves room in the control frame for the
  /// rest of the call, and it is the spec reader's own cap.
  public static let maxFormBytes = 32 * 1024

  /// The longest directory a script may name, in UTF-8 bytes. It matches the system's path limit.
  public static let maxDirectoryBytes = 1024

  /// The longest file name a script may give to content it sends, in UTF-8 bytes. It matches the
  /// system's file name limit.
  public static let maxFileNameBytes = 255

  /// The most content one send may carry, in bytes. A send is the only message with a larger
  /// frame, so the reader allocates this much only for a message of its own type.
  public static let maxSendBytes = 1024 * 1024

  /// The largest payload a reply may carry. It leaves room in the frame for the reply's header.
  public static let maxReplyPayload = maxControlBody - 1024

  /// The environment variable the app passes a REPL's token in. The helper reads it first and then
  /// drops the whole environment.
  public static let replTokenVariable = "UNITERM_REPL_TOKEN"

  /// The size of a REPL's token, in bytes. Every byte is random.
  public static let tokenBytes = 32

  /// The longest line a REPL reports or recalls, in UTF-8 bytes. Janet's line editor holds 1023
  /// bytes of a line, so a line it returns always fits.
  public static let maxReplLineBytes = 1024

  /// The most lines one history message may carry. The app splits a longer history across
  /// messages, so no message passes the control frame's size.
  public static let historyLinesPerMessage = 32

  /// The most lines of a restored history the helper keeps to recall. It is the line editor's own
  /// limit. The app sends no more than this across all of a history's messages, and the helper
  /// refuses a history that holds more.
  public static let recallLines = 100

  /// The most memory one helper's Janet VM may hold, in bytes. The helper's allocator enforces it.
  /// It matches `UNITERM_JANET_DEFAULT_MEMORY_CAP` in the Janet shim, which a test proves.
  public static let helperMemoryCap = 1 << 30

  /// How far past the cap a REPL helper's footprint may go before the app kills it. The cap counts
  /// only what Janet's allocator hands out, and the footprint counts everything the process holds.
  public static let footprintKillMargin = helperMemoryCap / 4
}

/// Which way a new pane splits the pane beside it.
public enum ScriptAxis: UInt8, Sendable, Equatable, CaseIterable {
  /// The panes sit side by side.
  case row = 1

  /// The panes are stacked.
  case column = 2
}

/// How a script names a pane, or one tab of it. Every number is an exact integer that fits in a
/// Janet number. The app finds the window, pane, and tab only while they are open in this launch.
public struct ScriptPaneReference: Sendable, Equatable {
  public var window: UInt64
  public var pane: UInt64
  public var tab: UInt64?

  public init(window: UInt64, pane: UInt64, tab: UInt64? = nil) {
    self.window = window
    self.pane = pane
    self.tab = tab
  }
}

/// The pane a call acts on: one a script names, or the nearest pane of an applet type to the
/// caller's own pane. The app resolves a nearest target when it runs the call, among the panes the
/// caller may control, and never opens one when none matches.
public enum ScriptTarget: Sendable, Equatable {
  case pane(ScriptPaneReference)

  /// The kind is an applet type, such as `browser`.
  case nearest(kind: String)
}

/// The access a pane a script opens starts with. A script can enable control only on a pane it
/// creates in its own group, never on a pane that exists.
public enum ScriptPaneAccess: UInt8, Sendable, Equatable, CaseIterable {
  case disconnected = 0
  case remoteControlled = 1
}

extension ByteWriter {
  mutating func put(target: ScriptTarget) {
    switch target {
    case .pane(let reference):
      put(UInt8(0))
      put(reference: reference)

    case .nearest(let kind):
      put(UInt8(1))
      put(string: kind, limit: ScriptProtocol.maxKindBytes)
    }
  }

  mutating func put(id: UInt64) {
    put(UInt32(truncatingIfNeeded: id >> 32))
    put(UInt32(truncatingIfNeeded: id))
  }

  mutating func put(reference: ScriptPaneReference) {
    put(id: reference.window)
    put(id: reference.pane)

    if let tab = reference.tab {
      put(UInt8(1))
      put(id: tab)
    } else {
      put(UInt8(0))
    }
  }

  /// The `--allow` names of a begin, at most `ControllerBegin.maxCapabilities` of them.
  mutating func put(capabilities: [String]) {
    put(UInt8(min(capabilities.count, ControllerBegin.maxCapabilities)))

    for name in capabilities.prefix(ControllerBegin.maxCapabilities) {
      put(string: name, limit: ControllerBegin.maxCapabilityBytes)
    }
  }

  /// A string that may be absent. A flag says which.
  mutating func put(optional text: String?, limit: Int) {
    guard let text else {
      put(UInt8(0))
      return
    }

    put(UInt8(1))
    put(string: text, limit: limit)
  }
}

extension ByteReader {
  /// An ID. One above `ScriptProtocol.maxID` cannot be a Janet integer, so the app never sees it
  /// from a helper that checks its arguments.
  mutating func id() throws -> UInt64 {
    let high = UInt64(try u32())
    let low = UInt64(try u32())
    let value = high << 32 | low

    guard value <= ScriptProtocol.maxID else {
      throw WireError.badValue("an ID is too large for a script number")
    }

    return value
  }

  mutating func reference() throws -> ScriptPaneReference {
    let window = try id()
    let pane = try id()

    let flag = try u8()

    switch flag {
    case 0: return ScriptPaneReference(window: window, pane: pane)
    case 1: return ScriptPaneReference(window: window, pane: pane, tab: try id())
    default: throw ScriptRetiredNames.unknownValue("a tab flag", flag)
    }
  }

  mutating func target() throws -> ScriptTarget {
    let form = try u8()

    switch form {
    case 0: return .pane(try reference())
    case 1: return .nearest(kind: try string(limit: ScriptProtocol.maxKindBytes))
    default: throw ScriptRetiredNames.unknownValue("a target form", form)
    }
  }

  /// JSON text with a 32-bit length before it. The length is checked against `limit` before any
  /// byte is read. `what` names the text in the error, such as "the layout is".
  mutating func json(limit: Int, what: String) throws -> String {
    let count = Int(try u32())

    guard count <= limit else { throw WireError.tooLong(declared: count, limit: limit) }

    guard remaining >= count else { throw WireError.truncated }

    var bytes = Data()

    for _ in 0..<count { bytes.append(try u8()) }

    guard let text = String(data: bytes, encoding: .utf8) else {
      throw WireError.badValue("\(what) not UTF-8")
    }

    return text
  }

  /// Exactly `count` bytes. A body that ends first is truncated, and one that goes on is refused
  /// as trailing bytes by the message's own check.
  mutating func bytes(count: Int) throws -> Data {
    guard remaining >= count else { throw WireError.truncated }

    var bytes = Data()

    for _ in 0..<count { bytes.append(try u8()) }

    return bytes
  }

  /// The `--allow` names of a begin: a count, then each name.
  mutating func capabilities() throws -> [String] {
    let count = Int(try u8())

    guard count <= ControllerBegin.maxCapabilities else {
      throw WireError.tooLong(declared: count, limit: ControllerBegin.maxCapabilities)
    }

    var names: [String] = []

    for _ in 0..<count {
      names.append(try string(limit: ControllerBegin.maxCapabilityBytes))
    }

    return names
  }

  mutating func optionalString(limit: Int) throws -> String? {
    let flag = try u8()

    switch flag {
    case 0: return nil
    case 1: return try string(limit: limit)
    default: throw ScriptRetiredNames.unknownValue("an optional-string flag", flag)
    }
  }
}

/// How serious a script's status message is.
public enum ScriptStatusLevel: UInt8, Sendable, Equatable, CaseIterable {
  case info = 0
  case warning = 1
  case error = 2
}

/// The command schema version a script was written for, as a major and a minor.
public struct ScriptSchemaVersion: Equatable, Sendable {
  public let major: UInt32
  public let minor: UInt32

  public init(major: UInt32, minor: UInt32 = 0) {
    self.major = major
    self.minor = minor
  }
}

/// A host function call. Each case is one function, named on the wire by a 16-bit code that never
/// changes meaning. A new function takes a new code and keeps the others.
public enum ScriptCall: Equatable, Sendable {
  case postStatus(level: ScriptStatusLevel, text: String)
  case listWindows
  case listPanes(window: UInt64)
  case openPane(
    kind: String, beside: ScriptTarget, axis: ScriptAxis?, directory: String?,
    access: ScriptPaneAccess)
  case openTab(pane: ScriptTarget, directory: String?)
  case send(pane: ScriptTarget, name: String, content: Data)

  /// One applet command for a pane. It names the applet type and the command schema version the
  /// script was written for, and the app refuses either when the pane does not support it. The
  /// arguments are a JSON object as text, which the app checks against the applet's schema.
  case sendCommand(
    pane: ScriptTarget, appletType: String, schemaVersion: ScriptSchemaVersion, command: String,
    arguments: String)

  /// A layout for the caller's subtree, anchored at a pane it may control. The layout is a JSON
  /// object as text, which the app parses and checks.
  case requestLayout(pane: ScriptTarget, layout: String)

  /// Reads the clipboard's plain text. It is a power of its own, which the user grants apart from
  /// pane control and apart from writes.
  case readClipboard

  /// Replaces the clipboard with plain text. It is a power of its own, apart from reads.
  case writeClipboard(text: String)

  /// Shows a form to the user, as JSON text that the app reads strictly. The reply is the form's
  /// handle at once. The answers wait under the handle for `waitForm`.
  case openForm(spec: String)

  /// Waits for a form's result. It only reads, so its reply may come later. Reading does not
  /// consume the result.
  case waitForm(form: UInt64)

  /// Frees a form's handle. A form still open closes as ended.
  case discardForm(form: UInt64)

  var code: UInt16 {
    switch self {
    case .postStatus: return 1
    case .listWindows: return 2
    case .listPanes: return 3
    case .openPane: return 4
    case .openTab: return 5
    case .send: return 6
    case .sendCommand: return 7
    case .requestLayout: return 8
    case .readClipboard: return 9
    case .writeClipboard: return 10
    case .openForm: return 11
    case .waitForm: return 12
    case .discardForm: return 13
    }
  }

  /// The code of the one call that carries content, and so has a frame of its own type.
  static let sendCode: UInt16 = 6

  func encode(into body: inout ByteWriter) {
    body.put(code)

    switch self {
    case .postStatus(let level, let text):
      body.put(level.rawValue)
      body.put(string: text, limit: ScriptProtocol.maxStatusBytes)

    case .listWindows:
      break

    case .listPanes(let window):
      body.put(id: window)

    case .openPane(let kind, let beside, let axis, let directory, let access):
      body.put(string: kind, limit: ScriptProtocol.maxKindBytes)
      body.put(target: beside)
      body.put(axis?.rawValue ?? 0)
      body.put(optional: directory, limit: ScriptProtocol.maxDirectoryBytes)
      body.put(access.rawValue)

    case .openTab(let pane, let directory):
      body.put(target: pane)
      body.put(optional: directory, limit: ScriptProtocol.maxDirectoryBytes)

    case .send(let pane, let name, let content):
      body.put(target: pane)
      body.put(string: name, limit: ScriptProtocol.maxFileNameBytes)
      body.put(raw: content)

    case .sendCommand(let pane, let type, let version, let command, let arguments):
      body.put(target: pane)
      body.put(string: type, limit: ScriptProtocol.maxKindBytes)
      body.put(version.major)
      body.put(version.minor)
      body.put(string: command, limit: ScriptProtocol.maxCommandNameBytes)
      let bytes = Data(arguments.utf8.prefix(ScriptProtocol.maxCommandArgumentBytes))

      body.put(UInt32(bytes.count))
      body.put(raw: bytes)

    case .requestLayout(let pane, let layout):
      body.put(target: pane)

      let bytes = Data(layout.utf8.prefix(ScriptProtocol.maxLayoutBytes))

      body.put(UInt32(bytes.count))
      body.put(raw: bytes)

    case .readClipboard:
      break

    case .writeClipboard(let text):
      body.put(string: text, limit: ScriptProtocol.maxClipboardBytes)

    case .openForm(let spec):
      let bytes = Data(spec.utf8.prefix(ScriptProtocol.maxFormBytes))

      body.put(UInt32(bytes.count))
      body.put(raw: bytes)

    case .waitForm(let form), .discardForm(let form):
      body.put(id: form)
    }
  }

  /// Public because the helper reads back the call its shim wrote, before it sends the call.
  public static func decode(
    from reader: inout ByteReader, retired: ScriptRetiredNames = .current
  ) throws -> ScriptCall {
    let callTag = try reader.u16()

    switch callTag {
    case 1:
      let levelByte = try reader.u8()

      guard let level = ScriptStatusLevel(rawValue: levelByte) else {
        throw ScriptRetiredNames.unknownValue("a status level", levelByte)
      }

      return .postStatus(
        level: level, text: try reader.string(limit: ScriptProtocol.maxStatusBytes))

    case 2:
      return .listWindows

    case 3:
      return .listPanes(window: try reader.id())

    case 4:
      let kind = try reader.string(limit: ScriptProtocol.maxKindBytes)
      let beside = try reader.target()
      let axisByte = try reader.u8()

      guard axisByte == 0 || ScriptAxis(rawValue: axisByte) != nil else {
        throw ScriptRetiredNames.unknownValue("a split axis", axisByte)
      }

      let directory = try reader.optionalString(limit: ScriptProtocol.maxDirectoryBytes)
      let accessByte = try reader.u8()

      guard let access = ScriptPaneAccess(rawValue: accessByte) else {
        throw ScriptRetiredNames.unknownValue("a pane access", accessByte)
      }

      return .openPane(
        kind: kind, beside: beside, axis: ScriptAxis(rawValue: axisByte), directory: directory,
        access: access)

    case 5:
      return .openTab(
        pane: try reader.target(),
        directory: try reader.optionalString(limit: ScriptProtocol.maxDirectoryBytes))

    case 6:
      let pane = try reader.target()
      let name = try reader.string(limit: ScriptProtocol.maxFileNameBytes)
      // The content is the rest of the body by design. Its size is the field's own bound.
      let content = reader.rest()

      guard content.count <= ScriptProtocol.maxSendBytes else {
        throw WireError.tooLong(declared: content.count, limit: ScriptProtocol.maxSendBytes)
      }

      return .send(pane: pane, name: name, content: content)

    case 7:
      let pane = try reader.target()
      let type = try reader.string(limit: ScriptProtocol.maxKindBytes)
      let major = try reader.u32()
      let minor = try reader.u32()

      guard major <= ScriptProtocol.maxSchemaVersion, minor <= ScriptProtocol.maxSchemaVersion
      else {
        throw WireError.badValue("a schema version is too large")
      }

      let command = try reader.string(limit: ScriptProtocol.maxCommandNameBytes)
      let arguments = try reader.json(
        limit: ScriptProtocol.maxCommandArgumentBytes, what: "the arguments are")

      return .sendCommand(
        pane: pane, appletType: type,
        schemaVersion: ScriptSchemaVersion(major: major, minor: minor), command: command,
        arguments: arguments)

    case 8:
      let pane = try reader.target()
      let layout = try reader.json(limit: ScriptProtocol.maxLayoutBytes, what: "the layout is")

      return .requestLayout(pane: pane, layout: layout)

    case 9:
      return .readClipboard

    case 10:
      return .writeClipboard(text: try reader.string(limit: ScriptProtocol.maxClipboardBytes))

    case 11:
      return .openForm(
        spec: try reader.json(limit: ScriptProtocol.maxFormBytes, what: "the form spec is"))

    case 12:
      return .waitForm(form: try reader.id())

    case 13:
      return .discardForm(form: try reader.id())

    default:
      throw retired.refusal(callTag: callTag)
    }
  }
}

/// Why a call did not succeed. The kind lets a script tell its own mistake from a refusal.
public enum ScriptFailureKind: UInt8, Sendable, Equatable, CaseIterable {
  /// The call's arguments are not acceptable.
  case badArgument = 1

  /// The app declined the call, such as for a missing window.
  case refused = 2

  /// The app failed while it ran the call.
  case failed = 3

  /// The window, pane, or tab the call names is not open in this launch. It may have closed, or
  /// the reference may come from an earlier launch. The text never names another pane.
  case notFound = 4

  /// The pane runs another applet type than the call names, or does not support the command
  /// schema version it names. Nothing ran.
  case unsupported = 5

  /// The applet command ran, and its reply could not be sent to the script. The command's effect
  /// stands, so the script must not take this for a refusal.
  case replyLost = 6

  /// The app is still working on another call of the same kind from this caller, such as a layout
  /// it is preparing. Nothing ran, and the call may be sent again once the other one is answered.
  case busy = 7

  /// The form ended before the user answered it: the run ended, the program's authority ended, or
  /// the form was discarded. Nothing was submitted.
  case ended = 8
}

/// The app's answer to one call.
public enum ScriptResult: Equatable, Sendable {
  /// The call ran. The payload is the function's result, which is empty for a function that
  /// returns nothing.
  case ok(Data)

  case failure(ScriptFailureKind, String)
}

/// A run of a controller package, which the bundle's own command asks the app to admit. It names
/// the package by path and nothing else. The app reads, verifies, and copies the package itself, so
/// a digest or a name the peer could claim never reaches it.
public struct ControllerBegin: Equatable, Sendable {
  public enum Entry: UInt8, Sendable, Equatable, CaseIterable {
    /// The command runs the package's Janet entry in its own VM, once the app admits it.
    case janet = 1

    /// The command execs the package's native entry from the app's snapshot.
    case native = 2
  }

  /// The most capabilities one run may ask for, and the longest name of one.
  public static let maxCapabilities = 32
  public static let maxCapabilityBytes = 32

  public let entry: Entry

  /// The package folder's absolute path, with every link resolved by the command.
  public let package: String

  /// The Janet capabilities the user granted the run with `--allow`. Each must be one the
  /// descriptor declares.
  public let capabilities: [String]

  public init(entry: Entry, package: String, capabilities: [String] = []) {
    self.entry = entry
    self.package = package
    self.capabilities = capabilities
  }
}

/// A run of a declared script file, which the bundle's own command asks the app to admit. It names
/// the file by its resolved path and nothing else. The app reads and copies the file itself, so a
/// digest or a name the peer could claim never reaches it. What the file declares comes later, in
/// a declaration the command reads from the app's copy.
public struct FileBegin: Equatable, Sendable {
  /// The file's absolute path, with every link resolved by the command.
  public let path: String

  /// The Janet capabilities the user granted the run with `--allow`. Each must be one the
  /// declaration lists.
  public let capabilities: [String]

  public init(path: String, capabilities: [String] = []) {
    self.path = path
    self.capabilities = capabilities
  }
}

/// A run of a script file that declares nothing, which the bundle's own command asks the app to
/// admit. The command runs the file itself, so only a name and the `--allow` capabilities go to
/// the app. Nothing runs until the app answers.
public struct UndeclaredBegin: Equatable, Sendable {
  /// The script's file name, which labels its messages and its review.
  public let name: String

  /// The Janet capabilities the user granted the run with `--allow`. Nothing declares them, so the
  /// review only lists them.
  public let capabilities: [String]

  public init(name: String, capabilities: [String] = []) {
    self.name = name
    self.capabilities = capabilities
  }
}

/// A `uniterm open` command, which asks the app to route files to panes. It carries absolute paths
/// and nothing else. The command resolves a relative argument against its own working directory
/// first, and never looks at a target, so the app sees only the names the user typed.
///
/// A path is never cut to fit, since a cut path names another file. The command refuses a path or a
/// count that does not fit, and the reader refuses a frame that holds one.
public struct OpenBegin: Equatable, Sendable {
  /// The most paths one command may name.
  public static let maxPaths = 256

  /// The most bytes all the paths of one command may hold together. It leaves room in the control
  /// frame for the count and each path's length.
  public static let maxPathBytes = 48 * 1024

  public let paths: [String]

  public init(paths: [String]) {
    self.paths = paths
  }

  /// Why a list of paths cannot be sent, or nil when it can. Each path must be absolute, hold no
  /// NUL, and fit the path limit. The list must not be empty.
  public static func problem(with paths: [String]) -> String? {
    guard !paths.isEmpty else { return "no path was given" }

    guard paths.count <= maxPaths else {
      return "\(paths.count) paths is more than the \(maxPaths) one command may open"
    }

    var total = 0

    for path in paths {
      guard path.hasPrefix("/") else { return "a path is not absolute" }

      guard !path.utf8.contains(0) else { return "a path holds a NUL byte" }

      guard path.utf8.count <= ScriptProtocol.maxDirectoryBytes else {
        return "a path is longer than \(ScriptProtocol.maxDirectoryBytes) bytes"
      }

      total += path.utf8.count
    }

    guard total <= maxPathBytes else {
      return "the paths hold more than \(maxPathBytes) bytes together"
    }

    return nil
  }
}

/// A message from a script helper. The app validates each one and trusts none of them.
public enum ScriptHelperMessage: Equatable, Sendable {
  case hello(version: UInt16)

  /// Names the script, or the REPL, that the connection serves. The name labels the script's
  /// messages in the status bar.
  case begin(name: String)

  /// A host function call. The reply carries the same request ID.
  case request(id: UInt32, call: ScriptCall)

  /// A REPL helper presents its single-use token. It comes after the hello and the identity, in
  /// place of `begin`, and names the REPL pane the connection serves.
  case attach(token: Data)

  /// The code directory hash of the bundled command that sent it. The bundled command and its REPL
  /// send it right after the hello, and before `begin`, `attach`, or any other declaration. The
  /// app refuses the other order by name. The app compares the hash with the one it kept for its
  /// own command at launch. A program built against this library on its own sends none, and the
  /// app admits it as before. The message keeps one form in every version.
  case identity(codeDirectoryHash: Data)

  /// A line the user entered in the REPL, reported before it is evaluated. The app keeps its own
  /// copy of the history from these.
  case replLine(String)

  /// Whether the REPL is evaluating a form now. The app asks it before it closes the pane.
  case replEvaluating(Bool)

  /// The answer to the app's ping. The helper's watchdog thread sends it, never the VM thread, so
  /// a busy VM still answers.
  case pong(UInt32)

  /// The helper's allocator is about to end the process for passing its memory cap. The helper
  /// writes this frame itself, in one write, before it exits.
  case memoryLimit

  /// Declares the connection a controller run, in place of `begin`. The app answers with
  /// `controllerAdmitted` or `controllerRefused`, and no call is answered before that.
  case controllerBegin(ControllerBegin)

  /// Declares the connection a run of a declared script file, in place of `begin`. The app answers
  /// with `fileAdmitted` or `controllerRefused`, and no call is answered before the run is
  /// admitted.
  case fileBegin(FileBegin)

  /// What the file's first form declares, read by the command from the app's copy and converted to
  /// the descriptor's permission structure as JSON text. It follows `fileAdmitted`, and only once.
  case fileDeclaration(String)

  /// Declares the connection a run of a script file that declares nothing, in place of `begin`.
  /// The app answers with `undeclaredAdmitted` or `controllerRefused`, and may first say the run
  /// waits for review. No call is answered before the run is admitted.
  case undeclaredBegin(UndeclaredBegin)

  /// Declares the connection a `uniterm open` command, in place of `begin`. The app answers with
  /// `openDone` or `controllerRefused`, and may first say the request waits for the user. The
  /// connection makes no call.
  case openBegin(OpenBegin)

  /// Declares the connection a question-only session, in place of `begin`. The command runs no
  /// script code, so the session may make only the three form calls. The app answers with
  /// `questionOnlyAdmitted` or `controllerRefused`, and no call is answered before that.
  case questionBegin

  /// The frame type of the one call that carries content.
  static let sendType: UInt8 = 4

  /// Whether the message tells the app what the connection is: a script, a REPL, a controller run,
  /// a file, an open, or a question session. The identity message must come before one.
  public var declaresRole: Bool {
    switch self {
    case .begin, .attach, .controllerBegin, .fileBegin, .undeclaredBegin, .openBegin,
      .questionBegin:
      return true

    default:
      return false
    }
  }

  /// Whether the message is a REPL's token, which the app answers with `attachRefused`.
  public var isAttach: Bool {
    if case .attach = self { return true }

    return false
  }

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .begin: return 2
    case .request(_, let call):
      if case .send = call { return Self.sendType }

      return 3
    case .attach: return 5
    case .replLine: return 6
    case .replEvaluating: return 7
    case .pong: return 8
    case .memoryLimit: return 9
    case .controllerBegin: return 10
    case .fileBegin: return 11
    case .fileDeclaration: return 12
    case .undeclaredBegin: return 13
    case .openBegin: return 14
    case .questionBegin: return 15
    case .identity: return 16
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)

    case .begin(let name): body.put(string: name, limit: ScriptProtocol.maxNameBytes)

    case .pong(let nonce): body.put(nonce)

    case .memoryLimit, .questionBegin: break

    case .controllerBegin(let begin):
      body.put(begin.entry.rawValue)
      body.put(string: begin.package, limit: ScriptProtocol.maxDirectoryBytes)
      body.put(capabilities: begin.capabilities)

    case .fileBegin(let begin):
      body.put(string: begin.path, limit: ScriptProtocol.maxDirectoryBytes)
      body.put(capabilities: begin.capabilities)

    case .fileDeclaration(let json):
      let bytes = Data(json.utf8.prefix(ScriptProtocol.maxDeclarationBytes))

      body.put(UInt32(bytes.count))
      body.put(raw: bytes)

    case .undeclaredBegin(let begin):
      body.put(string: begin.name, limit: ScriptProtocol.maxNameBytes)
      body.put(capabilities: begin.capabilities)

    case .openBegin(let begin):
      // Nothing is cut or dropped. A list or a path that does not fit makes a frame the reader
      // refuses, so the app never opens a different set of files than the user named.
      body.put(UInt16(clamping: begin.paths.count))

      for path in begin.paths {
        let bytes = Data(path.utf8)
        let fits = bytes.count <= ScriptProtocol.maxDirectoryBytes

        body.put(UInt16(fits ? bytes.count : 0))
        body.put(raw: fits ? bytes : Data())
      }

    case .attach(let token): body.put(raw: token)

    case .identity(let hash):
      body.put(UInt8(min(hash.count, ScriptProtocol.maxIdentityBytes)))
      body.put(raw: hash.prefix(ScriptProtocol.maxIdentityBytes))

    case .replLine(let text): body.put(string: text, limit: ScriptProtocol.maxReplLineBytes)

    case .replEvaluating(let running): body.put(running ? UInt8(1) : UInt8(0))

    case .request(let id, let call):
      body.put(id)
      call.encode(into: &body)
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  /// The most body bytes a message of `type` may declare.
  public static func bodyLimit(type: UInt8) -> Int {
    type == sendType
      ? ScriptProtocol.maxSendBytes + ScriptProtocol.maxControlBody : ScriptProtocol.maxControlBody
  }

  /// Decodes one frame. A tag this build does not know, a value it does not know, and bytes after
  /// a message's last field are refused by name. `retired` is only a test's to change.
  public static func decode(
    type: UInt8, body: Data, retired: ScriptRetiredNames = .current
  ) throws -> ScriptHelperMessage {
    do {
      return try decodeKnown(type: type, body: body, retired: retired)
    } catch WireError.trailingBytes {
      throw ScriptRetiredNames.trailingBytes(in: name(ofType: type), from: .helper)
    }
  }

  /// What a frame type is called in an error. A type this build does not know is only a number.
  static func name(ofType type: UInt8) -> String {
    switch type {
    case 1: return "hello"
    case 2: return "begin"
    case 3, sendType: return "call"
    case 5: return "attach"
    case 6: return "REPL line"
    case 7: return "REPL evaluating"
    case 8: return "pong"
    case 9: return "memory limit"
    case 10: return "controller begin"
    case 11: return "file begin"
    case 12: return "file declaration"
    case 13: return "undeclared begin"
    case 14: return "open begin"
    case 15: return "question begin"
    case 16: return "identity"
    default: return "tag \(type)"
    }
  }

  private static func decodeKnown(
    type: UInt8, body: Data, retired: ScriptRetiredNames
  ) throws -> ScriptHelperMessage {
    var reader = ByteReader(body)
    let message: ScriptHelperMessage

    switch type {
    case 1:
      let version = try reader.u16()

      // A hello of another version is not read past its version field. It may hold fields this
      // build does not know, and the refusal names the versions instead.
      guard version == ScriptProtocol.version else { return .hello(version: version) }

      message = .hello(version: version)

    case 2: message = .begin(name: try reader.string(limit: ScriptProtocol.maxNameBytes))

    case 3, sendType:
      let id = try reader.u32()
      let call = try ScriptCall.decode(from: &reader, retired: retired)

      var isSend = false

      if case .send = call { isSend = true }

      guard isSend == (type == sendType) else {
        throw WireError.badValue("a call is in a frame of the wrong type")
      }

      message = .request(id: id, call: call)

    case 5:
      message = .attach(token: try reader.bytes(count: ScriptProtocol.tokenBytes))

    case 6: message = .replLine(try reader.string(limit: ScriptProtocol.maxReplLineBytes))

    case 7:
      switch try reader.u8() {
      case 0: message = .replEvaluating(false)
      case 1: message = .replEvaluating(true)
      default: throw WireError.badValue("an evaluating flag is not 0 or 1")
      }

    case 8: message = .pong(try reader.u32())

    case 9: message = .memoryLimit

    case 10:
      let entryByte = try reader.u8()

      guard let entry = ControllerBegin.Entry(rawValue: entryByte) else {
        throw ScriptRetiredNames.unknownValue("a controller entry kind", entryByte)
      }

      let package = try reader.string(limit: ScriptProtocol.maxDirectoryBytes)
      let capabilities = try reader.capabilities()

      message = .controllerBegin(
        ControllerBegin(entry: entry, package: package, capabilities: capabilities))

    case 11:
      let path = try reader.string(limit: ScriptProtocol.maxDirectoryBytes)
      let capabilities = try reader.capabilities()

      message = .fileBegin(FileBegin(path: path, capabilities: capabilities))

    case 12:
      message = .fileDeclaration(
        try reader.json(limit: ScriptProtocol.maxDeclarationBytes, what: "the declaration is"))

    case 13:
      let name = try reader.string(limit: ScriptProtocol.maxNameBytes)
      let capabilities = try reader.capabilities()

      message = .undeclaredBegin(UndeclaredBegin(name: name, capabilities: capabilities))

    case 14:
      let count = Int(try reader.u16())

      guard count <= OpenBegin.maxPaths else {
        throw WireError.tooLong(declared: count, limit: OpenBegin.maxPaths)
      }

      var paths: [String] = []
      var total = 0

      for _ in 0..<count {
        let path = try reader.string(limit: ScriptProtocol.maxDirectoryBytes)

        total += path.utf8.count

        guard total <= OpenBegin.maxPathBytes else {
          throw WireError.tooLong(declared: total, limit: OpenBegin.maxPathBytes)
        }

        paths.append(path)
      }

      if let problem = OpenBegin.problem(with: paths) {
        throw WireError.badValue("an open begin is not acceptable: \(problem)")
      }

      message = .openBegin(OpenBegin(paths: paths))

    case 15: message = .questionBegin

    case 16:
      let count = Int(try reader.u8())

      guard (1...ScriptProtocol.maxIdentityBytes).contains(count) else {
        throw WireError.badValue(
          "a code identity is not 1 to \(ScriptProtocol.maxIdentityBytes) bytes")
      }

      message = .identity(codeDirectoryHash: try reader.bytes(count: count))

    default: throw retired.refusal(messageTag: type, from: .helper)
    }

    try reader.finished()

    return message
  }

  /// What the app checks of the helper's hello.
  public static func validateHello(_ message: ScriptHelperMessage) throws {
    guard case .hello(let version) = message else {
      throw WireError.badValue("the helper did not start with a hello")
    }

    guard version == ScriptProtocol.version else {
      throw WireError.versionMismatch(found: version, expected: ScriptProtocol.version)
    }
  }
}

/// A message from the app. The helper validates each one.
public enum ScriptAppMessage: Equatable, Sendable {
  case hello(version: UInt16)

  case reply(id: UInt32, result: ScriptResult)

  /// The app turned a REPL's token away. The text says why, and the helper shows it and ends.
  case attachRefused(String)

  /// Lines of history for the REPL's line editor to recall, oldest first. The helper never
  /// evaluates them. The last message of a history has `final` set, and an empty history is one
  /// empty message with it set, so the helper always knows the app accepted its token.
  case history(lines: [String], final: Bool)

  /// A liveness probe. The helper's watchdog thread answers with a pong that carries the same
  /// nonce, whatever the VM thread is doing.
  case ping(UInt32)

  /// The user asked to stop what the helper is running. The watchdog thread carries it out by
  /// signalling the VM thread, which interrupts the form the way Ctrl-C does. It changes nothing
  /// when no form is running.
  case stop

  /// The app verified the controller and admitted the run. `snapshot` is the folder of the run's
  /// private copy, and `version` the SHA-256 of its descriptor. The command loads only what that
  /// folder holds, and only when its descriptor has that digest.
  case controllerAdmitted(snapshot: String, version: Data)

  /// The app refused the run. The text says why, and the command shows it and runs nothing.
  case controllerRefused(String)

  /// The run waits for the user's review of its requested powers. The command shows the text and
  /// keeps waiting for the admission or the refusal. It may come once, before either.
  case controllerReviewing(String)

  /// The app read the file, made its private copy, and waits for the declaration. `snapshot` is the
  /// copy's path, and `version` the SHA-256 of the whole file. The command reads the copy once,
  /// checks its hash against `version`, and only then parses it.
  case fileAdmitted(snapshot: String, version: Data)

  /// The app admitted a script file that declares nothing. The command runs it now.
  case undeclaredAdmitted

  /// The app took a `uniterm open` request. It says nothing about the files: a file that is
  /// missing, one no applet opens, and one that opened all get this same reply, and it carries no
  /// content. Whatever went wrong shows only in the app's own status message. A request the user
  /// did not allow gets `controllerRefused` instead.
  case openDone

  /// The app authenticated the command and admitted its question-only session. The command may
  /// make form calls now.
  case questionOnlyAdmitted

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .reply: return 2
    case .attachRefused: return 3
    case .history: return 4
    case .ping: return 5
    case .stop: return 6
    case .controllerAdmitted: return 7
    case .controllerRefused: return 8
    case .controllerReviewing: return 9
    case .fileAdmitted: return 10
    case .undeclaredAdmitted: return 11
    case .openDone: return 12
    case .questionOnlyAdmitted: return 13
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)

    case .reply(let id, let result):
      body.put(id)

      switch result {
      case .ok(let payload):
        body.put(UInt8(0))
        body.put(raw: payload)

      case .failure(let kind, let text):
        body.put(kind.rawValue)
        body.put(string: text, limit: ScriptProtocol.maxFailureBytes)
      }

    case .attachRefused(let text):
      body.put(string: text, limit: ScriptProtocol.maxFailureBytes)

    case .ping(let nonce): body.put(nonce)

    case .stop, .undeclaredAdmitted, .openDone, .questionOnlyAdmitted: break

    case .controllerAdmitted(let snapshot, let version), .fileAdmitted(let snapshot, let version):
      body.put(string: snapshot, limit: ScriptProtocol.maxDirectoryBytes)
      body.put(raw: version.prefix(ScriptProtocol.versionDigestBytes))

    case .controllerRefused(let text), .controllerReviewing(let text):
      body.put(string: text, limit: ScriptProtocol.maxFailureBytes)

    case .history(let lines, let final):
      body.put(final ? UInt8(1) : UInt8(0))
      body.put(UInt16(min(lines.count, ScriptProtocol.historyLinesPerMessage)))

      for line in lines.prefix(ScriptProtocol.historyLinesPerMessage) {
        body.put(string: line, limit: ScriptProtocol.maxReplLineBytes)
      }
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  public static func bodyLimit(type: UInt8) -> Int {
    ScriptProtocol.maxControlBody
  }

  /// Decodes one frame. A tag this build does not know, a value it does not know, and bytes after
  /// a message's last field are refused by name. `retired` is only a test's to change.
  public static func decode(
    type: UInt8, body: Data, retired: ScriptRetiredNames = .current
  ) throws -> ScriptAppMessage {
    do {
      return try decodeKnown(type: type, body: body, retired: retired)
    } catch WireError.trailingBytes {
      throw ScriptRetiredNames.trailingBytes(in: name(ofType: type), from: .app)
    }
  }

  /// What a frame type is called in an error. A type this build does not know is only a number.
  static func name(ofType type: UInt8) -> String {
    switch type {
    case 1: return "hello"
    case 2: return "reply"
    case 3: return "attach refused"
    case 4: return "history"
    case 5: return "ping"
    case 6: return "stop"
    case 7: return "controller admitted"
    case 8: return "controller refused"
    case 9: return "controller reviewing"
    case 10: return "file admitted"
    case 11: return "undeclared admitted"
    case 12: return "open done"
    case 13: return "question-only admitted"
    default: return "tag \(type)"
    }
  }

  private static func decodeKnown(
    type: UInt8, body: Data, retired: ScriptRetiredNames
  ) throws -> ScriptAppMessage {
    var reader = ByteReader(body)

    switch type {
    case 1:
      let version = try reader.u16()

      // A hello of another version is not read past its version field. It may hold fields this
      // build does not know, and the refusal names the versions instead.
      if version == ScriptProtocol.version { try reader.finished() }

      return .hello(version: version)

    case 2:
      let id = try reader.u32()
      let status = try reader.u8()

      if status == 0 {
        // The payload is the rest of the body by design. The call's own decoder reads it strictly.
        return .reply(id: id, result: .ok(reader.rest()))
      }

      guard let kind = ScriptFailureKind(rawValue: status) else {
        throw ScriptRetiredNames.unknownValue("a failure kind", status, from: .app)
      }

      let text = try reader.string(limit: ScriptProtocol.maxFailureBytes)
      try reader.finished()

      return .reply(id: id, result: .failure(kind, text))

    case 3:
      let text = try reader.string(limit: ScriptProtocol.maxFailureBytes)
      try reader.finished()

      return .attachRefused(text)

    case 4:
      let final: Bool

      switch try reader.u8() {
      case 0: final = false
      case 1: final = true
      default: throw WireError.badValue("a history flag is not 0 or 1")
      }

      let count = Int(try reader.u16())

      guard count <= ScriptProtocol.historyLinesPerMessage else {
        throw WireError.tooLong(declared: count, limit: ScriptProtocol.historyLinesPerMessage)
      }

      var lines: [String] = []

      for _ in 0..<count {
        lines.append(try reader.string(limit: ScriptProtocol.maxReplLineBytes))
      }

      try reader.finished()

      return .history(lines: lines, final: final)

    case 5:
      let nonce = try reader.u32()
      try reader.finished()

      return .ping(nonce)

    case 6:
      try reader.finished()

      return .stop

    case 7:
      let snapshot = try reader.string(limit: ScriptProtocol.maxDirectoryBytes)
      let version = try reader.bytes(count: ScriptProtocol.versionDigestBytes)
      try reader.finished()

      return .controllerAdmitted(snapshot: snapshot, version: version)

    case 8:
      let text = try reader.string(limit: ScriptProtocol.maxFailureBytes)
      try reader.finished()

      return .controllerRefused(text)

    case 9:
      let text = try reader.string(limit: ScriptProtocol.maxFailureBytes)
      try reader.finished()

      return .controllerReviewing(text)

    case 10:
      let snapshot = try reader.string(limit: ScriptProtocol.maxDirectoryBytes)
      let version = try reader.bytes(count: ScriptProtocol.versionDigestBytes)
      try reader.finished()

      return .fileAdmitted(snapshot: snapshot, version: version)

    case 11:
      try reader.finished()

      return .undeclaredAdmitted

    case 12:
      try reader.finished()

      return .openDone

    case 13:
      try reader.finished()

      return .questionOnlyAdmitted

    default:
      throw retired.refusal(messageTag: type, from: .app)
    }
  }

  /// What the helper checks of the app's hello.
  public static func validateHello(_ message: ScriptAppMessage) throws {
    guard case .hello(let version) = message else {
      throw WireError.badValue("the app did not start with a hello")
    }

    guard version == ScriptProtocol.version else {
      throw WireError.versionMismatch(found: version, expected: ScriptProtocol.version)
    }
  }
}
