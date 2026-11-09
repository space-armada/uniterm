# UTERM-003 M1-M5: Janet scripting and REPL work-queue run

Started 2026-11-09. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-003 M1-M5`, from `spec/proposals/UTERM-003-janet-scripting.md`. UTERM-003 embeds Janet in helper
processes, gives scripts a small host API over a per-user Unix socket, and adds `uniterm run` and a REPL applet. The
specs live in the code repo, so every commit below is in this repo, on the `agent/petunia` branch.

## Run state

The run is in progress.

Step 0 fetched `upstream/main`. The branch already held it, so no rebase ran. The run's base and the row's base are
both "Rate UTERM-018's link session risk the same as a regular browser".

The row has no dependencies, and no milestone carries a `Live after` line. Nothing is held, blocked, or skipped, and no
work is stashed. No commands need the user's credentials.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-003 M1: Embedded Janet and the first host function | DONE | "Embed Janet in a script helper and post status from scripts" |
| UTERM-003 M2: Host API v1 | DONE | "Let scripts list, open, and send to panes" |
| UTERM-003 M3: `uniterm run` | DONE | "Run scripts against uniterm from the command line" |
| UTERM-003 M4: REPL applet | QUEUED | |
| UTERM-003 M5: Sandbox and limits | QUEUED | |

## Local checks

The implementer runs these through `cg_run`: `make fmt-check`, `make lint`, `make check`, `make build`,
`caffeinate -dimsu make test-package`, `scripts/check-sandbox-off.sh` on the built app, and `make test-helper-sandbox`.
It adds `scripts/swiftpm-offline-check.sh` when `Package.swift` changes, and a scoped `make fuzz` when the wire
changes. It runs `proposals.py check` and `proposals.py freeze`.

The coordinator runs the UI tests through `cg_run`. It runs a filtered `-only-testing:` run of the touched classes,
with a one-class probe first, and one full `make test-app` before the final review. After UI runs it checks the
crash-report folder.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. The `uniterm` helper is unsandboxed, under ADR-10's last bullet. `uniterm run` reads the script by path, connects
   to a socket path, and may hold `--allow fs-read`. A REPL helper launches through a terminal, which can pass only a
   directory, an environment, and a program, so it must connect by path too. Janet's `sandbox`, the memory cap, and
   process isolation bound it instead. ADR-10 is not edited.
2. Window IDs are a 37-bit random epoch per launch plus a 16-bit counter, below 2^53, and never read the clock. Tab
   references map `AppletTabID` values to small integers per window.
3. `send` carries bytes and a type, not a path, so file access stays under the script's Janet sandbox. If this is
   wrong, a REPL, which holds no capabilities, could never put a file into a viewer.
4. `open-tab` covers terminal shell mode and the browser. Other applets refuse.
5. M1 builds the listener and a minimal file-run mode. M3 finishes `uniterm run`.
6. The command installer uses a save panel that defaults to `~/.local/bin`. It never overwrites a regular file, and
   it says when the chosen folder is not on the usual `PATH`.
7. No Janet formatter or linter is added as a dependency.
8. A new `check-janet-isolation.sh` in `make check` keeps Janet out of the app target, per ADR-07.
9. Janet v1.43.0, the newest tag at planning.
10. ADR-09: the grant-free host API is the gap UTERM-003 and UTERM-004 already plan for, closed by UTERM-004 M1-M2.
    Findings on it are recorded as advisory.
11. The bundled CLI's Xcode target is `UnitermCLI`, so it does not collide with the app target. Only the symlink on
    `PATH` is named `uniterm`.
12. The socket directory gets a Debug override in M1. UI tests pass a short socket directory, since their scratch
    path leaves too little of the 104-byte `sun_path`.
13. M3 proves that a second instance hands its own address to the helpers it spawns. M4 proves the REPL half. M2's
    REPL refusal is handled the same way. The proposal is amended to match.

## UTERM-003 M1: Embedded Janet and the first host function

### Commits

- "Embed Janet in a script helper and post status from scripts"

### What landed

Janet v1.43.0 is vendored by `scripts/vendor-janet.sh`, pinned in `janet.pin`, and verified in `make check`. A
`CJanet` C target holds the amalgamation, a counting allocator in `janetconf.h`, and a shim that owns every call into
Janet. `scripts/check-janet-isolation.sh` keeps Janet out of the app, host, and wire targets. `ScriptWire` carries
the protocol with a version hello and a fuzzer. `ScriptRuntime` runs one VM with `uniterm/api-version` and
`uniterm/post-status`. The `UnitermCLI` tool target ships at `Contents/Helpers/uniterm`, unsandboxed by design.
`ScriptHost` listens at `Application Support/uniterm/run/<pid>.sock` and hands calls to the main actor. The script
mode is `uniterm run --socket PATH file.janet`. The As built block in the proposal has the details.

### Checks

| Check | Run | Result |
|---|---|---|
| `make fmt-check`, `make lint`, `make check` | EP2ZCJ, 2F19Q4, 4VJVJ5 | pass |
| `make build`, then `check-sandbox-off.sh` on the built app | XF4CY7 | pass |
| `make test-helper-sandbox` | CAR8EJ | pass |
| `caffeinate -dimsu make test-package` | 1ZEXH3 | pass, exit 0 |
| `ScriptWireFuzzTests` under ASan, 5000 iterations | 5MZDZE | pass |
| `scripts/swiftpm-offline-check.sh` | ECKQ5N | pass |
| `WindowsUITests`, run by the coordinator with the listener wired in | WRNCXY | 6 tests, 0 failures |
| `proposals.py check`, `proposals.py freeze` | | no UTERM-003 finding; freeze empty |

The crash folder held only `ImageDecoderHelper` and `DocumentDecoderHelper` reports. They match the pattern from before
this run, written while the image and text viewer tests end their helpers. No `uniterm` or script-helper crash
appeared.

### Best guesses

1. Hello is one version field. The script's name travels in a separate `begin` message. A second `begin` is a protocol
   violation. If wrong, M4 adds its token message beside `begin` without reshaping hello.
2. The app answers a mismatched hello with its own before refusing, so the helper can print the relaunch message and
   exit with status 70.
3. Janet's sandbox is applied from M1, denying everything but compile, unmarshal, high-resolution time, and exit.
   Native modules are off in `janetconf.h`. M3 clears bits for `--allow`.
4. `(import uniterm)` resolves through `module/cache`. The module has no file.
5. Script errors go to stderr only. The app's status bar never shows a script failure.
6. The per-instance socket is `<pid>.sock`. A stale file from the same PID is unlinked at start. M3's lock handles files
   that crashed instances leave behind.
7. The listener caps 32 peers, a 5-second hello, and 8 calls in flight per peer. It refuses a socket folder that is a
   symlink or another user's.
8. UI tests point `UNITERM_SCRIPT_DIR` at `/tmp/ut-<8 hex>`, since their scratch path is too long for a socket.
9. Janet's event loop does not run after the script's last form.

### Review findings

| Finding | Disposition |
|---|---|
| Plan: only `janet_continue` ran under a Janet error boundary | Fixed. One `janet_try` boundary covers setup and evaluation, and error-to-text runs under its own. Proven by a temporary injected panic, reported as a start error. No permanent test, since Janet 1.43 has no script-level hook that panics in `tostring` |
| PLAUSIBLE: `stop()` left `<pid>.sock` behind on a normal quit | Confirmed by a test that failed first. Fixed: `stop()` unlinks before it returns |
| PLAUSIBLE: `stop()` could write to a closed wake descriptor | Confirmed by reading the code. No test, since a poll error cannot be induced. Fixed: `stop()` alone owns and closes the descriptor |
| PLAUSIBLE: unbounded `begin` frames and a rename by a second `begin` | Confirmed by a test that failed first. Fixed: a second `begin` is a protocol violation |
| Observation: status text from scripts | Not a defect. `StatusText.bounded` already neutralizes control characters and bounds length. A test pins it |
| Comment named a proposal ID | Fixed |
| ADR-impact: the proposal's ADR-01 citation claimed more than ADR-01 says | Fixed. It now uses the wording from "REPL features" |
| ADR-impact ADVISORY: ADR-09, no grant on `post-status` | Recorded as the planned gap that UTERM-004 M1-M2 close |
| ADR-impact ADVISORY: ADR-07, the writer queue is unbounded until M3 | Recorded. M3 bounds it |
| ADR-impact uncovered: the socket's same-user trust boundary | Dismissed as an ADR candidate. UTERM-004's caller identity settles it under ADR-09 |
| ADR-impact uncovered: vendoring and the Janet isolation check | Dismissed as an ADR candidate. It enforces ADR-07 and adds no new rule |

### Test cost

| Class | Test time alone |
|---|---|
| `ScriptCodecTests` | 0.003 s |
| `ScriptWireFuzzTests`, 400 iterations | about 0.1 s |
| `ScriptHelperIntegrationTests`, 10 tests with real helper processes | 0.70 s |

The full package suite ran in 152 s.

### Left open

- The Debug `uniterm` app that the implementer started for a smoke test, PID 46637, could not be ended inside the
  sandbox. The user was asked to end it.
- No UI test drives a script against the real app yet. M3's UI test does.

## UTERM-003 M2: Host API v1

### Commits

- "Let scripts list, open, and send to panes"

### What landed

Scripts can call `list-windows`, `list-panes`, `open-pane`, `open-tab`, and `send`. WindowKit implements them behind a
ScriptHost protocol, against the real window and pane objects. Window IDs are a 37-bit random epoch per launch plus a
16-bit counter, and never read the clock. Tab references are small numbers that only grow, per window. AppletKit
gains two declared capabilities. `TabOpening` covers a terminal in shell mode and the browser. `InputOwning` marks an
applet that refuses sent content: the terminal now, and the REPL in M4. `send` writes bytes into a private spool at
`sent/<pid>.<start-second>/<uuid>/<name>`. Each pane holds one file, and a pane's earlier file is discarded when it
receives a new one or closes. The wire protocol moved to version 2, with a `notFound` failure kind. The host API
version stays 1.

### Checks

| Check | Run | Result |
|---|---|---|
| `make fmt-check`, `make lint`, `make check` | 5MJ1CT, CX7XQS, 6RN6JC | pass |
| `make build`, then `check-sandbox-off.sh` on the built app | WQX9NC, Q9694V | pass |
| `make test-helper-sandbox`, run by the coordinator | YXFHH4 | pass |
| `caffeinate -dimsu make test-package` | NZ6E56 | 2068 tests, 0 failures, 7 skipped |
| ASan fuzz of the wire, plus the C reply reader tests, 5000 iterations | 6AVGNZ | pass |
| `scripts/swiftpm-offline-check.sh` | DXKCH6 | pass |
| Regression run with the spool discard disabled | VXMQFV | the many-sends test failed, as it should |
| `proposals.py check`, `proposals.py freeze` | | no UTERM-003 finding; freeze empty |

### Best guesses

1. An action on a stale or unknown reference fails with a not-found error that never names another pane.
   `list-panes` on a window that is gone returns nil. If wrong, actions would return nil too.
2. References accept a struct or a table, and extra keys are ignored, so a pane reference works as a window reference.
3. `:directory` must be absolute and must exist. The terminal's silent fallback to home would otherwise hide a wrong
   path. A browser refuses any directory.
4. `send` targets an existing pane only. A script runs `open-pane` first. A later `:open` option could add this.
5. A viewer that receives sent content starts in its own directory, never the spool.
6. Each send is capped at 1 MiB, with a budget of 256 MiB per instance. A pane that the user alone changes keeps its
   last file until the next send to it, or a relaunch.
7. A sent name is a plain file name: no slash, no NUL, no leading dot, at most 255 bytes.
8. A reply holds at most 63 KiB. `list-panes` past that fails outright, with no partial answer.
9. `open-pane` kinds leave out program mode, so no script can start a program.
10. With no `:axis`, a wide pane splits side by side and a tall one stacks.
11. An exhausted window-ID counter redraws an epoch unused in this launch. Epoch 0 is never drawn.
12. With no `:directory`, `open-tab` passes the pane's reported current directory explicitly. With none reported, the
    applet's default applies, which is home for a terminal. This is implicit inheritance, so CLAUDE.md "Applet
    Attributes" has it raised for the user.

### Review findings

| Finding | Disposition |
|---|---|
| PLAUSIBLE: the spool budget never freed accepted files | Confirmed by trace. Fixed with per-pane ownership. A 300-send test failed with the discard disabled |
| PLAUSIBLE, reviewer and ADR-impact (ADR-08): `stat` on a script's path ran on the main thread | Fixed. The check runs off the main actor, and the pane is looked up again after it returns |
| ADR-impact: `open-tab`'s default directory was left to the applet | Fixed. The host passes it explicitly. Raised for the user |
| PLAUSIBLE: the C reply reader had no proof. It accepted duplicate keys | Fixed. Crafted-byte tests cover it, and C now rejects duplicate keys |
| Test-only public `ScriptValue.decode` | Fixed. It is now internal |
| PLAUSIBLE: reported text kept C1 and bidi controls | Fixed through `StatusText.bounded` |
| PLAUSIBLE: `send` skipped the window's modal gate | Confirmed. Fixed for `send`. `open-tab` still lacks the gate, and M3 adds it |
| PLAUSIBLE: restored sent panes | Traced. Each viewer shows its existing missing-file message. Recorded as a known limit |
| PLAUSIBLE: a reused PID kept a dead spool | Confirmed. Fixed by naming folders with the process start second |
| Comment craft: four items | Fixed |
| ADR-impact ADVISORY: ADR-09, no grants | Recorded as the planned gap that UTERM-004 M1-M2 close |
| ADR-impact uncovered: the spool's lifetime | Dismissed as an ADR candidate. It is internal and reversible |
| ADR-impact uncovered: `InputOwning` | Dismissed as an ADR candidate. ADR-05 and the proposal cover it |

### Test cost

| Class | Test time alone |
|---|---|
| `ScriptHostAPITests`, 11 tests, 15 helper launches | about 3.7 s, of which the 300-send test takes 2.2 s |
| `WindowScriptingTests`, 22 tests | 1.95 s |
| `ScriptReplyReaderTests` | 0.16 s |
| `ScriptTerminalTests` | 0.26 s |
| `WindowIDSourceTests` | 0.09 s |
| `ScriptSentContentTests` | 0.02 s |

The 300-send test earns its 2.2 s. It is the only proof that the budget frees, and that needs real sends past the
budget. The package suite grew from 152 s to 155 s.

### Left open

- No UI test drives the host API in the real app yet. M3's `uniterm run` UI test covers it.

## UTERM-003 M3: `uniterm run`

### Commits

- "Run scripts against uniterm from the command line"

### What landed

`uniterm run [--allow CAP]... [--socket PATH] file.janet [args...]` runs a script against the running app. The first
instance claims `run/uniterm.sock` under an `flock`ed `run/uniterm.lock`, and later instances never take it over.
`--socket` wins over `UNITERM_SOCKET`, which wins over the well-known address. The command refuses to run unless it
resolves to a bundle's `Contents/Helpers/uniterm`. Only the package twin's own `main` bypasses that check. The exit
statuses are 64 for usage, 69 for no app reachable, 74 for a lost connection, and 78 for not the bundle's own
command. "Install Command Line Tool…" links the command into a folder the user picks, `~/.local/bin` by default. It
claims the place atomically, and refuses when uniterm runs translocated or from a read-only volume. Each connection's
outbound queue is capped at 64 messages or 1 MiB, and a peer that stops reading is disconnected. A watchdog thread in
the helper ends it when the app's side closes, even while the VM spins. `open-tab` now honors the window's modal
gate, as `open-pane` and `send` already did.

### Checks

| Check | Run | Result |
|---|---|---|
| `make fmt-check`, `make lint`, `make check` | GX68C3, W7CC2K, PAWCJD, then ZZB5ZP | pass |
| `make build`, then `check-sandbox-off.sh` on the built app | 9VH1S9, SY5VB6 | pass |
| `make test-helper-sandbox` | 7JNNPZ | pass |
| `caffeinate -dimsu make test-package` | 3Z852D | pass, 156 s |
| Script classes after the final message fix | VGFGQ9 | 28 tests, 0 failures |
| Installer mutation run with plain `rename` | PZE0M6 | 5 failures, as it should |
| `ScriptRunUITests`, first run, launched from the test runner | BHZ80H | 2 failures: the sandboxed runner cannot reach the socket |
| `ScriptRunUITests`, through the terminal, second run | 1RX5Z3 | 1 failure: the fixture passed an integer where a reference belongs |
| `ScriptRunUITests`, final | PN2XTW | 2 tests, 0 failures |
| `proposals.py check`, `proposals.py freeze` | | no UTERM-003 finding; freeze empty |

The crash folder held only image and document decoder reports, in the same pattern as before.

### Best guesses

1. Takeover is literal. A later instance never takes the well-known address, even after its owner quits.
2. `--socket` wins over `UNITERM_SOCKET`, which wins over the well-known address. An empty value counts as unset.
3. Script arguments arrive in `(dyn :args)`, with the script's path first, as in Janet's own convention.
4. The well-known address is a second listening socket, not a symlink.
5. A `<pid>.sock` is stale when its process is gone, or when the process started after the file's birth time.
6. Exit statuses 64, 69, 74, and 78 are new public contract.
7. A lost connection ends the helper. The VM thread flushes stdout first. The watchdog does not, since it cannot know
   whether the VM thread holds the stdio lock. Piped output may be cut off when the app quits mid-run.
8. The installer checks a fixed list of `PATH` folders and gives a hint for any folder outside it.
9. The helper checks the peer's uid after it connects, so it never sends a script's name to another user's socket.
10. `--allow` takes Janet's capability names, minus `all`. It refuses a name the default already allows, with status 64,
    since granting it does nothing. The default denies file, network, process, and FFI access, as "Sandboxing" says.
11. The UI tests drive the command from the instance's own terminal. The XCUITest runner is sandboxed, and anything it
    launches inherits that sandbox.

### Review findings

| Finding | Disposition |
|---|---|
| PLAUSIBLE: the installer's `lstat` then `rename` could replace a regular file | Confirmed. Fixed with `RENAME_EXCL` and `RENAME_SWAP`, plus an undo. A mutation run failed without it. A brief window remains during the undo, recorded in As built |
| PLAUSIBLE: `_exit` dropped buffered stdout on a lost connection | Confirmed by reading the code. The VM-thread path now flushes. The watchdog path cannot flush safely, which is recorded |
| PLAUSIBLE: a translocated launch would leave a dangling link | Confirmed. Fixed: the installer refuses and asks the user to move uniterm to Applications |
| PLAUSIBLE, coordinator's UI run: the UI test could not launch the command from the runner | Confirmed. Fixed by driving the command through the terminal |
| UI test waited on `fileExists`, which is true at bind, before listen | Fixed. The shell retries while the command exits 69 |
| `--allow net` read like a grant | Traced. The default already denied net, subprocess, and FFI. Fixed: `--allow` now refuses names that are always allowed. New fixtures cover a denied net call and a denied subprocess call |
| Comment craft: `stop()` doc | Fixed |
| Coordinator: the M1 footprint test used an unbounded `for await` | Fixed. It is now bounded at 60 s |
| A UI test fixture passed an integer to `list-panes`. The shim's error message did not mention tables | Fixed |
| ADR-impact ADVISORY: ADR-09, `--allow` and a uid-only peer check | Recorded as the planned gap that UTERM-004 M1-M2 close |
| ADR-impact borderline: "the command is a symlink into the bundle" as an ADR | Dismissed as an ADR candidate. The proposal's skew rule already records it |

The run cancelled one hung package run, H4XYC7. A new test waited on listener events with no bound. Every listener
wait now goes through a bounded `drive(timeout:)`.

### Test cost

| Class | Time alone |
|---|---|
| `ScriptRunCommandTests`, 7 tests | 1.23 s |
| `ScriptRunAppQuitTests`, 2 tests | 0.10 s |
| `ScriptListenerTests`, 11 tests | 0.43 s |
| `ScriptCommandInstallerTests` and `ScriptCommandTests`, 12 tests | about 0.02 s |
| `ScriptRunUITests`, 2 UI tests | about 12 s |

The package suite ran in 156 s.

### Left open

- The REPL half of the second-instance check moves to M4, by amendment.
