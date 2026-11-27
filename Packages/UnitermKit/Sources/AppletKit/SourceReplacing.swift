import AppKit
import UniformTypeIdentifiers

/// An applet that shows one source and can swap it for another. A viewer adopts this to get the
/// pane-local Open command.
///
/// `replaceSource` and the applet type's `AppletSourceFactory` are the two faces of one
/// source-taking function. The factory makes an applet that opens the source. `replaceSource` swaps
/// the source of a running one. A viewer implements both through the same code, so the router, a
/// drop, and this command all reach one path.
///
/// The start directory is explicit and absolute. It comes from the chosen file, and the applet
/// never reads it from another pane.
@MainActor
public protocol SourceReplacing: Applet {
  func replaceSource(with file: URL, startDirectory: String) throws

  /// Shows a file that a script sent, in place of what the pane shows. The file lives in uniterm's
  /// own folder for sent content, and the script chose its bytes and its name, never its place.
  /// An applet whose source can name other files must not let this one reach them. By default a
  /// sent file opens like any other.
  func replaceSource(withSent file: URL, startDirectory: String) throws

  /// The file types the pane's open panel accepts, or nil for any file. Folders are always
  /// choosable.
  var openPanelContentTypes: [UTType]? { get }

  /// Shows the panel the pane-local Open command asks with. The app gives each viewer the
  /// system's panel. A debug build can give it one that answers without showing.
  var openPicker: OpenPicker { get }

  /// The swap to a file the user picked or dropped, while its start directory is learned.
  var sourceSwap: SourceSwap { get }
}

extension SourceReplacing {
  public var openPanelContentTypes: [UTType]? { nil }

  public func replaceSource(withSent file: URL, startDirectory: String) throws {
    try replaceSource(with: file, startDirectory: startDirectory)
  }

  /// Shows a file the user picked or dropped, once its start directory is known. A later choice
  /// wins over one still waiting. A failure goes to the pane's status bar, and the pane keeps the
  /// source it had.
  @discardableResult
  public func replaceSource(withChosen file: URL) -> Task<Void, Never> {
    sourceSwap.start(file) { [weak self] file, startDirectory in
      guard let self else { return }

      do {
        try self.replaceSource(with: file, startDirectory: startDirectory)
      } catch {
        self.host?.applet(
          self, post: .warning,
          text:
            "\u{201C}\(file.lastPathComponent)\u{201D} could not be opened: "
            + error.localizedDescription)
      }
    }
  }
}

extension AppletCommand {
  /// The pane-local "Open in This Pane..." that a viewer's command set declares. It has no key,
  /// since Cmd-O belongs to the window's File > Open, which routes by type. A user can remap a key
  /// to it. Its title reads apart from that Open's, so a remap can name one of the two.
  ///
  /// It replaces the source of the pane the command is aimed at. Choosing the file in the panel is
  /// the user's act. The applet gets that one file and nothing more.
  public static func openSource(section: Int = 0) -> AppletCommand {
    AppletCommand(
      name: openSourceName, title: "Open in This Pane\u{2026}", home: .file, section: section,
      isAvailable: { $0 is any SourceReplacing },
      run: { applet in
        Task { @MainActor [weak applet] in
          guard let target = applet as? any SourceReplacing else { return }

          await SourceOpening.open(target, picker: target.openPicker)
        }
      })
  }

  /// The command's name within its applet type.
  public static let openSourceName = "open"
}

/// The work behind the pane-local Open command.
public enum SourceOpening {
  /// Asks for one file or folder and hands it to the applet. A failure goes to the pane's status
  /// bar, and the applet keeps the source it had.
  @MainActor
  public static func open(_ applet: any Applet, picker: OpenPicker) async {
    guard let target = applet as? any SourceReplacing else { return }

    let request = OpenPanelRequest(
      startingIn: applet.currentDirectory, allowsMultipleSelection: false,
      contentTypes: target.openPanelContentTypes)

    guard let file = await picker(request, applet.view.window).first else { return }

    await target.replaceSource(withChosen: file).value
  }
}
