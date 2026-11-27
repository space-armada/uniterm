# UTERM-045 M3: the launcher count is met

Started 2026-11-27, as the fifth row of a `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 report](20261127-uterm-044-m3-failed-shard-reruns-alone.md). Every commit is in this repo, on
`agent/petunia`. All CI times below are UTC.

The row depends on UTERM-045 M1, which is DONE. It has no `Live after` line.

## UTERM-045 M3

### Plan

Recount the launcher entry's streak from the previous cutoff, 2026-11-25T07:27:48Z, by the Rule section's method.
The count to meet is 33, and 23 were clean before the cutoff. The coordinator downloaded every attempt's job list
and every `app` job log into the scratchpad. The implementer read them there.

### What was done

- 10 more clean CI attempts, in 9 runs, through 2026-11-26T05:25:54Z. The streak is 33, so the count is met.
  - 45672965577 attempts 1 and 4: the launcher test passed in both. Both attempts failed on
    `QuestionsUITests.testEveryAnswerTypeReturnsItsShape`, which is logged under its own entry.
  - 45674064633 attempt 3, 45686673599, 45713785782, and 45719243800: unsharded, passed.
  - 45749818748, 45752629043, 45755641410 attempt 1, and 45760228289: sharded. The test ran in shard 1, 4th or 5th,
    and passed.
- Neutral attempts:
  - 45755641410 attempt 2 carried attempt 1's shard results, so it counts once.
  - Four cancelled `app` jobs have no log. See the best guess below.
  - 11 runs skipped the `app` job.
- Every head holds the pointer change. No log holds a launcher-test failure.
- M3 is DONE, with an As built block. A 2026-11-27 Decision Log entry holds the figures. The launcher entry moved to
  Fixed in `spec/flaky-tests.md`, with a "Fixed by:" line, a "Cause:" line, and a "Fix:" line.

### Checks

- `proposals.py check`: only the expected finding that the row moves to history.
- No code changed, so no build or test ran.

### Best guesses

- Four cancelled jobs, 139416896056, 139430501640, 139434429359, and 139443577745, return 404 for their logs. Each
  ran 15:02 from start to finish. In the neighbouring jobs, the launcher test started between 16:50 and 18:00 into the
  job. So each ended before the test could start, and each is neutral under the Rule. If one had been mid-test, the
  streak would have broken there, and M2 would not run in this run.

### Review

- adr-impact: no ADR touched. No uncovered decision.
- The reviewer recomputed the streak independently and agreed with 33 and with every classification. It had four
  findings, all fixed:
  - "In 10 runs" should be "in 9 runs".
  - The Fixed entry kept a Status line and open-sounding hedges, unlike other Fixed entries. It now ends in "Cause:"
    and "Fix:" lines, in the past tense.
  - The skip count's span ended before the last skipped run. It now names 05:33Z.
  - A Decision Log sentence packed three ideas. Split.
