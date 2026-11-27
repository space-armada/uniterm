# UTERM-044 M3 re-check: a failed shard reruns alone on CI

Started 2026-11-27, as the first row of a second `/work-queue` run of `next 6` that day. This report also carries the
run's state. Every commit is in this repo, on `agent/petunia`. All CI times below are UTC.

## Run state

The run's base is "Log a second sighting of the second-Ctrl-C test flake". A peer session committed it after this run
was planned. The peer is landing this branch upstream in batches, so new CI runs appear during the run.

| Row | Milestone | Run status | Note |
|-----|-----------|------------|------|
| UTERM-044 M3 | A failed shard reruns alone on CI | DONE, by a peer | A peer session closed it at the user's direction, from run 46055769038's rerun |
| UTERM-060 M5 | The recorder sees a Cmd-T stall | HELD | 40 more local runs saw no stall. The user then ended such batches |
| UTERM-060 M6 | A failed CI shard keeps its evidence | DONE, by a peer | The same peer session closed it, and split off UTERM-060 M7 |
| UTERM-045 M4 | The wheel change holds in CI | HELD | The wheel change is on no CI run yet |
| UTERM-063 M1 | Reset to version 0 and freeze | DONE | |
| UTERM-063 M2 | Refuse stale programs by name | DONE | Row reviewed. UTERM-063 is implemented |
| UTERM-067 M1 | Every store checked against ADR-18 | DONE | Drafts UTERM-071, UTERM-072, and UTERM-073 filed |
| UTERM-067 M2 | The trust stores keep what they cannot read | DONE | Row reviewed. UTERM-067 is implemented |

The run finished on 2026-11-27. Midway, at the user's request, the branch was rebased onto `upstream/main` at "Merge
pull request #125", and one redundant snip was dropped. The run's commits, by subject, in order:

- "Log a second batch of 40 shortcut test runs with no Cmd-T stall"
- "File the bug that a failed CI shard collects its kept log twice"
- "Reset every external version to 0 and fail the build when one moves"
- "Refuse stale programs and swapped commands by name at version 0"
- "Name what each UTERM-063 milestone moved and point its notes at the right entries"
- "Mark UTERM-063 implemented and move its finished row to history"
- "Check every store against ADR-18 and draft fixes for the ones that fall short"
- "Keep every approval the trust store cannot read, in one policy file"
- "File the bug that the reaper's log test reads no entries in some full runs"
- "Log a third sighting of the second-Ctrl-C test flake"
- "Cost one entry, not the policy file, for a bad string inside it"
- "Mark UTERM-067 implemented and move its finished row to history"
- "Show the re-approval notice even when a change or a second refresh comes first"
- "Record the second work-queue run's final review in its reports"

The final review is in [the UTERM-067 report](20261127-uterm-067-m1-m2-stores-keep-what-they-cannot-read.md).

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
- At 19:52 the first of the three had finished. Run 46052402044, "Polish the data viewer's columns, filter, and long
  cells", failed its `app (0)` shard at 19:05:16, on
  `DataViewerUITests.testTheColumnArrowsReachTheFarEdgeOfAWideTable`. Shards 1 and 2 passed. The `ci` job failed after
  it. This is the first failed shard on CI.
- The run is at attempt 1. Nobody has used "Re-run failed jobs" on it. The peer pushed a new commit for that batch
  instead, as run 46056825129. M3's check needs the rerun of this run's failed job, which only a rerun on GitHub can
  give. The run never reruns upstream CI, so M3 stays NOT STARTED. A rerun of 46052402044's failed jobs would now give
  M3 its proof.

### Checks

None. No file changed.
