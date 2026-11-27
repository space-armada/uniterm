# A failed Open in This Pane drops the pane's old file instead of keeping it

**Status:** fixed 2026-11-27
**Fixed:** 2026-11-27
**Estimate:** medium. Four viewers took the same change, and the design call was settled with the user.

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

## Fix note

Fixed on 2026-11-27. Open in This Pane and a drop now check the chosen file before the pane gives up its source.

- `SourceReplacing` has a new async `checkSource(_:startDirectory:)`. It reads the file far enough to know the pane can
  open it, and throws why when it cannot. It changes nothing the pane shows or saves.
- `replaceSource(withChosen:)` checks first, then replaces. A failure posts the warning and leaves the old file, its
  content, and its saved description alone. A swap that a later choice superseded says nothing.
- `SourceSwap` now waits for the check, tells the swap whether it is still current, and cancels the swap it supersedes.
- Data viewer: `TableLoader.probe` reads until the first rows arrive or the load ends. It catches a missing, unsupported,
  or unparsable file.
- Image viewer: the check runs the same source load. It catches a file that is not an image, or cannot be read.
- Text viewer: the check covers the format, the size cap, and the PDF or Markdown read. The PDF and Markdown failure
  messages are now shared with the load.
- Map viewer: the check reads and parses the file as a load does, and drops the result.

Files: `AppletKit/SourceReplacing.swift`, `AppletKit/SourceSwap.swift`, `TableData/TableLoader.swift`, and the four
viewers' applets. Each viewer's test target has a regression test that opens a good file, swaps in a bad one, and checks
the old source, the description, and the warning. Each failed on the old code because the pane showed the bad file and
described it.

What stays open. A failure that only the full load reaches still shows in the pane after the swap, as before. Examples
are a corrupt image the helper cannot decode, a document the helper rejects, and a JSON error far into a big table. The
sync `replaceSource(with:)` is unchanged, so a script's send and a new pane's factory still replace at once.

UTERM-062 will reshape where a failed open lands, because every open into a viewer pane will add a tab. This fix keeps
the old file in the pane for now.
