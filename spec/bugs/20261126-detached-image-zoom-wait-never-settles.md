# A program's zoom wait on a detached image pane never settles until the pane comes back

**Status:** open. Traced on 2026-11-26 against the current code. The path is deterministic. No run was made.
**Estimate:** small; no open design decisions. Settle the zoom once the viewport is set, as UTERM-062 settles it for hidden tabs.

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
- An animated image is not affected. `releaseZoomedFrames` sets `zoomLevel` to nil, and `zoomIsSettled` treats that as settled.
- The fix is one line in `zoomIsSettled`: a still settles when `isDetached` or it holds a tile. `reattach` already calls `restoreZoomAfterReattach`, so the tiles arrive later.
- The design call is trivial. UTERM-062 already decides that a program's zoom into a hidden tab settles without tiles. Keeping the wait pending would leave a program's `wait` hanging on a pane the user cannot see.
- Regression test: in `ImageZoomTests.swift`, open a large still, `detach()`, send a remote `zoom` past fit, and assert the zoom handle settles as `.zoomed`. It must fail on the current code.
- Files the fix touches: `Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerApplet+Remote.swift` and `Packages/UnitermKit/Tests/ImageViewerAppletTests/ImageZoomTests.swift`. The doc comment on `zoomIsSettled` also changes.
