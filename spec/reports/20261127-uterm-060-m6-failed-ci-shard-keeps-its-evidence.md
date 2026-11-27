# UTERM-060 M6: a failed CI shard keeps its evidence

Started 2026-11-27, as the third row of a `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 report](20261127-uterm-044-m3-failed-shard-reruns-alone.md). All CI times below are UTC.

The row depends on UTERM-060 M4, which is DONE, and follows the UTERM-060 M5 row. It has no `Live after` line.

## UTERM-060 M6

### Plan

M6 needs a failed CI `app` shard, whose upload would carry the kept log. The run never pushes and never reruns
upstream CI. The coordinator checks the gate itself. With no failed shard, the milestone stays NOT STARTED and the
proposal is not edited.

### What was done

- `gh run list` on `space-armada/uniterm` showed no run after 45762275495, created 2026-11-26T05:32:32Z. M4's As
  built block already covers every run up to it.
- No shard has failed, so no upload exists to inspect. M6 stays NOT STARTED. Its run status is HELD.

### Checks

None. No file changed.

### Best guesses

- The same as the UTERM-044 M3 row: a gate with no evidence leaves the milestone untouched.
- The quarantine bug found in the UTERM-060 M5 row bears on M6 too. A kept log from a failed shard can lose the app's
  records without saying so. See `spec/bugs/20261127-input-records-lost-to-log-quarantine.md`.
