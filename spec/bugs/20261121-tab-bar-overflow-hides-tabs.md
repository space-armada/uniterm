# Tabs past the tab bar's trailing edge cannot be seen or clicked

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27, by UTERM-041 M1. The shared tab bar scrolls by trackpad and shift-scroll and keeps the selected tab in view.
**Estimate:** medium; no open design decisions. The user chose the scrolling bar at UTERM-041's review gate.
**Triaged:** 2026-11-22 (still reproduces in a package test; fix stays with UTERM-041 M1)
**Validation:** found by reading the code during the UTERM-041 review. Reproduced by a package test on 2026-11-22, not in the running app.
**Found:** 2026-11-21, during the UTERM-041 review

## Observed

A terminal or browser pane with more tabs than fit its width lays the extra tabs out past the bar's trailing edge.
They cannot be seen or clicked. Selecting one from the keyboard or the palette does not bring it into view.

## Cause

- `AppletTabBar.layout` (`Packages/UnitermKit/Sources/AppletKit/AppletTabBar.swift`, about line 178) gives each tab
  at least 80 points and places tabs one after another, past the bar's width when they do not fit.
- The bar does not scroll, and it has no overflow menu.

## Repro

In a browser pane about 500 points wide, open 8 tabs. Expected: every tab is reachable in the bar. Actual: about 5
tabs show, and the rest are cut off at the bar's edge.

## Fix

UTERM-041 M1 takes this on: the shared tab bar scrolls by trackpad and shift-scroll, with no scroll control, and keeps
the selected tab in view. The user chose that at UTERM-041's review gate on 2026-11-21. The options it weighed:

- Scroll the bar, and scroll the selected tab into view.
- Add an overflow control at the trailing end that lists the tabs past the edge.
- Shrink tabs below 80 points before either, down to a floor that keeps the marker slot whole.

Whichever fix lands, it keeps the selected tab in view. It should not add a second list of tabs, such as an overflow
menu, unless that list draws each tab's markers too. UTERM-041 shows markers only in the tab bar and at the pane
level, so a marked tab past the edge shows its marker nowhere until this is fixed. A control at the bar's trailing end
sits where the control badge does. See `20261121-terminal-tab-bar-ignores-control-badge.md`.

## Workarounds

Switch tabs from the keyboard or the palette. The selected tab's content shows, though its tab stays out of view.

## Investigation notes

Triage run on 2026-11-22.

- The code is unchanged. `AppletTabBar.layout` still clamps each tab to at least `narrowest` (80 points). It places
  tabs and the new-tab button past `bounds.width` and has no scroll view.
- A scratch package test built an `AppletTabBar` 500 points wide with 8 titles and the new-tab control shown. After
  layout, 2 of the 9 subviews had `frame.maxX` past 500, and the farthest reached 658. The test was deleted after the
  run.
- No regression test for this bug exists. `AppletTabTests` covers tab IDs only.
- UTERM-041 is accepted and M1 is not started. The fix is one change with the marker slot and the badge reach in
  `20261121-terminal-tab-bar-ignores-control-badge.md`. Landing it here would split that change.
- The fix touches `AppletTabBar.swift` and its callers in the terminal and browser. Its regression test should put 8
  tabs in a 500-point bar, then check that the selected tab ends inside the visible range.
