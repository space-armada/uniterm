import Foundation
import PaneModel
import ProcessInspection
import ScriptWire
import StatusKit

/// What the window layer offers `uniterm open`. The host asks the user first, and calls this only
/// for a request the user allowed. Until then no path is statted, opened, or typed, so it never
/// reaches this protocol and no window code can touch it.
@MainActor
public protocol ScriptFileOpening: AnyObject {
  /// Routes each path to a pane, which takes focus as the user's own open does. The caller is the
  /// pane the command ran in, or nil when it ran in no terminal session. It returns at once and
  /// reports nothing about the files to the host. The window layer posts what failed in its own
  /// status message.
  func open(_ paths: [String], from caller: ScriptCaller?)

  /// The name the approval gives the caller's pane, or nil when the pane is gone.
  func label(of caller: ScriptCaller) -> String?
}

/// A terminal session the user allowed to open files. It binds the session root and the generation
/// the root had when the user answered, so a root that restarts, or a new session in the same pane,
/// is a different session. It lives in memory only, so a restored pane never carries it.
struct OpenSessionGrant: Hashable, Sendable {
  let root: ProcessIdentity
  let generation: UInt64
}

/// The words of an open approval.
public enum OpenApprovalText {
  /// The paths as the user must read them: every one in full, with each control, format, and line
  /// or paragraph separator written out as its code point. A path that holds a newline, or a right
  /// to left override, could otherwise fake a line of the question.
  public static func display(_ path: String) -> String {
    var shown = ""

    for scalar in path.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator:
        shown += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"

      default:
        shown.unicodeScalars.append(scalar)
      }
    }

    return shown
  }

  public static func title(count: Int) -> String {
    count == 1 ? "Open a file or folder" : "Open \(count) files or folders"
  }

  /// What the program asks for, with where it lands, as the three open questions all say it. One
  /// path goes in a new pane. Several each go in their own.
  public static func request(count: Int) -> String {
    count == 1
      ? "asks to open this path in a new pane"
      : "asks to open these \(count) paths, each in a new pane"
  }

  /// Opening a window is a power of its own, so every open question says that one may open.
  public static let windowNote = "A new window opens when a batch or a lack of room calls for one"

  /// The line that tells the user nothing was looked at, and so what the answer cannot be based on.
  public static func notLooked(count: Int) -> String {
    "uniterm has not looked at \(count == 1 ? "it" : "them") yet."
  }

  /// `pane` is the terminal the command ran in, or nil when it ran in none.
  public static func detail(paths: [String], pane: String?) -> String {
    let list = paths.map { "  \(display($0))" }.joined(separator: "\n")
    let request = request(count: paths.count)

    let lead: String
    let tail: String

    if let pane {
      lead = "A program in the terminal session of pane \u{201C}\(pane)\u{201D} \(request)."
      tail =
        "Allow for This Terminal Session lets every program in this session open files without "
        + "asking, until the session ends."
    } else {
      lead = "A program that runs in no uniterm terminal session \(request)."
      tail =
        "It may run in tmux, in screen, or outside uniterm, and uniterm cannot tell which program "
        + "it is. \(notLooked(count: paths.count)) This answer covers this request only."
    }

    let looked = pane == nil ? "" : "\(notLooked(count: paths.count)) "

    return "\(lead) \(windowNote):\n\(list)\n\(looked)\(tail)"
  }
}

extension ScriptHost {
  /// The power every open question is asked under.
  static let openPower = "open files"

  static let openDeniedText = "You denied this request."
  static let openWithdrawnText =
    "The request ended before you answered it, since the command or its session went away."

  /// A `uniterm open` began. Nothing here looks at a path. The connection is bound to its terminal
  /// session through the peer's ancestry, as any connection is, and the user is asked before the
  /// window layer sees a path.
  func beginOpen(_ connection: ScriptConnection, _ request: OpenBegin) {
    sessions[connection.id, default: Session()].name = "uniterm open"
    sessions[connection.id, default: Session()].kind = .openCommand

    watchPeer(of: connection)
    bindConnection(connection)

    guard fileOpener != nil else {
      return refuseController(connection, "uniterm cannot open files here.")
    }

    guard !peerWasReplaced(connection) else {
      return refuseController(connection, Self.openReplacedText)
    }

    let session = openSession(of: connection)

    if let session, openGrantHolds(session) {
      return finishOpen(connection, request.paths, session: session, remember: false)
    }

    askToOpen(connection, request.paths, session: session)
  }

  static let openReplacedText =
    "The program that ran this command has since started another executable, so the request ended."

  /// The terminal session the connection acts in, while its binding and the ancestry behind it
  /// still hold. Nil means the command is outside any session the app knows.
  private func openSession(of connection: ScriptConnection) -> OpenSessionGrant? {
    guard let binding = connection.binding, connection.validateBinding(registry: sessionRoots)
    else { return nil }

    let peer = ProcessIdentity(pid: connection.peer.pid, started: connection.peerStartTime)

    guard ProcessAncestry.findRoot(for: peer, in: sessionRoots) == binding.root else {
      return nil
    }

    return OpenSessionGrant(root: binding.root, generation: binding.generation)
  }

  private func openGrantHolds(_ session: OpenSessionGrant) -> Bool {
    openGrants.contains(session)
      && sessionRoots.sessionGeneration(for: session.root) == session.generation
  }

  private func askToOpen(
    _ connection: ScriptConnection, _ paths: [String], session boundSession: OpenSessionGrant?
  ) {
    let boundCaller = boundSession == nil ? nil : self.caller(for: connection)
    let pane = boundCaller.flatMap { fileOpener?.label(of: $0) }
    let name = pane.map { StatusText.bounded($0, maximumBytes: Self.maxLabelBytes) }

    // A session the question cannot name is no session the user could be told about. Its wording,
    // its buttons, and any grant therefore all follow the one condition: a named pane.
    let session = name == nil ? nil : boundSession
    let caller = name == nil ? nil : boundCaller

    // A command outside every session shares one bound with the rest of them. Each is a fresh
    // connection that holds a listener slot while it waits, so a loop of them must not fill it.
    let requester: PermissionRequests.Requester =
      session == nil ? .unboundOpen(connection.id) : .connection(connection.id)
    let key = PermissionRequests.Key(requester: requester, power: Self.openPower)

    // A denial of a session outlives the command, so a program in a loop cannot ask again at
    // once. It goes when the pane closes. A command outside a session has nothing to bind a denial
    // to, so its denial ends with its connection and the next command asks again.
    let denial = session.flatMap { session in
      caller.map {
        PermissionRequests.Key(
          requester: .terminal(window: $0.window, pane: $0.pane.rawValue),
          power: "\(Self.openPower), session \(session.root.pid).\(session.root.started) "
            + "generation \(session.generation)")
      }
    }

    let subject =
      name.map { "Programs in \u{201C}\($0)\u{201D}" }
      ?? "uniterm open (PID \(connection.peer.pid))"

    let outcome = permissionRequests.ask(
      key, deniedAs: denial, subject: subject, pid: connection.peer.pid,
      title: OpenApprovalText.title(count: paths.count),
      detail: OpenApprovalText.detail(paths: paths, pane: name),
      sessionTitle: "Allow for This Terminal Session", onceOnly: session == nil
    ) { [weak self, weak connection] answer in
      guard let self, let connection, !connection.isClosed else { return }

      switch answer {
      case .deny:
        refuseController(connection, Self.openDeniedText)

      case .withdrawn:
        refuseController(connection, Self.openWithdrawnText)

      case .allowOnce:
        finishOpen(connection, paths, session: session, remember: false)

      case .allowForSession:
        finishOpen(connection, paths, session: session, remember: true)
      }
    }

    switch outcome {
    case .waiting:
      connection.send(
        .controllerReviewing(
          "uniterm asks you before it opens anything. Choose Window > Pending Requests in uniterm "
            + "to answer."))

    case .denied:
      refuseController(
        connection,
        "You denied this earlier. To be asked again, choose Ask Again in Window > Pending Requests."
      )

    case .busy:
      refuseController(
        connection, "Too many requests wait for you in uniterm. Try again later.")
    }
  }

  /// The user allowed the request, or a session grant covers it. The session and the peer are
  /// checked again, since either can end while the question waits. The reply goes out before any
  /// path is looked at, so what it says never depends on a file.
  private func finishOpen(
    _ connection: ScriptConnection, _ paths: [String], session: OpenSessionGrant?, remember: Bool
  ) {
    guard !connection.isClosed else { return }

    guard !peerWasReplaced(connection) else {
      return refuseController(connection, Self.openReplacedText)
    }

    if let session {
      guard openSession(of: connection) == session else {
        return refuseController(connection, "The terminal session this command ran in has ended.")
      }

      if remember { openGrants.insert(session) }
    }

    guard let fileOpener else {
      return refuseController(connection, "uniterm cannot open files here.")
    }

    let caller = session == nil ? nil : self.caller(for: connection)

    connection.send(.openDone)
    connection.closeAfterSending()

    fileOpener.open(paths, from: caller)
  }

  /// Ends the open grants of sessions that closed.
  func endOpenGrants(where ends: (OpenSessionGrant) -> Bool) {
    openGrants = openGrants.filter { !ends($0) }
  }
}
