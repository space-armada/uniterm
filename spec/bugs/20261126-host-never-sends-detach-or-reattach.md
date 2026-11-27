# The host never sends an applet detach or reattach, so audio and alerts never pause off screen

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27
**Estimate:** medium; the user settled the one design decision by retiring the two events.

## Observed

ADR-05 P1 says uniterm sends the lifecycle events start, detach, reattach, willQuit, and close. P3 says an applet
pauses audio and video and holds back alerts on detach. UTERM-001's "Undo close pane" decision says the same:
"uniterm sends them". The `Applet` protocol documents `detach()` as "The applet has left the screen and stays alive".

No host code calls either method. Every applet implements them, and the browser, data, image, map, terminal, and text
viewers forward to `AppletAlerts`, but nothing reaches them outside tests. A page playing sound keeps playing wherever
its pane goes, and no applet ever holds back an alert.

UTERM-005's As built already notes the gap in passing: "Nothing in the host sends detach or reattach, so the tests
call them." Nothing tracked it as a bug.

## Cause

`Packages/UnitermKit/Sources/AppletKit/Applet.swift:261-270` declares `detach()` and `reattach()`. A search of `App/`
and `Packages/UnitermKit/Sources/` finds no caller outside the applets' own forwarding to `alerts.detach()` and
`alerts.reattach(...)`.

The host's only sender was the grace slot that kept a closed pane alive for undo. It came in with "Add undo close pane
with grace and description tiers and close guards". "Reopen closed panes from their description only" removed the
grace slot, and the detach and reattach calls went with it. No other event took their place.

## Repro

1. Search for host callers: `grep -rn -E '[a-zA-Z]\??\.(detach|reattach)\(' App Packages/UnitermKit/Sources`, leaving
   out `alerts.detach` and `alerts.reattach`.
2. Expected: at least one host call site for each event. Actual: none.

The audible symptom needs an event the host should treat as leaving the screen, which the fix has to choose first.

## Fix

The user settled this on 2026-11-27. The fix is not a sender. It retires the two events.

- Detach was built for a closed pane kept alive for undo. That tier is gone, so no applet leaves the screen and stays
  alive.
- Hiding a view is not a detach. That covers a hidden, minimized, or covered window, and a pane that zoom hides. The
  applet keeps running, as a Mac app does when its window is hidden.
- Audio keeps playing. Stopping it breaks the macOS convention and makes for a worse experience.

The candidates this file first listed, a minimized window, an occluded window, and a zoom-hidden pane, are all ruled
out as senders.

## Fix note

Fixed 2026-11-27.

- `detach()` and `reattach()` are gone from the `Applet` protocol and every applet.
- Alert holding is gone from `AppletAlerts`. An alert goes out when it happens. The path that presented a held record
  again went with it: the `presenting:` argument of the host's send, the pane host's ledger, and `StatusQueue.present`.
- The browser no longer pauses media or holds loads and dialogs for a detached pane.
- The image viewer keeps its pause and release code, and the text viewer keeps its held file change. Both are the
  applet's own off-screen state now, as `leaveScreen()` and `returnToScreen()`. Nothing in the app calls them until
  UTERM-062's hidden tabs do.
- ADR-05 drops the two events from P1 and strikes P3. UTERM-006, UTERM-010, UTERM-019, UTERM-026, UTERM-053, UTERM-054,
  UTERM-062, and `spec/ideas.md` are amended to match. The implemented proposals are frozen and keep their wording.

No regression test fails before this fix and passes after it. The fix removes a contract, and the compiler proves no
caller is left. The tests that only proved detached behavior were deleted. The tests that used detach as setup for a
contract that still holds were rewritten without it.
