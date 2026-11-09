import Darwin
import Foundation
import ScriptWire

/// What a REPL's helper needs to start: where to connect, and the token that binds its connection
/// to the pane that asked for it.
public struct ScriptReplLaunch: Sendable, Equatable {
  /// This instance's own address, never another instance's and never the well-known one.
  public let address: String

  /// The single-use token, as 64 hex digits. It passes to the helper in its environment.
  public let token: String
}

/// What happened to a REPL's helper, as the app sees it.
public enum ScriptReplEvent: Sendable, Equatable {
  /// The helper presented its token and is bound to this pane. The ID names the process.
  case attached(ProcessIdentity)

  /// The user entered a line. The app keeps its own history from these.
  case line(String)

  /// A form started or finished evaluating.
  case evaluating(Bool)

  /// The helper's connection closed, so the helper is gone or about to be.
  case ended
}

/// How the app makes sure a helper it started is gone. The app never trusts a process ID alone,
/// since the system reuses them.
public struct ProcessReaper: Sendable {
  /// How long a helper has to leave on its own after its connection closes and its pty hangs up.
  public var delay: Duration

  /// True while the process the identity names is still running. A reused process ID is another
  /// process, so it reads false.
  public var isRunning: @Sendable (ProcessIdentity) -> Bool

  public var kill: @Sendable (pid_t) -> Void

  public init(
    delay: Duration, isRunning: @escaping @Sendable (ProcessIdentity) -> Bool,
    kill: @escaping @Sendable (pid_t) -> Void
  ) {
    self.delay = delay
    self.isRunning = isRunning
    self.kill = kill
  }

  public static let live = ProcessReaper(
    delay: .seconds(2), isRunning: { $0.isRunning }, kill: { _ = Darwin.kill($0, SIGKILL) })

  /// Kills the process after the delay, when it is still the one that was recorded.
  func reap(_ identity: ProcessIdentity) {
    let reaper = self

    Task.detached {
      try? await Task.sleep(for: reaper.delay)

      if reaper.isRunning(identity) { reaper.kill(identity.pid) }
    }
  }
}

/// One REPL pane's side of its helper: the token it issued, the connection that spent it, and the
/// events that connection reports.
///
/// The token binds a connection to this pane, so a helper cannot attach to the wrong one. It is
/// not a defense against another process of the same user, which can read the helper's original
/// environment. Nothing relies on it as one.
@MainActor
public final class ScriptReplChannel {
  public let launch: ScriptReplLaunch

  /// The helper's process, once it has attached.
  public private(set) var helper: ProcessIdentity?

  public var onEvent: (@MainActor (ScriptReplEvent) -> Void)?

  let tokenData: Data
  let history: [String]

  private weak var host: ScriptHost?
  private var connection: ScriptConnection?
  private let reaper: ProcessReaper
  private var ended = false

  init(
    launch: ScriptReplLaunch, tokenData: Data, history: [String], host: ScriptHost,
    reaper: ProcessReaper
  ) {
    self.launch = launch
    self.tokenData = tokenData
    self.history = history
    self.host = host
    self.reaper = reaper
  }

  /// True from the moment the helper attaches until its connection closes.
  public var isAttached: Bool { connection != nil && !ended }

  func bind(_ connection: ScriptConnection) {
    self.connection = connection

    let started = ProcessIdentity.startTime(of: connection.peer.pid) ?? 0

    helper = ProcessIdentity(pid: connection.peer.pid, started: started)
    onEvent?(.attached(helper!))
  }

  func connectionClosed() {
    guard !ended else { return }

    connection = nil
    onEvent?(.ended)
  }

  /// Ends the helper. The token is withdrawn when no helper has used it yet. The connection
  /// closes, which makes the helper exit, and a helper that is still there after the delay is
  /// killed. The channel reports nothing more.
  public func end() {
    guard !ended else { return }

    ended = true
    onEvent = nil

    host?.withdraw(self)

    connection?.close()
    connection = nil

    if let helper { reaper.reap(helper) }
  }
}

extension ScriptHost {
  /// Splits a history into messages that each fit a control frame. The last one carries the final
  /// flag, and an empty history is one empty message, so the helper always hears that it was
  /// accepted.
  static func historyMessages(_ lines: [String]) -> [ScriptAppMessage] {
    let recalled = Array(lines.suffix(ScriptProtocol.recallLines))
    var chunks: [[String]] = []
    var current: [String] = []
    var bytes = 0

    for line in recalled {
      let size = min(line.utf8.count, ScriptProtocol.maxReplLineBytes) + 2

      if !current.isEmpty
        && (current.count >= ScriptProtocol.maxHistoryLines || bytes + size > historyChunkBytes)
      {
        chunks.append(current)
        current = []
        bytes = 0
      }

      current.append(line)
      bytes += size
    }

    chunks.append(current)

    return chunks.enumerated().map { index, lines in
      .history(lines: lines, final: index == chunks.count - 1)
    }
  }

  /// The most text one history message carries. The control frame holds 64 KiB, so this leaves
  /// room for its header and for lines that change size when they are cut at a character.
  static let historyChunkBytes = 24 * 1024

  /// Issues a token for a REPL pane's helper. The helper connects to this instance's own address
  /// and presents the token, which the host spends on first use. `history` is what the helper
  /// recalls, oldest first, and is never evaluated.
  public func openRepl(history: [String]) -> ScriptReplChannel {
    var bytes = Data(count: ScriptProtocol.tokenBytes)

    bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }

    let token = bytes.map { String(format: "%02x", $0) }.joined()
    let channel = ScriptReplChannel(
      launch: ScriptReplLaunch(address: instanceAddress, token: token), tokenData: bytes,
      history: history, host: self, reaper: reaper)

    pendingRepls[bytes] = channel

    return channel
  }

  /// Takes the token of a channel that ends before its helper used it.
  func withdraw(_ channel: ScriptReplChannel) {
    pendingRepls[channel.tokenData] = nil

    for (id, bound) in boundRepls where bound === channel {
      boundRepls[id] = nil
    }
  }

  /// Spends the token a helper presented. A token the host did not issue, or one already spent,
  /// is refused with a message and the connection closes.
  func attach(_ connection: ScriptConnection, token: Data) {
    guard let channel = pendingRepls.removeValue(forKey: token) else {
      refuseAttach(connection)

      return
    }

    boundRepls[connection.id] = channel
    sessions[connection.id, default: Session()].name = "repl"

    for message in Self.historyMessages(channel.history) {
      connection.send(message)
    }

    channel.bind(connection)
  }

  private func refuseAttach(_ connection: ScriptConnection) {
    sessions[connection.id, default: Session()].refused = true

    connection.send(
      .attachRefused(
        "uniterm did not accept this REPL. Its token was not issued by this uniterm, or was "
          + "already used."))
    connection.closeAfterSending()

    onRefusal(.replTokenRefused)
  }
}
