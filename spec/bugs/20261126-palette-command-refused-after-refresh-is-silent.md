# A palette command that becomes unavailable after the list was built does nothing, silently

**Status:** fixed 2026-11-26
**Estimate:** medium; no open design decisions. The user chose the fix on 2026-11-26. See "Chosen fix".
**Fixed:** 2026-11-26

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

## Estimate check

2026-11-26, a design critique of the triage estimate during a bug sweep.

- Missing decision, not trivial: whether the palette hides or stays up on a refusal. `choose` hides the palette before
  it calls `run` (`MainWindowController+Palette.swift`, about lines 215-216). Two existing patterns point opposite
  ways:
  - Hide, then post. A pane-gone command does this (`CommandRegistry.swift`, about lines 215-217).
  - Stay up, update the row in place, then post. A stale tab row does this in `chooseTab` (`+Palette.swift`, about
    lines 230-236). UTERM-061 follows it for its own refusal.
- Staying up needs the palette to check before it hides. It also means the selection moves past the dimmed row, per
  UTERM-061 M1, so a second Return runs a different command.
- Size is medium, not small. The fix touches `CommandRegistry.swift`, `+Palette.swift`, and `+Commands.swift`.
  Changing `run`'s return type touches about six test sites. A new internal method that returns a reason enum, with
  `run` wrapping it, avoids that.
- The recorded decisions hold: palette rows only, a warning naming the command such as `"Clear Screen" did not run,
  because it is not available now.`, and `run` reporting why it refused. Use an enum for the reason, not a flag.
- The regression test belongs in `CommandPaletteTests.swift`. It drives `palette.onChoose` with a row that was enabled
  and is now unavailable, as `TabSearchTests` drives stale tab rows.
- UTERM-061 M1 rewrites `choose` and covers this refusal. A fix landed first is compatible, but M1 restructures it.

## Chosen fix

2026-11-26, chosen by the user: a command row refused when chosen keeps the palette open. The row dims in place, and
the status bar says the command did not run, such as `"Clear Screen" did not run, because it is not available now.`.
The row loses the selection, and no row is selected, so Return runs nothing. Down selects the first selectable row
below it, and Up the first above it. The same selection rule holds for any selected row that dims in place. UTERM-061's
"The palette list holds still" and its M1 checks were amended to match.

The recorded decisions stand: palette rows only, and `run` reports why it refused through an enum. A gone pane keeps
its own message. The regression test lives in `CommandPaletteTests.swift`.

## Fix note

Two new tests in `Packages/UnitermKit/Tests/WindowKitTests/CommandPaletteTests.swift` failed on the unfixed code.
`testChoosingACommandThatBecameUnavailableKeepsThePaletteUpAndSaysWhy` saw the palette hide with no message.
`testASelectedRowThatDimsInPlaceLeavesNoSelectionAndArrowsMoveFromIt` saw the selection jump to the first runnable row,
so Return ran Settings. `testChoosingACommandWhosePaneClosedHidesAndPostsOneMessage` pins the gone-pane path to one
message.

- `CommandRegistry.swift`: `attempt` returns a `CommandOutcome` of ran, unavailable, or pane gone. `run` wraps it and
  keeps its Bool, so menu, key, and status-bar dispatch are unchanged.
- `MainWindowController+Palette.swift`: `choose` checks availability before it hides. A refused command row keeps the
  palette open, updates the rows in place, and posts the warning. A gone pane still hides, and the registry posts its
  one message. A refusal that only shows up after the hide also posts the warning.
- `MainWindowController+Commands.swift`: `postCommandUnavailable` posts `"<title>" did not run, because it is not
  available now.` at warning level, beside `postPaneGone`.
- `CommandPaletteView.swift`: in-place updates go through `updateEntriesInPlace`, which never picks a row. A selected
  row that dims loses the selection, and Return runs nothing. Down then selects the first runnable row below it, and Up
  the first above it. With none on that side, nothing is selected. A full re-sort after typing keeps its old rule.
