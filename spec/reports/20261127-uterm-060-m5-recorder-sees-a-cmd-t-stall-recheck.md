# UTERM-060 M5 re-check: the recorder sees a Cmd-T stall

Started 2026-11-27, as the second row of the day's second `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 re-check report](20261127-uterm-044-m3-failed-shard-reruns-alone-recheck.md). Every commit is in this
repo, on `agent/petunia`. Times below are local Pacific time.

The row depends on UTERM-060 M2, which is DONE. It has no `Live after` line.

## UTERM-060 M5

### Plan

Run the shortcut test alone, with recording on, for 40 iterations, as the first run did. On a stall in an iteration
the log did not quarantine, record whether uniterm recorded each unconfirmed T event. With no stall, log the tries in
the Decision Log and leave M5 NOT STARTED.

### What was done

- `cg_list` showed no peer UI run. The only peer run was a PR watcher.
- The coordinator ran `make test-app-select UI_TESTS=ShortcutOwnershipUITests/testARemapOntoAnAppletKeyWinsAndWarnsOnce`
  under `caffeinate -dimsu`, with `-test-iterations 40` added to `UI_TEST_FLAGS`. It ran from 11:04:59 for 194 s.
- All 40 passed, each in 4.3 s to 5.3 s.
- `log show` with the kept log's predicate, for 11:05:00 to 11:09:00, holds 40 "Recording input" lines from 40 app
  processes. Each process has one Cmd-T key down record. No "confirmation delay timeout" line appears.
- `log show --info --debug` for the same window holds no QUARANTINED line. Every iteration's records survived.
- The crash-folder check for new `.ips` reports was denied by the permission check, so it did not run. The test run
  itself exited 0 with every iteration passing.
- M5 stays NOT STARTED. A second 2026-11-27 Decision Log entry records the tries. The total with no stall is now 125
  since the 3-in-9 sighting.

### Checks

- `proposals.py check`: no findings.
- `proposals.py freeze`: no hunk on UTERM-060. The four origin `other` hunks on UTERM-001, UTERM-002, UTERM-004, and
  UTERM-009 predate this run, as the first run's report says. They are left for the user.

### Review

- adr-impact: no ADR touched, no uncovered decision.
- The reviewer confirmed the 40 processes, the 40 Cmd-T key down records, the absence of late confirmations and
  quarantine lines, and the 125 total. The pass times rest on the cg run's output, which the reviewer could not read.
- One style finding: a sentence packed the log window and its contents. Split. A second note, on why no stall says
  nothing about rate, was already covered by the entry. Dismissed.

### Best guesses

- With no stall, M5 keeps waiting and is not split again, as the first run decided. The 2026-11-25 entry that split M5
  from M2 says it waits for a stall.
