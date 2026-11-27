# UTERM-044 M3: a failed shard reruns alone on CI

Started 2026-11-27, as the first row of a `/work-queue` run of `next 6`. This report also carries the run's state.
Every commit is in this repo, on `agent/petunia`. All CI times below are UTC.

## Run state

The run's base is "8< --- snip ---", the branch head after "Correct the ISO gain map bug's fix note". The branch
already holds `upstream/main` through #118, so no rebase ran.

| Row | Milestone | Run status | Note |
|-----|-----------|------------|------|
| UTERM-044 M3 | A failed shard reruns alone on CI | HELD | No failed CI shard since run 45762275495 |
| UTERM-060 M5 | The recorder sees a Cmd-T stall | HELD | 40 local runs saw no stall. Stays NOT STARTED |
| UTERM-060 M6 | A failed CI shard keeps its evidence | HELD | No failed CI shard since run 45762275495 |
| UTERM-046 M3 | Every test signal goes through a guarded sender | DONE | Row reviewed. UTERM-046 is implemented |
| UTERM-045 M3 | The launcher count is met | DONE | 33 clean runs met the count |
| UTERM-045 M2 | One way to send a wheel | DONE | Its CI count moved to a new UTERM-045 M4 row |

Row reports:

- [UTERM-060 M5](20261127-uterm-060-m5-recorder-sees-a-cmd-t-stall.md)
- [UTERM-060 M6](20261127-uterm-060-m6-failed-ci-shard-keeps-its-evidence.md)
- [UTERM-046 M3](20261127-uterm-046-m3-guarded-test-signals.md)
- [UTERM-045 M3](20261127-uterm-045-m3-launcher-count.md)
- [UTERM-045 M2](20261127-uterm-045-m2-one-way-to-send-a-wheel.md)

The rows that changed only spec text, UTERM-060 M5 and UTERM-045 M3, had their milestone review stand as their row
review. The final review covers them again over the whole range.

## UTERM-044 M3

### Plan

M3 needs a shard to fail on CI, and then a rerun of failed jobs that reruns only that shard. The run never pushes and
never reruns upstream CI. The coordinator checks the gate itself. With no failed shard, the milestone stays NOT
STARTED and the proposal is not edited.

### What was done

- `gh run list` on `space-armada/uniterm` at the start of the run showed no run after 45762275495, created
  2026-11-26T05:32:32Z. M2's and UTERM-060 M4's As built blocks already cover every run up to it.
- No shard job has failed in any run since sharding landed. M3 stays NOT STARTED. Its run status is HELD.

### Checks

None. No file changed.

### Best guesses

- A gate with no evidence leaves the milestone untouched. The queue note says the row advances only when a shard
  fails, and the run cannot cause one. If this is wrong, M3 would instead be split or amended to a proof the run can
  give, as M2 was.
