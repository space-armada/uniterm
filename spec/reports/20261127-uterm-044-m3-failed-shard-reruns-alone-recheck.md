# UTERM-044 M3 re-check: a failed shard reruns alone on CI

Started 2026-11-27, as the first row of a second `/work-queue` run of `next 6` that day. This report also carries the
run's state. Every commit is in this repo, on `agent/petunia`. All CI times below are UTC.

## Run state

The run's base is "Log a second sighting of the second-Ctrl-C test flake". A peer session committed it after this run
was planned. The peer is landing this branch upstream in batches, so new CI runs appear during the run.

| Row | Milestone | Run status | Note |
|-----|-----------|------------|------|
| UTERM-044 M3 | A failed shard reruns alone on CI | HELD | No failed CI shard at the run's start. Re-checked at the end |
| UTERM-060 M5 | The recorder sees a Cmd-T stall | IN PROGRESS | 40 local runs of the shortcut test |
| UTERM-060 M6 | A failed CI shard keeps its evidence | QUEUED | Waits on UTERM-060 M5, an earlier row of its proposal |
| UTERM-045 M4 | The wheel change holds in CI | QUEUED | |
| UTERM-063 M1 | Reset to version 0 and freeze | QUEUED | |
| UTERM-063 M2 | Refuse stale programs by name | QUEUED | |
| UTERM-067 M1 | Every store checked against ADR-18 | QUEUED | |
| UTERM-067 M2 | The trust stores keep what they cannot read | QUEUED | |

Row reports:

- [UTERM-060 M5](20261127-uterm-060-m5-recorder-sees-a-cmd-t-stall-recheck.md)
- [UTERM-060 M6](20261127-uterm-060-m6-failed-ci-shard-keeps-its-evidence-recheck.md)
- [UTERM-045 M4](20261127-uterm-045-m4-wheel-change-holds-in-ci.md)
- [UTERM-063 M1-M2](20261127-uterm-063-m1-m2-external-versions-at-0.md)
- [UTERM-067 M1-M2](20261127-uterm-067-m1-m2-stores-keep-what-they-cannot-read.md)

## UTERM-044 M3

### Plan

M3 needs a shard to fail on CI, and then a rerun of failed jobs that reruns only that shard. The run never pushes and
never reruns upstream CI. The coordinator checks the gate itself. With no failed shard, the milestone stays NOT
STARTED and the proposal is not edited. This follows the first run's report,
[20261127-uterm-044-m3-failed-shard-reruns-alone.md](20261127-uterm-044-m3-failed-shard-reruns-alone.md).

### What was done

- `gh run list` on `space-armada/uniterm` at 19:04 showed five runs after 45762275495. Two had finished:
  46050921112, a pull request run created 18:37:59, and 46051725633, its main push at 18:44:45. Both succeeded.
- Three pull request runs were still going: 46052402044 (18:50:25), 46053190319 (18:57:11), and 46054005885
  (19:03:58). They come from the peer's landing.
- No shard has failed. M3 stays NOT STARTED for now. The run checks the three open runs again before it finishes.

### Checks

None. No file changed.
