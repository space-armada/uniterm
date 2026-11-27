# The host never sends an applet detach or reattach, so audio and alerts never pause off screen

**Status:** open

**Estimate:** medium. The send itself is small, but which host events count as leaving the screen is a design call.
See "Fix".

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

Send `detach()` when an applet leaves the screen and `reattach()` when it returns, from one place in the window or pane
host, and add a test that drives the host event and sees the applet's call.

The design call is which events count as leaving the screen. Candidates, which can combine:

- The window is minimized, or the app is hidden with Cmd-H.
- The window is fully occluded or on another Space, from `NSWindow.occlusionState`.
- The pane is hidden inside its window, such as behind a zoomed pane once pane zoom exists.

A detached applet's alerts are held, so a broad rule hides more alerts. A narrow one leaves sound playing in cases
the user cannot see. ADR-05 does not say which, and the choice may want an amendment to it.

Also fix the documents that say the host sends them: UTERM-001's "Undo close pane" decision, and UTERM-005's M6 As
built line, once the fix lands.
