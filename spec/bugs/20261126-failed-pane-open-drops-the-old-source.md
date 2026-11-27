# A failed Open in This Pane drops the pane's old file instead of keeping it

**Status:** open
**Validation:** not confirmed in the running app; traced in the code of all five viewers

**Estimate:** medium. Each viewer needs the same change, and the fix has one design call. See "Fix".

## Observed

`SourceReplacing` promises that a failed swap keeps the old source. Its doc on `replaceSource(withChosen:)` says "A
failure goes to the pane's status bar, and the pane keeps the source it had." UTERM-015 M3's As built says the same:
"A failure reaches the pane's status bar, and the applet keeps its source."

No viewer keeps it. Choose Open in This Pane… in a viewer showing a good file, and pick a file the viewer cannot read,
such as a GeoJSON file with broken JSON in a map pane. The pane then shows the load failure for the new file. The old
file is gone from the pane and from its saved description, so a relaunch restores the broken file too.

## Cause

Every viewer's `replaceSource(with:startDirectory:)` writes the new path into its description, then starts an async
load. None of them throws, so the `catch` in `replaceSource(withChosen:)` at
`Packages/UnitermKit/Sources/AppletKit/SourceReplacing.swift` never runs for a bad file.

- `DataViewerApplet/DataViewerApplet.swift:289` replaces `record` before `open(path:...)`.
- `ImageViewerApplet/ImageViewerApplet.swift:301` replaces `record` before `begin(path:...)`.
- `TextViewerApplet/TextViewerApplet.swift:290` goes through `replace(with:...)`.
- `MapViewerApplet/MapViewerApplet.swift:341` and its `load(_:startDirectory:)` at line 366 set `record.path`, then
  `open(path:...)` clears the file pins and forgets the document before the read. Its doc comment says outright that
  it never throws, "since every failure shows once the load runs".

The protocol's contract was written while no viewer existed, and a fixture applet that throws proved it. Every real
viewer loads asynchronously, so no viewer can know about a failure in time to throw.

## Repro

1. Open a map pane on a good GeoJSON file. Its pins show.
2. Write a file named `broken.geojson` that holds `{ "type": "FeatureCollection", "features": [`.
3. Choose File > Open in This Pane… and pick `broken.geojson`.
4. Expected: a warning on the status bar names `broken.geojson`, and the pane still shows the first file's pins.
   Actual by the code: the pins go at once, and the pane reports the failure for `broken.geojson`.

## Fix

Restore the contract: load the new file aside, and swap the description and view only once it reads. A failure then
posts the warning and leaves the old source alone. A test per viewer opens a good file, swaps in a bad one, and
checks that the old source and description remain. This should fail on today's code.

The design call is how the failure reaches the protocol's caller now that every load is async:

- Make the swap `async throws`, so `replaceSource(withChosen:)` keeps owning the warning. This changes the protocol
  for every viewer.
- Keep the call synchronous, and have each viewer post its own warning when the aside load fails. This splits one
  rule across five viewers.

The alternative of rewriting the docs to match the code withdraws the guarantee. A failed open would then keep
destroying the pane's file and its saved description.

UTERM-062 plans to have every open into a viewer pane add a tab. That proposal changes where a failed open lands, so
the fix and that proposal should agree on it.
