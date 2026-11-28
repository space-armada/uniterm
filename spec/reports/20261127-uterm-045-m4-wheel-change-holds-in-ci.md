# UTERM-045 M4: the wheel change holds in CI

Started 2026-11-27, as the fourth row of the day's second `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 re-check report](20261127-uterm-044-m3-failed-shard-reruns-alone-recheck.md). All CI times below are
UTC.

The row depends on UTERM-045 M2, which is DONE. It has no `Live after` line.

## UTERM-045 M4

### Plan

M4 counts clean CI runs of the launcher test after M2's change lands. The coordinator checks whether any CI run carries
"Send every UI test wheel through one settled call". With none, the count is 0 and the proposal is not edited.

### What was done

- `upstream/main` ends at "Merge pull request #119 from ripta/agent/petunia-land6/ci-shard-records". It does not hold
  the wheel change.
- The wheel change's rebased copy sits only on a peer's local staging branch, `agent/stage/petunia`. The three pull
  request runs in progress at 19:04 are for other batches: terminal scrollback, palette rows, and the data viewer.
- No CI run has tested the change, so the count is 0. M4 stays NOT STARTED, with run status HELD.

### Checks

None. No file changed.

### Best guesses

- A count of 0 leaves the milestone untouched, the same rule the first run applied to the evidence rows.
