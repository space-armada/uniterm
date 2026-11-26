# UTERM-062: Tabs in the Viewers

**Status:** draft
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-006, UTERM-007, UTERM-008, UTERM-009: the image, text, map, and data viewers that gain tabs
- UTERM-013: applet-declared commands and keys, Close Tab or Pane, and Reopen Closed Tab or Pane
- UTERM-015: the pane-local Open, drops, the source-replacing contract every viewer adopts, and the read scope that
  hides a user's files from programs
- UTERM-018: routed opens that land on an existing viewer pane. Until its M3 lands, a routed open makes a new pane, as
  UTERM-015 says, and only the pane-local Open, Cmd-T, and drops reach an existing pane

## Impacts

- UTERM-009 — "Large files": "One memory budget covers every data viewer pane together" becomes a budget for each file.
  UTERM-009 is implemented, so on acceptance it gains a "Superseded in part by UTERM-062" marker there. M1's check that a
  drop of several files is refused with a message also changes: several files open as several tabs.
- UTERM-018 — accepted, not started. Its Summary's "a viewer replaces its document" becomes "a viewer adds a tab" for
  the user's opens. Its batch rule gives each file of a Finder batch a capable pane the batch has not used, and splits
  new panes for the rest, because "walking each file alone would replace one viewer 20 times". Once opens add tabs, that
  rationale is gone, and a batch would give one tab and new panes where a drop of the same files gives tabs. Its M3
  checks pin the batch rule, the replaced-document Reopen entry, the map's "Discard and Open", and the refusal of a
  second replace while a question is up. These need amending before M3 is built, or 062 makes them dead code.
- UTERM-015 — "How a file type maps to an applet" and the drop rules: a viewer pane takes several dropped files. Its
  rule that a caller learns nothing about a user's file outside its read scope must hold per tab. See "Read scope
  applies to each tab".
- UTERM-040 — accepted, not started. It retires the map's command layers and moves program pins into the document under
  schema 2.0. Which tab a program's pin edit lands in is a question either way.
- UTERM-042 — its tab action menu reaches viewer tabs. Its "Panes with no tab bar" rationale says drivers attach only to
  the image and map viewers, "which have one tab each", so a driver's chip shows at the pane level. That no longer holds.
  Its single close for a set of tabs asks one question for the set, which bears on "The map's unsaved edits across
  tabs".
- UTERM-054, UTERM-055 — "For an applet with one tab or no per-tab owners, a pane among the program's targets counts as
  wholly its own", and a pane capture shows every title in the tab bar. A capture of a viewer pane with tabs would show
  the titles of files the user opened. The open bug `20261122-capture-bypasses-image-viewer-read-scope` is related.
- UTERM-006 — M5, exec driver reads, assumes one source per image pane.
- UTERM-061 — the viewers' tab commands join the titles shared across applet types.

## Summary

The data, text, image, and map viewers each hold several files as tabs in one pane. They draw the shared tab bar the
terminal and the browser use, which stays hidden while a pane has one tab. Every open the user makes into a viewer pane
adds a tab and selects it: the pane's Open…, Cmd-T, a drop, and a routed open that lands on the pane. A tab, once
loaded, stays loaded, as browser tabs do.

## Motivation

The user reviewed the data viewer on 2026-11-26. A pane holds one file, so keeping a second file open means a second
pane, and each extra file costs a split. The text, image, and map viewers have the same shape. Each publishes one tab
and draws no bar, and every way of opening a file replaces the one document. A drop of several files is refused in all
four.

Tabs let one pane switch between files. Comparing two files side by side still takes two panes.

The shared pieces already exist. The tab model, the tab bar, Close Tab or Pane, Reopen Closed Tab or Pane, the
palette's tab search, and script tab addressing all work on any applet that publishes tabs. The terminal and the
browser use them today.

## Design Decisions (Settled)

### All four viewers get tabs

Decision: the data, text, image, and map viewers each hold a list of tabs, one file per tab, and draw the shared tab
bar. The bar is hidden while the pane has one tab, as in the terminal and the browser. Closing a viewer's last tab
closes the pane, through the shared Close Tab or Pane rule.

Rationale: the user chose one proposal for all four viewers. They share one source contract and one problem.

### Every user open adds a tab

Decision: every open the user makes into a viewer pane adds a tab and selects it.

- The pane-local Open… adds a tab.
- Cmd-T opens the file panel, and the chosen file opens in a new tab.
- A drop adds a tab for each dropped file. A drop of several files is no longer refused.
- A routed open that lands on the pane adds a tab, once UTERM-018 routes opens to existing panes.

Rationale: the user chose it on 2026-11-26 over keeping replacement for some paths. What a program's open does is an
open question. See "What a program's open does".

### A loaded tab stays loaded

Decision: a tab keeps its document once it has loaded, whether or not it is selected. A restored tab loads the first
time it is selected, as a restored browser tab does. Nothing evicts a hidden tab. What "loaded" holds for an image tab
is open. See "What a hidden image tab keeps".

Rationale: the user chose this on 2026-11-26. No applet unloads hidden tabs. The user expects opening large files to use
a lot of memory.

### The data viewer's memory budget applies to each file

Decision: the data viewer's memory budget bounds each file on its own, not every pane and tab together. A single file
past the budget still stops at its first rows, with UTERM-009's notice. The memory-pressure warning still stops every
load running at that moment, in every tab.

Rationale: the user chose this on 2026-11-26. UTERM-009's shared budget was there so that "a huge file cannot get
uniterm killed along with its terminals". A shared pool also cuts later files short when several are open, and with
tabs that happens routinely. The user accepts the memory that many open files take. Whether an app-wide ceiling should
stay as well is open. See "An app-wide ceiling for data files".

### Read scope applies to each tab

Decision: wherever a program can learn about a viewer pane, read scope is checked per tab, not once per pane. That covers
a tab's title in the pane listing, the pane's directory, a tab's content, a pending wait, and a capture. A tab whose
file is outside the caller's scope is listed with no title, as a pane is today.

Rationale: UTERM-015 settles that a caller learns nothing about a user's file outside its read scope. Today the check
reads one path per pane, through the user-file source, and applies the answer to every tab's title. With several tabs,
a program scoped to one folder would read the names of files the user opened from another. This restores UTERM-015's
rule. It lands with the first milestone that publishes several tabs.

## Design Decisions (Open)

### Tab keys that collide with viewer keys

The terminal and the browser put Select Tab 1 to 9 on Cmd-1 to Cmd-9. The map holds Cmd-1, Cmd-2, and Cmd-3 for its
Standard, Satellite, and Hybrid styles. The image viewer holds Cmd-9 for Zoom to Fit. When two commands of one applet
share a key, both lose it and a warning posts. New Tab on Cmd-T and Control-Tab for next and previous collide with
nothing in the viewers.

- A. Viewers take Cmd-1 to Cmd-9 for tabs, as the terminal and browser do, and the map styles and Zoom to Fit move to
  other keys.
- B. Viewers skip the numbered tab keys that collide. The map selects tabs 4 to 9 by number, and the image viewer tabs
  1 to 8.
- C. Viewers have no numbered tab keys, and select tabs with Control-Tab, the tab bar, and the palette.

### What a hidden image tab keeps

The image viewer's bitmap budget is one lease per pane, with one 256 MiB floor. It covers the backdrop and animation
frames as well as tiles, and it drops its cache first under pressure. The decode helper is one process per pane, and it
keeps a bounded set of sources.

- A. Hidden image tabs keep their bitmaps, in the pane's one lease. A full lease drops a hidden tab's cache first, so a
  hidden tab redraws from the helper when selected.
- B. Each tab gets its own lease and floor, so a hidden tab keeps everything.
- C. A hidden image tab keeps its place and zoom, and releases its bitmaps. Its first frame on selection comes from the
  helper.

The text and map viewers must also say whether each tab keeps its own web view or map view. That is an implementation
choice under "A loaded tab stays loaded".

### An app-wide ceiling for data files

With a budget per file of the smaller of 1 GiB and a quarter of physical memory, and no app bound, a drop of 20 large CSV
files can hold about 20 GiB in uniterm's process, beside every terminal. ADR-07 asks a design that lets one part
end the app to say what bounds that exposure. Whether macOS ends the app at that point has not been traced. ADR-07
also names memory exhaustion as a failure a separate process contains, and the image helper is killed past its 1 GiB
footprint.

- A. A budget per file and no app ceiling. The memory-pressure stop is the only app-wide guard.
- B. A budget per file plus an app-wide ceiling sized against physical memory, so later files are cut only near real
  exhaustion.
- C. A budget per file, and tabs a drop adds load on first selection, so a drop of many files loads one at a time.
- D. Move the data viewer's rows into a helper, so the app's memory no longer grows with data files. This reopens the
  scope the user left out.

### What a program's open does

Some program commands replace a viewer's document today: the text viewer's `show-markdown`, the image viewer's
`show`, and ScriptWire's `send`. ADR-15 asks that a program's operation behave as the user's. ADR-13 asks that a caller
on today's version keeps today's meaning. A live-preview driver that calls `show-markdown` on every keystroke would make
a tab per call if it added tabs.

- A. On new schema versions, a program's open adds a tab, as the user's does. Today's versions keep replacing the
  selected tab.
- B. A program's open replaces the tab that program opened in the pane, and adds one when it has none there.
- C. A program's open always adds a tab, on every version. This breaks ADR-13 for today's callers.

### What a program addresses in a viewer pane

Script and controller commands name a pane and, optionally, a tab number. Only the browser reads the tab today. The
viewers' remote commands act on the pane's one document. ScriptWire's `send` returns nothing, so a program cannot learn
which tab its send made. The exec wire's commands and events, such as `shown` and `pin-selected`, carry no tab.

- A. A command with no tab acts on the selected tab, as in the browser, and a named tab is honored. A user's tab switch
  between two of a program's commands sends the second to the user's tab.
- B. A command with no tab is refused once the pane has several tabs.
- C. A command with no tab acts on the tab this caller last opened in the pane, or else on the selected tab.

The version split falls on each channel's own version: each viewer's command schema under ADR-13 P4, ScriptWire for
`send`, and the exec wire for driver commands and events. Adding a tab field to any of them is a new minor version.

### What a program may reach in a viewer pane with tabs

Under ADR-14, a run's targets are the panes it opened and the pane it acts for. A viewer pane may hold tabs the user
opened beside tabs a program opened.

- A. A program reaches every tab in a pane it may control.
- B. A program reaches only the tabs it opened, as the browser's per-controller tab ownership does. UTERM-039 keeps that
  ownership. This brings in per-tab caller ownership in four viewers.
- C. A program reaches every tab of a pane it may control, with read scope gating each tab's title, directory, content,
  and capture. Viewers already gate content by read scope, where the browser gates by ownership.

### A cap on tabs a program opens

ADR-14 P15 bounds every program effect. The browser's limit of 10 is for tabs a page's scripts open. Its cap of 16
controller tabs per grant was dropped by UTERM-039, on the user's ruling of 2026-11-21 that a cap is a behavior
difference ADR-15 rules out.

- A. Cap the viewer tabs a program opens. This reopens the user's 2026-11-21 ruling.
- B. No cap for viewers, as UTERM-039 has for the browser.

### A new pane's empty tab

A tab list is never empty. A new viewer pane shows one tab that offers Open and a drop. Read literally, "every user open
adds a tab" leaves that empty tab beside the first file, so a drop of three files on a new pane gives four tabs.

- A. The empty tab stays, and the user closes it.
- B. The first open into a pane whose only tab is empty fills that tab. This is a special case of "every user open adds
  a tab".

### What Cmd-T means to a program

A script's tab open dispatches on the shared tab-opening contract and expects a tab ID back at once. A viewer's Cmd-T
shows a file panel, which cannot answer at once.

- A. Viewers adopt the tab-opening contract, and a program's tab open makes an empty tab.
- B. Viewers do not adopt it. A program's tab open is refused with a message that says the viewer opens tabs from
  files, in place of today's "the pane's applet has no tabs to open".

### The map's unsaved edits across tabs

The map asks Save, Don't Save, or Cancel when a close would lose edits. An applet reports one unsaved-work label, and the
host reads it in three places. Either option changes that shared contract. Several untitled tabs with edits mean
several Save As panels in a row.

- A. Close Tab asks about that tab's edits. A pane, window, or app close lists every tab with edits in one question.
- B. Each tab with edits asks in turn when a pane closes.

### A hidden tab's running work

The image viewer's slideshow, animated images, and prefetch run in its pane. A detached pane already pauses perceptible
work and holds back alerts, per ADR-05.

- A. A hidden tab pauses as a detached pane does, holds back its alerts, and resumes when selected.
- B. A slideshow keeps running in a hidden tab. It shares the pane's one helper, which serves one request at a time, so
  it slows the selected tab.

### The saved layout's tab list

None of the four viewers' payloads has a tab array. Each needs one, plus a selected tab.

- A. Bump each viewer's payload version, and write a tab array and a selected index, as the terminal and the browser do.
  An older build keeps the newer payload's bytes, per ADR-06.
- B. Add the tab array as a new field, and write the lowest version that holds what the pane has, as the text viewer's
  payload does today. A one-tab pane then still saves in today's format, and an older build restores it.

### Opening a file a tab already shows

- A. Add another tab for it, as the browser does for a second visit to an address.
- B. Select the tab that already shows it.

### Tab identity

Tab IDs are not saved, and a restored tab gets a new ID. Script tab numbers are window-wide and never reused within a
launch, and a stale number resolves to "the tab is not open in that pane". ADR-02 covers pane-tree nodes only.

- A. Keep today's model, as the terminal and the browser use.
- B. Give tabs stable IDs that are saved and never reused, and address them by ID across the program boundary. No
  current failure mode is named that this prevents, and it changes every applet with tabs.

## Risks

- **A program learns the names of files outside its read scope** — likelihood: high, impact: high.
  Without per-tab checks, the pane listing, the pane's directory, and captures leak tab titles from the moment a pane
  holds several tabs.
  Mitigation: "Read scope applies to each tab" is settled, and M1 builds it before any viewer publishes several tabs.
- **Program commands meet several tabs before their rules exist** — likelihood: medium, impact: medium.
  Mitigation: M1 settles and builds the program-facing rules before any viewer milestone ships tabs.
- **Many large data files fill uniterm's memory** — likelihood: medium, impact: high.
  The memory-pressure stop ends running loads but frees nothing already loaded.
  Mitigation: "An app-wide ceiling for data files" decides the bound before acceptance, or the risk is accepted there.
- **UTERM-018 M3 is built on the replace model first** — likelihood: medium, impact: medium.
  Mitigation: amend UTERM-018's batch rule and M3 checks when this proposal is accepted, before M3 is scheduled.
- **The payload change strands a newer layout on an older build** — likelihood: medium, impact: low.
  Mitigation: ADR-06 keeps an unreadable payload's bytes and restores the pane as a placeholder. "The saved layout's tab
  list" option B also keeps one-tab panes readable by older builds.
- **A map tab's edits are lost on close** — likelihood: low, impact: high.
  Mitigation: every close path asks about each tab with edits. M5 checks Close Tab, pane close, window close, and quit.

## Milestones

### M1: Shared tab groundwork and the program boundary

**Status:** NOT STARTED

- Read scope is checked per tab for titles, the pane's directory, content, pending waits, and captures. A program
  scoped to one folder never reads the title of a tab whose file is elsewhere
- The source-swap path takes each open as its own tab: N rapid opens, or N dropped files, add N tabs in order, and
  none supersedes another
- Each tab keeps its own notices. A hidden tab's load notice names its file, and a new tab's load never drops another
  tab's notices
- Program commands, events, and opens on a viewer pane follow "What a program addresses", "What a program's open
  does", and "What a program may reach" as settled, on new versions of each channel
- A caller on today's versions keeps today's meaning, per ADR-13
- Each open decision above is settled

### M2: Data viewer tabs

**Status:** NOT STARTED

- A data viewer pane holds several files as tabs, draws the shared tab bar, and hides it with one tab
- The pane-local Open…, Cmd-T, and a drop each add a tab and select it. A drop of several files adds one tab per file,
  and selects the tab "A new pane's empty tab" and the drop rule settle
- Next, previous, and numbered tab selection work as "Tab keys that collide" settles. Close Tab or Pane closes the
  selected tab, and the last tab's close closes the pane
- Reopen Closed Tab or Pane brings back a closed data tab with its sort and filter
- A hidden tab keeps its rows. A restored tab loads when first selected
- A restored tab that was never selected saves its path, bookmark, sort, filter, and sheet unchanged
- Each file has its own budget, with the app-wide bound "An app-wide ceiling" settles. A memory-pressure warning still
  stops every running load in every tab
- Loading several dropped files never blocks the main thread
- Each tab keeps its own find, filter, and popovers
- Relaunch restores every tab and the selected tab

### M3: Text viewer tabs

**Status:** NOT STARTED

- A text viewer pane holds several documents as tabs, with the same open, select, close, and reopen behavior as M2
- Each tab keeps its own scroll position, find, and contents sidebar state
- A decoder helper exit shows a failure in the tab it was serving. The other tabs decode again on their next request
- Relaunch restores every tab and the selected tab

### M4: Image viewer tabs

**Status:** NOT STARTED

- An image viewer pane holds several images or folders as tabs, with the same open, select, close, and reopen behavior
  as M2
- Each tab keeps its own zoom, position, and folder place
- A hidden tab keeps what "What a hidden image tab keeps" settles, and its running work behaves as "A hidden tab's
  running work" settles
- A decode helper crash shows a failure in the selected tab. The other tabs decode again on their next request
- Relaunch restores every tab and the selected tab

### M5: Map viewer tabs

**Status:** NOT STARTED

- A map viewer pane holds several map files as tabs, with the same open, select, close, and reopen behavior as M2
- Each tab keeps its own region, style, and pins, including what UTERM-040 leaves of program pins
- Close Tab, a pane close, a window close, and quit each ask about every tab with unsaved edits, as "The map's unsaved
  edits across tabs" settles
- A map tab closed with Don't Save and reopened behaves as a closed pane's undo does today
- Relaunch restores every tab and the selected tab, and restoring runs no program, per ADR-03

### M6: The user's check

**Status:** NOT STARTED

- The user opens, switches, closes, and reopens tabs in each of the four viewers in the running app, and confirms the
  tab bar reads well in light and dark

## Decision Log

- 2026-11-26: Drafted from the user's review of the data viewer. The user chose one proposal for all four viewers.
- 2026-11-26: The user chose that every open into a viewer pane adds a tab, over keeping replacement on some paths.
- 2026-11-26: The user chose that a loaded tab stays loaded, as in the browser, and that the data viewer's budget
  applies to each file instead of every pane together. Moving the data viewer's rows into a helper is left out of this
  proposal.
- 2026-11-26: First critique pass. The key bindings, which collide with the map's style keys and the image viewer's Zoom
  to Fit, moved to an open question. Added the settled rule that read scope applies to each tab, which restores
  UTERM-015's rule. The program-facing rules moved into M1, ahead of every viewer. Corrected the budget rationale's
  wording and the facts on the browser's caps and on tab numbers. Added open questions on the image viewer's hidden
  tabs, an app-wide ceiling, a program's open, a new pane's empty tab, and Cmd-T for programs. Added impacts on
  UTERM-018's batch rule and M3, UTERM-040, UTERM-042, UTERM-054, and UTERM-055. Dropped UTERM-041 from Dependencies,
  since no milestone needs it.
- 2026-11-26: ADR candidate: stable tab identity across the program boundary. `adr-impact` found that no ADR covers tab
  identity for any applet. Outcome: undecided, held by "Tab identity".
- 2026-11-26: ADR candidate: whether an open into an occupied pane adds or replaces, across applets. Outcome: undecided.
  UTERM-018 may be the better home.

## References

- ADR-02: panes are addressed by stable ID
- ADR-03: restore never runs a program
- ADR-04: applet keys
- ADR-05: close guards and detached panes
- ADR-06: each applet versions its own payload
- ADR-07: failure isolation
- ADR-13: outside wires stay compatible
- ADR-14: a controller controls what it opened
- ADR-15 (proposed): an action means one thing, whoever starts it
