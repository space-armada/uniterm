# The reaper's log test reads no log entries in some full package runs

**Status:** open
**Validation:** not confirmed; the failure came only in subagent runs, and no run of the coordinator's reproduced it

## Observed

`ProcessReaperTests.testTheReaperLogsThePidPathAndFailuresButNotAGoneHelper` fails in some full runs of
`make test-package`. It reads no log entry for helpers 4402, 4404, and 4405, so three assertions fail:

- "a kill by process ID was not logged"
- "an unreached helper was not logged as an error"
- "a refused helper was not logged as an error"

It passes alone every time, with `make test-package-select PACKAGE_TESTS=ProcessReaperTests`.

Sightings, all on 2026-11-27, local Pacific time, during one `/work-queue` run:

| When | Who ran the suite | Result |
|------|-------------------|--------|
| About 12:00, twice | A subagent, after a UI test run had ended at 11:50 | Failed |
| 12:06 | The coordinator | Passed |
| 12:38 and 12:45 | A subagent | Failed |
| 12:52 | The coordinator | Passed |
| About 13:00 | A subagent, with nothing else running | Passed |
| About 14:00, twice | A subagent | Passed |
| 14:14 and 14:34 | The coordinator | Passed |
| About 15:05 | A subagent, through a shell with the sandbox off | Failed |

Four earlier full runs by the first subagent passed. The test's code did not change that day. The changes under test
were wire versions and the controller trust store, which the test does not touch.

## Cause

Unknown. The test reads the unified log store for its own process, through `OwnLog.entries`, and waits until the
entry for helper 4405 shows. An empty read means the store gave back nothing for the process in time.

Leads, none checked:

- The unified log can quarantine a process for high logging volume, and drop its records. That happened to the app in
  a UI test the same day. See `20261127-input-records-lost-to-log-quarantine.md`. A full package run logs a lot before
  this test starts.
- Every failure was in a run a subagent started. Every run the coordinator started passed. The two may differ in how
  the process is launched, or in what else the machine was doing.
- One subagent blamed a UI test run. That is wrong for the first sighting, since the UI run had ended 10 minutes
  before.

## Repro

No reliable one. Run `caffeinate -dimsu make test-package` several times. Expected: the test passes. Actual: in
5 of about 14 full runs that day, it failed as above.

To check the quarantine lead, run `log show --info --debug` for the failing run's window, with a predicate for
`QUARANTINED` and the test process.

## Fix

Not known until the cause is. If the log store drops the entries, the test's doc already says the log line is the
contract and that it needs a readable store. The fix would then need a design call: read the entries another way, or
have the test say the store was unreadable and skip.
