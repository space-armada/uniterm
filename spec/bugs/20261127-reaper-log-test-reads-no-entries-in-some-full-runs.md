# The reaper's log test reads no log entries in some full package runs

**Status:** open
**Triaged:** 2026-11-27 (not reproducible alone; fails only in some full runs; see investigation notes)
**Validation:** confirmed in one run; the unified log quarantined the test process 30 seconds into a failing run

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
| About 18:10 | A subagent | Failed |
| 18:14 | The coordinator | Failed |

Four earlier full runs by the first subagent passed. The test's code did not change that day. The changes under test
were wire versions and the controller trust store, which the test does not touch.

## Cause

The unified log quarantines the test process for high logging volume, and drops its records. In the 18:14 run,
`log show` for the run's window has this line from the `xctest` process at 18:15:46: "QUARANTINED DUE TO HIGH LOGGING
VOLUME". The reaper test ran after that and read no entries. This is the first failure in a run the coordinator
started, so who starts the run does not matter. The earlier sightings were not checked this way.

The 18:10 and 18:14 runs came after suspend and resume for controllers was built, which adds tests and log lines. That
may have pushed the volume over the limit more often. Two runs earlier the same evening, at 17:21 and 17:55, passed
with most of that work in place.

The test reads the unified log store for its own process, through `OwnLog.entries`, and waits until the
entry for helper 4405 shows. An empty read means the store gave back nothing for the process in time.

Earlier leads:

- The unified log can quarantine a process for high logging volume, and drop its records. That happened to the app in
  a UI test the same day. See `20261127-input-records-lost-to-log-quarantine.md`. A full package run logs a lot before
  this test starts.
- Every failure was in a run a subagent started. Every run the coordinator started passed. The two may differ in how
  the process is launched, or in what else the machine was doing.
- One subagent blamed a UI test run. That is wrong for the first sighting, since the UI run had ended 10 minutes
  before.

## Repro

No reliable one. Run `caffeinate -dimsu make test-package` several times. Expected: the test passes. Actual: in
7 of about 19 full runs that day, it failed as above.

To check the quarantine lead, run `log show --info --debug` for the failing run's window, with a predicate for
`QUARANTINED` and the test process.

## Fix

The log store drops the entries. The test's doc already says the log line is the contract and that it needs a readable
store. The fix needs a design call. The options:

- Find what logs so much in a full package run, and cut it. This fixes the cause, and it also protects the app's own
  records in UI tests.
- Read the entries another way.
- Have the test say the store was unreadable and skip.

## Investigation notes

Triage run on 2026-11-27.

- No separate regression test exists. The failing test is the only one that covers this path.
- The test passes alone on the current build with `make test-package-select PACKAGE_TESTS=ProcessReaperTests`: 3 tests,
  0 failures, 2.7 s for this test.
- No full package run was repeated. The failure needs a full run and fails in about 7 of 19, so one pass or one run
  would not settle it.
- The recorded cause stands: the unified log quarantines the test process for high logging volume. The fix is still the
  design call under "Fix".
