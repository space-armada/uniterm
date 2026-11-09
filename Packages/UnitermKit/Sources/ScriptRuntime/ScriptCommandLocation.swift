import Darwin
import Foundation

/// Whether this process is the command that ships inside a uniterm bundle.
///
/// The command on `PATH` is a symlink into the bundle. Following the link leads to
/// `<name>.app/Contents/Helpers/uniterm`, in a bundle whose main executable exists. A copy of the
/// command anywhere else fails the check, since it would not travel with the app and would meet
/// an app of another version.
enum ScriptCommandLocation {
  static let message =
    "This uniterm command is not the one inside the uniterm app. Reinstall the command from "
    + "uniterm's menu, Install Command Line Tool."

  /// The path of the running executable with every link followed, or nil when the system will not
  /// say.
  static func currentExecutablePath() -> String? {
    var size: UInt32 = 0

    _ = _NSGetExecutablePath(nil, &size)

    var buffer = [CChar](repeating: 0, count: Int(size))

    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }

    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }

    return realpath(String(decoding: bytes, as: UTF8.self))
  }

  static func realpath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }

    defer { free(resolved) }

    return String(cString: resolved)
  }

  /// Nil when `path`, already resolved, is the bundle's own command. Otherwise the message to show.
  static func refusal(forResolved path: String?) -> String? {
    guard let path else { return message }

    let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

    guard parts.count >= 4, parts[parts.count - 1] == "uniterm",
      parts[parts.count - 2] == "Helpers", parts[parts.count - 3] == "Contents",
      parts[parts.count - 4].hasSuffix(".app")
    else { return message }

    let helpers = (path as NSString).deletingLastPathComponent
    let contents = (helpers as NSString).deletingLastPathComponent

    guard let main = mainExecutable(contents: contents) else { return message }

    var info = stat()

    guard stat(main, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_mode & S_IXUSR != 0
    else { return message }

    return nil
  }

  /// The bundle's main executable, named by `CFBundleExecutable` in its Info.plist.
  private static func mainExecutable(contents: String) -> String? {
    let plist = (contents as NSString).appendingPathComponent("Info.plist")

    guard let data = FileManager.default.contents(atPath: plist),
      let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let info = object as? [String: Any],
      let name = info["CFBundleExecutable"] as? String,
      !name.isEmpty, !name.contains("/")
    else { return nil }

    return ((contents as NSString).appendingPathComponent("MacOS") as NSString)
      .appendingPathComponent(name)
  }
}
