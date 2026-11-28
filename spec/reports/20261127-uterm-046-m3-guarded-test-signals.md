# UTERM-046 M3: every test signal goes through a guarded sender

Started 2026-11-27, as the fourth row of a `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 report](20261127-uterm-044-m3-failed-shard-reruns-alone.md). Every commit is in this repo, on
`agent/petunia`.

The row's base is "Log 40 more shortcut test runs that saw no Cmd-T stall". It depends on UTERM-046 M2 and M4, both
DONE. It has no `Live after` line.

## UTERM-046 M3

### Plan

- Move `HelperHandle` into `ScriptTestSupport` as public API.
- Add `ProcessTestSupport`, which depends only on `ProcessInspection`. It holds the sender and the stopped-state
  reader.
- Move every spawn site onto the handle and every non-reaped site onto the sender.
- Close the reused-pid bug.

### What was done

- `HelperHandle` now lives in `Tests/ScriptTestSupport` with a public API. `ScriptFixtures.start` stays in
  `ScriptHostTests`.
- `Tests/ProcessTestSupport/ProcessSender.swift` holds the sender. A `ProcessRecord` is a pid and its start time in
  microseconds. `ProcessSender.signal` takes an expected path, accepts gone, and fails the test on unreached, refused,
  or the other path. `ProcessSender.send` returns what the guarded call reported, for the `BrowserHungProcessTests`
  closure. The shared `isStopped` reader replaces the two copies.
- Package.swift adds `ProcessTestSupport` to six test targets, and `ProcessInspection` to ExecDriverTests and
  TerminalSurfaceTests. The `ProcessInspection` comment names every user.
- Renames: `ReplProcess.interrupt` is `sendInterrupt`, and `ReplProcess.process` is a handle. `WebContent.kill` in
  `BrowserRecoveryTests` is `crash`.
- The sites the M3 list did not name moved too, and M3's text now names them. They are BrowserRecoveryTests'
  `WebContent` helper and defers, MarkdownRig, ExecPaneTests, and the ScriptReplLimitsTests SIGSTOP.
- A `LineCollector` whose pipe was released at the end of `start` let the helper die of SIGPIPE. It now retains an
  owner.
- Paths taken: `login` gave no token, so it takes the pid path. Every other terminal tree member, WebContent, and the
  exec driver took the token path. A new terminal test sends SIGCONT to each live tree member and checks its path.
- The final search of `Tests/` for `kill(`, `.terminate()`, and `.interrupt()` finds only the handle's own signal,
  the `killpg` in RemoteClientWatcherTests, and the exemptions M3 lists.
- `spec/bugs/20261122-declared-file-watchdog-may-signal-reused-pid.md` is closed as fixed. M3 pins the fix, not the
  bug, since no test can force a pid's reuse.

### Checks

- `make fmt-check lint check`: pass.
- `caffeinate -dimsu make test-package`: 3296 tests, 10 skipped, 0 failures, 281 s wall. The skips need
  `make test-helper-sandbox`.
- After the review fixes: `make fmt-check lint check` pass, and `BrowserRecoveryTests` with `ScriptReplLimitsTests`
  pass, 42 tests.
- `proposals.py check`: only the expected findings that UTERM-046 is now implemented and its row moves to history. The
  row review handles them.
- `proposals.py freeze`: no UTERM-046 hunk. The four `other` hunks on UTERM-001, UTERM-002, UTERM-004, and UTERM-009
  predate the run.

### Test cost

- Full `make test-package`: 281 s wall, at 3296 tests.
- `ControllerRunTests` with `DeclaredFileRunTests`: about 11 s together. The new terminal path test: 0.18 s.

### Best guesses

- The plan's guesses held: the handle's public move, the new target, the extra sites, and the bug closure.
- `ProcessSender.send` sits beside `signal`, since the browser closure must return the guarded call's result. If this
  is wrong, the closure would map a Bool back to a result.
- The terminal teardown picks the expected path from the executable name: `login` gets pid, every other member gets
  token.
- No mutation of the sender was run. The As built block says so.

### Review

- adr-impact: no conflict. ADR-07, ADR-08, and ADR-10 are consistent. No uncovered decision.
- The reviewer found no blocking issue. Its findings:
  - `WebContent.crash` returned silently on a nil record, and its signal result was dropped. The trace confirmed this
    by reading the code. Fixed: it fails on a nil record, and asserts the token path at a crash. Cleanup defers still
    accept gone. No failing test was written first, since forcing it needs a stand-in view. The fix is pinned by the
    passing live runs, not by a regression test.
  - The SIGSTOP in `ScriptReplLimitsTests` dropped its result. Fixed: it asserts `.sent`.
  - Two As built lines ran past 120 columns. Fixed.
  - The As built search bullet left out `ProcessSignalTests`. Fixed.
  - The `WebContent` header comment was stale. Fixed.
  - The terminal teardown's path choice leans on one test. Dismissed: that test signals every tree member and asserts
    each path, so the choice is checked.

### Row review

- adr-impact over the range: no conflict. ADR-07, ADR-08, ADR-10, and ADR-14 are consistent. No uncovered decision.
- The reviewer found the handle, the sender, and the guarded call one coherent design, with no leftover duplicates.
  Its findings:
  - The 2026-11-27 Decision Log entry sat under References. Moved to the end of the Decision Log.
  - The `**Updated:**` header was stale. Fixed.
  - The sender's failure arms were proven only by the live sites. Fixed: `ProcessSenderTests` pins them, in a new
    `ProcessTestSupportTests` target. Mutations made the wrong-path arm, refused, and unreached accept, and each
    failed its test. The arm for a pid path where a token was expected stays unpinned. It needs a process that gives
    no token, such as `login`, and the terminal tree test covers it live.
  - The milestone commit also carried the UTERM-060 M6 report. Dismissed: the plan approved committing a row's report
    with the next commit when the row changes no files.
- The first fix agent stalled on a script run that never started. It was stopped after a nudge, and a fresh agent
  finished from its partial work. `ProcessSender.swift` was confirmed unchanged.
- Checks after the fixes: `make fmt-check lint check` pass. `ProcessSenderTests`: 6 of 6 pass.

### Unowned failure

`make test-package-select PACKAGE_TESTS=TerminalSessionIntegrationTests/testShellSeesTheScrubbedEnvironmentAndUnitermsIdentity`
ends the test process with no result. It does the same on the unmodified test file from the base commit. It passes in
a clean environment and inside the full `make test-package`. The cause is unconfirmed. Filed as
`spec/bugs/20261127-terminal-test-exits-silently-under-make-select.md`.

### Bugs found

- Fixed in this milestone: the `LineCollector` pipe release, which this work's own move exposed.
- Filed: the silent exit above, in "File the bug that a terminal test exits silently under make
  test-package-select".
