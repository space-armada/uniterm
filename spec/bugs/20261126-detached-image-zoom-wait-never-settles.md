# A program's zoom wait on a detached image pane never settles until the pane comes back

**Status:** open. Traced on 2026-11-26 against the current code. The path is deterministic. No run was made.
**Estimate:** small to medium, with one non-trivial design call: whether a program's zoom on a detached pane
settles before the helper has accepted it. Settling once the viewport is set drops the `zoom-limit` refusal that
UTERM-006 promises. See "Estimate check".

## Observed

Found by a design critique of UTERM-062 on 2026-11-26. A program sends `zoom` past fit to a still image in a detached
pane, then waits on the handle. The handle stays pending until the user brings the pane back.

## Cause

- `refreshTiles` (`Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerApplet+Zoom.swift`, about line 180) returns
  early while the pane is detached, so a detached pane asks for no tiles.
- `zoomIsSettled` (`ImageViewerApplet+Remote.swift`, about lines 307-318) counts a zoom past fit on a still as done
  only once the pane holds at least one tile.
- So a zoom past fit on a detached still can never settle while the pane stays detached.

## Repro

Not run. A package test would detach an image pane holding a still, send `zoom` with a scale past fit, and check that
the handle is still pending after the zoom's viewport is applied.

## Fix

Two plausible behaviors, so this needs a design call:

- Settle a zoom on an off-screen pane once its viewport is set, without waiting for tiles. The tiles arrive when the
  pane comes back.
- Keep the wait pending, and document that a zoom on a detached pane waits for reattach.

UTERM-062 settles the first for hidden image tabs, in "A hidden tab's running work". Fixing this bug the same way keeps
detached panes and hidden tabs alike.

## Triage notes

2026-11-26. Read the code the fix would touch.

- `zoomRemotely` applies the viewport with `content.zoom` and calls `observeRemote`. `zoomIsSettled` then reads `!tiles.entries.isEmpty`.
- `detach` calls `releaseZoomForDetach`, which drops the tiles. `refreshTiles` and `tileArrived` both bail while `isDetached`. So no tile can arrive.
- An animated image is not affected by a zoom sent before detach. A zoom sent after detach is; see "Estimate check".
- The fix is one line in `zoomIsSettled`: a still settles when `isDetached` or it holds a tile. `reattach` already calls `restoreZoomAfterReattach`, so the tiles arrive later.
- The design call is trivial. UTERM-062 already decides that a program's zoom into a hidden tab settles without tiles. Keeping the wait pending would leave a program's `wait` hanging on a pane the user cannot see.
- Regression test: in `ImageZoomTests.swift`, open a large still, `detach()`, send a remote `zoom` past fit, and assert the zoom handle settles as `.zoomed`. It must fail on the current code.
- Files the fix touches: `Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerApplet+Remote.swift` and `Packages/UnitermKit/Tests/ImageViewerAppletTests/ImageZoomTests.swift`. The doc comment on `zoomIsSettled` also changes.

## Estimate check

2026-11-26, a design critique of the triage estimate during a bug sweep.

- The design call is not trivial. Today `done` on a still means a tile arrived, so the helper accepted the zoom.
  UTERM-006 says a zoom the helper or a budget refuses fails its handle with `zoom-limit`
  (`spec/proposals/UTERM-006-image-viewer-applet.md`, about line 815). Only `failRemoteZoom` does that, and only on a
  helper or budget event during a decode. Settling a detached zoom at once would report `done` for a zoom the helper
  later refuses at reattach.
- The options:
  - Settle once the viewport is set. This drops the `zoom-limit` guarantee off screen, and UTERM-006's text needs a
    note. UTERM-062 picks this for hidden tabs, but that decision was made autonomously and does not weigh `zoom-limit`.
  - While detached, still ask the helper for one tile or level for a program's pending zoom, and settle on that tile or
    on the refusal without showing it. This keeps the contract. It matches UTERM-062's line that a hidden tab still asks
    the helper for the decodes its program's commands need. It touches `refreshTiles`, `tileArrived`, and the detach
    release.
  - Keep the wait pending, and document that it waits for reattach.
- Gap in the planned fix: an animated image larger than fit hangs the same way for a zoom sent after detach.
  `retargetFrames` (`ImageViewerApplet+Zoom.swift`, about lines 111-138) has no detached guard and sets `zoomLevel`.
  `fillWindow` then bails while detached, so the animated branch of `zoomIsSettled` stays false. `retargetFrames` also
  evicts held frames while detached.
- Gap in the planned fix: a zoom already pending when the pane detaches stays pending. `detach()`
  (`ImageViewerApplet.swift`, about lines 1055-1063) never calls `observeRemote`, and `tileArrived` bails while
  detached without observing. The fix needs `detach()` to observe, and a second test.
