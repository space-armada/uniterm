# A file that passes the open check but fails its full load still replaces the pane's old file

**Status:** open
**Validation:** not confirmed in a test or the running app; traced in the code and in each check's own doc comment

## Observed

`SourceReplacing` says of `replaceSource(withChosen:)`: "A failure goes to the pane's status bar, and the pane keeps the
source it had." That holds only for a failure the viewer's `checkSource` can see. Each check is shallower than the
viewer's full load. A file that passes the check and then fails in the load replaces the pane's old file. The pane shows
the failure, and its saved description names the bad file, so a relaunch restores the bad file too.

This is the part left open by `20261126-failed-pane-open-drops-the-old-source.md`. Its fix landed as "Keep a pane's file
when Open in This Pane cannot read the new one".

## Cause

`replaceSource(withChosen:)` in `Packages/UnitermKit/Sources/AppletKit/SourceReplacing.swift` runs `checkSource`, then
the synchronous `replaceSource(with:startDirectory:)`. The replace gives up the old source at once and starts the load.
What each check leaves to the load:

- Image viewer, `ImageViewerApplet.swift:318`. The check runs `SourceLoader.load`, which finds and opens the source. The
  helper's decode runs only in the load. A file with an image type whose bytes the helper cannot decode passes.
- Text viewer, `TextViewerApplet.swift:654`. PDF and Markdown run their real readers. RTF and Word get only an open and
  a size check, so a document the helper rejects passes. A Markdown file that the page rejects passes too.
- Data viewer, `DataViewerApplet.swift:302`. `TableLoader.probe` at `TableData/TableLoader.swift:87` stops at the first
  snapshot. A parse error past the first rows passes.
- Map viewer, `MapViewerApplet.swift:372`. The check reads and parses the whole document, so no gap is known. It reads
  the file twice.

Every viewer also has a window between the check and the load. A file that changes or goes away in that window fails in
the load.

## Repro

1. Open an image pane on a good image.
2. Write a file named `broken.png` that holds a valid PNG signature and header, then garbage.
3. Choose File > Open in This Pane… and pick `broken.png`.
4. Expected: a warning on the status bar names `broken.png`, and the pane still shows the first image.
   Actual by the code: the pane shows the decode failure for `broken.png`, and the first image is gone.

Not run. The fixture has to pass `SourceLoader.load` and fail the helper's decode, and that was not checked.

## Fix

Load the new file aside, and swap the description and the view only once the full load succeeds. The check then has
nothing left to miss, and the file is read once. The earlier bug recorded this as its fix, and the user chose the
`async throws` swap for it. What landed is a check before a synchronous replace instead.

Design calls:

- Whether a script's `send` keeps the old source too. Today `send` and the routed open replace at once. The check was
  built to keep `WindowScripting.send` and the `ScriptHost` contract synchronous, with nothing suspended between
  `prepareSource` and `send`. The options are an async swap for user-chosen opens only, or one for every caller, which
  changes the script contract.
- How each viewer holds two loads at once. The data viewer's session and the image viewer's helper each hold one source
  today.

UTERM-062 plans to have every open into a viewer pane add a tab. A failed open then lands in a new tab and the old file
stays in its own. That may close this bug for viewers with tabs, so the fix and that proposal should agree.
