# UTERM-070: A Viewer Keeps Its File When the New One Fails to Load

**Status:** accepted
**Created:** 2026-11-27
**Updated:** 2026-11-27

## Dependencies

- UTERM-015, whose source-replacing contract promises that a failed swap keeps the pane's old source

## Impacts

- UTERM-062 — "Every user open adds a tab", "What a program's open does", and M1 to M5. Once a user's open adds a tab,
  the user has no replace inside a tab, so this proposal's rule for the user's open lasts until each viewer's tab
  milestone. UTERM-062 carries six amendments for this proposal, listed in "Whether this proposal is needed once
  UTERM-062 lands". This proposal needs nothing from UTERM-062, so it is not a dependency. Its rows go ahead of
  UTERM-062 M1, which rebuilds the source-swap path and the program replaces into a named tab.
- UTERM-009 — "Large files": "One memory budget covers every data viewer pane together". While a chosen data open
  loads aside, the pane's two leases pass that shared limit by the outgoing table. UTERM-062 already supersedes the
  shared budget in part with a budget for each file.
- UTERM-018 — none in practice. A routed open makes a new pane today, and UTERM-018's M3 to M5 route opens to an
  existing pane only after UTERM-062 M5, when they add a tab. No routed open ever replaces a pane's file.

## ADR Deviations

None.

## Summary

A viewer pane keeps its old file when a file the user chooses for it, or a program sends or shows in it, fails its full
load. Today the pane shows the failure, and its saved description names the bad file, so a relaunch restores the bad
file too. Each viewer loads the chosen file aside and swaps only once it has loaded.

## Motivation

`SourceReplacing` promises that a failed swap keeps the pane's old source. UTERM-015 M3 says the same. No viewer kept
that promise. Each viewer wrote the new path into its description before its asynchronous load began, and none could
throw.

The first fix landed as the commit "Keep a pane's file when Open in This Pane cannot read the new one". It adds a
`checkSource` call to the protocol. The pane's Open and a drop run it before the swap. Each viewer's check reads the
file far enough to find the failures it can, then drops what it read. A file that fails the check leaves the pane alone.

A file that passes the check and fails the load still replaces the pane's file. The checks stop short of the full load
on purpose, since a full load held twice is costly:

- The image viewer's check finds and opens the file but never decodes it. On 2026-11-27 a scratch test opened a good
  PNG, then swapped in a file with a PNG signature and 64 bytes of garbage. The pane showed the decode failure, took the
  title `broken.png`, and saved that path. The old image was gone.
- The text viewer's check runs the PDF and Markdown readers, and only opens and sizes an RTF or Word file. The rest of
  that load was traced, not run.
- The data viewer's check stops at the first rows. A parse error past them was traced, not run.
- The map viewer's check reads the whole document, so no gap is known there. It reads the file twice.

The first fix kept the synchronous replace. A script's `send` and a new pane's factory still replace at once. The
earlier bug offered two ways for a failure to reach the chosen swap's caller. The user chose an `async throws` swap,
which "changes the protocol for every viewer". The check landed in its place.

A program learns of a failed load in two of its three replaces. The image viewer's `show` and the text viewer's
`show-markdown` answer at once with a handle, and a later `wait` on it reports `failed` with a code. `send` answers
`null` as soon as the replace returns, before the load runs. The review's scan found no reply, event, or pane listing
field that tells a script the sent file failed to load. Today a routed open always makes a new pane through the viewer's
factory, so no routed open replaces a pane's file.

The bug is `20261127-chosen-open-check-misses-full-load-failures`.

## Design Decisions (Settled)

### What a failed load does to the file a pane or tab already shows

Original question: when a chosen or program-sent file passes the open check and fails its load, does the pane keep its
old file?

Decision: the pane keeps the old file. The viewer loads the new file aside. It swaps its saved description only at the
load's commit point, once the new file has loaded. Its view swaps then too, except where a viewer can show the new file
early and swap back on a late failure, as the data viewer does. A failure posts a warning on the pane's status bar and
changes nothing else. The `SourceReplacing` contract stays as written. The file is read once. `checkSource`, the data
viewer's `TableLoader.probe`, and the extra current-swap check in `replaceSource(withChosen:)` then have nothing left to
catch, so they are removed. Each viewer's own load generation guards the commit instead. (autonomous)

Each viewer's commit point, and how it holds the old view and the new load together, are settled in "How each viewer
holds two loads".

Rationale: this restores the contract that `SourceReplacing` and UTERM-015 M3 state, for every failure. Narrowing the
docs to what the checks see would withdraw the guarantee for every failure they miss, and a relaunch would keep
restoring the bad file. The earlier bug records that the user chose to load aside, through an `async throws` swap, over
rewriting the docs. A rollback that restores the old record and reloads it would re-read a file that may have changed or
gone. It would drop the view state and the map's unsaved edits, and inline Markdown has no file to reload. The text
viewer's reload already keeps the old render until a new one is ready, so the pattern exists in the code. Converged in 1
pass.

**Decided by:** proposal-reviewer (autonomous), 2026-11-27

### Whether this proposal is needed once UTERM-062 lands

UTERM-062 is accepted and not started. Its summary says every open the user makes into a viewer pane adds a tab. Its
"What a program's open does" says `show`, `show-markdown`, and `send` replace the tab they name, and a new `open`
command adds one. After it lands, a user's open can no longer replace a file. A failed open lands in a new tab, and the
old tab is untouched.

The gap that stays is a program's replace into a named tab, and the interval before UTERM-062 ships. Whether a program's
replace should keep the old content on a failed load was not decided there. Whether UTERM-062's tab open should drop a
tab whose load failed was not either.

Decision: this proposal is needed, for the interval and after it. Through the interval it restores the contract for the
user's chosen opens: the pane-local Open and a drop. For the program replaces "Which callers keep the old file" names,
it keeps the rule after UTERM-062 too, inside the tab the program names. UTERM-062 owns what a failed tab open does.
This proposal asked UTERM-062 for these amendments. The user picked all six on 2026-11-27, and UTERM-062 carries them:
(autonomous, addition)

- A failed tab open shows its failure in its own tab. With `checkSource` removed, every failure behaves one way: the tab
  opens and shows why its file did not load. UTERM-062's in-tab load notices already assume this.
- UTERM-062 M1 rebuilds the source-swap path before any viewer has tabs. Its checks gain one: a viewer that has no tabs
  yet still keeps its file when a chosen open fails its load.
- Each of UTERM-062 M2 to M5 removes that viewer's aside load and supersede rule for the user's open, since the open
  then adds a tab.
- UTERM-062 M2 to M5 keep the aside load for a program's replace inside the tab it names: `send` in all four viewers,
  `show-markdown` in M3, and `show` in M4. A failed program replace into a tab keeps that tab's content.
- UTERM-062 M1's sent files kept per tab follow the same rule this proposal's M1 builds per pane: a tab's earlier sent
  file stays on disk while the tab can still go back to it, and closing the tab removes every sent file it held.
- UTERM-062 M2's budget for each file replaces the paired leases this proposal's M4 builds.

Rationale: the problem exists today. A user's image pane shows a good PNG. The user picks Open in This Pane and chooses
a PNG header followed by garbage. The check opens the file without decoding it and passes. The replace writes the new
path into the description and clears the image. The decode fails, and the pane saves the bad path. UTERM-062's queue row
is far down the queue, behind UTERM-063 and UTERM-064, so "UTERM-062 fixes it" leaves a stated contract broken for that
whole time. After UTERM-062 the user has no replace inside a tab, so the user-path work lasts until each viewer's tab
milestone. Throwing that work away later is a cost of effort, not a downside.

Retracting this proposal, or folding a program rule into UTERM-062, leaves the user's paths broken through the
interval. Which program replaces keep the old file is settled in "Which callers keep the old file". Converged in 1 pass.
Amended 2026-11-27; see Decision Log.

**Decided by:** proposal-reviewer (autonomous), 2026-11-27

### Which callers keep the old file

Original question: a user's Open and a drop keep it today for failures the check sees. A script's `send` and a routed
open replace at once. Does the rule hold for every caller?

Decision: every replace keeps the old file when the new one fails its load. That covers the pane-local Open, a drop,
the image viewer's `show`, the text viewer's `show-markdown`, and a script's `send`. Each loads aside with the same
per-viewer machinery. A new pane's factory has no old file to keep. No routed open replaces a pane's file, since a
routed open makes a new pane today and adds a tab after UTERM-062.

- `show` and `show-markdown` still answer at once with a handle, and their `wait` reports `failed` while the old
  content stays. A failed `show` keeps today's reply shape, and its redaction is checked against the caller's scope for
  the file that failed.
- `send` still answers `null` at once, and its reply does not change. A failed sent file keeps the pane's old content
  and posts the same warning a drop does. The script is not told of the failure. When the old content is an earlier
  sent file, the script host keeps that file while the pane still shows it, as "How the script host keeps a sent file
  the pane still shows" settles.

The chosen swap becomes `async throws`, as the user chose for the earlier bug. `replaceSource(withChosen:)` awaits the
aside load and owns the warning. `send` stays synchronous. Nothing suspends between `prepareSend` and `send`.

Rationale: the user chose this at the review gate on 2026-11-27. The review had left `send` replacing at once, and the
user chose that `send` keeps the old content too, with no change to its reply. A drop, `send`'s user counterpart, keeps
the old file, and the script learns nothing under either rule. The user also chose to leave out a report of the load
result to the script. `show` is the program's form of Open in This Pane, so the old rule lost an image on a program path
too. Making `send` wait for the load would hold a reply on a command with an effect, which ADR-11 argues against.
Amended 2026-11-27; see Decision Log.

**Decided by:** user, 2026-11-27

### How each viewer holds two loads

Only if a candidate above loads aside. The data viewer's session and the image viewer's helper each hold one source
today. The text viewer's PDF and Markdown readers and the map viewer's document read are already separable. Candidates
include a second session, a probe that runs the real loader to a settled result, and a rollback that restores the old
record and reloads it. A rollback re-reads the old file and drops its sort, filter, and scroll.

Decision: each viewer loads the new file aside with what it already has, and commits once the new file has loaded.
Until the commit, the old file's saved description stays, and the status bar names the file being opened. The old view
stays too, except in the data viewer, which shows the new table early and can swap back. Everything a replace clears
today moves to the commit: the data viewer's session close, the text viewer's unwatch, superseded program waits, and
mark of a program's sent file, the
image viewer's cleared image, and the map's forgotten document and removed pins. (autonomous)

- Text viewer: a PDF or a helper-decoded document commits when its read or decode finishes, through the reload path's
  kept render. Markdown commits when the page reports it rendered. When the pane already shows Markdown, the aside load
  renders into a second Markdown view, and the old view closes at the commit. The pane's one Markdown view cannot hold
  the old page, since it starts loading the new one at once.
- Image viewer: the helper opens the new source beside the shown one, and the decode runs at display priority. A single
  file commits at its first decoded frame. A folder commits once its scan finds a first image. A folder with no images
  is its failure. A damaged first member then shows its own failure inside the committed folder, as today.
- Map viewer: the document reads and parses off the main thread, and commits on a parsed document. The discard question
  is asked after the parse succeeds and before the commit. A failed load keeps the edits and the undo history.
- Data viewer: the new file loads into a second table session with its own lease. When the new table shows is settled
  in "When the data viewer's new table takes over". The old lease and the aside lease are budgeted as one pane, so
  neither counts the other's bytes against the limit. The aside load then reaches the rows a plain open would, and an
  old table still loading is not cut short by it. While both are held, the peak can pass the limit by the outgoing
  table. `TableBudget`'s doc comment states the new bound.

A second choice while an aside load runs supersedes it. The first aside load releases its lease, drops its helper
source, or cancels its job. The pane keeps the last file whose load ended, and a failed second choice keeps it. In the
data viewer, a superseded table that was streaming leaves the screen at once, and the last table whose load ended
shows until the next one's first rows.

Rationale: this restores the contract for every failure the loaders produce, and reads each file once. The data viewer
keeps UTERM-009's rows that appear as they arrive for every open that succeeds, which is the common case. Holding the
new table back until its parse ends would show nothing of a large file for the whole parse. A late failure is rare for
CSV, whose only late failure is a read error, and realistic for JSON cut off near its end. Everything live follows the
table on screen, so a controller's read scope is checked against the file it would read about. A probe to a settled
result would read every file twice and leave a window in which the file can change. Closing the old session at the new
table's first rows would leave the pane with neither file after a late parse or read error, which is the bug itself.
Keeping the rows read after a late error instead would change every data open, fresh opens included, and would lose the
old file and save the failing one. Budgeting the two leases apart would cut the new file short of what a plain open
reads. A table of 900 MiB beside an 800 MiB file would stop the new load at about 124 MiB, and choosing the file again
would not help. Converged in 1 pass. The data viewer's commit was reopened by the coherence review and settled on
showing the new table at once. Amended 2026-11-27; see Decision Log.

**Decided by:** proposal-reviewer (autonomous), 2026-11-27

### How the script host keeps a sent file the pane still shows

Original question: the script host keeps one sent file per pane, and discards a pane's previous sent file as soon as
`send` returns, before the new load runs. Once a failed `send` keeps the old content, the old content may be an earlier
sent file. How does the host keep that file while the pane shows it, and free it once the pane no longer does?

Decision: the aside load's task carries the answer. `replaceSource(withSent:)` starts the same aside load the chosen
swap awaits, and returns its task at once, so `send` still answers `null` at once. The script host awaits the task off
the reply path. A return is a commit, and the host frees the pane's earlier sent file. A throw is a failure, and the
host frees the new file. A cancel is a supersede or a pane close, and the host frees the new file and posts nothing.

A sent file stays when the user's own open commits over it. It is freed at the script's next send to that pane or at a
relaunch, as the sent-content folder's doc says today.

Rationale: the user chose this at the review gate on 2026-11-27. A task settles once by construction, so a commit and a
drop can never both arrive. Chosen and sent replaces share one signal, and a supersede or a close maps onto
cancellation. A callback would be a second "call once" signal beside the task. A query to the pane fails unsafe when a
viewer answers wrong. The user also chose to leave out freeing a sent file when the user's own open commits over it.
That file is bounded at one per pane, and this proposal did not cause it.

**Decided by:** user, 2026-11-27

### When the data viewer's new table takes over

Decision: the pane shows the new table at its first rows and streams the rest, as a plain open does. The old session
stays in memory until the load ends. The title, the pane listing, the read-scope source, and the current directory
follow the table on screen. Only the saved description stays on the old file until the load ends completed, or stopped
early with rows. A late parse or read error swaps back to the old session with its sort, filter, and scroll, re-reads
nothing, and posts a warning. A stop with no rows never shows the new table. A quit while the new table streams
restores the old file.

Rationale: the user chose this at the review gate on 2026-11-27, over showing the new table only when its load ends.
Rows already seen can vanish on a late error. A quit mid-load restores the old file. Holding the table back would show
nothing of a large file for the whole parse, against UTERM-009's rows that appear as they arrive.

**Decided by:** user, 2026-11-27

## Design Decisions (Open)

None. Every question is settled.

## Risks

- **A second load held at once raises a viewer's peak memory** — likelihood: medium, impact: medium.
  The data viewer's paired leases let the peak pass the shared limit by the outgoing table until the commit. The image
  helper holds a second source, and a text pane showing Markdown holds a second web view while the new page renders.
  Mitigation: the aside load ends and frees what it holds when it fails or is superseded, and the old one goes at the
  commit. The memory-pressure warning still stops every running load. A test loads a file near the budget aside and
  checks that the old table stays and the new one reaches the rows a plain open reads.
- **UTERM-062 M1 rebuilds the source-swap path and drops the aside load** — likelihood: medium, impact: medium.
  UTERM-062 is accepted, and its M1 changes the shared swap path before any viewer has tabs.
  Mitigation: UTERM-062 M1 now checks that a viewer with no tabs yet still keeps its file when a chosen open fails its
  load, and that its sent files kept per tab follow this proposal's rule. The regression tests this proposal adds also
  fail when the aside load is dropped.
- **One viewer runs this proposal's supersede rule and UTERM-062's tab rule at once** — likelihood: low, impact: medium.
  UTERM-062 M1 says N rapid opens add N tabs and none supersedes another. This proposal says a second choice supersedes
  the first. A viewer with both active would drop a tab open or keep a stale swap.
  Mitigation: the supersede rule for the user's open applies only to a viewer with no tabs. Each UTERM-062 viewer
  milestone now removes it for that viewer.
- **The paired leases and UTERM-062's budget for each file overlap** — likelihood: medium, impact: low.
  Both change `TableBudget`. Whichever lands second must undo or absorb the other.
  Mitigation: UTERM-062 M2 now says its budget for each file replaces the paired leases. Each is reverted by a
  redeploy, and neither changes stored data.
- **The old file stays on screen while a slow load runs** — likelihood: high, impact: low.
  A large PDF, a helper decode, or a stalled mount can take seconds, and the pane no longer says "Opening…" in place.
  Mitigation: the status bar names the file being opened until the commit or the failure.

- **A failed `send` keeps old content that looks current, and the script is not told** — likelihood: medium, impact:
  low.
  `send` answers `null` before the load runs. When the sent file fails, the pane keeps what it showed and posts one
  warning on the status bar and in the history, as a drop does. A watcher that sends every second can leave the last
  good content on screen while the user is not looking.
  Accepted: the user chose this at the review gate over replacing at once, and chose to leave out a report to the
  script. The warning names the sent file and stays in the history.

- **The script host removes a sent file the pane still shows, or keeps one too long** — likelihood: low, impact: medium.
  Once a failed `send` keeps old content, the host holds more than one sent file per pane. Removing one early leaves the
  pane showing a deleted file, and its file watch reports it gone. Keeping one too long fills the sent-content budget,
  and every later `send` is refused.
  Mitigation: M1's checks require that each sent file is removed exactly once, that a file the pane can go back to
  stays, and that closing the pane removes every file it held. The aside load's task settles once, so a commit and a
  drop never both arrive. (autonomous)

## Milestones

### M1: The chosen swap waits for the load, and the map loads aside

**Status:** NOT STARTED

- `replaceSource(withChosen:)` awaits the viewer's aside load and posts the warning when it throws. A later choice
  supersedes an earlier one, which says nothing
- A viewer that does not load aside yet keeps today's check before its replace, so the image, text, and data viewers
  behave as today until their own milestones
- A program's `send`, `show`, and `show-markdown` supersede a chosen swap still waiting, and stay synchronous. In a
  viewer that loads aside, a failed `send` leaves the last file whose load ended
- A `send` into a viewer that does not load aside yet replaces at once, as today, until that viewer's milestone. The
  pane's earlier sent file is freed right after that replace, as today
- `replaceSource(withSent:)` returns its aside load's task at once, and `send` still answers `null` at once. The script
  host awaits the task off the reply path. A return frees the pane's earlier sent file. A throw or a cancel frees the
  new file
- An earlier sent file stays on disk while the pane can still go back to it. Each sent file is removed exactly once,
  and a task that settles for a file the host no longer holds changes nothing. Closing the pane removes every sent file
  it held
- A sent file stays when the user's own open commits over it, until the script's next send to that pane or a relaunch
- A failed `send` posts the same warning a drop does, exactly once, from one owner. A superseded `send` says nothing
- The script host's and the sent-content folder's doc comments describe the files a pane may still read
- Closing a pane during an aside load releases what the aside load holds
- While an aside load runs, the status bar names the file being opened, and the segment clears on the commit or the
  failure
- The map reads and parses off the main thread, asks its discard question after the parse succeeds, and reads
  `isDirty` at that moment. A second choice while the question is up makes the earlier answer do nothing
- A map file that fails to read or parse keeps the old document, its pins, its edits, and its undo history. The disk
  checker does not drop the aside load
- A chosen map file is read once, since the map's check no longer runs
- A test per path opens a good map file, swaps in one that changes on disk between today's check and the load so the
  load fails, and checks the old document, the description, and the warning. It fails on today's code
- A test sends a good map file, then sends one that fails to parse, and checks the old document, the description, the
  warning, and that the first sent file is still on disk. It fails on today's code

### M2: The image viewer loads aside

**Status:** NOT STARTED

- The helper opens the new source beside the shown one, at display priority, so a zoomed pane still decodes it. The
  shown source is never evicted for it
- A single file commits at its first decoded frame. A folder commits once its scan finds a first image, and a folder
  with no images fails
- A helper that crashes or times out during the aside decode keeps the shown image, and the pane reports the new file's
  failure
- A failed chosen open never reports a program's pending `wait` as superseded while that program's image stays on
  screen
- A `show` loads aside too. A failed `show` keeps the old image, and its `wait` reports `failed` in today's reply shape.
  The reply's redaction is checked against the caller's scope for the file that failed, not the file on screen. A second
  `show` that supersedes an aside load settles the first handle as superseded at once
- A test opens a good image, `show`s a damaged PNG, and checks the old image and the `failed` reply. It fails on today's
  code
- While the old image stays on screen, a pending `show` handle never settles as shown with the old image. A failed aside
  `show` fails only its own handle, not a pending step on the old folder
- A test opens a good PNG, swaps in a file with a PNG signature and garbage, and checks the old image, the description,
  and the warning. It fails on today's code
- A test sends a good image, then sends a damaged one, and checks the old image, the description, the warning, and that
  the first sent file is still on disk. It fails on today's code

### M3: The text viewer loads aside

**Status:** NOT STARTED

- A PDF or a helper-decoded document commits when its read or decode finishes, through the reload path's kept render
- Markdown over Markdown renders into a second Markdown view, which takes over when the page reports it rendered. The
  old view closes then. A render that fails keeps the old page
- A failed chosen open posts a warning that names the chosen file, not the reload notice. Inline content the pane
  showed keeps its text for Reload
- A Reload, or a file-watch change to the old file, during an aside load neither drops nor commits the aside load
- The second Markdown view renders at the pace of a visible one, and its web content process ending fails the aside load
- A `show-markdown` loads aside too, and a failed render keeps the old page while its `wait` reports `failed`. A run of
  `show-markdown` calls reuses one standby view, so a preview typed at normal speed still updates
- A test shows Markdown, sends a `show-markdown` with an injected render failure, and checks the old page and the
  `failed` reply. It fails on today's code
- A failed `show-markdown` over a kept user file is redacted for its caller by the caller's own content, not by the
  kept file's scope
- A failed chosen open never reports a program's pending `wait` as superseded while that program's content stays on
  screen
- A test per format opens a good file, swaps in one that fails in the full load, and checks the old content, the
  description, and the warning. RTF and Word use a file the helper rejects. PDF uses a file that changes between
  today's check and the load. Markdown uses an injected render failure. Each fails on today's code
- Whether the pane shows a program's sent file changes only at the commit, so a failed open never changes how the kept
  page resolves its images
- A test sends a good Markdown file, then sends one whose render fails, and checks the old page, the description, the
  warning, and that the first sent file is still on disk. It fails on today's code

### M4: The data viewer loads aside, and the checks are removed

**Status:** NOT STARTED

- The new file loads into a second table session with its own lease. The view shows it at its first rows and streams
  the rest, and the old session stays in memory until the load ends
- The title, the pane listing, the read-scope source, and the current directory follow the table on screen. The saved
  description changes when the load ends completed, or stopped early with rows. A quit mid-load restores the old file
- A stop with no rows, such as a memory-pressure warning, never shows the new table
- A second choice while a new table streams swaps back, on a later failure, to the last table whose load ended. A swap
  back after the user sorted or filtered the new table posts a warning that names the file and says its rows were
  dropped
- While a new table streams, a saved description pairs the old file with the old session's sort, filter, and sheet.
  The view switches between the two sessions
- A `send` that arrives while a new table streams supersedes the streaming table only. A failed `send` then swaps back
  to the last table whose load ended. When the pane has no such table, as in a new pane's first load, it swaps back to
  the table still loading
- A test sends a good CSV, then sends a JSON file cut off near its end, and checks the old table, the description, the
  warning, and that the first sent file is still on disk. It fails on today's code
- The old lease and the aside lease are budgeted as one pane. A file near the budget, chosen beside a large table,
  reaches the rows a plain open reads, and an old table still loading is not cut short by it. `TableBudget`'s doc
  comment states the new bound
- A parse or read error past the first rows swaps back to the old table, its sort, filter, and scroll, and its
  description, and re-reads nothing
- `checkSource`, `TableLoader.probe`, and the extra current-swap check are gone, and each chosen file is read once
- The `SourceReplacing` doc comments describe the aside load for every replace, `replaceSource(withSent:)` included.
  UTERM-015 M3's contract text needs no change

### M5: The user's check

**Status:** NOT STARTED

- The user opens a good file in each of the four viewers in the running app, chooses a file that fails its full load,
  and confirms the old file stays and the warning and the opening segment read well

## Decision Log

- 2026-11-27: Filed as a draft from bug `20261127-chosen-open-check-misses-full-load-failures`. The triage reproduced
  the image viewer's case and found two non-trivial decisions: which callers keep the old file, and how each viewer
  holds two loads. The user chose a proposal over fixing now or amending the bug.
- 2026-11-27: Drafting read UTERM-062 after that choice. It shows that a user's open will add a tab and never replace
  one. The first open decision asks whether this proposal is needed at all.
- 2026-11-27: Review start: 0 milestones, 0 settled decisions, 2 risks, no live-after lines or row gates; 4 open
  questions; no out-of-scope statements; autonomous review of the whole draft at commit "Draft UTERM-070 for a viewer
  that keeps its file when a load fails".
- 2026-11-27: Corrected facts found by the review's trace. The Motivation said the user chose an `async throws` swap
  "for every caller". The earlier bug's option said it "changes the protocol for every viewer". That record does not say
  whether a program's `send` was meant to wait on the swap. The UTERM-018 impact said routed opens call the
  source-replacing path. They make a new pane through the factory. The Motivation now records how a program learns of a
  failed load: `show` and `show-markdown` through `wait`, and `send` not at all.
- 2026-11-27: What a failed load does: the pane keeps the old file, loads the new one aside, and swaps at the load's
  commit point. `checkSource`, the data probe, and the extra current-swap check are removed. (autonomous)
- 2026-11-27: Whether this proposal is needed once UTERM-062 lands: yes, for the user's chosen opens through the
  interval. A program's replace keeps its documented behavior. Two amendments to UTERM-062 go to the user: a failed tab
  open shows its failure in its own tab, and its M1 keeps the aside load for viewers that have no tabs yet. The
  recommendation moved from also keeping a program's old content, once the review found that no contract asks for it
  and that a kept sent file is discarded before its replacement loads. (autonomous)
- 2026-11-27: Which callers keep the old file: the pane-local Open and a drop. `send`, `show`, and `show-markdown`
  replace at once, and `send` stays synchronous. (autonomous)
- 2026-11-27: How each viewer holds two loads: each loads aside with what it has and commits once the new file has
  loaded. Markdown over Markdown renders into a second view, a folder commits at its first image, and the data
  viewer's two leases are budgeted as one pane. (autonomous)
- 2026-11-27: Removed the risk "An asynchronous swap for program callers changes what `send` waits for". `send` stays
  synchronous, so nothing waits. Its mitigation, "the swap settles before `send` replies", would have held a reply on a
  command with an effect, against ADR-11. Added risks on UTERM-062 M1 and on the old file staying on screen during a
  slow load. Wrote M1 to M5. (autonomous)
- 2026-11-27: Coherence review. Removed UTERM-062 from Dependencies, since this proposal needs nothing from it and the
  dependency would schedule it after the milestones that make it moot. The Impacts entry now says its rows go ahead of
  UTERM-062 M2 to M5, which remove each viewer's aside load for the user's open, and that UTERM-062 M2's budget for
  each file replaces the paired leases. Added risks on two swap rules in one viewer, on the overlapping budgets, and on
  a failed `send`. Routed checks to M1 to M4 for viewers not yet converted, pane close, Reload during an aside load,
  the second Markdown view, superseded waits, and tests that can fail on today's code. (autonomous)
- 2026-11-27: Which callers keep the old file, reopened by the coherence review: `show` and `show-markdown` keep the old
  content too. The proposal's Summary names only a file the user chooses, so this entry tags it. Before, only the user's
  chosen opens did. The earlier rationale read each viewer's "shows its failure in the pane" doc as a program rule, and
  the protocol's copy of it was written by the check commit the day before. `show` is the program's form of Open in This
  Pane, and both handle replaces already meet ADR-11. "Whether this proposal is needed" was amended to match. It said "A
  program's replace keeps its documented behavior". (autonomous, addition)
- 2026-11-27: How each viewer holds two loads, the data viewer's commit reopened by the coherence review: the new table
  shows at its first rows and streams, the old session stays in memory, and a late error swaps back. Before, the new
  table showed only when its load ended. "What a failed load does" was amended to match. It said the viewer "swaps its
  description and its view only at the load's commit point". (autonomous)
- 2026-11-27: Coherence re-check. Added three amendments asked of UTERM-062: its viewer milestones remove the aside
  load for the user's open, its M3 and M4 keep the aside load for `show-markdown` and `show` inside a named tab, and its
  M2 budget replaces the paired leases. The two risk mitigations that cited them now say the user has not settled them.
  Fixed two sentences in "How each viewer holds two loads" that ignored the data viewer's early show. Routed checks to
  M2 to M4. The re-check argued from the script host's code that `send` should keep the old content too, with no reply
  change. "Which callers keep the old file" was already reopened once this review, so it stays as decided and the
  question goes to the review gate. (autonomous)
- 2026-11-27: Risk review. Every risk carries a likelihood, an impact, and a mitigation or an acceptance, and none is
  high in both. No decision is a one-way door: the saved description's format does not change, the helpers ship in the
  app bundle, and a redeploy reverts each milestone. The paired leases let the data viewer pass the shared budget that
  UTERM-009 states by the outgoing table until a commit, which UTERM-062's budget for each file supersedes later. That
  changes a shipped bound, so this entry tags it. (autonomous, addition)
- 2026-11-27: ADR candidate (cuts across the system): a replace that fails leaves what the pane shows and saves
  unchanged, for every viewer and every caller the rule names. Declined: the `SourceReplacing` contract and UTERM-015
  M3 already state it, and it does not hold for every caller while `send` replaces at once. Still declined on
  2026-11-27, after the gate: every caller now keeps the old file, and the `SourceReplacing` contract, which M4 rewrites
  to cover every replace, guards it.
- 2026-11-27: Closing re-check converged. Reworded the failed `show` reply as today's shape, placed the rows ahead of
  UTERM-062 M1, and routed program-replace regression tests to M2 and M3. (autonomous)
- 2026-11-27: Growth check. The proposal loop's three passes each added cases that serve one requirement, that a failed
  load keeps the old file. The full pass added the program replaces, the data viewer's early show with its swap-back
  and identity rule, and three UTERM-062 amendments. The re-check added the standby Markdown view and the rule that a
  superseded streaming table leaves the screen. The question per-viewer commit pass before them added the second
  Markdown view, the folder commit rule, the zero-row stop, and the paired leases. The review added no more cases for
  this requirement, and the growth question goes to the review gate. (autonomous)
- 2026-11-27: Review gate: the user kept the rule and its cases at the growth question. The user changed "Which callers
  keep the old file" for `send`, from "replace at once" to "keep the old content", with no change to `send`'s reply.
  The user chose to leave out a report of a sent file's load result. The user kept showing the data viewer's new table
  at its first rows, now its own settled decision, "When the data viewer's new table takes over". The `send` change
  opens "How the script host keeps a sent file the pane still shows". (addition)
- 2026-11-27: Revisited the user's `send` decision through the proposal. The UTERM-062 amendment for program replaces
  now covers `send` in all four viewers, and a sixth amendment asks UTERM-062 M1's sent files kept per tab to follow
  this proposal's rule. Every viewer milestone gained a `send` test, M1 gained the script host's rule for sent files,
  and M4's streaming `send` now supersedes the streaming table only. The `send` risk now records the user's acceptance.
  Before, the amendment covered only `show` and `show-markdown`, and M4 said a streaming `send` "supersedes both, and no
  swap-back follows". A re-check converged. (addition)
- 2026-11-27: How the script host keeps a sent file the pane still shows: the aside load's task carries the answer. A
  return frees the earlier sent file, and a throw or a cancel frees the new one. The user chose this at the review
  gate. M1's checks for sent files now name the task.
- 2026-11-27: The user declined freeing a sent file when the user's own open commits over it. The file stays until the
  script's next send to that pane or a relaunch, as today.
- 2026-11-27: The user picked all six amendments asked of UTERM-062 at the review gate, and they are applied there. A
  failed tab open shows its failure in its tab. M1 keeps a tabless viewer's file on a failed chosen open, and its sent
  files kept per tab follow this proposal's rule. M2 to M5 remove the aside load for the user's open and keep it for a
  program's replace into a named tab. M2's budget for each file replaces the paired leases.
- 2026-11-27: Accepted. No decision earns an ADR.

## References

- UTERM-015: the source-replacing contract
- UTERM-062: tabs in the viewers
- UTERM-063: every wire at version 0
- Bug `20261126-failed-pane-open-drops-the-old-source`, fixed in part
- Bug `20261127-chosen-open-check-misses-full-load-failures`
