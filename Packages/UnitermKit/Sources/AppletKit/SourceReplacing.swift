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
/// `replaceSource` takes the new source at once, and the pane's old one goes with it. A swap the
/// user chooses must not lose the old source to a file that cannot be opened. So it asks
/// `checkSource` first, and replaces only when the check passes. See `replaceSource(withChosen:)`.
///
/// The start directory is explicit and absolute. It comes from the chosen file, and the applet
/// never reads it from another pane.
@MainActor
public protocol SourceReplacing: Applet {
  /// Shows `file` in place of the pane's source, at once. The load runs after this returns, so a
  /// file that cannot be read shows its failure in the pane. Call `checkSource` first to keep the
  /// pane's source when the file cannot be opened.
  func replaceSource(with file: URL, startDirectory: String) throws

  /// Reads `file` far enough to know the pane can open it, and throws why when it cannot. It
  /// changes nothing the pane shows or saves, and it stops early when its task is cancelled. A
  /// failure that only a full render can find still shows in the pane after the swap.
  func checkSource(_ file: URL, startDirectory: String) async throws

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

  /// The swap to a file the user picked or dropped, while its start directory is learned and the
  /// file is checked.
  var sourceSwap: SourceSwap { get }
}

extension SourceReplacing {
  public var openPanelContentTypes: [UTType]? { nil }

  public func replaceSource(withSent file: URL, startDirectory: String) throws {
    try replaceSource(with: file, startDirectory: startDirectory)
  }

  /// Shows a file the user picked or dropped, once its start directory is known and the pane has
  /// checked that it opens. A later choice wins over one still waiting, and the earlier one says
  /// nothing. A failure goes to the pane's status bar, and the pane keeps the source it had.
  @discardableResult
  public func replaceSource(withChosen file: URL) -> Task<Void, Never> {
    sourceSwap.start(file) { [weak self] file, startDirectory, isCurrent in
      guard let self else { return }

      do {
        try await self.checkSource(file, startDirectory: startDirectory)

        guard isCurrent() else { return }

        try self.replaceSource(with: file, startDirectory: startDirectory)
      } catch is CancellationError {
        return
      } catch {
        guard isCurrent() else { return }

        self.host?.applet(
          self, post: .warning,
          text:
            "\u{201C}\(file.lastPathComponent)\u{201D} could not be opened: "
            + error.localizedDescription)
      }
    }
  }
}

/// Why a pane's `checkSource` found that it cannot open a file, in words the status bar shows.
public struct SourceCheckFailure: LocalizedError, Equatable, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
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
