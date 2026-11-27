# The File menu shows two items titled "Open…" while a viewer is focused

**Status:** fixed 2026-11-26
**Fixed:** 2026-11-26
**Estimate:** small to medium; no open design decisions. The user chose the fix on 2026-11-26. See "Chosen fix".

## Observed

Found by a design critique of UTERM-061 on 2026-11-26. With a data, text, image, or map viewer focused, the File menu
holds two items titled "Open…". One is uniterm's Open on Cmd-O, which routes a file by type. The other is the viewer's
pane-local Open, which replaces the focused pane's file. They read the same, and they do different things.

An App Shortcuts remap matches a menu item by its title. A remap of "Open…" cannot say which of the two it means.

## Cause

- uniterm's Open takes the menu-only title "Open…" (`Packages/UnitermKit/Sources/WindowKit/Commands/StandardCommands.swift`,
  about lines 45-46).
- Each viewer declares the pane-local Open with the title "Open…" and a File menu home
  (`Packages/UnitermKit/Sources/AppletKit/SourceReplacing.swift`, `openSource`, about lines 65-73). The map viewer
  puts it in section 0, beside uniterm's. The other viewers put it in section 1.
- The menu hides an applet item only by type (`WindowKit/Menu/CommandMenu.swift`, `sync`), so with a viewer focused
  both items show.

## Repro

Focus a text viewer and open the File menu. Expected: one item per action, each with a title that says what it does.
Actual: two items titled "Open…".

## Fix

It needs a design call:

- Give the pane-local Open its own menu title, such as "Open in This Pane…". Registry commands already carry a menu
  title apart from the palette title, so an applet command would need the same field. An existing remap of the
  pane-local Open's title stops matching.
- Keep both titles, and accept that a remap of "Open…" is ambiguous.

## Chosen fix

2026-11-26, chosen by the user: rename the viewer's pane-local Open to "Open in This Pane…" in the palette and the
menu alike. Applet commands carry one title, so no separate menu title is needed. An existing App Shortcuts remap of
"Open…" for the pane-local item stops matching, which follows from giving the two actions different names. The tests
that pin the "Open…" title change with it.

The user also asked for a rule that one thing reads the same in every place it shows. It is proposed as ADR-17.

The fix touches `AppletKit/SourceReplacing.swift` (`openSource`), plus `WindowKitTests/SourceOpeningTests.swift` and
`AppletCatalogTests/BuiltInCommandsTests.swift`, which pin the old title.

## Fix note

The viewers' pane-local Open is now "Open in This Pane…" in the File menu and the palette. uniterm's own Open keeps
"Open…". File: `AppletKit/SourceReplacing.swift`. Regression test:
`SourceOpeningTests.testThePaneLocalOpenReadsApartFromEveryFileMenuItem`.
