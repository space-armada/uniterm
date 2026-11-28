# UTERM-060 M6 re-check: a failed CI shard keeps its evidence

Started 2026-11-27, as the third row of the day's second `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 re-check report](20261127-uterm-044-m3-failed-shard-reruns-alone-recheck.md). All CI times below are
UTC.

The row depends on UTERM-060 M4, which is DONE. It also sits behind UTERM-060 M5 in queue order, and M5 is still NOT
STARTED, so `proposals.py row` reports M6 as not ready.

## UTERM-060 M6

### What was done

- M6 needs a failed CI `app` job, which the run cannot cause. The same `gh run list` as the UTERM-044 M3 row showed no
  failed shard. Two runs after 45762275495 had passed, and three were still going.
- M6 stays NOT STARTED, with run status HELD. It waits on M5, and on a failed shard. The run checks the three open runs
  again before it finishes.

### A failed shard appeared during the run

At 19:52 run 46052402044 had finished with its `app (0)` shard failed. Its evidence bears on all three of M6's checks.
M6 still cannot run, because UTERM-060 M5 is an earlier row of the proposal and is unfinished. So the evidence is kept
here. The artifact expires on 2026-12-04.

- The failed job uploaded artifact `ui-test-results-shard-0-attempt-1`, 6,081,023 bytes, with 261 files. Its listing
  holds two `.xcresult` bundles and `ui-test-kept-log-shard-0.txt.gz`, 1,271,650 bytes. So the failed `app` job uploads
  the kept log with its test results.
- The shard's index in the kept log's name is 0, its job index. Only one shard failed, so the run shows one failing
  shard carrying its own kept log, not several.
- The test step's own `log show` took 8.4 s, from "Collecting testmanagerd log" at 19:04:49.6 to "Kept log written" at
  19:04:58.1. This is one shard's window, not a full suite's. The job did not reach its time limit, so the upload under a
  time limit is still unshown.
- The follow-up step "Collect kept log if test step did not complete" ran too, from 19:04:59.1 to 19:05:05.9, and wrote
  over the kept log. Its doc says it runs only when the test step did not complete. Filed as
  `spec/bugs/20261127-ci-kept-log-collected-twice-on-a-failed-shard.md`.

### Checks

None. No file changed.
