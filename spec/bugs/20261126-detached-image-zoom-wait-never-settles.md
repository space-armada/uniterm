# A program's zoom wait on a detached image pane never settles until the pane comes back

**Status:** open. Not confirmed: the mechanism is traced, not reproduced.
**Estimate:** small, with one design call: whether a zoom settles without tiles while its pane is off screen.

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
