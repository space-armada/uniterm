import AppKit
import ProcessInspection
import ProcessTestSupport
import Theme
import XCTest

@testable import TerminalSurface

/// Runs a real zsh through the session protocol, inside a window that is never shown.
///
/// These tests start real shells, so each costs about a second. A mock cannot prove what they
/// prove: that libghostty injects shell integration, that the integration's OSC 7 and OSC 133
/// reach the protocol, and that the running-state query follows the prompt.
@MainActor
final class TerminalSessionIntegrationTests: XCTestCase {
  private var sandbox: URL!
  private var resources: URL!
  private var helper: URL!
  private var engine: GhosttyTerminalEngine!

  /// The sessions' clipboard. It is private to the test, so another program's copy during a run
  /// cannot change what a test reads, and no test touches the user's clipboard.
  private var pasteboard: NSPasteboard!
  private var window: NSWindow!
  private var sessions: [any TerminalSession] = []
  private var savedEnvironment: [String: String?] = [:]
  private var baselineChildren: Set<pid_t> = []

  override func setUp() async throws {
    continueAfterFailure = false
    _ = NSApplication.shared

    sandbox = FileManager.default.temporaryDirectory.appending(
      path: "uniterm-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sandbox.appending(path: "home"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: sandbox.appending(path: "work"), withIntermediateDirectories: true)
    try Data().write(to: sandbox.appending(path: "home/.zshrc"))

    resources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Frameworks/GhosttyResources/ghostty")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: resources.appending(path: "shell-integration").path),
      "run `make build` so Ghostty's resources exist")

    helper = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Support/ghostty-bin", directoryHint: .isDirectory)
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: helper.appending(path: "ghostty").path),
      "uniterm's ghostty helper is missing or not executable")

    // The shell must not read the developer's dotfiles, which may prompt for an ssh passphrase.
    // ZDOTDIR goes in the process environment, since Ghostty's zsh integration reads it there and
    // restores it for the user's startup files. A ZDOTDIR passed as a launch variable would
    // override the integration's own.
    for name in [
      "SHELL", "ZDOTDIR", "SSH_AUTH_SOCK", "SSH_ASKPASS", "MAKEFLAGS", "GHOSTTY_RESOURCES_DIR",
    ] {
      savedEnvironment[name] = getenv(name).map { String(cString: $0) }
    }

    setenv("SHELL", "/bin/zsh", 1)
    setenv("ZDOTDIR", sandbox.appending(path: "home").path, 1)
    setenv("SSH_AUTH_SOCK", "", 1)
    unsetenv("SSH_ASKPASS")
    pasteboard = NSPasteboard.withUniqueName()
    engine = try GhosttyTerminalEngine(
      configStore: TerminalConfigStore(directory: sandbox.appending(path: "config")),
      resourcesDirectory: resources, helperDirectory: helper, palette: .latte,
      pasteboard: pasteboard)

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    baselineChildren = Set(children(of: getpid()))
  }

  override func tearDown() async throws {
    // A program a test starts can outlive its session. Everything the test process started since
    // setUp is ended, children first, so no test leaves an orphan.
    //
    // The tree is recorded before close(). libghostty reaps `login` when its session closes, and
    // its pid is then free. A signal goes only to a process that still has the recorded start time.
    let started = Set(children(of: getpid())).subtracting(baselineChildren)
    let stragglers = started.flatMap { recordTree(of: $0) }

    for session in sessions {
      session.close()
    }
    sessions = []

    endTree(stragglers)
    engine = nil
    pasteboard.releaseGlobally()
    window.close()
    try? FileManager.default.removeItem(at: sandbox)

    for (name, value) in savedEnvironment {
      if let value {
        setenv(name, value, 1)
      } else {
        unsetenv(name)
      }
    }
    savedEnvironment = [:]
  }

  private func startShell(
    policy: TerminalClipboardPolicy = .interactive, replay: String? = nil
  ) throws -> any TerminalSession {
    let launch = TerminalLaunch.loginShell(
      workingDirectory: sandbox.appending(path: "work").path,
      environment: ["HOME": sandbox.appending(path: "home").path], replay: replay)
    return host(try engine.makeSession(launch: launch, clipboardPolicy: policy))
  }

  private func startProgram(_ words: [String]) throws -> any TerminalSession {
    let launch = TerminalLaunch.program(
      words, workingDirectory: sandbox.appending(path: "work").path)
    return host(try engine.makeSession(launch: launch, clipboardPolicy: .interactive))
  }

  private func host(_ session: any TerminalSession) -> any TerminalSession {
    sessions.append(session)

    session.view.frame = window.contentView!.bounds
    window.contentView!.addSubview(session.view)
    session.setFocused(true)
    return session
  }

  private func waitUntil(
    _ description: String, timeout: Duration = .seconds(20), _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout

    while !condition() {
      if ContinuousClock.now > deadline {
        XCTFail("timed out waiting for \(description). Screen:\n\(sessions.last.map(screen) ?? "")")
        throw CancellationError()
      }

      try await Task.sleep(for: .milliseconds(25))
    }
  }

  /// `send(text:)` pastes, and a shell does not run a pasted newline. Enter is a real key event.
  private func press(
    _ session: any TerminalSession, keyCode: UInt16, characters: String,
    modifiers: NSEvent.ModifierFlags = []
  ) throws {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))

      if type == .keyDown {
        session.view.keyDown(with: event)
      } else {
        session.view.keyUp(with: event)
      }
    }
  }

  private func run(_ command: String, in session: any TerminalSession) throws {
    session.send(text: command)
    try press(session, keyCode: 0x24, characters: "\r")
  }

  private func screen(_ session: any TerminalSession) -> String {
    session.view.accessibilityValue() as? String ?? ""
  }

  /// Catches shell integration that never reaches the protocol, and a running-state query that
  /// does not follow the prompt. The shell reports its directory with OSC 7, which starts at the
  /// first prompt. The query is false there, true while vim runs, and false again after vim quits.
  func testRunningStateFollowsThePromptAndVim() async throws {
    let session = try startShell()
    var directories: [String] = []
    session.onEvent = { event in
      if case .workingDirectoryChanged(let path) = event { directories.append(path) }
    }

    try await waitUntil("the first prompt's working directory") { !directories.isEmpty }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let expected = sandbox.appending(path: "work").resolvingSymlinksInPath().path
    XCTAssertEqual(URL(fileURLWithPath: directories[0]).resolvingSymlinksInPath().path, expected)

    try run("vim -u NONE -N", in: session)
    try await waitUntil("vim's screen") {
      let text = self.screen(session)
      return text.contains("VIM - Vi IMproved")
        || text.split(separator: "\n").filter { $0.hasPrefix("~") }.count >= 3
    }

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(session.isRunningSomething, "vim is up and the query says idle")

    try press(session, keyCode: 0x35, characters: "\u{1B}")
    try press(session, keyCode: 0x29, characters: ":", modifiers: .shift)
    try press(session, keyCode: 0x0C, characters: "q")
    try press(session, keyCode: 0x12, characters: "!", modifiers: .shift)
    try press(session, keyCode: 0x24, characters: "\r")
    try await waitUntil("the prompt after vim") { !session.isRunningSomething }
  }

  /// Catches OSC 133 marks that never arrive. The shell reports a finished command's exit status,
  /// and the working directory follows `cd`.
  func testCommandFinishedAndDirectoryChangeReachTheProtocol() async throws {
    let session = try startShell()
    var finished: [Int?] = []
    var directories: [String] = []
    session.onEvent = { event in
      switch event {
      case .commandFinished(let code, _): finished.append(code)
      case .workingDirectoryChanged(let path): directories.append(path)
      default: break
      }
    }

    try await waitUntil("an idle prompt") { !session.isRunningSomething && !directories.isEmpty }

    try run("false", in: session)
    try await waitUntil("the exit status of false") { finished.contains(1) }

    try run("true", in: session)
    try await waitUntil("the exit status of true") { finished.contains(0) }

    let target = sandbox.appending(path: "home").resolvingSymlinksInPath().path
    try run("cd \(target)", in: session)
    try await waitUntil("OSC 7 after cd") {
      directories.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == target }
    }
  }

  /// Catches a missing terminfo or a TERM other than xterm-ghostty. Also checks that the `ssh`
  /// wrapper from the `ssh-env` feature exists, and that a program started by ssh sees
  /// TERM=xterm-256color. The probe uses ssh's ProxyCommand, which runs locally with ssh's own
  /// environment, so no remote host is needed. A real host without the terminfo entry is not
  /// reachable from here.
  ///
  /// Ghostty's wrapper runs `$GHOSTTY_BIN_DIR/ghostty +ssh`, so this also catches a shell whose
  /// `GHOSTTY_BIN_DIR` is not uniterm's helper, whose `PATH` gained uniterm's executable directory,
  /// and a helper that stops forwarding the terminal variables. `ssh -G` prints the options the
  /// helper added without connecting.
  func testTermTerminfoAndSshFallback() async throws {
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run(
      "echo \"T:$TERM:\"; infocmp xterm-ghostty >/dev/null && echo \"I:$((6*7)):\"", in: session)
    try await waitUntil("TERM and infocmp output") {
      let text = self.screen(session)
      return text.contains("T:xterm-ghostty:") && text.contains("I:42:")
    }

    try run("whence -w ssh", in: session)
    try await waitUntil("the ssh wrapper") { self.screen(session).contains("ssh: function") }

    try run(
      "ssh -F /dev/null -o BatchMode=yes -o ProxyCommand='echo \"PT:$TERM:\" >&2; exit 1' nowhere",
      in: session)
    try await waitUntil("the TERM that ssh passes on") {
      self.screen(session).contains("PT:xterm-256color:")
    }

    try run(
      "ssh -F /dev/null -G nowhere | grep -c '^sendenv TERM_PROGRAM' | sed 's/^/SE:/'", in: session)
    try await waitUntil("the forwarded variables") { self.screen(session).contains("SE:2") }

    let executableDirectory = Bundle.main.executableURL!.deletingLastPathComponent().path
    try run(
      #"[ "$GHOSTTY_BIN_DIR" = '\#(helper.path)' ] && echo "BD:$((6*7)):"; "#
        + #"case ":$PATH:" in *':\#(executableDirectory):'*) ;; *) echo "PA:$((5*5)):" ;; esac"#,
      in: session)
    try await waitUntil("the helper and PATH checks") {
      let text = self.screen(session)
      return text.contains("BD:42:") && text.contains("PA:25:")
    }
  }

  /// Catches a resize that never reaches the shell. The shell's own `stty size` reports the grid.
  ///
  /// libghostty applies a resize to the pty 25 ms later, so a command typed right after the resize
  /// can still see the old size. The script waits for the SIGWINCH that the kernel sends once the
  /// size changes, and only then asks.
  func testShellSeesTheNewSize() async throws {
    let script = sandbox.appending(path: "winch-\(getpid()).sh")
    try """
    trap 'stty size | sed "s/^/S:/;s/ /x/"; kill "$pid"; exit' WINCH
    sleep 30 &
    pid=$!
    printf 'W:%s\\n' ready
    wait "$pid"
    """.write(to: script, atomically: true, encoding: .utf8)

    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let before = session.gridSize
    XCTAssertGreaterThan(before.columns, 20)

    try run("sh '\(script.path)'", in: session)
    try await waitUntil("the size watcher") { self.screen(session).contains("W:ready") }

    session.resize(to: CGSize(width: 400, height: 200))

    let after = session.gridSize
    XCTAssertLessThan(after.columns, before.columns)
    XCTAssertLessThan(after.rows, before.rows)

    let expected = "S:\(after.rows)x\(after.columns)"
    try await waitUntil("stty to report \(expected)") { self.screen(session).contains(expected) }
  }

  // MARK: Scrollback

  /// Catches a capture that reads only the visible rows. Output scrolls well past the screen, and
  /// the capture still holds its first line.
  func testScrollbackTextHoldsOutputThatScrolledOffTheScreen() async throws {
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run(#"for i in $(seq 1 200); do echo "SB:$i:"; done"#, in: session)
    try await waitUntil("the last line") { self.screen(session).contains("SB:200:") }

    XCTAssertFalse(screen(session).contains("SB:1:\n"), "the first line is still on screen")

    let text = try XCTUnwrap(session.scrollbackText())
    XCTAssertTrue(text.contains("SB:1:\n"), "the capture lost the scrolled-off lines")
    XCTAssertTrue(text.contains("SB:200:\n"))
  }

  /// Catches a replay that loses shell integration, shows its text after the prompt, or leaks its
  /// variables and file. The shell reports its directory with OSC 7, which only integration does.
  /// The saved lines sit above the first prompt. The shell is a login shell, sees none of the
  /// launcher's variables, and the file is gone.
  func testAReplayShowsAboveThePromptAndKeepsShellIntegration() async throws {
    var directories: [String] = []
    let session = try startShell(replay: "EARLIER-ONE\nEARLIER-TWO\n")
    session.onEvent = { event in
      if case .workingDirectoryChanged(let path) = event { directories.append(path) }
    }

    try await waitUntil("the first prompt's working directory") { !directories.isEmpty }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let lines = screen(session).split(separator: "\n", omittingEmptySubsequences: false)
    let saved = try XCTUnwrap(lines.firstIndex { $0.contains("EARLIER-TWO") }, "\(lines)")
    let prompt = try XCTUnwrap(lines.lastIndex { $0.contains("%") }, "\(lines)")
    XCTAssertEqual(lines.firstIndex { $0.contains("EARLIER-ONE") }, saved - 1)
    XCTAssertLessThan(saved, prompt)

    try run(
      #"echo "V:${UNITERM_REPLAY_FILE-unset}:${UNITERM_REPLAY_SHELL-unset}:$0:""#, in: session)
    try await waitUntil("the shell's report") {
      self.screen(session).contains("V:unset:unset:-zsh:")
    }

    let left = try FileManager.default.contentsOfDirectory(atPath: engine.replayDirectory.path)
    XCTAssertFalse(left.contains { $0.hasPrefix("replay-") }, "the replay file was kept: \(left)")
  }

  /// Catches a pane that stays open after its shell ends.
  func testShellExitEmitsExited() async throws {
    let session = try startShell()
    var exited = false
    session.onEvent = { event in
      if case .exited = event { exited = true }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run("exit", in: session)
    try await waitUntil("the exit event") { exited }
    XCTAssertTrue(session.hasExited)
  }

  /// Catches font zoom that does not reach the surface. A bigger font fits fewer columns, and
  /// reset brings the grid back.
  func testFontZoomChangesTheGridAndResets() async throws {
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }
    let original = session.gridSize

    session.perform(.increaseFontSize)
    session.perform(.increaseFontSize)
    XCTAssertLessThan(session.gridSize.columns, original.columns)

    session.perform(.decreaseFontSize)
    session.perform(.decreaseFontSize)
    session.perform(.decreaseFontSize)
    XCTAssertGreaterThan(session.gridSize.columns, original.columns)

    session.perform(.resetFontSize)
    XCTAssertEqual(session.gridSize, original)
  }

  /// Catches copy, paste, and select all that do not work through the protocol.
  func testCopyPasteAndSelectAll() async throws {
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run("echo \"K:$((40+2)):\"", in: session)
    try await waitUntil("the marker") { self.screen(session).contains("K:42:") }

    pasteboard.clearContents()
    session.perform(.selectAll)
    session.perform(.copy)
    try await waitUntil("the copied text") {
      pasteboard.string(forType: .string)?.contains("K:42:") == true
    }

    pasteboard.clearContents()
    pasteboard.setString("echo \"P:$((6*7)):\"", forType: .string)
    session.perform(.paste)
    try press(session, keyCode: 0x24, characters: "\r")
    try await waitUntil("the pasted command's output") { self.screen(session).contains("P:42:") }
  }

  /// Catches OSC 9 and OSC 777 notifications that do not reach the protocol.
  func testNotificationsReachTheProtocol() async throws {
    let session = try startShell()
    var notes: [String] = []
    session.onEvent = { event in
      if case .notification(let title, let body) = event { notes.append("\(title)|\(body)") }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run("printf '\\033]9;nine-body\\a'", in: session)
    try await waitUntil("the OSC 9 notification") { !notes.isEmpty }

    // libghostty allows one notification per second.
    try await Task.sleep(for: .milliseconds(1_200))
    try run("printf '\\033]777;notify;sevens-title;sevens-body\\a'", in: session)
    try await waitUntil("the OSC 777 notification") { notes.count >= 2 }

    XCTAssertTrue(notes.contains("|nine-body"), "got \(notes)")
    XCTAssertTrue(notes.contains("sevens-title|sevens-body"))
  }

  /// Catches an OSC 52 clipboard read that is answered before the user decides. The request waits.
  /// While it waits, the program receives nothing. An allowed request then sends the clipboard, and
  /// a denied one sends none of it.
  func testClipboardReadIsNeverAnsweredWithoutConfirmation() async throws {
    pasteboard.clearContents()
    pasteboard.setString("SECRET-CB", forType: .string)
    let encoded = Data("SECRET-CB".utf8).base64EncodedString()

    let session = try startShell()
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    // The shell reads the terminal's reply itself, so the output shows what the program received.
    let ask =
      "printf '\\033]52;c;?\\a'; IFS= read -rs -t 8 -d $'\\\\' reply; echo \"G:${reply#*;c;}:\""

    try run(ask, in: session)
    try await waitUntil("the clipboard request") { !requests.isEmpty }
    XCTAssertEqual(requests[0].kind, .read)

    try await Task.sleep(for: .seconds(1))
    XCTAssertTrue(session.isRunningSomething, "the program got its answer before confirmation")
    XCTAssertFalse(screen(session).contains(encoded), "the clipboard was sent before confirmation")

    requests[0].resolve(allow: false)
    try await waitUntil("the read to finish after a denial") { !session.isRunningSomething }
    XCTAssertFalse(screen(session).contains(encoded), "a denied read still sent the clipboard")

    try run(ask, in: session)
    try await waitUntil("the second request") { requests.count == 2 }
    requests[1].resolve(allow: true)
    try await waitUntil("the clipboard after confirmation") {
      self.screen(session).contains(encoded)
    }
  }

  /// Catches a Kitty clipboard read that is answered, or that asks the user, instead of being
  /// denied. Both a read for text and a read for the type names alone must get an `EPERM` status.
  /// The second kind reaches no confirm callback, so it proves the denial in the read callback.
  func testKittyClipboardReadsAreDenied() async throws {
    pasteboard.clearContents()
    pasteboard.setString("SECRET-KITTY", forType: .string)
    let encoded = Data("SECRET-KITTY".utf8).base64EncodedString()

    let session = try startShell()
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    // The payload names the MIME types, base64 encoded: "text/plain", then "." for the type names.
    let reads = [("T", "dGV4dC9wbGFpbg=="), ("L", "Lg==")]
    for (marker, payload) in reads {
      try run(
        "printf '\\033]5522;type=read;\(payload)\\a'; IFS= read -rs -t 8 -d $'\\a' reply; "
          + "echo \"\(marker):${reply#*status=}:\"", in: session)
      try await waitUntil("the \(marker) reply") {
        self.screen(session).contains("\(marker):EPERM:")
      }
    }

    XCTAssertTrue(requests.isEmpty, "a Kitty read asked the user")
    XCTAssertFalse(screen(session).contains(encoded), "a Kitty read received the clipboard")
  }

  /// Catches an OSC 52 write that asks the user, or that stops landing, now that `clipboard-write`
  /// is `ask`. It also catches a Kitty write that reaches the pasteboard instead of an `EPERM`.
  func testOSC52WritesLandAndKittyWritesAreDenied() async throws {
    pasteboard.clearContents()

    let session = try startShell()
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let osc52 = Data("WROTE-52".utf8).base64EncodedString()
    try run("printf '\\033]52;c;\(osc52)\\a'", in: session)
    try await waitUntil("the OSC 52 write") {
      pasteboard.string(forType: .string) == "WROTE-52"
    }

    // A Kitty write is a begin packet, a data packet for each MIME type, and an empty commit.
    let kitty = Data("WROTE-KITTY".utf8).base64EncodedString()
    try run(
      "printf '\\033]5522;type=write\\a\\033]5522;type=wdata:mime=dGV4dC9wbGFpbg==;\(kitty)\\a"
        + "\\033]5522;type=wdata\\a'; IFS= read -rs -t 8 -d $'\\a' reply; "
        + "echo \"W:${reply#*status=}:\"", in: session)
    try await waitUntil("the Kitty write reply") { self.screen(session).contains("W:EPERM:") }

    XCTAssertEqual(pasteboard.string(forType: .string), "WROTE-52")
    XCTAssertTrue(requests.isEmpty, "a clipboard write asked the user")
  }

  /// Catches a controlled session whose OSC 52 write lands without asking, a denial that still
  /// writes, and a session permission that does not cover the next write. The writes arrive
  /// through libghostty's own write callback, with its confirm flag set. A controlled read asks
  /// too, and its session permission answers the next read without asking.
  func testAControlledSessionAsksBeforeOSC52WritesAndReads() async throws {
    pasteboard.clearContents()
    pasteboard.setString("BEFORE", forType: .string)

    let session = try startShell(policy: TerminalClipboardPolicy(controlled: true, generation: 1))
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    func write(_ text: String) throws {
      try run("printf '\\033]52;c;\(Data(text.utf8).base64EncodedString())\\a'", in: session)
    }

    try write("W-DENIED")
    try await waitUntil("the first write request") { requests.count == 1 }
    XCTAssertEqual(requests[0].kind, .write)
    XCTAssertTrue(requests[0].offersSession)
    requests[0].resolve(.deny)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(pasteboard.string(forType: .string), "BEFORE", "a denied write landed")

    try write("W-ONCE")
    try await waitUntil("the second write request") { requests.count == 2 }
    requests[1].resolve(.allowOnce)
    try await waitUntil("the write allowed once") {
      pasteboard.string(forType: .string) == "W-ONCE"
    }

    try write("W-SESSION")
    try await waitUntil("a write after allow once to ask again") { requests.count == 3 }
    requests[2].resolve(.allowForSession)
    try await waitUntil("the write allowed for the session") {
      pasteboard.string(forType: .string) == "W-SESSION"
    }

    try write("W-FREE")
    try await waitUntil("a write the session covers") {
      pasteboard.string(forType: .string) == "W-FREE"
    }
    XCTAssertEqual(requests.count, 3, "a write the session covers asked again")

    let encoded = Data("W-FREE".utf8).base64EncodedString()
    let ask =
      "printf '\\033]52;c;?\\a'; IFS= read -rs -t 8 -d $'\\\\' reply; echo \"G:${reply#*;c;}:\""

    try run(ask, in: session)
    try await waitUntil("the read request") { requests.count == 4 }
    XCTAssertEqual(requests[3].kind, .read)
    XCTAssertTrue(requests[3].offersSession)
    requests[3].resolve(.allowForSession)
    try await waitUntil("the read allowed for the session") {
      self.screen(session).contains("G:\(encoded)")
    }

    try run(ask.replacingOccurrences(of: "G:", with: "H:"), in: session)
    try await waitUntil("a read the session covers") {
      self.screen(session).contains("H:\(encoded)")
    }
    XCTAssertEqual(requests.count, 4, "a read the session covers asked again")
  }

  /// Catches a program that floods a controlled session with OSC 52 writes and queues one prompt
  /// for each. While a write's prompt waits, every later write is denied at once, with no prompt,
  /// and none of them reaches the clipboard. Once the prompt is answered, the next write asks.
  func testAFloodOfControlledWritesAsksOnceAndChangesNothing() async throws {
    pasteboard.clearContents()
    pasteboard.setString("BEFORE-FLOOD", forType: .string)

    let session = try startShell(policy: TerminalClipboardPolicy(controlled: true, generation: 1))
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let flood = (1...20).map { "\\033]52;c;\(Data("FLOOD-\($0)".utf8).base64EncodedString())\\a" }

    try run("printf '\(flood.joined())'; echo FLOOD-$((1 + 1))-DONE", in: session)
    try await waitUntil("the flood to finish") { self.screen(session).contains("FLOOD-2-DONE") }
    try await Task.sleep(for: .milliseconds(500))

    XCTAssertEqual(requests.count, 1, "a flood of writes queued a prompt for each")
    XCTAssertEqual(pasteboard.string(forType: .string), "BEFORE-FLOOD")

    requests[0].resolve(.deny)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(pasteboard.string(forType: .string), "BEFORE-FLOOD")

    try run("printf '\\033]52;c;\(Data("AFTER".utf8).base64EncodedString())\\a'", in: session)
    try await waitUntil("a write after the answer to ask") { requests.count == 2 }
    requests[1].resolve(.deny)
  }

  /// Catches an answer that releases data or writes after the session's policy changed under it,
  /// or after the session closed. A pending write and a pending read are each answered allow once
  /// after the change, and neither the clipboard nor the program gets anything.
  func testAPendingClipboardAnswerIsStaleAfterAPolicyChangeOrAClose() async throws {
    pasteboard.clearContents()
    pasteboard.setString("SECRET-STALE", forType: .string)

    let session = try startShell(policy: TerminalClipboardPolicy(controlled: true, generation: 1))
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let encoded = Data("SECRET-STALE".utf8).base64EncodedString()
    let ask =
      "printf '\\033]52;c;?\\a'; IFS= read -rs -t 8 -d $'\\\\' reply; echo \"G:${reply#*;c;}:\""

    try run(ask, in: session)
    try await waitUntil("the read request") { requests.count == 1 }

    session.setClipboardPolicy(TerminalClipboardPolicy(controlled: false, generation: 2))
    requests[0].resolve(.allowOnce)

    try await waitUntil("the read to finish after a stale answer") {
      !session.isRunningSomething
    }
    XCTAssertFalse(screen(session).contains(encoded), "a stale read sent the clipboard")

    let written = Data("W-STALE".utf8).base64EncodedString()

    session.setClipboardPolicy(TerminalClipboardPolicy(controlled: true, generation: 3))
    try run("printf '\\033]52;c;\(written)\\a'", in: session)
    try await waitUntil("the write request") { requests.count == 2 }

    session.setClipboardPolicy(TerminalClipboardPolicy(controlled: true, generation: 4))
    requests[1].resolve(.allowOnce)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(
      pasteboard.string(forType: .string), "SECRET-STALE", "a stale write landed")

    try run("printf '\\033]52;c;\(written)\\a'", in: session)
    try await waitUntil("the write request before the close") { requests.count == 3 }

    session.close()
    requests[2].resolve(.allowOnce)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(
      pasteboard.string(forType: .string), "SECRET-STALE",
      "an answer after the session closed wrote the clipboard")
  }

  /// Catches libghostty bindings that survive in the generated config. With them, Cmd-Z, Cmd-W,
  /// Cmd-T, Cmd-D, and Cmd-Q would be taken by the terminal before uniterm's menu.
  func testBuiltInBindingsAreCleared() throws {
    let session = try startShell()
    let view = try XCTUnwrap(session.view as? GhosttySurfaceView)

    let keys: [(UInt16, Character)] = [
      (0x06, "z"), (0x0D, "w"), (0x11, "t"), (0x02, "d"), (0x0C, "q"),
    ]
    for (code, character) in keys {
      XCTAssertFalse(
        view.isLibraryBinding(keyCode: code, character: character, mods: .command),
        "Cmd-\(character) is still a libghostty binding")
    }
  }

  private var configFile: URL {
    sandbox.appending(path: "config/ghostty-\(getpid()).conf")
  }

  /// Catches a palette change that never reaches a running surface. The engine writes the new
  /// config, and libghostty announces that it applied it to the surface. The announcement stops
  /// when the `ghostty_app_update_config` call is removed.
  ///
  /// What this cannot prove is the color on screen, since libghostty has no call to read a
  /// surface's colors. That stays a check for the user.
  func testPaletteChangeReachesTheConfigFileAndTheRunningSurface() async throws {
    let session = try startShell()
    let view = try XCTUnwrap(session.view as? GhosttySurfaceView)
    let latte = try String(contentsOf: configFile, encoding: .utf8)
    XCTAssertTrue(latte.contains("background = #eff1f5"))

    let before = view.configChangeCount
    try engine.apply(palette: .mocha)

    let mocha = try String(contentsOf: configFile, encoding: .utf8)
    XCTAssertTrue(mocha.contains("background = #1e1e2e"))
    XCTAssertFalse(mocha.contains("background = #eff1f5"))
    try await waitUntil("the surface to apply the Mocha config") { view.configChangeCount > before }

    let afterMocha = view.configChangeCount
    try engine.apply(palette: .latte)
    try await waitUntil("the surface to apply the Latte config") {
      view.configChangeCount > afterMocha
    }
    XCTAssertTrue(try String(contentsOf: configFile, encoding: .utf8).contains("#eff1f5"))
  }

  /// An equal palette is skipped, so the surface is not told twice.
  func testApplyingTheSamePaletteTwiceDoesNotReloadTheSurface() async throws {
    let session = try startShell()
    let view = try XCTUnwrap(session.view as? GhosttySurfaceView)

    try engine.apply(palette: .latte)
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(view.configChangeCount, 0)
  }

  /// The direct children of a process, by pid. The unused tail of the buffer stays zero.
  private func children(of parent: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 256)
    let result = proc_listchildpids(parent, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return result > 0 ? Array(buffer.prefix { $0 > 0 }) : []
  }

  /// The tree under `root`, each member recorded in one pass with its start time. A child counts
  /// only while its parent is still the member that listed it, so a pid taken over between the
  /// listing and the read is left out.
  ///
  /// `login` is setuid root, so the system gives no audit token for it and its signal goes by pid.
  private func recordTree(of root: pid_t) -> [TreeMember] {
    guard let rootRecord = ProcessRecord(pid: root) else { return [] }

    var found = [rootRecord]
    var members = [TreeMember(record: rootRecord, path: signalPath(of: root))]
    var index = 0

    while index < found.count {
      let parent = found[index].pid

      for child in children(of: parent) where !found.contains(where: { $0.pid == child }) {
        guard let record = ProcessRecord(pid: child),
          ProcessInspection.parent(of: child)?.pid == parent
        else { continue }

        found.append(record)
        members.append(TreeMember(record: record, path: signalPath(of: child)))
      }

      index += 1
    }

    return members
  }

  private func signalPath(of pid: pid_t) -> ExpectedSignalPath {
    ProcessInspection.executablePath(of: pid)?.hasSuffix("/login") == true ? .pid : .token
  }

  /// Catches a teardown that expects the wrong signal path for the processes under `login`. The
  /// teardown ends them after `close()` has already reaped `login`, so it never sends a live
  /// signal to `login` itself. This test sends the harmless SIGCONT to each live member through the
  /// path the teardown expects, so a system that changes what it allows fails here and not only
  /// when a leaked process needs ending.
  func testEachMemberOfTheSessionsTreeTakesTheSignalPathTheTeardownExpects() async throws {
    let before = Set(children(of: getpid()))
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let login = try XCTUnwrap(
      Set(children(of: getpid())).subtracting(before).first, "the session's child was not found")

    try run("sleep 1000", in: session)
    try await waitUntil("sleep to run") { session.isRunningSomething }

    let members = recordTree(of: login)
    defer { endTree(members) }

    XCTAssertGreaterThan(members.count, 2, "no sleep under the shell")
    XCTAssertEqual(members.first?.path, .pid, "`login` is expected to take the pid path")

    for member in members {
      XCTAssertTrue(
        ProcessSender.signal(SIGCONT, member.record, expecting: member.path),
        "\(member.record.pid) was not reached")
    }
  }

  /// Guards the main thread against a hung close. libghostty hangs the child up with SIGHUP and
  /// loops until the child it tracks is gone. A shell that ignores SIGHUP might keep that loop
  /// running for good, and the free runs on the main thread.
  ///
  /// The trace found no hang. libghostty tracks `login(1)`, which exits on SIGHUP, so `close()`
  /// returns at once. The shell and its `sleep` survive, as `nohup` work does after any terminal
  /// closes. This test passed before any change and stays as a guard. A rescue kills the tree
  /// after 8 seconds so that a regression cannot hang the suite. The test ends the tree itself.
  func testCloseReturnsWhenTheChildIgnoresSIGHUP() async throws {
    let before = Set(children(of: getpid()))
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let child = try XCTUnwrap(
      Set(children(of: getpid())).subtracting(before).first, "the session's child was not found")

    try run("trap '' HUP; sleep 1000", in: session)
    try await waitUntil("sleep to run") { session.isRunningSomething }
    try await Task.sleep(for: .milliseconds(300))

    let members = recordTree(of: child)
    XCTAssertGreaterThan(members.count, 2, "no sleep under the shell")
    defer { endTree(members) }

    let rescue = DispatchWorkItem { endTree(members) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: rescue)

    let started = ContinuousClock.now
    session.close()
    rescue.cancel()
    let elapsed = ContinuousClock.now - started

    XCTAssertLessThan(elapsed, .seconds(3), "close() blocked the main thread for \(elapsed)")
  }

  /// Catches a spawned shell that cannot use the home folder, as a sandbox would force. The shell
  /// writes a file under `$HOME`, reads it back, and the file is removed.
  func testShellCanReadAndWriteHome() async throws {
    let name = ".uniterm-test-\(UUID().uuidString)"
    let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: name)
    defer { try? FileManager.default.removeItem(at: file) }

    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let token = "wrote-\(UUID().uuidString.prefix(8))"
    try run(
      "printf %s \(token) > \"$HOME/\(name)\" && echo \"H:$(cat \"$HOME/\(name)\"):\"", in: session)
    try await waitUntil("the file's contents") { self.screen(session).contains("H:\(token):") }

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), token)
  }

  /// Catches a real key path that drops the apostrophe. keyCode 39 then Space types an apostrophe
  /// on US and on US Extended, where the apostrophe is a dead key that Space completes. The
  /// events go through `keyDown` and the text input system, as typing does.
  func testApostropheTypedThroughKeyDownReachesTheShell() async throws {
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try press(session, keyCode: 39, characters: "'")
    try press(session, keyCode: 49, characters: " ")

    try await waitUntil("an apostrophe at the prompt") { self.screen(session).contains("% '") }
  }

  /// Catches a surface that drops or mangles a Command key that no menu item takes. Such a key is
  /// terminal input. A program that turns on the kitty keyboard protocol reads Command-J as `j`
  /// with the super bit, `CSI 106 ; 9 u`. A legacy program reads nothing for it.
  ///
  /// The surface's `performKeyEquivalent` declines the key, as it does for any Command key, so the
  /// menu can take it first. This cannot prove that the window's menu takes no Command-J.
  func testAnUnclaimedCommandKeyReachesAKittyProgramAndNotALegacyOne() async throws {
    for (mode, enable, expected) in [("kitty", #"\033[>1u"#, "\u{1B}[106;9u"), ("legacy", "", "")] {
      let output = sandbox.appending(path: "keys-\(mode)")
      let session = try startProgram([
        "/bin/sh", "-c",
        #"printf '\#(enable)'; stty raw -echo min 0 time 30; printf 'R:ready'; "#
          + #"dd bs=64 count=1 of="$1" 2>/dev/null"#,
        "sh", output.path,
      ])
      let view = try XCTUnwrap(session.view as? GhosttySurfaceView)
      var exited = false
      session.onEvent = { event in
        if case .exited = event { exited = true }
      }

      try await waitUntil("the \(mode) program to read") {
        self.screen(session).contains("R:ready")
      }

      let commandJ = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: "j",
          charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
      XCTAssertFalse(view.performKeyEquivalent(with: commandJ), "the surface claimed Command-J")

      try press(session, keyCode: 38, characters: "j", modifiers: .command)
      try await waitUntil("the \(mode) program to end") { exited }

      let read = try String(contentsOf: output, encoding: .utf8)
      XCTAssertEqual(read, expected, "the \(mode) program read \(Array(read.unicodeScalars))")
    }
  }

  /// The menu reaches the terminal with a nil target, so AppKit finds `copy:` and the others on
  /// the first responder and asks `validateMenuItem` whether to enable them. This drives that path
  /// in-process.
  func testMenuActionsReachTheFocusedTerminal() async throws {
    let session = try startShell()
    let view = try XCTUnwrap(session.view as? GhosttySurfaceView)
    XCTAssertTrue(window.makeFirstResponder(view))
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let copyItem = NSMenuItem(
      title: "Copy", action: #selector(TerminalMenuActions.copy(_:)), keyEquivalent: "c")
    XCTAssertFalse(view.validateMenuItem(copyItem), "Copy is enabled with nothing selected")

    try run("echo \"M:$((6*7)):\"", in: session)
    try await waitUntil("the marker") { self.screen(session).contains("M:42:") }

    XCTAssertTrue(view.tryToPerform(#selector(TerminalMenuActions.selectAll(_:)), with: nil))
    XCTAssertTrue(view.validateMenuItem(copyItem), "Copy is disabled with a selection")

    pasteboard.clearContents()
    XCTAssertTrue(view.tryToPerform(#selector(TerminalMenuActions.copy(_:)), with: nil))
    try await waitUntil("the copied text") {
      pasteboard.string(forType: .string)?.contains("M:42:") == true
    }

    pasteboard.clearContents()
    pasteboard.setString("echo \"V:$((5*9)):\"", forType: .string)
    XCTAssertTrue(view.tryToPerform(#selector(TerminalMenuActions.paste(_:)), with: nil))
    try press(session, keyCode: 0x24, characters: "\r")
    try await waitUntil("the pasted command's output") { self.screen(session).contains("V:45:") }

    // On a 1x display one step can round to the same cell width, so the font grows by two.
    let columns = session.gridSize.columns
    for _ in 0..<2 {
      XCTAssertTrue(
        view.tryToPerform(#selector(TerminalMenuActions.increaseTerminalFontSize(_:)), with: nil))
    }
    XCTAssertLessThan(session.gridSize.columns, columns)
    XCTAssertTrue(
      view.tryToPerform(#selector(TerminalMenuActions.resetTerminalFontSize(_:)), with: nil))
    XCTAssertEqual(session.gridSize.columns, columns)

    XCTAssertTrue(
      view.tryToPerform(#selector(TerminalMenuActions.clearTerminalScreen(_:)), with: nil))
    try await waitUntil("the cleared screen") { !self.screen(session).contains("M:42:") }
  }

  // MARK: Tabs and program mode

  /// Catches a second session that shares the first one's tty, which tabs must never do. Two shells
  /// report different terminal devices. A foreground `cat` in the first makes only the first read
  /// as running, since the query is per session.
  func testTwoSessionsAreIndependentTerminals() async throws {
    let first = try startShell()
    let second = try startShell()
    try await waitUntil("two idle prompts") {
      !first.isRunningSomething && !second.isRunningSomething
    }

    try run("echo \"Y:$(tty):\"", in: first)
    try run("echo \"Y:$(tty):\"", in: second)

    let pattern = #"Y:(/dev/ttys\d+):"#
    try await waitUntil("both devices") {
      self.firstMatch(pattern, in: self.screen(first)) != nil
        && self.firstMatch(pattern, in: self.screen(second)) != nil
    }

    let one = try XCTUnwrap(firstMatch(pattern, in: screen(first)))
    let two = try XCTUnwrap(firstMatch(pattern, in: screen(second)))
    XCTAssertNotEqual(one, two)

    try run("cat", in: first)
    try await waitUntil("cat to run in the first session") { first.isRunningSomething }

    try run("echo \"Z:$((6*7)):\"", in: second)
    try await waitUntil("the second session's own command to finish") {
      self.screen(second).contains("Z:42:") && !second.isRunningSomething
    }
    XCTAssertTrue(first.isRunningSomething, "the first session stopped reading as running")
  }

  private func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
    else { return nil }

    return String(text[range])
  }

  /// Catches program mode that runs a shell instead of the program, or that rewrites its
  /// arguments. Also catches a pane that waits for a key after its program ends. The program
  /// prints its arguments, which hold a space, an apostrophe, a semicolon, a glob, and a variable
  /// name. None of them may be interpreted. The program reads a line, so it is running until
  /// Return. Once it ends, the exit event arrives with no further key, and libghostty's own
  /// "Press any key" text never appears.
  func testProgramRunsWithItsArgumentsIntactAndEndsWithoutAKey() async throws {
    let session = try startProgram([
      "/bin/sh", "-c", #"printf 'A:%s:%s:%s:\n' "$1" "$2" "$3"; read x"#, "sh",
      "two words", "it's;*", "$HOME",
    ])
    var exited = false
    session.onEvent = { event in
      if case .exited = event { exited = true }
    }

    try await waitUntil("the arguments") {
      self.screen(session).contains("A:two words:it's;*:$HOME:")
    }
    XCTAssertTrue(session.isRunningSomething, "a program waiting for input reads as idle")

    try press(session, keyCode: 0x24, characters: "\r")
    try await waitUntil("the exit event") { exited }

    XCTAssertFalse(self.screen(session).contains("Press any key"), self.screen(session))
  }

  /// Catches a program that ends at once leaving the pane open. libghostty treats a command that
  /// ends within 250 ms of launch as failed, and waits for a key under its own error text. The
  /// exit event arrives anyway, and the text never appears.
  func testAProgramThatEndsAtOnceEndsWithoutAKey() async throws {
    let session = try startProgram(["/usr/bin/true"])
    var exited = false
    session.onEvent = { event in
      if case .exited = event { exited = true }
    }

    try await waitUntil("the exit event") { exited }

    XCTAssertFalse(self.screen(session).contains("Press any key"), self.screen(session))
  }

  /// Catches a program launch that loses Ghostty's TERM, or an ssh launch that keeps it. A plain
  /// program sees xterm-ghostty. An ssh program, by name or by path, hands xterm-256color to the
  /// process that ssh starts. The probe is ssh's ProxyCommand, which runs locally with ssh's own
  /// environment, so no remote host is needed. A real host without the terminfo entry is not
  /// reachable from here.
  func testProgramModeKeepsGhosttyTermExceptForSsh() async throws {
    let plain = try startProgram(["/bin/sh", "-c", #"echo "T:$TERM:"; read x"#])
    try await waitUntil("the plain program's TERM") {
      self.screen(plain).contains("T:xterm-ghostty:")
    }

    // ssh runs the proxy command as `exec <command>`, so only the echo runs and ssh then fails
    // within 250 ms. libghostty adds an error screen below the output, which keeps the echo line.
    let probe = #"ProxyCommand=echo "PT:$TERM:" >&2"#

    for ssh in ["ssh", "/usr/bin/ssh"] {
      let session = try startProgram(
        [ssh, "-F", "/dev/null", "-o", "BatchMode=yes", "-o", probe, "nowhere"])

      try await waitUntil("the TERM that \(ssh) passes on") {
        self.screen(session).contains("PT:xterm-256color:")
      }
      XCTAssertFalse(screen(session).contains("PT:xterm-ghostty:"), ssh)
    }
  }

  /// Catches a shell that inherits noise or another Ghostty's resources, and one that reports
  /// libghostty's name. The test process starts with `MAKEFLAGS` set, runs the startup scrub, and
  /// then inherits a `GHOSTTY_RESOURCES_DIR` that points nowhere. The shell sees no `MAKEFLAGS`,
  /// the engine's own resources directory, and `TERM_PROGRAM=uniterm` with uniterm's version. The
  /// harness cannot run the app's `main`, so it calls the same scrub function that `main` calls.
  func testShellSeesTheScrubbedEnvironmentAndUnitermsIdentity() async throws {
    setenv("MAKEFLAGS", "-j8", 1)
    _ = InheritedEnvironment.scrubProcess()
    setenv("GHOSTTY_RESOURCES_DIR", "/nonexistent/other-ghostty", 1)

    engine = try GhosttyTerminalEngine(
      configStore: TerminalConfigStore(directory: sandbox.appending(path: "config-env")),
      resourcesDirectory: resources, helperDirectory: helper, palette: .latte,
      pasteboard: pasteboard)

    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let version = TerminalIdentity.bundleVersion
    try run(
      #"echo "TP:$TERM_PROGRAM:$TERM_PROGRAM_VERSION:"; echo "MF:${MAKEFLAGS-unset}:"; "#
        + #"[ "$GHOSTTY_RESOURCES_DIR" = '\#(resources.path)' ] && echo "RD:$((6*7)):""#,
      in: session)

    try await waitUntil("the environment report") {
      let text = self.screen(session)
      return text.contains("TP:uniterm:\(version):") && text.contains("MF:unset:")
        && text.contains("RD:42:")
    }
  }

  /// Catches a wrong claim about program launches. libghostty picks shell integration from the
  /// first word of the command. uniterm single-quotes every word, so the word never reads as
  /// `zsh` and integration stays off, whether the program is given by name or by path. A swapped
  /// `ZDOTDIR` would show that integration reached a program the user typed.
  func testAProgramLaunchOfZshGetsNoShellIntegration() async throws {
    for command in [["/bin/zsh", "-f"], ["zsh", "-f"]] {
      let session = try startProgram(command)

      try run(
        #"case "$ZDOTDIR" in *shell-integration*) echo "ZI:$((6*7)):yes";; *) echo "ZI:$((6*7)):no";; esac"#,
        in: session)

      try await waitUntil("the ZDOTDIR report of \(command[0])") {
        self.screen(session).contains("ZI:42:")
      }
      XCTAssertTrue(screen(session).contains("ZI:42:no"), "\(command): integration applied")
    }
  }

  /// Catches a backend patch that reports no child, or reports some other process, such as the
  /// pty's foreground group. The event names a direct child of this process, and that child is
  /// `login`, the session root a shell runs under.
  func testProcessStartedEventReportsTheDirectChild() async throws {
    try await assertReportsLogin(try startShell())
  }

  /// Catches the same for program mode, where libghostty spawns `login` for the program too.
  func testProcessStartedEventReportsTheDirectChildInProgramMode() async throws {
    try await assertReportsLogin(try startProgram(["/bin/sleep", "30"]))
  }

  /// Catches an OSC 7 from another host that libghostty adopts as the working directory, and one
  /// it drops with no word to the embedder. The report names its host, and the directory stays.
  func testAnOSC7ForAnotherHostReportsItsHostAndKeepsTheDirectory() async throws {
    let session = try startShell()
    var hosts: [String] = []
    var directories: [String] = []
    session.onEvent = { event in
      switch event {
      case .remoteHostReported(let host): hosts.append(host)
      case .workingDirectoryChanged(let path): directories.append(path)
      default: break
      }
    }

    try await waitUntil("an idle prompt") { !session.isRunningSomething && !directories.isEmpty }

    try run("printf '\\033]7;file://remote.example.invalid/etc/remote-only\\007'", in: session)
    try await waitUntil("the remote host report") { !hosts.isEmpty }

    XCTAssertEqual(hosts, ["remote.example.invalid"])
    XCTAssertFalse(
      directories.contains { $0.contains("remote-only") }, "the remote path was adopted")
    XCTAssertFalse(
      session.workingDirectory?.contains("remote-only") ?? false, "the remote path was adopted")
  }

  /// Moves the pointer onto a cell of the session's grid, or clicks there, as the user does with
  /// Command held.
  private func point(
    _ session: any TerminalSession, row: Int, column: Int, type: NSEvent.EventType,
    modifiers: NSEvent.ModifierFlags = .command
  ) throws {
    let grid = session.gridSize
    let size = session.view.frame.size
    let x = size.width / CGFloat(grid.columns) * (CGFloat(column) + 0.5)
    let fromTop = size.height / CGFloat(grid.rows) * (CGFloat(row) + 0.5)
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: x, y: size.height - fromTop), modifierFlags: modifiers,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))

    switch type {
    case .leftMouseDown: session.view.mouseDown(with: event)
    case .leftMouseUp: session.view.mouseUp(with: event)
    default: session.view.mouseMoved(with: event)
    }
  }

  /// Catches a hover that reports a hyperlink's text in place of its target, a click that is not
  /// reported to the embedder, and libghostty joining clicked relative text to the working
  /// directory and checking it on disk. The relative file exists in the shell's directory, so an
  /// unpatched libghostty would hand the embedder its absolute path.
  func testCommandHoverAndClickReportTheLinkTextAsPrinted() async throws {
    let session = try startShell()
    let work = sandbox.appending(path: "work")

    try FileManager.default.createDirectory(
      at: work.appending(path: "sub"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: work.appending(path: "sub/file.txt"))

    var hovers: [String?] = []
    var opens: [String] = []
    var directories = 0
    session.onEvent = { event in
      switch event {
      case .linkHovered(let text): hovers.append(text)
      case .linkOpenRequested(let text): opens.append(text)
      case .workingDirectoryChanged: directories += 1
      default: break
      }
    }

    try await waitUntil("an idle prompt") { !session.isRunningSomething && directories > 0 }

    let absolute = work.appending(path: "sub/file.txt").path

    try run(
      "printf '\\033[H\\033[2J%s\\n%s\\n\\033]8;;file:///etc/hosts\\033\\\\LINKTEXT\\033]8;;\\033\\\\\\n%s\\n' "
        + "\(absolute) sub/file.txt https://example.com/x",
      in: session)
    try await waitUntil("the printed lines") { self.screen(session).contains("LINKTEXT") }

    // The absolute path is longer than a row, so it wraps and the other lines start below it.
    let columns = session.gridSize.columns
    let below = (absolute.count + columns - 1) / columns

    let rows: [(row: Int, expected: String)] = [
      (0, absolute), (below, "sub/file.txt"), (below + 1, "file:///etc/hosts"),
      (below + 2, "https://example.com/x"),
    ]

    for (row, expected) in rows {
      hovers = []
      opens = []

      // libghostty reports a hover once the pointer has moved across cells, so the pointer keeps
      // moving until the report arrives.
      var column = 3

      do {
        try await waitUntil("the hover over row \(row)", timeout: .seconds(10)) {
          column = column == 3 ? 4 : 3
          try? self.point(session, row: row, column: column, type: .mouseMoved)
          return hovers.compactMap { $0 }.last == expected
        }
      } catch {
        XCTFail("row \(row) expected \(expected), hovers were \(hovers)")
        throw error
      }

      try point(session, row: row, column: 3, type: .leftMouseDown)
      try point(session, row: row, column: 3, type: .leftMouseUp)
      try await waitUntil("the click on row \(row), saw \(opens)", timeout: .seconds(5)) {
        !opens.isEmpty
      }
      XCTAssertEqual(opens, [expected], "row \(row)")
    }

    try point(session, row: 10, column: 3, type: .mouseMoved)
    try await waitUntil("the pointer leaving the link") { hovers.last == .some(nil) }
  }

  /// Catches a closed session's queued exit reaching the session that reuses its address.
  ///
  /// libghostty queues each surface's messages for the main thread. The allocator often gives a
  /// freed surface's address to the next surface, as when a REPL restarts. A stale exit would end
  /// the new session's REPL, and libghostty would close it on the next key press.
  ///
  /// The main thread does not yield until the second session exists, so libghostty cannot drain
  /// the first session's exit before then. That exit is queued ahead of the second session's
  /// start, so it has had its turn once the start arrives.
  ///
  /// A pair whose second surface lands at another address proves nothing. The test makes another
  /// pair, and skips only when none of five pairs reuses an address.
  func testAClosedSessionsQueuedExitNeverReachesTheSessionThatReusesItsAddress() async throws {
    var reused: (any TerminalSession)?

    for _ in 0..<5 {
      let second = try startSecondAfterAQueuedExit()

      if second.reusedAddress {
        reused = second.session

        break
      }

      second.session.close()
    }

    guard let second = reused else {
      throw XCTSkip("no second surface reused the first's address, so nothing was proved")
    }

    var events: [String] = []

    second.onEvent = { event in
      switch event {
      case .exited: events.append("exited")
      case .processStarted: events.append("started")
      default: break
      }
    }

    try await waitUntil("the second session's start") { events.contains("started") }

    XCTAssertEqual(events, ["started"], "the second session got the first session's exit")
  }

  /// Starts a session whose program ends at once, waits on this thread until libghostty has reaped
  /// its child, closes it, and starts a second session. Nothing yields the main thread meanwhile.
  private func startSecondAfterAQueuedExit() throws -> (
    session: any TerminalSession, reusedAddress: Bool
  ) {
    let before = Set(children(of: getpid()))
    let first = try startProgram(["/usr/bin/true"])
    let deadline = ContinuousClock.now + .seconds(10)
    var login: pid_t?

    // libghostty reaps its child on its IO thread and queues the exit right after. Once the child
    // is gone, freeing the surface joins that thread, so the exit is in the queue on return.
    while ContinuousClock.now < deadline {
      let current = Set(children(of: getpid())).subtracting(before)

      if login == nil { login = current.first }

      if let login, !current.contains(login) { break }

      sched_yield()
    }

    let reaped = try XCTUnwrap(login, "the first session never started a child")

    XCTAssertFalse(children(of: getpid()).contains(reaped), "the first session's child never ended")

    let freed = try XCTUnwrap(Self.address(of: first), "the first session has no surface")

    first.close()

    let second = try startProgram(["/bin/sleep", "30"])

    return (second, Self.address(of: second) == freed)
  }

  /// The libghostty surface a session draws, read by reflection, so the view exports nothing for
  /// the test.
  private static func address(of session: any TerminalSession) -> UnsafeMutableRawPointer? {
    Mirror(reflecting: session).children.first { $0.label == "surface" }
      .flatMap { $0.value as? UnsafeMutableRawPointer }
  }

  /// Waits for the session's identity event, then checks the PID it names: a direct child of
  /// this process, running `login`, and started at the second the event reports.
  private func assertReportsLogin(
    _ session: any TerminalSession, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    var reported: TerminalProcessIdentity?

    session.onEvent = { event in
      if case .processStarted(let identity) = event { reported = identity }
    }

    try await waitUntil("the processStarted event") { reported != nil }

    let identity = try XCTUnwrap(reported, file: file, line: line)

    XCTAssertTrue(
      children(of: getpid()).contains(identity.pid), "the PID is not a direct child", file: file,
      line: line)

    // The child is setuid-root login, which proc_pidinfo refuses for this user, so read it with
    // sysctl.
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, identity.pid]
    var info = kinfo_proc()
    var command = ""

    // processStarted can arrive between the fork and the child's exec of login. Until that exec,
    // the child still carries this process's name, so the read waits for it. A child that is not
    // login never takes the name, and still fails below.
    let deadline = ContinuousClock.now + .seconds(10)

    repeat {
      var size = MemoryLayout<kinfo_proc>.size

      guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
        return XCTFail("no process info", file: file, line: line)
      }

      command = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      }

      if command == "login" { break }

      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline

    XCTAssertEqual(command, "login", "the direct child is not login", file: file, line: line)
    XCTAssertEqual(
      Int(info.kp_proc.p_starttime.tv_sec), identity.started, "the start time is not the child's",
      file: file, line: line)
  }
}

/// A process of a session's tree, with the path its signal is expected to take.
private struct TreeMember: Sendable {
  let record: ProcessRecord
  let path: ExpectedSignalPath
}

/// Ends each member of a recorded tree, children first. A member that has already gone is fine.
private func endTree(_ members: [TreeMember]) {
  for member in members.reversed() {
    ProcessSender.signal(SIGKILL, member.record, expecting: member.path)
  }
}
