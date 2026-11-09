import Darwin
import Foundation
import ScriptWire

/// The helper's entry point. The shipped command and the test helper both call it from a thin
/// `main`.
///
/// The one mode is `run --socket PATH file.janet`. The script runs in this process, against the
/// app that listens at PATH. Its output, input, and exit status are this process's own.
public enum ScriptHelperMain {
  /// Exit statuses follow sysexits.h where one fits.
  public enum Exit {
    public static let ok: Int32 = 0
    public static let scriptFailed: Int32 = 1
    public static let usage: Int32 = 64
    public static let noInput: Int32 = 66
    public static let unavailable: Int32 = 69
    public static let protocolMismatch: Int32 = 70
  }

  static let usageText = "usage: uniterm run --socket PATH file.janet"

  public static func run(arguments: [String]) -> Int32 {
    guard let invocation = Invocation(arguments: Array(arguments.dropFirst())) else {
      return fail(usageText, status: Exit.usage)
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
      session = try ScriptSession.open(path: invocation.socket, name: name)
    } catch WireError.versionMismatch {
      return fail(ScriptProtocol.mismatchText, status: Exit.protocolMismatch)
    } catch WireError.io(let code) {
      return fail(
        "cannot reach uniterm at \(invocation.socket): \(String(cString: strerror(code)))",
        status: Exit.unavailable)
    } catch {
      return fail(
        "cannot talk to uniterm at \(invocation.socket): \(error)", status: Exit.unavailable)
    }

    defer { session.close() }

    guard let failure = ScriptVM.run(name: name, source: source, session: session) else {
      return Exit.ok
    }

    return fail(failure.description, status: Exit.scriptFailed)
  }

  private static func fail(_ message: String, status: Int32) -> Int32 {
    FileHandle.standardError.write(Data((message + "\n").utf8))

    return status
  }

  struct Invocation {
    let socket: String
    let script: String

    init?(arguments: [String]) {
      guard arguments.first == "run" else { return nil }

      var socket: String?
      var script: String?
      var index = 1

      while index < arguments.count {
        let argument = arguments[index]

        if argument == "--socket" {
          guard index + 1 < arguments.count else { return nil }

          socket = arguments[index + 1]
          index += 2
        } else if script == nil, !argument.hasPrefix("--") {
          script = argument
          index += 1
        } else {
          return nil
        }
      }

      guard let socket, let script else { return nil }

      self.socket = socket
      self.script = script
    }
  }
}
