# The declared-file test watchdog may signal a process id that was already reused

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27
**Found:** 2026-11-22, during the UTERM-046 review
**Estimate:** large; two non-trivial decisions (see Estimate notes). Both settled 2026-11-23 (see Resolution)

## Observed

`DeclaredFileRunTests`' 60 s watchdog checks `isRunning`, then sends SIGKILL to `processIdentifier`. If the helper
exited and Foundation reaped it, the id is free for reuse. Should `isRunning` still read true at that moment, the
watchdog kills an unrelated process of the same user.

## Cause

`Packages/UnitermKit/Tests/ScriptHostTests/DeclaredFileRunTests.swift:136-138`. The check and the signal are two steps,
and the test does not own the reap. UTERM-046 logs a sighting where `waitUntilExit` hung after the helper exited. That
suggests `Process`'s view of the exit can lag or miss.

## Fix

Move this helper onto the fixture's handle. UTERM-046 M2 builds the handle, and M3 moves `start` and every other
signalling site onto it. The fixture signals only before its own `waitpid` reap, so the id cannot be reused.

## Estimate notes

Checked 2026-11-23 by reading the code. Not reproduced. A reused process id cannot be forced in a test, so the
race stays traced, not observed. Both watchdogs sit at `DeclaredFileRunTests.swift` lines 136-138 (`start`) and
160-164 (`run`).

The fix as written does not exist yet. UTERM-046 M2 is NOT STARTED. The proposal's "Leaves undone" list names
`DeclaredFileRunTests.start` as staying on Foundation's `isRunning`. M2's caller list names `DeclaredFileRunTests.run`
but not `start`. So the bug's "check it off there" step means widening M2's scope. That is a scope addition.

The same `isRunning` then `kill(processIdentifier)` pair also appears in `ReplSupport.swift`, `ScriptLintCommandTests`,
`ScriptAskRunTests`, `ControllerRunTests`, `ControllerConsentTests`, `ScriptRunCommandTests`, `ScriptLimitsTests`, and
`ScriptReplTests`. The bug names only one site.

Non-trivial decisions:

1. Whether `start` joins M2's scope, or the proposal keeps it out and this bug waits. A smaller stopgap exists, such
   as dropping the SIGKILL watchdog from `start`. That option loses the hang guard.
2. Whether the other sites with the same pair are fixed by this bug, by M2's neighbors step, or stay open. The
   proposal currently leaves them undone on purpose.

Files a fix would touch: `DeclaredFileRunTests.swift`, `Support.swift` (the fixture), and the UTERM-046 proposal text.

## Resolution

Triaged 2026-11-23. The code is unchanged since the estimate: both watchdogs still check `isRunning`, then send
`kill(processIdentifier, SIGKILL)`. The race is confirmed by tracing the code only. No reuse was forced or observed.

The same pair, or `Process.terminate` after an `isRunning` check, also sits outside M2's callers in `ReplSupport`'s
session, `ScriptReplTests`' own helper run, and `ControllerRunTests`' own `start`. M2's callers already lose their
watchdogs to the fixture's handle.

The user chose a new UTERM-046 milestone. After M2, M3 closes the race in every package test that signals a process by
its id. `DeclaredFileRunTests.start` is one of them. Design-critic passes on 2026-11-23 found about twenty sites in
`ScriptHostTests` beyond the four first named, and more in five other test targets. M3 lists them all. This settles
both decisions above. `start` leaves M2's scope as written, and the other signalling sites are fixed by M3, not by this
bug alone. The exit waits that never signal stay undone, as UTERM-046 already says.

## Fix note

Fixed by UTERM-046 M3. `DeclaredFileRunTests.start` and every other test that signalled a helper it spawned now
spawn it through the fixture's handle. The handle reaps its own helper and signals only before that reap, so the id
cannot be reused. The `login`, driver, and WebKit content processes that something else reaps are signalled through
`ProcessInspection`'s guarded call. A search of `Tests/` finds no raw signal to a process id outside the exemptions
M3 lists.

No test can force a process id's reuse. The change pins the fix, not the bug.
