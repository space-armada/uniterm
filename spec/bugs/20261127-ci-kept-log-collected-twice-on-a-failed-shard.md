# A failed CI shard collects its kept log twice, and the second copy replaces the first

**Status:** open

## Observed

A UI shard whose tests fail runs `log show` twice. The test step collects the kept log when its tests finish. Then the
step "Collect kept log if test step did not complete" collects it again and writes over the same file. The upload
carries the second copy.

UTERM-060 M2's As built block says the follow-up step "collects the kept log if the test step didn't complete". In the
run below, the test step completed. Its tests failed, and it exited 2.

## Cause

`.github/workflows/ci.yml:89-90`. The step runs on `always() && steps.test.outcome != 'success' && steps.test.outcome
!= 'skipped'`. A test step that runs to its end with a failing test has outcome `failure`, the same as one stopped by its
timeout. So the condition cannot tell the two apart.

## Repro

Run 46052402044 on `space-armada/uniterm`, job `app (0)`, attempt 1, on 2026-11-27. Times are UTC.

- 19:04:48: the test step prints `** TEST FAILED **`, with one failing test.
- 19:04:49.6 to 19:04:58.1: the test step collects the kept log to `ui-test-kept-log-shard-0.txt.gz`, and exits 2.
- 19:04:59.1 to 19:05:05.9: the follow-up step collects the kept log again, to the same path.
- 19:05:06: the upload carries `ui-test-kept-log-shard-0.txt.gz`, written at 19:05.

Expected: the follow-up step skips, since the test step completed and already wrote the log. Actual: it runs and
replaces the log.

## Fix

Skip the follow-up collection when the kept log already exists, such as `[[ -f <kept log> ]] && exit 0` at the top of
its script. A test step stopped by its timeout never reaches its own collection, so the file is missing exactly when
the follow-up is needed. No design call. The cost of the bug is one extra `log show` of about 7 s per failed shard, and a
kept log whose window ends at the follow-up step rather than at the tests.

Proving the fix needs a failed shard on CI after it lands. Run 46055769038's `app (1)` shows the same double
collection, at 19:32:26.9 and again at 19:32:34.7.
