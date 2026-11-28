# A terminal test ends the test process with no result under `make test-package-select`

**Status:** open
**Validation:** confirmed on 2026-11-27 by repro. The cause is not confirmed.

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

Not confirmed. The test sets `MAKEFLAGS`, runs `InheritedEnvironment.scrubProcess()`, and points
`GHOSTTY_RESOURCES_DIR` at a missing path. The suspicion is an inherited make jobserver, whose descriptors the scrub
or the shell start then disturbs. No trace was taken.

## Fix

Run the test under the failing environment with a debugger or `lldb`, to see what ends the process. Then fix the scrub
or the test's setup. The full suite passes today, so CI is not affected.
