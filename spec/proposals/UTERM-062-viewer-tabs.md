# UTERM-062: Tabs in the Viewers

**Status:** draft
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-006, UTERM-007, UTERM-008, UTERM-009: the image, text, map, and data viewers that gain tabs
- UTERM-013: applet-declared commands and keys, Close Tab or Pane, and Reopen Closed Tab or Pane
- UTERM-015: the pane-local Open, drops, and the source-replacing contract every viewer adopts
- UTERM-018: routed opens that land on an existing viewer pane. Until its M3 lands, a routed open makes a new pane, as
  UTERM-015 says, and only the pane-local Open, Cmd-T, and drops reach an existing pane
- UTERM-041: the uniform marker slot every tab carries

## Impacts

- UTERM-009 — "Large files": "One memory budget covers every data viewer pane together" becomes a budget for each file.
  UTERM-009 is implemented, so on acceptance it gains a "Superseded in part by UTERM-062" marker there. M1's check that a
  drop of several files is refused with a message also changes: several files open as several tabs.
- UTERM-018 — the Summary's "a viewer replaces its document" becomes "a viewer adds a tab". Its Reopen entry for a
  replaced document has nothing to cover, since an open no longer replaces anything.
- UTERM-015 — "How a file type maps to an applet" and the drop rules: a viewer pane takes several dropped files.
- UTERM-042 — its tab action menu reaches viewer tabs, since they become real tabs.
- UTERM-061 — the viewers' tab commands join the titles shared across applet types: New Tab, the tab selection
  commands, and Close Tab.

## Summary

The data, text, image, and map viewers each hold several files as tabs in one pane. They draw the shared tab bar the
terminal and the browser use, which stays hidden while a pane has one tab. Every open into a viewer pane adds a tab and
selects it: the pane's Open…, Cmd-T, a drop, and a routed open that lands on the pane. Nothing replaces the document a
tab shows. A tab, once loaded, stays loaded, as browser tabs do.

## Motivation

The user reviewed the data viewer on 2026-11-26. A pane shows one file, nothing in it names that file, and the only way
to compare two files is a second pane. The text, image, and map viewers have the same shape. Each publishes one tab and
draws no bar, and every way of opening a file replaces the one document.

The shared pieces already exist. The tab model, the tab bar, Close Tab or Pane, Reopen Closed Tab or Pane, the
palette's tab search, and script tab addressing all work on any applet that publishes tabs. The terminal and the
browser use them today.

## Design Decisions (Settled)

### All four viewers get tabs

Decision: the data, text, image, and map viewers each hold a list of tabs, one file per tab, and draw the shared tab
bar. The bar is hidden while the pane has one tab, as in the terminal and the browser. Closing a viewer's last tab
closes the pane, through the shared Close Tab or Pane rule.

Rationale: the user chose one proposal for all four viewers. They share one source contract and one problem.

### Every open adds a tab

Decision: every open into a viewer pane adds a tab and selects it.

- The pane-local Open… adds a tab.
- Cmd-T opens the file panel, and the chosen file opens in a new tab.
- A drop adds a tab for each dropped file. A drop of several files is no longer refused.
- A routed open that lands on the pane adds a tab, once UTERM-018 routes opens to existing panes.

Rationale: the user chose it on 2026-11-26 over keeping replacement for some paths. One rule for every path.

### Tab commands follow the terminal and the browser

Decision: each viewer declares New Tab on Cmd-T, Select Next and Previous Tab on Control-Tab and Control-Shift-Tab, and
Select Tab 1 to 9 on Cmd-1 to Cmd-9, as the terminal and the browser declare them. Close and reopen use uniterm's shared
Close Tab or Pane and Reopen Closed Tab or Pane.

Rationale: this follows the existing applets' pattern. Applet keys are declared through UTERM-013, per ADR-04.

### A loaded tab stays loaded

Decision: a tab keeps its document once it has loaded, whether or not it is selected. A restored tab loads the first
time it is selected, as a restored browser tab does. Nothing evicts a hidden tab.

Rationale: the user chose this on 2026-11-26. No applet unloads hidden tabs. Opening large files is expected to use a
lot of memory.

### The data viewer's memory budget applies to each file

Decision: the data viewer's memory budget bounds each file on its own, not every pane and tab together. Opening another
file never cuts an open file, or the new one, short. A single file past the budget still stops at its first rows, with
UTERM-009's notice. The image viewer's bitmap budget does not change, since it covers only the tiles a pane draws.

Rationale: the user chose this on 2026-11-26. UTERM-009's shared budget was there to keep uniterm safe from one huge
file. A shared pool also cuts later files short when several are open, and with tabs that happens routinely. Keeping
the data viewer in-process is a separate question from tabs: moving its rows into a helper would isolate crashes and
hostile files, not memory use.

## Design Decisions (Open)

### The saved layout's tab list

None of the four viewers' payloads has a tab array. Each needs one, plus a selected tab.

- A. Bump each viewer's payload version, and write a tab array and a selected index, as the terminal and the browser do.
  An older build keeps the newer payload's bytes, per ADR-06.
- B. Add the tab array as a new field, and write the lowest version that holds what the pane has, as the text viewer's
  payload does today. A one-tab pane then still saves in today's format, and an older build restores it.

### Opening a file a tab already shows

- A. Add another tab for it, as the browser does for a second visit to an address.
- B. Select the tab that already shows it.

### What a program addresses in a viewer pane

Script and controller commands name a pane and, optionally, a tab number. Only the browser reads the tab today. The
viewers' remote commands act on the pane's one document.

- A. A command with no tab acts on the selected tab, as in the browser, and a named tab is honored.
- B. A command with no tab is refused once the pane has several tabs.

Both must keep ADR-13's compatibility: a driver on today's wire version that sends a file to a viewer must not silently
get a different meaning. And per ADR-15, a program's open and the user's open must behave the same, so a version split
must fall on the wire version, not on who opens.

### What a program may reach in a viewer pane with tabs

Under ADR-14, a run's targets are the panes it opened and the pane it acts for. A viewer pane may hold tabs the user
opened beside tabs a program opened.

- A. A program reaches every tab in a pane it may control.
- B. A program reaches only the tabs it opened, as the browser's per-controller tab ownership does.

### A cap on tabs a program opens

ADR-14 P15 bounds every program effect. The browser caps the tabs scripts open in a pane at 10.

- A. The same cap of 10 for viewer tabs a program opens. The user's own opens are not capped.
- B. No cap for viewers.

### The map's unsaved edits across tabs

The map asks Save, Don't Save, or Cancel when a close would lose edits. The applet reports one unsaved-work label.

- A. Close Tab asks about that tab's edits. A pane, window, or app close lists every tab with edits.
- B. Each tab with edits asks in turn when a pane closes.

### A hidden tab's running work

The image viewer's slideshow runs in its pane. A detached pane already pauses perceptible work, per ADR-05.

- A. A hidden tab pauses as a detached pane does, and resumes when selected.
- B. A slideshow keeps running in a hidden tab.

### Tab identity

Tab IDs are not saved today. A restored tab gets a new ID, and scripts address tabs by number within a pane. ADR-02
covers pane-tree nodes only, not tabs. Its rationale weighs heaviest where a reference crosses a trust boundary, which
a program's tab number does.

- A. Keep today's model: in-memory IDs and per-pane tab numbers, as the terminal and the browser use.
- B. Give tabs stable IDs that are retired and never reused, and address them by ID across the program boundary. This
  changes every applet with tabs, not only the viewers.

## Risks

- **The payload change strands a newer layout on an older build** — likelihood: medium, impact: low.
  Mitigation: ADR-06 keeps an unreadable payload's bytes and restores the pane as a placeholder. "The saved layout's tab
  list" option B also keeps one-tab panes readable by older builds.
- **Many large data files use a lot of memory** — likelihood: high, impact: low.
  Accepted: the user expects opening large files to use memory. One file past the budget still stops at its first rows.
- **A map tab's edits are lost on close** — likelihood: low, impact: high.
  Mitigation: every close path runs the unsaved-work question for each tab with edits. M4 checks Close Tab, pane close,
  window close, and quit.
- **A program's opens flood a pane with tabs** — likelihood: low, impact: medium.
  Mitigation: "A cap on tabs a program opens".

## Milestones

### M1: Data viewer tabs

**Status:** NOT STARTED

- A data viewer pane holds several files as tabs, draws the shared tab bar, and hides it with one tab
- The pane-local Open…, Cmd-T, and a drop each add a tab and select it. A drop of several files adds one tab per file
- Control-Tab, Control-Shift-Tab, and Cmd-1 to Cmd-9 select tabs. Close Tab or Pane closes the selected tab, and the
  last tab's close closes the pane
- Reopen Closed Tab or Pane brings back a closed data tab with its sort and filter
- A hidden tab keeps its rows. A restored tab loads when first selected
- Each file has the whole memory budget. Opening a second file never shortens the first
- Relaunch restores every tab, the selected tab, and each tab's sort, filter, and sheet
- Loading several dropped files never blocks the main thread
- Each tab keeps its own find, filter, and popovers

### M2: Text viewer tabs

**Status:** NOT STARTED

- A text viewer pane holds several documents as tabs, with the same open, select, close, and reopen behavior as M1
- Each tab keeps its own scroll position, find, and contents sidebar state
- A failed render in one tab, such as a decoder helper exit, ends only that tab
- Relaunch restores every tab and the selected tab

### M3: Image viewer tabs

**Status:** NOT STARTED

- An image viewer pane holds several images or folders as tabs, with the same open, select, close, and reopen behavior
  as M1
- Each tab keeps its own zoom, position, and folder place
- A hidden tab's slideshow behaves as "A hidden tab's running work" settles
- A decode helper crash in one tab ends only that tab
- Relaunch restores every tab and the selected tab

### M4: Map viewer tabs

**Status:** NOT STARTED

- A map viewer pane holds several map files as tabs, with the same open, select, close, and reopen behavior as M1
- Each tab keeps its own region, style, file pins, and program layers
- Close Tab, a pane close, a window close, and quit each ask about every tab with unsaved edits, as "The map's unsaved
  edits across tabs" settles
- Relaunch restores every tab and the selected tab, and restoring runs no program, per ADR-03

### M5: Programs and viewer tabs

**Status:** NOT STARTED

- Script and controller commands address viewer tabs as "What a program addresses in a viewer pane" settles
- A driver on today's wire version keeps today's meaning, per ADR-13
- A program's open adds a tab exactly as the user's does, per ADR-15
- A program reaches the tabs "What a program may reach" allows, and opens no more than the settled cap
- Each open decision above is settled and built as decided

### M6: The user's check

**Status:** NOT STARTED

- The user opens, switches, closes, and reopens tabs in each of the four viewers in the running app, and confirms the
  tab bar reads well in light and dark

## Decision Log

- 2026-11-26: Drafted from the user's review of the data viewer. The user chose one proposal for all four viewers.
- 2026-11-26: The user chose that every open into a viewer pane adds a tab, over keeping replacement on some paths.
- 2026-11-26: The user chose that a loaded tab stays loaded, as in the browser, and that the data viewer's budget
  applies to each file instead of every pane together. Moving the data viewer's rows into a helper is left out of this
  proposal: it is about crash and hostile-file isolation, not tabs.
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
- ADR-13: outside wires stay compatible
- ADR-14: a controller controls what it opened
- ADR-15 (proposed): an action means one thing, whoever starts it
