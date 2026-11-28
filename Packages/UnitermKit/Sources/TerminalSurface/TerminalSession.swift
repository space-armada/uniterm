import AppKit
import Darwin
import ProcessInspection
import Theme

/// What a terminal session starts. The directory and environment are applied to the child process.
public struct TerminalLaunch: Sendable, Equatable {
  public var workingDirectory: String?
  public var environment: [String: String]

  /// The program and its arguments, or nil for the user's login shell. libghostty starts a program
  /// through `/bin/sh -c` with every word single-quoted, so no shell interprets the user's text.
  ///
  /// libghostty picks shell integration from the first word of the command. The quotes keep that
  /// word from reading as `zsh` or `fish`, so a program launch gets no integration scripts. It
  /// still inherits `GHOSTTY_SHELL_FEATURES`, which libghostty sets for every child.
  public var program: [String]?

  /// Plain text the terminal shows before the login shell starts, such as a closed tab's earlier
  /// output. A program launch ignores it. See `ScrollbackText.prepared`.
  public var replay: String?

  /// Starts the user's default login shell, from `$SHELL` or the passwd entry. The launch reports
  /// uniterm as the terminal program. A variable in `environment` replaces that.
  public static func loginShell(
    workingDirectory: String? = nil, environment: [String: String] = [:], replay: String? = nil,
    version: String = TerminalIdentity.bundleVersion
  ) -> TerminalLaunch {
    TerminalLaunch(
      workingDirectory: workingDirectory,
      environment: TerminalIdentity.environment(version: version).merging(environment) { $1 },
      program: nil, replay: replay)
  }

  /// Starts one program. The words are the program and its arguments, exactly as given.
  ///
  /// A program that is `ssh`, by name or by path, gets `TERM=xterm-256color`. Ghostty's `ssh-env`
  /// fallback lives in the shell integration, which a program launch bypasses. A host without the
  /// `xterm-ghostty` terminfo entry would otherwise break the remote session. Other routes to a
  /// remote host, such as `mosh` or a wrapper script, are not covered.
  public static func program(
    _ words: [String], workingDirectory: String? = nil, environment: [String: String] = [:],
    version: String = TerminalIdentity.bundleVersion
  ) -> TerminalLaunch {
    var environment = TerminalIdentity.environment(version: version).merging(environment) { $1 }

    if let name = words.first.map({ ($0 as NSString).lastPathComponent }), name == "ssh" {
      environment["TERM"] = "xterm-256color"
    }

    return TerminalLaunch(
      workingDirectory: workingDirectory, environment: environment, program: words, replay: nil)
  }
}

/// A terminal action that uniterm's own key bindings and menus call.
public enum TerminalAction: Sendable, Equatable, CaseIterable {
  case copy
  case paste
  case selectAll
  case increaseFontSize
  case decreaseFontSize
  case resetFontSize
  case clearScreen
}

public struct TerminalGridSize: Sendable, Equatable {
  public var columns: Int
  public var rows: Int

  public init(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
  }
}

/// How a session treats programmatic clipboard use. The host sets it per session, before the
/// session starts and before any change to the pane's control takes effect.
///
/// An interactive session asks before an OSC 52 read and lets an OSC 52 write through. A
/// controlled session asks before both, and its prompt can allow the rest of the session. Kitty
/// clipboard requests are denied either way, and the user's own copy and paste never ask.
public struct TerminalClipboardPolicy: Sendable, Equatable {
  public var controlled: Bool

  /// The pane's authority generation. A prompt answered under another generation is stale and
  /// counts as a denial.
  public var generation: UInt64

  public init(controlled: Bool, generation: UInt64) {
    self.controlled = controlled
    self.generation = generation
  }

  public static let interactive = TerminalClipboardPolicy(controlled: false, generation: 0)
}

/// The user's answer to a clipboard request.
public enum TerminalClipboardAnswer: Sendable, Equatable {
  case deny
  case allowOnce

  /// Allows this request and later ones of the same kind for the rest of the session, under the
  /// same policy. Only a request that `offersSession` honors it. Any other treats it as once.
  case allowForSession
}

/// A request from the program in the terminal to use the clipboard. The user's answer completes it
/// exactly once. A request that is dropped without an answer stays unanswered.
public final class TerminalClipboardRequest: @unchecked Sendable {
  public enum Kind: Sendable, Equatable {
    /// A program asked to read the clipboard with OSC 52. The text is what it would receive.
    case read
    /// A paste that libghostty judged unsafe.
    case unsafePaste
    /// A program in a controlled session asked to write the clipboard with OSC 52. The text is
    /// what it would write.
    case write
  }

  public let kind: Kind
  public let text: String

  /// True when the session is controlled, so the prompt may offer this-session permission. It
  /// covers every program in the terminal session, which is all an escape sequence can name.
  public let offersSession: Bool

  private let lock = NSLock()
  private var completion: (@Sendable (TerminalClipboardAnswer) -> Void)?

  init(
    kind: Kind, text: String, offersSession: Bool = false,
    completion: @escaping @Sendable (TerminalClipboardAnswer) -> Void
  ) {
    self.kind = kind
    self.text = text
    self.offersSession = offersSession
    self.completion = completion
  }

  /// Answers the request. A second call does nothing.
  public func resolve(_ answer: TerminalClipboardAnswer) {
    lock.lock()
    let completion = self.completion
    self.completion = nil
    lock.unlock()

    completion?(answer)
  }

  /// Allows the one request, or denies it.
  public func resolve(allow: Bool) {
    resolve(allow ? .allowOnce : .deny)
  }
}

/// The process a terminal session spawned: its PID, the second it started, and the session's
/// generation within its surface. The PID alone can be reused, so the start time tells a later
/// process with the same PID apart.
public struct TerminalProcessIdentity: Sendable, Equatable {
  public let pid: pid_t
  public let started: Int
  public let sessionGeneration: UInt64

  public init(pid: pid_t, started: Int, sessionGeneration: UInt64) {
    self.pid = pid
    self.started = started
    self.sessionGeneration = sessionGeneration
  }

  static func startTime(of pid: pid_t) -> Int? {
    ProcessInspection.startTime(of: pid)
  }
}

/// Something that happened in the terminal. The session reports it on the main actor.
public enum TerminalEvent: Sendable {
  case titleChanged(String)

  /// The shell reported its directory with OSC 7. The value is a path.
  case workingDirectoryChanged(String)

  /// The session's child process started. The identity names the process libghostty spawned,
  /// never one a program claims. It arrives on the main actor shortly after the session starts,
  /// so no identity exists at launch.
  case processStarted(TerminalProcessIdentity)

  /// The shell reported that a command ended, with OSC 133. This is the only prompt mark that
  /// libghostty passes to its embedder. Whether the cursor sits at a prompt is answered by
  /// `isRunningSomething`.
  case commandFinished(exitCode: Int?, duration: Duration)

  /// With Command held, the pointer moved onto a link, or off it. The text is the link's target for
  /// an OSC 8 hyperlink, and the text on screen for any other link, so a hyperlink's text can differ
  /// from it. Nothing is looked up for it. A program chose it.
  case linkHovered(String?)

  /// The user clicked a link with Command held. The text is the same kind as the hover's. The
  /// engine opens nothing, so the owner decides what the click does.
  case linkOpenRequested(String)

  /// A program reported a working directory that names another host with OSC 7. The engine does not
  /// adopt it, and `workingDirectory` keeps its value.
  case remoteHostReported(String)

  /// A program sent OSC 9 or OSC 777.
  case notification(title: String, body: String)

  case clipboardRequest(TerminalClipboardRequest)
  case bell

  /// The child process ended. The session is spent and needs `close()`.
  case exited
}

/// One terminal session: a child process on a pty, drawn into a view.
///
/// This is uniterm's boundary with the terminal engine. No engine type appears in it. The session
/// level is the only level that works, since the engine spawns the child and owns the pty.
@MainActor
public protocol TerminalSession: AnyObject {
  var view: NSView { get }

  var onEvent: (@MainActor (TerminalEvent) -> Void)? { get set }

  var title: String { get }
  var workingDirectory: String? { get }
  var gridSize: TerminalGridSize { get }

  /// True unless the cursor sits at an idle shell prompt. Shell integration marks the prompt with
  /// OSC 133. A shell without those marks always reads as running.
  var isRunningSomething: Bool { get }

  var hasExited: Bool { get }

  /// Sends text to the child the way a paste does. A shell with bracketed paste does not run a pasted
  /// newline. Real key presses reach the child through the hosted view.
  func send(text: String)

  /// False while the pane takes no input for the child: a typed key, a paste, dragged text, and
  /// composed text are all dropped. Scrolling, selection, and copy still work.
  var acceptsInput: Bool { get set }

  func perform(_ action: TerminalAction)

  /// Sets the view's size in points. The child sees the new grid size.
  func resize(to size: CGSize)

  func setFocused(_ focused: Bool)

  /// Tells the renderer whether the view can be seen.
  func setVisible(_ visible: Bool)

  /// How the session treats programmatic clipboard use now.
  var clipboardPolicy: TerminalClipboardPolicy { get }

  /// Replaces the session's clipboard policy. It applies to every request answered from now on,
  /// including one already waiting for the user, whose answer is then stale if the generation or
  /// the mode changed. A session permission the user gave ends with the old policy.
  func setClipboardPolicy(_ policy: TerminalClipboardPolicy)

  /// The screen and its scrollback as plain text, prepared by `ScrollbackText.prepared`. Colors and
  /// other attributes are lost. While a program such as vim uses the alternate screen, this is that
  /// screen. Nil when there is no text.
  func scrollbackText() -> String?

  /// Hangs up the child and releases the session. The session is unusable afterwards.
  func close()
}

/// Owns the engine and makes sessions.
@MainActor
public protocol TerminalEngine: AnyObject {
  /// Makes a session that runs `launch`. The clipboard policy is in place before the child can
  /// write any output, so its first escape sequence already meets it.
  func makeSession(launch: TerminalLaunch, clipboardPolicy: TerminalClipboardPolicy) throws
    -> any TerminalSession

  /// Updates the palette of every running session, and of sessions made later.
  func apply(palette: ThemePalette) throws

  /// True when any running session is running something.
  var anySessionRunningSomething: Bool { get }
}

/// The menu actions that the focused terminal answers. A menu item with a nil target finds them on
/// the first responder, so uniterm's menu owns the key bindings and the terminal only reacts.
@MainActor @objc public protocol TerminalMenuActions {
  func copy(_ sender: Any?)
  func paste(_ sender: Any?)
  func selectAll(_ sender: Any?)
  func increaseTerminalFontSize(_ sender: Any?)
  func decreaseTerminalFontSize(_ sender: Any?)
  func resetTerminalFontSize(_ sender: Any?)
  func clearTerminalScreen(_ sender: Any?)
}
