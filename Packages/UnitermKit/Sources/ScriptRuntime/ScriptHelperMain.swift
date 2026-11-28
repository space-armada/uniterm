import CJanet
import ControllerPackage
import Darwin
import Foundation
import ScriptWire

/// The helper's entry point. The shipped command and the test helper both call it from a thin
/// `main`.
///
/// The `run` mode is `run [--allow CAP]... [--socket PATH] file.janet [arguments]`. The script runs
/// in this process, against the app that listens at the address. Its output, input, arguments,
/// working directory, and exit status are this process's own.
///
/// The `repl` mode is `repl --socket PATH`, which only the app starts. See `ScriptReplMain`.
///
/// The `open` mode asks the app to open files in panes. See `ScriptOpenCommand`.
///
/// The `ask` mode shows the user a form and prints the answer. See `ScriptAskCommand`.
public enum ScriptHelperMain {
  /// Exit statuses follow sysexits.h where one fits.
  public enum Exit {
    public static let ok: Int32 = 0
    public static let scriptFailed: Int32 = 1
    public static let usage: Int32 = 64
    public static let dataError: Int32 = 65
    public static let noInput: Int32 = 66
    public static let unavailable: Int32 = 69

    /// `uniterm ask`: the user cancelled the form or closed it.
    public static let cancelled: Int32 = 3

    /// `uniterm ask`: the form ended before the user answered it.
    public static let formEnded: Int32 = 4

    /// `uniterm ask`: uniterm holds as many forms from this program as it may.
    public static let busy: Int32 = 75

    /// The app was reached and refused the run: strict mode, a rejected review, a denial, or a
    /// power the file did not declare. A caller that retries on `unavailable` must not retry this.
    public static let refused: Int32 = 77
    public static let protocolMismatch: Int32 = 70
    public static let connectionLost: Int32 = 74
    public static let notBundleCommand: Int32 = 78

    /// A script that took more memory than the cap. Sysexits names nothing for it.
    public static let memoryLimit = Int32(UNITERM_JANET_EXIT_MEMORY_LIMIT)

    /// A run that Ctrl-C stopped, as a shell reports a process that died of SIGINT.
    public static let interrupted = Int32(UNITERM_JANET_EXIT_INTERRUPTED)
  }

  /// Makes the allocator's cap smaller, so a test reaches it with a small script. Debug builds only,
  /// since a cap is not a setting. It takes a number of bytes.
  static let memoryCapFlag = "--memory-cap"

  /// Whether the command insists on being the one inside a uniterm bundle.
  public enum Identity: Sendable {
    /// The shipped command. It refuses to run from anywhere but the bundle's own path.
    case bundle

    /// The package tests' twin, which SwiftPM builds outside any bundle. Only its own `main`
    /// chooses this, so nothing a user sets can turn the check off.
    case unchecked
  }

  /// The environment variable that names the address when no flag does. A test instance has an
  /// address of its own, and this is how a test points the command at it.
  public static let addressVariable = "UNITERM_SOCKET"

  static var usageText: String {
    let grantable = ScriptCapabilities.grantable.joined(separator: ", ")
    let always = ScriptCapabilities.alwaysAllowed.joined(separator: ", ")

    return """
      usage: uniterm run [--allow CAPABILITY]... [--socket PATH] file.janet [argument...]
             uniterm run [--allow CAPABILITY]... [--socket PATH] package [argument...]
             uniterm lint file.janet
             uniterm open [--socket PATH] [--] path...
             uniterm ask --help
             uniterm controller --help

      Runs a Janet script against the running uniterm. Given a controller package's folder, it
      runs the package's Janet entry from uniterm's verified copy of the package, and each
      --allow must name a capability the package's controller.json declares.

      A file whose first form is (declare-permissions ...) declares the powers it needs. uniterm
      shows them for review, then runs its own copy of the file with no import of any other file.
      Each --allow must name a capability the declaration lists.

      A file that declares nothing is refused while uniterm's Script files setting is Strict, which
      is the default. In Unsafe mode, uniterm asks you about it each time before it runs.

        --allow CAPABILITY  let the script use a capability. Repeat it to allow more. The
                            names are Janet's own, and each is denied by default.
        --socket PATH       connect to the uniterm at PATH, which wins over UNITERM_SOCKET.
        -h, --help          show this text.

      Capabilities that --allow can grant:
        \(grantable)

      Capabilities every script has, which --allow refuses because it would grant nothing:
        \(always)

      The script reads its arguments with (dyn :args), its own path first.
      """
  }

  public static func run(
    arguments: [String], identity: Identity = .bundle,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Int32 {
    if identity == .bundle,
      let refusal = ScriptCommandLocation.refusal(
        forResolved: ScriptCommandLocation.currentExecutablePath())
    {
      return fail(refusal, status: Exit.notBundleCommand)
    }

    if arguments.dropFirst().first == "repl" {
      return ScriptReplMain.run(arguments: Array(arguments.dropFirst(2)))
    }

    if arguments.dropFirst().first == "lint" {
      return ScriptLintCommand.run(arguments: Array(arguments.dropFirst(2)))
    }

    if arguments.dropFirst().first == "open" {
      return ScriptOpenCommand.run(
        arguments: Array(arguments.dropFirst(2)), environment: environment)
    }

    if arguments.dropFirst().first == "ask" {
      return ScriptAskCommand.run(
        arguments: Array(arguments.dropFirst(2)), environment: environment)
    }

    if arguments.dropFirst().first == "controller" {
      return ControllerCommands.run(
        arguments: Array(arguments.dropFirst(2)), environment: environment)
    }

    #if DEBUG
      var arguments = arguments

      if let refusal = takeMemoryCap(from: &arguments) {
        return fail(refusal, status: Exit.usage)
      }
    #endif

    let invocation: Invocation

    switch Invocation.parse(Array(arguments.dropFirst())) {
    case .help:
      print(usageText)

      return Exit.ok

    case .usage(let problem):
      return fail("\(problem)\n\(usageText)", status: Exit.usage)

    case .run(let parsed):
      invocation = parsed
    }

    let denied: UInt32

    do {
      denied = try ScriptCapabilities.denied(granting: invocation.allowed)
    } catch {
      return fail("\(error)", status: Exit.usage)
    }

    let address: Address

    do {
      address = try Address.resolve(socket: invocation.socket, environment: environment)
    } catch {
      return fail("\(error)", status: Exit.unavailable)
    }

    if ControllerCommands.isPackage(invocation.script) {
      return ControllerCommands.runJanet(
        package: invocation.script, allowed: invocation.allowed, denied: denied,
        arguments: invocation.arguments, address: address, environment: environment)
    }

    let source: Data

    do {
      source = try readScript(at: invocation.script)
    } catch {
      return fail(
        "cannot read \(invocation.script): \(error.localizedDescription)", status: Exit.noInput)
    }

    switch DeclaredScript.read(source) {
    case .declared:
      return DeclaredFileCommands.run(
        script: invocation.script, allowed: invocation.allowed, denied: denied,
        arguments: invocation.arguments, address: address)

    case .invalid(let text):
      return fail("\(invocation.script): \(text)", status: Exit.dataError)

    case .undeclared:
      break
    }

    let name = URL(fileURLWithPath: invocation.script).lastPathComponent
    let session: ScriptSession

    do {
      session = try ScriptSession.openUndeclared(
        path: address.path, begin: UndeclaredBegin(name: name, capabilities: invocation.allowed))
    } catch {
      return connectionFailure(error, address: address)
    }

    uniterm_janet_block_sigint()

    let watchdog = ScriptWatchdog.start(
      reading: session, onStop: { uniterm_janet_request_interrupt() },
      onHangup: { ScriptSession.endHelper(ScriptSession.appQuitText, flushingOutput: false) })

    defer {
      watchdog.finish()
      session.close()
    }

    let script = [invocation.script] + invocation.arguments

    uniterm_janet_enable_run_sigint()

    guard
      let failure = ScriptVM.run(
        name: name, source: source, session: session, sandbox: denied, arguments: script)
    else { return Exit.ok }

    return fail(
      failure.description,
      status: failure.kind == .interrupted ? Exit.interrupted : Exit.scriptFailed)
  }

  /// Reads an undeclared script until end of file. A pipe, such as process substitution names, has
  /// no size to ask for up front, so the read cannot be one whole-file call. It stops past the
  /// same cap a declared file has.
  static func readScript(at path: String) throws -> Data {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))

    defer { try? handle.close() }

    var data = Data()

    while let chunk = try handle.read(upToCount: 1 << 16), !chunk.isEmpty {
      data.append(chunk)

      if data.count > DeclaredFileSnapshot.maxBytes {
        throw ScriptReadError.tooLarge(DeclaredFileSnapshot.maxBytes)
      }
    }

    return data
  }

  #if DEBUG
    /// Removes `--memory-cap BYTES` when it comes right after `run`, so a script's own arguments
    /// never carry it. Returns a message when the value is not a positive number.
    static func takeMemoryCap(from arguments: inout [String]) -> String? {
      guard arguments.count > 1, arguments[1] == "run", arguments.count > 2,
        arguments[2] == memoryCapFlag
      else { return nil }

      guard arguments.count > 3, let bytes = UInt64(arguments[3]), bytes > 0 else {
        return "\(memoryCapFlag) needs a number of bytes"
      }

      arguments.removeSubrange(2...3)
      uniterm_janet_set_memory_cap(bytes)

      return nil
    }
  #endif

  /// The message and exit status for a connection that did not open, or a run the app refused.
  static func connectionFailure(_ error: any Error, address: Address) -> Int32 {
    switch error {
    case WireError.versionMismatch(let found, let expected):
      return fail(
        ScriptProtocol.versionMismatchText(program: expected, uniterm: found),
        status: Exit.protocolMismatch)

    case WireError.notRecognized(let text):
      return fail(text, status: Exit.protocolMismatch)

    case WireError.io(let code) where Address.meansNobodyListens(code):
      return fail(Address.unreachableText(address), status: Exit.unavailable)

    case WireError.io(let code):
      return fail(
        "cannot reach uniterm at \(address.path): \(String(cString: strerror(code)))",
        status: Exit.unavailable)

    case WireError.closed:
      return fail(
        "uniterm at \(address.path) closed the connection before the script began",
        status: Exit.unavailable)

    case ScriptSessionError.failed(_, let text):
      return fail(text, status: Exit.refused)

    case ScriptSessionError.foreignSocket(let path):
      return fail("the socket at \(path) belongs to another user", status: Exit.unavailable)

    default:
      return fail(
        "cannot talk to uniterm at \(address.path): \(scriptWireText(error))",
        status: Exit.unavailable)
    }
  }

  static func fail(_ message: String, status: Int32) -> Int32 {
    _ = writeAll(Data((message + "\n").utf8), to: STDERR_FILENO)

    return status
  }

  /// Writes every byte to `descriptor` with POSIX `write`, which reports a closed pipe as an error
  /// code. `FileHandle.write` raises an Objective-C exception for it, and that ends the process
  /// with an abort when SIGPIPE is ignored. Returns the error code, or nil when all was written.
  static func writeAll(_ data: Data, to descriptor: Int32) -> Int32? {
    var offset = 0

    while offset < data.count {
      let written = data.withUnsafeBytes { buffer in
        write(descriptor, buffer.baseAddress! + offset, data.count - offset)
      }

      if written < 0 {
        if errno == EINTR { continue }

        return errno
      }

      offset += written
    }

    return nil
  }

  /// Where the command connects.
  struct Address: Equatable {
    let path: String

    /// True for the well-known address, which the command checks before it connects.
    let isWellKnown: Bool

    struct NotFound: Error, CustomStringConvertible {
      let text: String

      var description: String { text }
    }

    /// The flag wins over the environment, and the environment wins over the well-known address.
    /// An empty value counts as not set. The well-known address comes from the home folder in the
    /// user database, never from `HOME`.
    static func resolve(
      socket flag: String?, environment: [String: String],
      home: String? = ScriptAddress.homeDirectory()
    ) throws -> Address {
      if let flag, !flag.isEmpty { return Address(path: flag, isWellKnown: false) }

      if let variable = environment[ScriptHelperMain.addressVariable], !variable.isEmpty {
        return Address(path: variable, isWellKnown: false)
      }

      guard let home else {
        throw NotFound(text: "cannot find your home folder, so cannot find uniterm")
      }

      let path = ScriptAddress.wellKnownPath(home: home)

      // A missing file, another user's file, or a link says there is no app. The command never
      // connects to any of them.
      guard ScriptAddress.isOwnSocket(path: path) else {
        throw NotFound(text: unreachableText(Address(path: path, isWellKnown: true)))
      }

      return Address(path: path, isWellKnown: true)
    }

    /// True for the errors that mean no process listens at the address.
    static func meansNobodyListens(_ code: Int32) -> Bool {
      code == ENOENT || code == ECONNREFUSED || code == ENOTDIR
    }

    static func unreachableText(_ address: Address) -> String {
      "no uniterm is reachable at \(address.path). Start uniterm and run the script again."
    }
  }

  struct Invocation: Equatable {
    var allowed: [String] = []
    var socket: String?
    var script = ""
    var arguments: [String] = []

    enum Parsed: Equatable {
      case run(Invocation)
      case help
      case usage(String)
    }

    /// Everything after the script's file belongs to the script.
    static func parse(_ arguments: [String]) -> Parsed {
      guard let first = arguments.first else { return .usage("a command is needed") }

      if first == "-h" || first == "--help" { return .help }

      guard first == "run" else { return .usage("unknown command \"\(first)\"") }

      var invocation = Invocation()
      var index = 1

      while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "-h", "--help":
          return .help

        case "--allow", "--socket":
          guard index + 1 < arguments.count else { return .usage("\(argument) needs a value") }

          let value = arguments[index + 1]

          if argument == "--allow" {
            invocation.allowed.append(value)
          } else {
            invocation.socket = value
          }

          index += 2

        default:
          guard !argument.hasPrefix("-") else {
            return .usage("unknown option \(argument)")
          }

          invocation.script = argument
          invocation.arguments = Array(arguments[(index + 1)...])

          return .run(invocation)
        }
      }

      return .usage("a script file is needed")
    }
  }
}

/// Why an undeclared script could not be read.
enum ScriptReadError: LocalizedError {
  case tooLarge(Int)

  var errorDescription: String? {
    switch self {
    case .tooLarge(let limit): return "the script is larger than \(limit) bytes"
    }
  }
}
