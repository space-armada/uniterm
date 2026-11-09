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
| UTERM-003 M2: Host API v1 | QUEUED | |
| UTERM-003 M3: `uniterm run` | QUEUED | |
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
