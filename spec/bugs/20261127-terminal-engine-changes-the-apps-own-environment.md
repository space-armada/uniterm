# The terminal engine changes the app's own environment

**Status:** open
**Validation:** confirmed by reading the code; the test failures it is blamed for were not reproduced on purpose

## Observed

Starting the terminal engine changes the environment of the whole process, not only of the children it starts.

- `GhosttyTerminalEngine.swift`, near line 68, calls `setenv("GHOSTTY_RESOURCES_DIR", ...)`.
- `InheritedEnvironment.swift`, near line 57, calls `unsetenv` on variables the app inherited.

Found on 2026-11-27. A new package test ran a real engine inside the test process. In three full runs after it was
added, `TerminalSessionIntegrationTests` then failed or died: one test reported the local hostname, and one ended the
process with no result. The new test now saves the environment and restores it in teardown. The next full runs
passed. The link between the two is likely, not proven.

## Cause

The engine edits process-wide state to shape what its children see. Anything else in the process that reads the
environment afterwards sees the edited one. `setenv` and `unsetenv` are also unsafe while another thread calls
`getenv`.

In the app this is one engine for the life of the process, so the effect is small. In the test process it leaks from
one test class to the next.

## Repro

Remove the environment restore in `ReplProcessTreeTests`, then run `caffeinate -dimsu make test-package`. Expected:
the suite passes. Seen before the restore was added: failures in `TerminalSessionIntegrationTests`.

## Fix

The engine passes an environment to each child it starts, and leaves the process's own alone. That may need a
libghostty option or a patch, since libghostty reads `GHOSTTY_RESOURCES_DIR` from the process. That makes it a design
call. Until then, a test that starts a real engine restores the environment itself.
