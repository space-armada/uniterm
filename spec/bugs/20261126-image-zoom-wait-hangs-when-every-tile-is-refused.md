# A program's zoom wait hangs when the budget refuses every tile it needs

**Status:** open
**Validation:** not confirmed; traced in the code during the detached zoom fix, not reproduced in a test.

## Observed

Found while fixing the detached image zoom wait on 2026-11-26. A program zooms a still image past fit and waits on the
handle. If the bitmap budget refuses every tile the zoom needs, or no tile can be made into an image, the handle stays
pending until the program's wait times out. UTERM-006 says a zoom the helper or a budget refuses fails its handle with
`zoom-limit`. This holds whether the pane is attached or detached.

## Cause

- `tileArrived` (`Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerApplet+Zoom.swift`, about lines 260-300)
  adds a tile to `tileDenied` when `BitmapFactory.makeImage` fails or `reserve` refuses its bytes. It then calls
  `refreshTiles` and returns.
- `requestNextTile` skips every key in `tileDenied`. Once every wanted tile is denied, nothing more is asked for.
- `zoomIsSettled` (`ImageViewerApplet+Remote.swift`) counts a still's zoom as done only once the pane holds a tile.
  Nothing on the denial path calls `zoomRefused`, which is what fails a program's zoom with `zoom-limit`.

## Repro

Not run. A package test would set a bitmap budget too small for one tile at the zoom's level, send `zoom` past fit to a
still, and check that the handle fails with `zoom-limit`. Today it stays pending.

## Fix

Call `zoomRefused` once every tile the viewport wants is denied and the pane holds none at that level. A partial
denial, where some tiles show, stays a zoom that worked. This needs a design call. `zoomRefused` puts the pane back to
the last zoom that showed tiles, or to fit, with a notice. So the user would see a fallback where today the pane stays
at the new scale with no detail.
