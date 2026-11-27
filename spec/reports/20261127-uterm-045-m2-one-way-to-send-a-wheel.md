# UTERM-045 M2: one way to send a wheel

Started 2026-11-27, as the sixth row of a `/work-queue` run of `next 6`. The run's state is in
[the UTERM-044 M3 report](20261127-uterm-044-m3-failed-shard-reruns-alone.md). Every commit is in this repo, on
`agent/petunia`.

The row's base is "Retire the launcher count's queue row". It depends on UTERM-045 M3, met earlier in this run, and
UTERM-044 M1, DONE. It has no `Live after` line.

## UTERM-045 M2

### Plan

- Promote the launcher's private settle into one base-class call that aims, settles, and wheels.
- Move all seven raw wheels onto it.
- Add a check that fails on any other raw wheel, with fixtures inside the script.
- Add a local trace, and run it.
- Move the launcher entry back to Potential.
- Split the CI-count bullet into a new milestone.

### What was done

- `UITests/UITestWheel.swift` adds `sendWheel(deltaY:at:in:...)` and `pointerLocation()` to `UnitermUITestCase`.
  - It reads the target's and the window's frames once, and intersects them.
  - It fails with "wheel settle:" when the target overruns the window, which means the caller should aim at the
    enclosing scroll view.
  - When the pointer is already inside the visible rect, it wheels there. Otherwise it hovers at the middle, polls
    with a fresh read each time, and fails with "wheel settle:" on timeout.
  - The coordinates are built from the window, so XCUI never resolves a large target per event.
- All seven raw wheels moved: the launcher's two, the data table's three, the image pane's one, and the terminal's
  one in `InputRecordingProofTest`. The data table's wheels aim at its scroll view. The proof test already clicks at
  the terminal's center, so the settle does not change what it proves.
- `scripts/check-ui-wheel.sh` runs in `make check`, with its `--self-test`.
  - It blanks strings and comments, joins split calls, and allows only the helper's one call.
  - It fails when `UITests` is missing.
  - The self-test's reject fixtures each assert the reported file and line.
- A test-only trace under `UNITERM_WHEEL_TRACE` logs the phases, the pointer, the aim, and the visible rect.
- M2 is DONE. The new M4 "The wheel change holds in CI" takes M2's CI bullet, with a queue row after M2. The
  launcher entry moved back to Potential, naming "Send every UI test wheel through one settled call".

### Checks

- `make lint check`: pass, including the wheel check's self-test. A planted raw wheel split across lines fails the
  check with its file and line.
- `build-for-testing`: pass.
- UI runs by the coordinator, under `caffeinate -dimsu`, of the launcher scroll test, `InputRecordingProofTest`, and
  the image viewer's wheel test:
  - Run AZS788, the first build: all passed. The image viewer test took 54.1 s.
  - Trace runs 15NGGW, AJ6HDT, FTTK3F, and the final WV68JX: all passed.
  - In the final run, every wheel had 0 events between settle and wheel, and each pointer lay inside its visible
    rect. The image viewer test took 32.1 s.
- No crash report appeared during the UI runs.
- `proposals.py check`: only the expected history move.

### Test cost

- The image viewer's wheel test took 20.2 s at the base commit locally, measured by stashing the UI test changes,
  running it, and restoring them. CI logged 26 to 33 s at earlier heads.
- The first build took it to 54 s, since the call resolved the 2000-row table about five times per wheel.
  - Aiming at the scroll view and building coordinates from the window brought it to 45.7 s.
  - Skipping the redundant hover brought it to 31.9 s.
- The remaining 12 s is the fresh frame read before each data table wheel, which the precondition needs, plus XCUI's
  own per-event cost against that table.

### Best guesses

- The call clips to the window only, and a target inside a scroll view must be that scroll view. The call enforces it
  by failing when the target overruns the window. If this is wrong, callers would pass a clip view explicitly.
- When a fresh read shows the pointer already inside, the call skips the hover. M2's wheel bullet now reads "at the
  point the pointer settled on, which is the hover point when a hover was needed".
- The check's fixtures live inside the script as a self-test, which keeps the diff inside M2's file list.
- The CI-count bullet moved to the new M4, as the plan approved.

### Review

- adr-impact: no ADR touched. No uncovered decision.
- The reviewer found no blocker. Its findings:
  - Clipping only to the window left "aim at the visible part" to the caller. Fixed with the overrun guard.
  - The check had three false negatives, all confirmed on a scratch tree: a `//` inside a string, a `"/*"` string,
    and a missing directory. Fixed, with fixtures.
  - The window could move between the read and the wheel. Dismissed: the test windows are fixed, and the hover path
    has the same exposure.
  - As built held intermediate history and an unproven "inside the target" claim. Fixed: the trace prints the visible
    rect, and As built cites the final run.
  - The flaky entry's Fix line did not mention the skip path. Fixed.
  - Duplicate pointer readers and a long doc comment. Fixed.
