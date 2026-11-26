# VoiceOver reads a palette filter row's kind as empty

**Status:** open. Confirmed by reading the code, not with VoiceOver.

## Observed

Found by a design critique of UTERM-061 on 2026-11-26. A palette row of the filter or notice kind reads to VoiceOver as
its title, then ", enabled", with nothing before the comma.

## Cause

- A row's accessibility value is `"\(entry.label), enabled"` or `", disabled"`
  (`Packages/UnitermKit/Sources/WindowKit/CommandPaletteView.swift`, `configure`, about line 801).
- `Kind.label` is the empty string for `.filter` and `.notice`
  (`Packages/UnitermKit/Sources/WindowKit/Commands/PaletteRanking.swift`, about line 36), and such rows carry no applet
  name.

## Repro

Type `applet:` in the palette and move VoiceOver onto a filter suggestion row. Expected: a value that names the row's
kind, or no leading comma. Actual: ", enabled".

## Fix

UTERM-061 M1 has a check that every row's value names its kind, so the fix can land there or on its own. Build the
value without an empty kind, or give filter and notice rows a kind word.
