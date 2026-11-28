# A terminal test ends the test process with no result under `make test-package-select`

**Status:** open
**Estimate:** medium; one non-trivial decision, shared with the terminal-engine environment bug. The engine either keeps editing the process environment or passes one to each child.
**Triaged:** 2026-11-27 (still reproduces; cause narrowed to the scrub; fix waits on a trace and that decision)

## Observed

`TerminalSessionIntegrationTests/testShellSeesTheScrubbedEnvironmentAndUnitermsIdentity` starts, and then the test
process exits with no pass, no failure, and no crash report. `swift test` exits non-zero and `make` reports Error 1.
The log ends at the line that names the test.

## Repro

Run from the repo root, outside the agent sandbox:

`make test-package-select PACKAGE_TESTS=TerminalSessionIntegrationTests/testShellSeesTheScrubbedEnvironmentAndUnitermsIdentity`

The same happens with `swift test --filter` and `MAKEFLAGS='--warn-undefined-variables --jobserver-auth=3,4 -j'`,
`MAKELEVEL=1`, and `MFLAGS=-j` in the environment. It passes with `swift test --filter` and a clean environment. It
passes in a full `make test-package` run. The failure also reproduces with `HEAD`'s unmodified
`TerminalSessionIntegrationTests.swift`, so it predates UTERM-046 M3.

## Cause

Not confirmed. The make-jobserver suspicion is wrong. A triage run on 2026-11-27 ran `swift test --filter` on the test
alone, with the environment changed one way at a time.

- A clean environment passes.
- `MAKEFLAGS=-j` ends the process with no result.
- `UNITERM_PROBE=1` alone ends it the same way. No make run sets that variable.

So the process ends whenever the environment holds a variable that `InheritedEnvironment.scrubProcess()` unsets. A run
that unsets nothing passes. The suspect is the real `unsetenv` inside the test process, which other threads may read.
No trace was taken. The sibling bug `20261127-terminal-engine-changes-the-apps-own-environment` blames the same
process-wide environment edits.

## Fix

Run the test with `UNITERM_PROBE=1` set, under `lldb`, to see what ends the process. Then fix the scrub or the test's
setup, together with the sibling bug's design call. The full suite passes today, so CI is not affected.
