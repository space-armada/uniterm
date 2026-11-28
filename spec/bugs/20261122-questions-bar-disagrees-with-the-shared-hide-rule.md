# The questions applet's tab bar disagrees with UTERM-041's shared hide rule

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27, by [UTERM-041](../proposals/UTERM-041-uniform-tab-marker-slot.md) M1. The questions bar hides below two tabs, with no blank strip.
**Estimate:** small; one design decision, settled by the user on 2026-11-23. The questions applet follows the shared
hide rule. Under that rule an empty book's one placeholder tab shows no bar, so the second decision falls away.

## Observed

UTERM-041 says every applet other than the terminal and the browser publishes exactly one tab and has no bar. Its M1
makes the shared bar hide below two tabs. The questions applet has a bar, always shown at a fixed height, and one tab
per pending question.

Once UTERM-041 M1 lands, a pane with one pending question would hide that question's tab, while the bar's space stays.
An empty pane publishes one placeholder tab, so a bar that showed the published list would show a phantom tab with a
close button.

## Cause

- `QuestionsView` (`Packages/UnitermKit/Sources/QuestionsApplet/QuestionsView.swift`, about lines 50-53) pins the bar
  at `AppletTabBar.height` with no hide rule. `show` (about line 75) feeds it the requester names, which are empty for
  an empty book.
- `QuestionsApplet` (`Packages/UnitermKit/Sources/QuestionsApplet/QuestionsApplet.swift`, about lines 464-471)
  publishes one "Untitled" tab when the book is empty, and one tab per entry otherwise.
- UTERM-041 "How the host knows the tab bar is hidden" (about line 269) states the one-tab rule for every other applet.

## Repro

None run. After UTERM-041 M1: open one question in a questions pane. Expected: its tab shows, or the bar's space goes
with the bar. Suspected actual: the tab hides and the space stays.

## Fix

A design call on UTERM-041: the questions applet follows the shared hide rule and its view drops the fixed height, or
it keeps its always-shown bar and UTERM-041's rule names it. Under UTERM-053 the bar reads the published list, so the
empty book's placeholder tab also needs a rule.

## Triage

Triaged on 2026-11-23 by reading the code. `QuestionsView` still pins the bar at `AppletTabBar.height`, about line
53, and `QuestionsApplet` still publishes one "Untitled" tab for an empty book. UTERM-041 M1 is not started, so the
disagreement cannot occur yet.

The user chose that the questions applet follows the shared hide rule. UTERM-041's "How the host knows the tab bar is
hidden" had a correction of fact, since it said every applet but the terminal and the browser has no bar. It gained a
bullet for the questions applet, and M1 gained a check for one, zero, and two pending questions.
