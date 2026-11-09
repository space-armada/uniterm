import Foundation
import ScriptWire

/// Why a host function did not do what a script asked. The kind tells the script's mistake from a
/// refusal. The text reaches the script as the message of a Janet error, so it never names a pane
/// other than the one the script gave.
public struct ScriptCallError: Error, Equatable, Sendable {
  public let kind: ScriptFailureKind
  public let text: String

  public init(_ kind: ScriptFailureKind, _ text: String) {
    self.kind = kind
    self.text = text
  }

  public static func badArgument(_ text: String) -> ScriptCallError {
    ScriptCallError(.badArgument, text)
  }

  public static func refused(_ text: String) -> ScriptCallError {
    ScriptCallError(.refused, text)
  }

  public static func notFound(_ text: String) -> ScriptCallError {
    ScriptCallError(.notFound, text)
  }

  public static func failed(_ text: String) -> ScriptCallError {
    ScriptCallError(.failed, text)
  }
}

/// What the window layer offers scripts. The window layer implements it, and the app hands it to
/// the host, so this target never depends on windows.
///
/// Every function runs on the main actor and never blocks it. The two that check a directory on
/// disk are async, so the check runs off the main actor. A reference that names a window,
/// pane, or tab that is not open in this launch throws `notFound`, except for `listPanes`, which
/// answers nil for a window that is gone. No reference resolves to a different pane.
@MainActor
public protocol ScriptWindowAPI: AnyObject {
  /// The open windows, oldest first.
  func listWindows() throws -> ScriptValue

  /// The panes of a window, or nil when the window is not open.
  func listPanes(window: UInt64) throws -> ScriptValue

  /// Splits `beside` and starts the applet `kind` in the new pane. The directory is where the new
  /// pane starts, or nil for the one the pane beside it reports.
  func openPane(
    kind: String, beside: ScriptPaneReference, axis: ScriptAxis?, directory: String?
  ) async throws -> ScriptValue

  /// Opens a tab in a pane whose applet has tabs. The directory is where the tab starts, or nil
  /// for the one the pane reports.
  func openTab(pane: ScriptPaneReference, directory: String?) async throws -> ScriptValue

  /// True while the pane the reference names is open. The host asks before it keeps a file for a
  /// pane, and again to find the files of panes that have closed.
  func isOpen(_ pane: ScriptPaneReference) -> Bool

  /// Throws when `pane` cannot take sent content. The host asks before it writes the content, so a
  /// refusal leaves nothing behind.
  func prepareSend(to pane: ScriptPaneReference) throws

  /// Hands a file the app wrote to the pane's applet, which reads it like any file it opens. The
  /// host calls it right after `prepareSend`, with nothing suspended between them.
  func send(to pane: ScriptPaneReference, file: URL) throws -> ScriptValue
}
