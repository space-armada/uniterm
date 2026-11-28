# UTERM-074: The Terminal Engine Leaves the App's Environment Alone

**Status:** draft
**Created:** 2026-11-27
**Updated:** 2026-11-27

## Dependencies

- UTERM-023, which made the `uniterm` command drop loader variables and added the startup scrub of inherited variables
- UTERM-046, whose M3 added the terminal integration test that the sibling bug ends

## Impacts

None.

## ADR Deviations

None.

## Summary

Starting the terminal engine no longer edits the environment of the whole process. The engine hands each child shell the
environment it should see.

## Motivation

Two bugs share one cause.

The engine edits process-wide state to shape what its children see. `GhosttyTerminalEngine.init` calls
`setenv("GHOSTTY_RESOURCES_DIR", ...)`. `InheritedEnvironment.scrubProcess()` calls `unsetenv` on every inherited
variable the app wants to keep out of shells. Anything else in the process that reads the environment afterwards sees the
edited one. `setenv` and `unsetenv` are also unsafe while another thread calls `getenv`.

In the app this is one engine for the life of the process, so the effect is small. In the package test process it leaks
from one test class to the next.

- The bug "The terminal engine changes the app's own environment" saw `TerminalSessionIntegrationTests` fail after a new
  test started a real engine. One test reported the local hostname. One ended the process with no result.
- The bug "A terminal test ends the test process with no result under `make test-package-select`" traced the silent exit
  to the scrub. The process ends whenever its environment holds a variable that `scrubProcess()` unsets. A clean
  environment passes.

A test that starts a real engine restores the environment by hand today. That is a workaround, and the next such test
must remember it.

The startup scrub has a stated reason. A launch's `environment` can add or replace a variable but never remove one, so
unsetting at startup is the only way to keep a variable out of every shell. Any fix has to keep that guarantee.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### How the engine shapes the environment its children see

Candidates:

- Pass a complete environment to each child the engine starts, and leave the process's own alone. The scrub becomes a
  filter over a copy. This fixes the cause. It may need a libghostty option or a patch, since libghostty reads
  `GHOSTTY_RESOURCES_DIR` from the process and builds each child's environment from the process's. The first step is to
  find out whether libghostty has such an option.
- Keep editing the process, once at app start, before any thread exists. Make tests that start a real engine run it in a
  child process, so a leak cannot reach another test. This keeps the app's behavior and changes only test isolation. The
  process-wide edit stays.
- Keep both edits and keep restoring the environment by hand in each test that starts an engine. This is today's
  workaround. It leaves the leak in place and depends on every later test remembering it.

The pass-per-child option is the complete fix. Whether it is possible waits on what libghostty offers. The answer decides
the milestones.

## Risks

- **libghostty has no per-child environment option** — likelihood: medium, impact: medium. Mitigation: M1 settles it
  before any code changes. The patch route needs the user's decision, since the libghostty version is pinned.
- **A variable the scrub keeps out of shells reaches one** — likelihood: low, impact: medium. Mitigation: the existing
  scrub tests stay, and M2 adds a check that a shell sees none of the scrubbed variables when the process holds them.

## Milestones

### M1: The per-child environment option is settled

**Status:** NOT STARTED

- The pinned libghostty either offers a way to pass a child's whole environment, or does not. The result is recorded in
  the As built block.
- The user rules on the open decision with that result in front of them.

### M2: The engine leaves the process environment alone

**Status:** NOT STARTED

The milestone's checks follow the user's ruling on M1.

- Starting a real engine in a test leaves the process environment as it found it.
- A shell started by the engine sees none of the scrubbed variables, even when the process holds them.
- `TerminalSessionIntegrationTests/testShellSeesTheScrubbedEnvironmentAndUnitermsIdentity` passes under
  `make test-package-select` with a scrubbed variable in the environment.
- The hand-written environment restore in the tests that start a real engine is gone.

## Decision Log

- 2026-11-27: Filed as a draft from bug triage. Both bugs trace to the process-wide environment edits. Nothing is
  decided.

## References

- The bug "The terminal engine changes the app's own environment"
- The bug "A terminal test ends the test process with no result under `make test-package-select`"
- UTERM-023: loader variables and the startup scrub
- UTERM-046: deterministic package test flakes
