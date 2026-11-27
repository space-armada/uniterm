# A program's zoom wait hangs when the budget refuses every tile it needs

**Status:** fixed 2026-11-26
**Fixed:** 2026-11-26
**Estimate:** small; no open design decisions. Calling `zoomRefused` follows the other refusal paths and restores the UTERM-006 contract.

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
denial, where some tiles show, stays a zoom that worked. `zoomRefused` puts the pane back to the last zoom that showed
tiles, or to fit, with a notice. That is what every other refused zoom already does, and what UTERM-006 states. So the
fallback is not a new choice.

## Investigation notes

Triage run on 2026-11-26.

- The trace holds on the current code. `tileArrived` inserts the key into `tileDenied` and calls `refreshTiles`.
  `requestNextTile` skips denied keys. `zoomIsSettled` stays false while the pane holds no tile. Nothing calls
  `zoomRefused`.
- Reproduced by a scratch package test, since deleted. It showed a 1200 by 800 still on a pane whose bitmap budget had a
  floor equal to the backdrop's held bytes (968192) and a limit of 1. A zoom to scale 1 left its handle `pending` after
  the 20 s wait. The pane had 6 denied tiles and held none.
- The same test with a floor of 3.84 MB let 3 tiles in and denied 3. The handle ended `done`. That is the partial
  denial the fix keeps.
- No regression test exists. The regression test should be that scratch test, asserting `failed` with `zoom-limit` and a
  pane back at fit.
- The fix touches `ImageViewerApplet+Zoom.swift`, in `tileArrived`'s two denial branches or in `refreshTiles`.

## Fix note

Fixed 2026-11-26. `tileArrived` in `ImageViewerApplet+Zoom.swift` now routes both denial branches through a new `deny`
step. When every tile the viewport wants is denied and the pane holds none, `deny` calls `zoomRefused`. The handle
fails with `zoom-limit` and the pane goes back to its last good zoom, or to fit, with a notice. A partial denial is
unchanged.

Two regression tests in `ImageViewerControlTests` cover it. The full-denial test failed before the fix, with the handle
still pending after 20 s. The partial-denial test passed before and after, and pins the case the fix leaves alone.
