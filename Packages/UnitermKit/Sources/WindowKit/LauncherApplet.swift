import AppKit
import AppletKit
import Theme

/// Fills a new pane until the user picks what runs there.
///
/// Choosing an applet replaces the launcher in the same pane, so the pane keeps its ID. The
/// launcher runs nothing, so it has nothing to pause and closing it asks nothing. It leaves no undo
/// entry, since there is nothing to bring back.
///
/// A launcher remembers the directory of the pane it was opened from, and starts what it opens
/// there. It saves that directory, so a launcher that survives a relaunch still opens where the
/// user split. The filter and the typed command are not saved and start over.
@MainActor
final class LauncherApplet: Applet {
  static let identifier = "launcher"
  static let currentVersion = 1

  let typeID = LauncherApplet.identifier
  let title = "New pane"
  let segments: [AppletSegment] = []
  let isRunningSomething = false
  weak var host: (any AppletHost)?

  /// The launcher's one tab, for its whole life.
  let publishedTabs: AppletTabList

  let launcher = LauncherView()

  /// Where whatever the user picks starts. Nil when the pane it was opened from had no directory.
  let currentDirectory: String?

  var view: NSView { launcher }

  /// Opens the choice in this launcher's pane. It throws when the choice cannot start, and the
  /// launcher shows the reason.
  var onChoose: ((AppletChoice) throws -> Void)? {
    get { launcher.onChoose }
    set { launcher.onChoose = newValue }
  }

  init(directory: String? = nil) {
    currentDirectory = directory
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: "New pane"))

    launcher.onExit = { [weak self] in
      guard let self else { return }

      host?.appletDidExit(self)
    }
  }

  /// Restores a launcher from its description. The description is refused when it is another type
  /// or a newer version.
  convenience init(restoring description: AppletDescription) throws {
    guard description.type == Self.identifier else {
      throw AppletRestoreError.wrongType(expected: Self.identifier, found: description.type)
    }

    guard description.version <= Self.currentVersion else {
      throw AppletRestoreError.newerVersion(
        found: description.version, supported: Self.currentVersion)
    }

    var directory: String?
    if case .object(let fields) = description.payload, case .string(let path)? = fields["directory"]
    {
      directory = path
    }

    self.init(directory: directory)
  }

  func start(origin: StartOrigin) {}

  func close() {
    launcher.stop()
  }

  func focus() {
    launcher.focusCurrent()
  }

  func describe() -> AppletDescription {
    var fields: [String: JSONValue] = [:]
    if let currentDirectory {
      fields["directory"] = .string(currentDirectory)
    }

    return AppletDescription(
      type: Self.identifier, version: Self.currentVersion, payload: .object(fields))
  }

  func apply(_ palette: ThemePalette) {
    launcher.apply(palette)
  }
}
