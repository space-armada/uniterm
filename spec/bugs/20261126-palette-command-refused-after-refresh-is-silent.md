# A palette command that becomes unavailable after the list was built does nothing, silently

**Status:** open. Confirmed by reading the code, not by a test.

**Estimate:** small; no open design decisions. Triaged 2026-11-26 by reading the code. Not built or run.

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

## Triage notes, 2026-11-26

Still present. `run` returns false silently when `isAvailable` fails, and `choose` discards the result.

Scope is the palette only. `dispatch` also feeds the status bar's `onCommand` (message dismiss, history toggle). A
warning posted from inside `run` would fire on those paths. Menu items validate before dispatch, so a refusal there is
not reachable. UTERM-061's check says "A row refused at run time says why in the status bar", which names palette rows.

`run` already posts the gone-pane message and then returns false. A caller cannot tell the two refusals apart, so a
caller-side post would show two messages for a gone pane. The fix has `run` report why it refused, for example with a
small result enum, or a flag that makes the unavailable case post. `choose` posts the unavailable message only for that
case.

Message: follows `postPaneGone` in `MainWindowController+Commands.swift`, warning level, naming the command title, such
as "Clear Screen" did not run, because it is not available now. `isAvailable` returns a Bool, so no specific reason
exists.

Files the fix touches: `Packages/UnitermKit/Sources/WindowKit/Commands/CommandRegistry.swift`,
`WindowKit/MainWindowController+Palette.swift`, `WindowKit/MainWindowController+Commands.swift`, and a test beside the
CommandRegistry tests.
