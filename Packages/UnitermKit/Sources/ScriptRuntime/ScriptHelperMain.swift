import CJanet
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
public enum ScriptHelperMain {
  /// Exit statuses follow sysexits.h where one fits.
  public enum Exit {
    public static let ok: Int32 = 0
    public static let scriptFailed: Int32 = 1
    public static let usage: Int32 = 64
    public static let noInput: Int32 = 66
    public static let unavailable: Int32 = 69
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

      Runs a Janet script against the running uniterm.

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

    let source: Data

    do {
      source = try Data(contentsOf: URL(fileURLWithPath: invocation.script))
    } catch {
      return fail(
        "cannot read \(invocation.script): \(error.localizedDescription)", status: Exit.noInput)
    }

    let name = URL(fileURLWithPath: invocation.script).lastPathComponent
    let session: ScriptSession

    do {
      session = try ScriptSession.open(path: address.path, name: name)
    } catch WireError.versionMismatch {
      return fail(ScriptProtocol.mismatchText, status: Exit.protocolMismatch)
    } catch WireError.io(let code) where Address.meansNobodyListens(code) {
      return fail(Address.unreachableText(address), status: Exit.unavailable)
    } catch WireError.io(let code) {
      return fail(
        "cannot reach uniterm at \(address.path): \(String(cString: strerror(code)))",
        status: Exit.unavailable)
    } catch WireError.closed {
      return fail(
        "uniterm at \(address.path) closed the connection before the script began",
        status: Exit.unavailable)
    } catch ScriptSessionError.failed(_, let text) {
      return fail(text, status: Exit.unavailable)
    } catch {
      return fail("cannot talk to uniterm at \(address.path): \(error)", status: Exit.unavailable)
    }

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

  private static func fail(_ message: String, status: Int32) -> Int32 {
    FileHandle.standardError.write(Data((message + "\n").utf8))

    return status
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
