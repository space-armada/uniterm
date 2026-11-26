# A palette command that becomes unavailable after the list was built does nothing, silently

**Status:** open. Confirmed by reading the code, not by a test.

## Observed

Found by a design critique of UTERM-061 on 2026-11-26. A palette row is enabled when the list is built. If the
command's own check fails by the time the user chooses it, the palette hides and nothing happens. No message says why.

## Cause

`CommandRegistry.run` returns false without a message when `isAvailable` fails
(`Packages/UnitermKit/Sources/WindowKit/Commands/CommandRegistry.swift`, `run`, about line 213). Only a pane-scoped
command whose pane is gone posts a message, the gone-pane one (about lines 215-218). The palette's choose path ignores
the result (`WindowKit/MainWindowController+Palette.swift`, `choose`).

## Repro

Not run. With a terminal session running, open the palette and select Clear Screen. End the session, then choose the
row before the list updates. Expected: a status message that says the command could not run. Actual: nothing.

## Fix

Post a status message naming the command when a palette run is refused. UTERM-061 M1 has a check for this, so the fix
can land there or on its own.
