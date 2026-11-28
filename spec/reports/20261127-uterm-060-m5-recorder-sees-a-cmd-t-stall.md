# UTERM-060 M5: the recorder sees a Cmd-T stall

Started 2026-11-27, as the second row of a `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 report](20261127-uterm-044-m3-failed-shard-reruns-alone.md). Every commit is in this repo, on
`agent/petunia`. Times below are local Pacific time.

The row depends on UTERM-060 M2, which is DONE. It has no `Live after` line.

## UTERM-060 M5

### Plan

Run the shortcut test alone, with recording on, for 40 iterations. On a stall, record whether uniterm recorded each
unconfirmed T event. With no stall, log the tries in the Decision Log and leave M5 NOT STARTED.

### What was done

- Recording needs no flag. `UITests/UnitermUITestCase.swift:199` sets `UNITERM_RECORD_INPUT=1` on every launch.
- The coordinator ran `make test-app-select UI_TESTS=ShortcutOwnershipUITests/testARemapOntoAnAppletKeyWinsAndWarnsOnce`
  under `caffeinate -dimsu`, with `-test-iterations 10` and then `-test-iterations 30` appended to the Makefile's
  `UI_TEST_FLAGS`. No peer UI run and no other uniterm instance was running.
- All 40 passed, at about 4.6 s each. A passing run keeps no log, so the coordinator saved `log show` with the kept
  log's predicate from 02:59:30 to 03:04:00. It holds 40 test starts and no "confirmation delay timeout" line. No
  Cmd-T was even confirmed late.
- M5 stays NOT STARTED. A 2026-11-27 Decision Log entry records the tries. The total with no stall is now 85 since
  the 3-in-9 sighting.

### Checks

- `proposals.py check`: no findings.
- `proposals.py freeze`: no hunk on UTERM-060. Four hunks with origin `other`, on UTERM-001, UTERM-002, UTERM-004,
  and UTERM-009, predate this run. They are left for the user.

### Best guesses

- With no stall, M5 keeps waiting and is not split again. The 2026-11-25 entry that split M5 from M2 says it waits for
  a stall. If this is wrong, M5 would need a proof other than a local stall.

### Review

- adr-impact: no conflict. ADR-04 is the nearest ADR, and the entry does not touch it. No uncovered decision.
- The reviewer confirmed every figure against the saved log. It had four findings:
  - The entry gave 144 s for the second run. That was the whole make run, which the log cannot show. Dropped.
  - Several sentences carried two ideas. Split.
  - "The current branch head" could not be checked later. Dropped.
  - The log holds 80 Cmd-T events but only 78 records for key code 17. Traced, below.

### Bugs found

- The trace paired events with records by event number. One whole iteration, pid 76918 at 03:02:52.951, had no record
  for any event, though every event was confirmed and the test passed.
- `log show --info --debug` for that pid shows `QUARANTINED DUE TO HIGH LOGGING VOLUME` from `libsystem_trace` at
  03:02:53.542. That was 206 ms before its first Cmd-T. The log dropped the records, not the recorder.
- The kept log's predicate leaves the quarantine line out. So a reader cannot tell a dropped record from an event that
  never reached the app. That defeats M5's second bullet.
- Filed as `spec/bugs/20261127-input-records-lost-to-log-quarantine.md`. The fix needs a design call. The bug lays out
  the options and the decisions each would amend. The Decision Log entry names it.
