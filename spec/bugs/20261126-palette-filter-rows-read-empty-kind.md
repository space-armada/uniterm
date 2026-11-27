# VoiceOver reads a palette filter row's kind as empty

**Status:** open. Confirmed by reading the code, not with VoiceOver.

**Estimate:** small, but one non-trivial decision. Which words VoiceOver reads for a filter or notice row is unsettled.
Candidates: omit the kind and read only the enabled state, give filter and notice rows kind words, or read the row as
its title alone. UTERM-061's "How a command row reads to VoiceOver" decision settles "Browser command" and "Browser tab"
for command and tab rows. It names no wording for filter, notice, or filter-keyword rows. Its acceptance line only says a
filter row's value does not read as an empty kind, which both candidate fixes satisfy. UTERM-002 settles no
accessibility wording. The fix would touch `CommandPaletteView.swift` (`configure`), possibly `PaletteRanking.swift`
(`Kind.label`), and a test under `Packages/UnitermKit/Tests/WindowKitTests`.

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
