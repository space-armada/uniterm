# UTERM-062: Tabs in the Viewers

**Status:** accepted
**Created:** 2026-11-26
**Updated:** 2026-11-27

## Dependencies

- UTERM-006, UTERM-007, UTERM-008, UTERM-009: the image, text, map, and data viewers that gain tabs
- UTERM-013: applet-declared commands and keys, Close Tab or Pane, and Reopen Closed Tab or Pane
- UTERM-015: the pane-local Open, drops, the source-replacing contract every viewer adopts, and the read scope that
  hides a user's files from programs
- UTERM-063: every wire at version 0, so the viewers' commands change meaning in place
- UTERM-064: every program command names its target, and how a program finds a tab to name
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
  second replace while a question is up. These need amending before M3 is built, or 062 makes them dead code. Its M3
  also gains the rate bound on routed opens that add a tab, keyed on the source pane for `uniterm open` and on the
  sending app for a Launch Services sender. Its M5's program file opens gain the same bound, keyed on the run.
- UTERM-015 — "How a file type maps to an applet" and the drop rules: a viewer pane takes several dropped files. Its
  rule that a caller learns nothing about a user's file outside its read scope must hold per tab. See "Read scope
  applies to each tab".
- UTERM-040 — accepted, not started. It retires the map's command layers and moves program pins into the document under
  the document, in place at the map's schema 0.0. Which tab a program's pin edit lands in is a question either way.
  Amended 2026-11-27; see Decision Log.
- UTERM-042 — its tab action menu reaches viewer tabs. Its "Panes with no tab bar" rationale says drivers attach only to
  the image and map viewers, "which have one tab each", so a driver's chip shows at the pane level. That no longer holds.
  Its single close for a set of tabs asks one Close-or-Cancel question for the set. When the set holds a map tab with
  edits, that question must offer Save, Don't Save, and Cancel, per "The map's unsaved edits across tabs".
- UTERM-054, UTERM-055 — "For an applet with one tab or no per-tab owners, a pane among the program's targets counts as
  wholly its own", and a pane capture shows every title in the tab bar. Viewers now keep per-tab owners in group panes,
  so that rule needs amending: a driver's own pane counts as wholly its own, and a group pane's tab scope is the tabs
  the program owns. Its open question "What a program's capture shows of a file the program may not read" decides
  whether a capture shows the titles of tabs outside the program's scope. The open bug `20261122-capture-bypasses-image-viewer-read-scope`
  is related.
- UTERM-041 — accepted, not started. It exempts a driver's pane from the per-tab authority marker because "Only the
  image and map viewers accept a driver ... and each has one tab", and says the exclusion "needs another look" if a
  multi-tab applet accepts a driver. It also puts the marker on a viewer's one tab. Both premises end here. Under "What
  a program may reach", a driver reaches every tab of its own pane, so its exemption can stand at the pane level, while
  group panes mark the tabs a program owns.
- UTERM-028, UTERM-056 — UTERM-063 holds every external wire at version 0, so this proposal changes those wires in
  place and waits on neither. UTERM-028 lands in place too, and UTERM-056 is deferred until ScriptWire's
  declaration.
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

Rationale: the user chose it on 2026-11-26 over keeping replacement for some paths. What a program's open does is
settled separately. See "What a program's open does".

### A loaded tab stays loaded

Decision: a tab keeps its document once it has loaded, whether or not it is selected. A restored tab loads the first
time it is selected, as a restored browser tab does. Nothing evicts a hidden tab, with one exception for image
backdrops. See "What a hidden image tab keeps".

Rationale: the user chose this on 2026-11-26. No applet unloads hidden tabs. The user expects opening large files to use
a lot of memory.

### The data viewer's memory budget applies to each file

Decision: the data viewer's memory budget bounds each file on its own, not every pane and tab together. A single file
past the budget still stops at its first rows, with UTERM-009's notice. The memory-pressure warning still stops every
load running at that moment, in every tab.

Rationale: the user chose this on 2026-11-26. UTERM-009's shared budget was there so that "a huge file cannot get
uniterm killed along with its terminals". A shared pool also cuts later files short when several are open, and with
tabs that happens routinely. The user accepts the memory that many open files take. The app-wide guard is settled in
"An app-wide ceiling for data files".

### Read scope applies to each tab

Decision: wherever a program can learn about a viewer pane through events and replies, read scope is checked per tab,
not once per pane. That covers a tab's title in the pane listing, the pane's directory, a tab's content, and a pending
wait. A tab whose file is outside the caller's scope is listed with no title, as a pane is today. The pane-level title
and directory follow the selected tab's check.

Captures are not part of this decision. What a program's capture shows of a file it may not read is UTERM-054's open
question, and this proposal follows its answer for each tab.

Rationale: UTERM-015 settles that events and replies carry no path or content from a source outside the caller's read
scope. Today the check reads one path per pane, through the user-file source, and applies the answer to every tab's
title. With several tabs, a program scoped to one folder would read the names of files the user opened from another.
This restores UTERM-015's rule. It lands with the first milestone that publishes several tabs.

### What a program may reach in a viewer pane with tabs

Original question: a viewer pane may hold tabs the user opened beside tabs a program opened. Should a program reach
every tab in a pane it may control, or only the tabs it opened?

Decision: reach follows how the program came to the pane. (autonomous, addition)

- A driver attaches to a pane, not a tab, so under ADR-14 P2 its source is the whole pane. It reaches every tab of its
  own pane, as it reaches the pane's document today. Its own pane never checks tab owners, so its commands still run
  after Disconnect and after Revoke, as Revoke promises today.
- In a pane a program reaches as a member of its group, each tab has one owner: the run that opened it, or the user.
  The first tab of a pane a program opens is the program's from the moment the pane is created, whether it starts
  enabled or disconnected.
- Give Group, and UTERM-033's reclaim once it is built, give the new owner every tab the pane holds at that moment.
  Enable and Run hand over nothing.
- Owners survive a new control generation. The generation still voids queued work, so ADR-14 P11 holds. Owners clear
  when their grant ends.
- Tabs the user adds to a group pane stay the user's.

Rationale: a first draft of this decision recorded owners through the existing caller-owning contract, which clears
every owner on any control change. Enable, Disconnect, Revoke, and a driver's attach all change the generation. That
would refuse a deployed driver in its own pane after Disconnect or Revoke, refuse a script whose group pane was
disconnected and enabled again, and refuse a controller once the user ran a driver on its pane. All of those work
today, and the user uses Disconnect and Enable as a pause, so they must keep working. Making every widening a hand-over would sweep a tab the user dropped in to the program
at the next Enable. Reaching every tab would let a group's controller edit a map the user dropped into its pane: under
UTERM-040 a `remove`, or a `clear` with a prefix, which the user can undo. This rule keeps every caller that reaches a
viewer today, and keeps a user's later tab out of a group's reach, as UTERM-054 does for the terminal on Enable.

Leaves undone: Give Group hands over a viewer pane's tabs, while UTERM-054 gives a terminal or browser pane's existing
tabs to no one, and the terminal and the browser still clear their owners on any change of control. Aligning them is a
separate addition. A program that makes an empty group pane, where the user drops a file before the program shows anything, is
refused in that pane, where today it acts on the dropped file. It brings in per-tab owners in four viewers, an
owner-clearing rule beside the caller-owning contract, and an amendment to UTERM-054's capture wording so that a
driver's own pane counts as wholly its own.

### Tab identity

Original question: tab IDs are not saved, and a restored tab gets a new ID. Should tabs keep today's model, or get
stable IDs that are saved and never reused?

Decision: keep today's model, as the terminal and the browser use. (autonomous)

Rationale: script tab numbers are window-wide and never reused within a launch, and a stale number resolves to "the tab
is not open in that pane". No program holds a tab reference across a launch, since restore runs nothing under ADR-03
and no live binding is saved under ADR-14 P11 and P12. Saved IDs would change every tabbed applet's payload and two
outside wires with no caller to serve. Converged in 1 pass.

### An app-wide ceiling for data files

Original question: with a budget per file and no app bound, a drop of 20 large files can hold about 20 GiB in uniterm's
process. ADR-07 asks a design to say what bounds that exposure. Should an app-wide ceiling stay?

Decision: the memory-pressure guard becomes a state, not an event. The data viewer tracks the system's pressure level,
normal included. While the level is warning or critical, it refuses reservations past each lease's floor and stops
running loads. A lease's floor is still granted, so a small file still opens. Filters reserve nothing and still run. A
sort whose key memory would pass its lease's floor is refused while the level holds, with a notice that names memory
pressure, not the row count, and it runs once the level returns to normal. A load stopped this way resumes on its own
once the level returns to normal, and says so while it waits. No sized ceiling is added. (autonomous, addition)

The first check of M2 measures, by dropping 20 large files, whether the system delivers the return to normal, how long
a warning lasts on a busy machine, and whether the warning arrives before swapping slows the terminals. If the warning
arrives late, an app-wide ceiling sized against physical memory joins the guard as a backstop. If the return to normal
never comes, or resumed loads bring the warning straight back, the guard falls back to today's rule, which ends only the
loads running at a warning. The result is recorded in M2's As built block.

Rationale: today a warning ends only the loads running at that moment, and a file opened while pressure persists loads
its full budget. So "the pressure stop is the only guard" names a weaker guard than it sounds. On traced facts, macOS
compresses and swaps memory rather than ending an app for its footprint, so the harm to guard against is a machine
slowed by swapping, terminals included. The system's own pressure signal tracks that harm across every process. A
fixed ceiling cannot see other apps' memory, so it cuts too early on a large Mac and too late on a busy one. Loading on
first selection bounds only how many files load at once. A helper would reopen the scope the user left out.

### Tab keys that collide with viewer keys

Original question: the terminal and the browser put Select Tab 1 to 9 on Cmd-1 to Cmd-9. The map holds Cmd-1 to Cmd-3
for its styles, and the image viewer holds Cmd-9 for Zoom to Fit. Which keys do the viewers' tab commands take?

Decision: every viewer declares all nine Select Tab commands. Only a colliding key is left off: the map's Select Tab 1
to 3, and the image viewer's Select Last Tab, exist in the menu and the palette with no key. The text and data viewers
take Cmd-1 to Cmd-9 in full. No collision warning posts. (autonomous)

Rationale: every key then behaves as it does today, or as the other tabbed applets' keys do, and every tab command
stays reachable. Preview also puts Zoom to Fit on Cmd-9, so moving the viewers' keys would break that convention and
the keys users of UTERM-006 and UTERM-008 have learned. Dropping numbered keys everywhere would take working keys from
the text and data viewers with nothing to justify it. A user's App Shortcuts remap still wins.

### What a program's open does

Original question: some program commands replace a viewer's document today: the text viewer's `show-markdown`, the
image viewer's `show`, and ScriptWire's `send`. Programs also open files through approved Launch Services senders and
`uniterm open`. Once the user's open adds a tab, what does a program's open do?

Decision: `show`, `show-markdown`, and `send` replace the content of the tab they name, and never the selected tab. A
new `open` command on the text, image, and map viewers adds a tab and selects it, as the user's open does. Each of
these answers with the identity of the tab it opened or filled, under ADR-16. Routed opens from `uniterm open` and
Launch Services senders keep making a new pane, as UTERM-015 says, until UTERM-018 routes them to an existing pane.
Then they add a tab under "Every user open adds a tab". (autonomous, addition)

Rationale: a live preview that calls `show-markdown` on every keystroke keeps one tab, since it replaces the tab it
names. Adding a tab per call would flood the pane. Once tabs exist, the user has no replace inside a tab, so a program's
replace has no user act to differ from, and the new `open` command matches the user's add under ADR-15. A routed open
makes a new pane today, so a tool that opens a file on every save already floods panes. A tab is milder. Every
external wire is at version 0 under UTERM-063, so these commands change meaning in place. See "Callers that cannot name a tab".
Leaves undone: the data viewer has no command schema, so no program command adds a data tab. A program fills one with
`send` into a tab it names. It brings in an `open` command in three viewer schemas.

### What a program addresses in a viewer pane

Original question: script and controller commands name a pane and, optionally, a tab number. Only the browser reads the
tab today. What does a command with no tab act on once a viewer pane holds several tabs?

Decision: a program's command names the tab it acts on. uniterm never picks the target from the user's selection or
focus, and a command naming a tab outside the caller's tab scope is refused. The user chose this at the review gate, to
remove ambiguity. UTERM-064 holds the rule for every applet. Every caller names a tab, per "Callers that cannot name a
tab", and finds one to name per "Finding a tab to name".

Rationale: a command that names its target means one thing, whatever the user does meanwhile. Acting on the selected
tab would send a driver's `zoom` into a tab the user just switched to. Acting on the caller's last tab is hidden state
kept for each caller, which the project's instructions ask to avoid. ADR-16 records the principle.

### Callers that cannot name a tab

Original question: a driver or native controller built against today's versions cannot name a tab. Should it keep
acting on its own tab, as ADR-13 would require, or must every caller name a tab?

Decision: every caller names a tab, now. UTERM-063 resets every wire to version 0, which carries no compatibility
promise, so a program built against an earlier build is rebuilt against the current one. The user chose this at the
review gate.

Rationale: keeping a second rule for old callers would keep the hidden caller's-tab state this proposal removes, and
the version splits it needs.

### Finding a tab to name

Original question: a program needs a tab's identity before it can name it. How does a program that lost track, or
wants its own tab, find one?

Decision: settled for every applet in UTERM-064: commands take only an identity, a caller's own-tab alias and a find
query return identities, the pane listing shows each tab's owner, "not open" and "not yours" share one error, and
aliases follow one documented naming convention. This proposal's viewers follow it. The user chose this at the review
gate.

### The saved layout's tab list

Original question: none of the four viewers' payloads has a tab array. Bump each viewer's payload version, or write the
lowest version that holds what the pane has?

Decision: add the tab array as a new field, and write the lowest version that holds what the pane has, as the text
viewer's payload does. A one-tab pane still saves in today's format. A payload at the newer version holds the tab array
alone, with no flat fields beside it. (autonomous)

Rationale: both are lossless under ADR-06, and only this one keeps one-tab panes live when the user goes back to an older
build. Under a bump, every viewer pane becomes a placeholder there. The text viewer and UTERM-040 already follow this
rule. A newer build reads version 1 as one tab. An older build keeps a multi-tab pane's bytes and writes them back
unchanged. No deploy order is needed. Converged in 1 pass.

### A new pane's empty tab

Original question: a tab list is never empty, and a new viewer pane shows one tab that offers Open and a drop. Read
literally, every user open adds a tab beside it. Should that empty tab stay, or be filled? And which tab does a drop of
several files select?

Decision: a pane that holds no file shows one placeholder tab, and the placeholder exists only while the pane holds no
file. The first open removes it and adds the file's tab, with a new tab ID owned by whoever opened it. A map placeholder
that holds pins is a document, not a placeholder, and is never filled or removed this way. A drop of several files
selects the last dropped file's tab. (autonomous)

Rationale: every viewer's routed and launcher pane is built empty and then opened into, so a literal "adds a tab" would
give every new viewer pane a tab bar with an empty tab, not only a drop on a new pane. One rule covers the factories,
drops, Open…, and program opens. Filling the placeholder in place would keep its ID and its owner, so a user's file
dropped on a program-made pane would become the program's tab. A new ID owned by the opener keeps "What a program may
reach" whole. Selecting the last dropped file's tab is what "adds a tab and selects it" does applied once per file.
Converged in 1 pass.

### What Cmd-T means to a program

Original question: a script's tab open dispatches on the shared tab-opening contract and expects a tab back at once. A
viewer's Cmd-T shows a file panel, which cannot answer at once. Should viewers adopt the contract, or refuse?

Decision: viewers do not adopt the tab-opening contract. A program's tab open on a viewer pane is refused with a message
that says the viewer opens tabs from files. On the text, image, and map viewers it names the `open` command. On the data
viewer, which has no command schema, it says a program can replace its tab with `send`. The refusal comes from its own
hook, not from a stub of the tab-opening contract, and the host never switches on applet type to find it. (autonomous)

Rationale: nothing changes for existing callers, and the message points to the real path. Adopting the contract would
make an empty tab no user can make, which ADR-15 asks a program-only capability to avoid, and it would duplicate the
`open` command. Raising a file panel for a program would bring in a program-raised modal and a handle reply no caller
needs. Converged in 1 pass.

### The map's unsaved edits across tabs

Original question: the map asks Save, Don't Save, or Cancel when a close would lose edits, and an applet reports one
unsaved-work label. How does a close ask about several map tabs with edits?

Decision: an applet reports unsaved work per tab, as it already reports running work per tab. Each close act asks one
question that lists every tab with edits it would close: Close Tab, a pane close, a window close, quit, and UTERM-042's
set closes, such as Close Other Tabs. Save then saves each listed tab in turn. A Cancel partway through Save leaves the
earlier tabs saved and the close cancelled, as a window close does today. (autonomous)

Rationale: window close and quit already ask one question that lists every pane, and the running-work report is
already per tab. UTERM-042 settled one question for a set of tabs, since asking once per tab needs a sequence and a rule
for a refusal halfway. Asking each tab in turn would contradict both. Converged in 1 pass.

### Opening a file a tab already shows

Original question: when the user or a program opens a file that a tab in the pane already shows, should it add another
tab, or select the existing one?

Decision: it adds another tab, as the browser does for a second visit to an address. (autonomous)

Rationale: this is the plain behavior, with no rule for the case. Reopening still refreshes a data file, which has no
watcher and no Reload today. Selecting the existing tab would hand a program's `open` a user-owned tab as its caller's
tab, so its later commands would land in the user's tab, and it would leave a changed data file stale. Two tabs editing
one map file are caught at save by the map's existing conflict check. Converged in 1 pass.

### What a hidden image tab keeps

Original question: the image viewer's bitmap budget is one lease per pane, with one floor. Should hidden image tabs keep
their bitmaps in the pane's lease, get a lease each, or release their bitmaps?

Decision: a hidden image tab keeps what the image viewer's off-screen code keeps today: its fit backdrop and the frame on
screen. It releases its tiles, zoomed frames, the helper's level, and its cached neighbors, through that same code. All
of a pane's tabs share its one lease. When a reservation for on-screen content would fail, hidden tabs' backdrops give
way first, least recently selected first, in any pane's lease. On-screen content is never refused while a hidden tab
anywhere holds a backdrop. (autonomous) Amended 2026-11-27; see Decision Log.

Rationale: the viewer's off-screen code already keeps only the backdrop, so a hidden tab reuses it, and switching to
it is instant at fit. Keeping everything in the shared lease would hold tiles nobody sees, and today's reservation frees
only the current image's cache, so the selected tab could be refused its first frame. A lease per tab grants a floor to
content nobody sees. Releasing every bitmap would stall a program's `wait` on its hidden tab, and turn a tab whose
folder image was deleted into an error. Without reclaim across panes, one pane's hidden backdrops could starve another
pane's zoom. Converged in 1 pass.

### A hidden tab's running work

Original question: the image viewer's slideshow, animated images, and prefetch run in its pane, and a detached pane
pauses them. What does a hidden tab do?

Decision: a tab runs perceptible work only while it is on screen, meaning the tab is selected. A hidden tab pauses its
animation, its slideshow timer, keeping the intent to play, its prefetch, and its tiles, and resumes when selected. Its
alerts go out at once and name its file, as the terminal's hidden tabs do. It still asks the helper for the still
decodes its own first load and its program's commands need, behind the selected tab's requests. A program's zoom into a
hidden tab settles without waiting for tiles. (autonomous) Amended 2026-11-27; see Decision Log.

Rationale: a hidden tab is not seen, so its animation and slideshow would run for nobody. Keeping a slideshow
running would also make the pane's one helper serve the hidden tab, starving the selected tab's tiles and frames. Holding
alerts back would hide a failed open until the user selects its tab, against M1's notice rule. Pausing still decodes
would stall a program's `show` and `wait` on its hidden tab. The off-screen code's zoom wait had the same gap, filed
and since fixed as `20261126-detached-image-zoom-wait-never-settles`. Converged in 1 pass.

## Design Decisions (Open)

None. Every question is settled.

## Risks

- **A program learns the names of files outside its read scope** — likelihood: high, impact: high.
  Without per-tab checks, the pane listing and the pane's directory leak tab titles from the moment a pane holds several
  tabs.
  Mitigation: "Read scope applies to each tab" is settled, and M1 builds it before any viewer publishes several tabs.
  Captures follow UTERM-054's answer.
- **Program commands meet several tabs before their rules exist** — likelihood: medium, impact: medium.
  Mitigation: M1 settles and builds the program-facing rules before any viewer milestone ships tabs.
- **Many large data files slow the machine** — likelihood: medium, impact: medium.
  macOS compresses and swaps memory rather than ending an app for its footprint, so the harm is swapping that slows
  every process, terminals included. Nothing already loaded is freed.
  Mitigation: the memory-pressure guard holds as a state, so no file loads past its floor while the system reports
  pressure, unless M2's first check falls back to today's rule. That check measures whether the warning arrives in
  time, and adds a physical-memory backstop if it does not.
- **UTERM-018 M3 is built on the replace model first** — likelihood: medium, impact: medium.
  Mitigation: amend UTERM-018's batch rule and M3 checks when this proposal is accepted, before M3 is scheduled. The
  same holds for UTERM-041's driver-pane exemption, UTERM-042's set close, and UTERM-054 and UTERM-055's tab-scope rule
  for applets with one tab.
- **Programs built against an earlier build stop working** — likelihood: high, impact: low.
  Every program command to a viewer must now name a tab, and the replace commands answer with an identity. A driver or
  native controller written for today's wires fails until it is rewritten. Accepted: every external wire is at
  version 0 under UTERM-063, which makes no compatibility promise, and the only such programs are the user's own. The user chose this at
  the review gate.
- **Program-opened text and map tabs have no memory bound** — likelihood: low, impact: medium.
  A loaded tab stays loaded, and each keeps its own web view or map view. A run at the rate bound accumulates them, and
  ADR-07 asks the design to say what bounds that. Accepted: the rate bound limits how fast a run adds them, revoking
  the run ends its reach, and the user closes tabs as with any tabs they keep. Per-view cost is not measured. (autonomous)
- **UTERM-006 M5 is built on one source per image pane** — likelihood: medium, impact: low.
  Mitigation: amend UTERM-006 M5's driver reads to name a tab when this proposal is accepted, before M5 is scheduled.
- **The payload change strands a newer layout on an older build** — likelihood: medium, impact: low.
  Mitigation: ADR-06 keeps an unreadable payload's bytes and restores the pane as a placeholder. One-tab panes still save
  at today's version, so older builds read them.
- **A map tab's edits are lost on close** — likelihood: low, impact: high.
  Mitigation: every close path asks about each tab with edits. M5 checks Close Tab, pane close, window close, and quit.

## Milestones

### M1: Shared tab groundwork and the program boundary

**Status:** NOT STARTED

- Read scope is checked per tab for titles, content, and pending waits. A program scoped to one folder never reads the
  title of a tab whose file is elsewhere. The pane-level title and directory follow the selected tab's check
- A pending wait checks the source of the tab its handle belongs to, not the selected tab
- The source-swap path takes each open as its own tab: N rapid opens, or N dropped files, add N tabs in order, and
  none supersedes another
- Each tab keeps its own notices. A hidden tab's load notice names its file, and a new tab's load never drops another
  tab's notices
- Each viewer records each tab's owner in group panes. Give Group and reclaim give the new owner every tab the pane holds
  at that moment, Enable and Run hand over nothing, and tabs the user adds later stay the user's
- A program-opened pane's first tab is the program's from creation, whether the pane starts enabled or disconnected
- Owners survive a new control generation, and clear when their grant ends. The caller-owning contract's rule that
  owners end with any change of control is amended for viewers, or viewers use a contract of their own
- A driver's commands to its own pane run after Disconnect and after Revoke, and reach every tab of that pane. They are
  marked as the driver's explicitly, never by leaving the caller out
- Every program command to a viewer names its tab, as UTERM-064 requires
- `show`, `show-markdown`, and `send` replace the named tab, never the selected tab, and a replace into a hidden tab does
  not select it. `send` carries the caller's grant and passes the named tab through
- The new `open` command on the text, image, and map viewers adds a tab and selects it
- The viewers' `open`, `show`, `show-markdown`, and `send` answer with the identity of the tab they opened or filled, and
  a viewer's events carry their tab's identity
- UTERM-064's find query and pane listing see viewer tabs and their owners
- A tab brought back by Reopen Closed Tab is the user's, whoever owned it before
- The rate bound on `open` keys on the run's grant, and an `open` past it is refused as busy. A driver's bound in its
  own pane keys on its run, so a revoked driver whose commands still run keeps its bound. The user's own opens are
  never limited
- Sent files are kept per tab, and a file is released when its tab closes, so a second send never deletes a file an
  open tab reads
- A program's tab open on a viewer pane is refused through its own hook, with a message that names `open`, or `send`
  for the data viewer
- A pane's placeholder tab exists only while it holds no file. The first open removes it and adds a tab with a new ID
  owned by the opener, and a map placeholder that holds pins is never removed this way

### M2: Data viewer tabs

**Status:** NOT STARTED

- A data viewer pane holds several files as tabs, draws the shared tab bar, and hides it with one tab
- The pane-local Open…, Cmd-T, and a drop each add a tab and select it. The "Drop one file at a time" refusal is gone,
  and a drop of several files adds one tab per file and selects the last dropped file's tab. A new pane holds no empty
  tab beside its first file
- Opening a file a tab already shows adds another tab, and the new tab reads the file as it is now
- Next, previous, and numbered tab selection work as "Tab keys that collide" settles. Close Tab or Pane closes the
  selected tab, and the last tab's close closes the pane
- Reopen Closed Tab or Pane brings back a closed data tab with its sort and filter
- A hidden tab keeps its rows. A restored tab loads when first selected
- A restored tab that was never selected saves its path, bookmark, sort, filter, and sheet unchanged
- Each file has its own budget. While the system reports memory pressure, reservations past each lease's floor are
  refused and running loads stop in every tab, and loads go on normally once it reports normal
- Loading several dropped files never blocks the main thread
- Each tab keeps its own find, filter, and popovers
- Relaunch restores every tab and the selected tab. A one-tab pane saves at today's payload version, and a payload at
  the newer version holds only the tab array
- The memory-pressure guard holds as a state. Its first check measures, by dropping 20 large files, whether the system
  reports the return to normal, how long a warning lasts, whether resumed loads bring the warning straight back, and
  whether the warning arrives before swapping slows the terminals. The result is recorded in the As built block. A late
  warning adds the physical-memory backstop, and a missing return to normal or a warning loop falls back to today's rule
- A load stopped by memory pressure says so, and resumes on its own once the level returns to normal. A lease's floor
  is granted under pressure. Filters run under pressure. A sort past its floor is refused with a notice that names
  memory pressure, not the row count, and runs once the level is normal
- Under the state guard and under its fallback alike, a tab loaded before a warning sorts again, which closes
  `20261126-memory-warning-stops-sorting-in-open-data-panes`

### M3: Text viewer tabs

**Status:** NOT STARTED

Amended 2026-11-27; see Decision Log.

- A text viewer pane holds several documents as tabs, with the same open, select, close, and reopen behavior as M2
- Each tab keeps its own scroll position, find, and contents sidebar state
- A decoder helper exit shows a failure in the tab it was serving. The other tabs decode again on their next request
- Each tab keeps its own web view, and a web content process that ends reports to its own tab
- A hidden tab's alerts go out at once and name its file. A hidden tab holds its file-watch changes through the text
  viewer's existing held change, and applies them when selected
- Relaunch restores every tab and the selected tab. The written payload version is the highest any tab needs

### M4: Image viewer tabs

**Status:** NOT STARTED

Amended 2026-11-27; see Decision Log.

- An image viewer pane holds several images or folders as tabs, with the same open, select, close, and reopen behavior
  as M2
- Each tab keeps its own zoom, position, and folder place
- A hidden tab keeps its fit backdrop and the frame on screen, and releases its tiles, zoomed frames, the helper's
  level, and its cached neighbors through the viewer's existing off-screen code
- On-screen content in any pane takes back hidden tabs' backdrops, least recently selected first, before it is refused.
  The budget's count follows what views actually hold
- Every gate on running work tests "on screen", which means selected. A hidden tab's animation, slideshow timer,
  prefetch, and tiles pause and resume on selection
- A hidden tab's alerts go out at once and name its file. Its still decodes for its first load and its program's
  commands run behind the selected tab's requests, and a program's zoom into a hidden tab settles without tiles
- Selecting a tab whose helper source was dropped opens it again without a visible error
- A decode helper crash shows a failure in the tab whose request was in flight, which can be a hidden tab's prefetch.
  The other tabs decode again on their next request
- Relaunch restores every tab and the selected tab

### M5: Map viewer tabs

**Status:** NOT STARTED

- A map viewer pane holds several map files as tabs, with the same open, select, close, and reopen behavior as M2
- Each tab keeps its own region, style, and pins, including what UTERM-040 leaves of program pins
- Unsaved work is reported per tab. Close Tab, a pane close, a window close, quit, and UTERM-042's set closes each ask
  one Save, Don't Save, or Cancel question listing every tab with edits it would close
- Each Save As panel names or selects the tab it saves. A Cancel partway through leaves earlier tabs saved and the close
  cancelled
- Each tab keeps its own map view and undo history, so Undo in one tab never undoes another tab's edit
- A hidden tab's alerts go out at once and name its file
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
- 2026-11-26: Second critique pass. Took captures out of the settled read-scope decision, since UTERM-054 holds that
  question open. Corrected the version facts: ScriptWire and the exec wire have one whole-number version each, and the
  viewers' events belong to their command schemas. Added impacts on UTERM-041 and UTERM-028, the routed opens that
  programs send, labels on options that add scope, and checks for waits, drops, and helper crashes.
- 2026-11-26: Third critique pass. Corrected ScriptWire: it already carries a tab on pane targets, and its version
  negotiation is UTERM-056's, not UTERM-028's. Native controllers keep today's meaning of `send`. Added the impact on
  UTERM-056, made the UTERM-054 impact depend on "What a program may reach", and added a check that events keep their
  meaning for callers on today's minor.
- 2026-11-26: A closing re-check of the third pass's fixes converged. Routed its checks on the version that gates each
  program open path, and added the terminal precedent from UTERM-054 to "What a program may reach".
- 2026-11-26: Review start: 6 milestones, 5 settled decisions, 6 risks, no live-after lines or row gates; 14 open
  questions; autonomous review of the whole draft at commit "Route UTERM-062's closing critique checks".
- 2026-11-26: What a program may reach: per-tab owners, with a hand-over rule at Run, Give Group, and reclaim.
  (autonomous, addition)
- 2026-11-26: Tab identity: keep today's model. (autonomous)
- 2026-11-26: An app-wide ceiling: the memory-pressure guard becomes a state, with a physical-memory ceiling as a
  backstop only if M2's first check shows the warning arrives late. (autonomous)
- 2026-11-26: Tab keys: all nine Select Tab commands in every viewer, with colliding keys left off. (autonomous)
- 2026-11-26: What a program's open does: the replace commands keep replacing, into the caller's tab, and a new `open`
  command adds a tab. (autonomous, addition)
- 2026-11-26: What a program addresses: a command with no tab acts on the caller's tab. Provisional until the review
  gate, since it is implicit state kept for each caller. (autonomous, provisional)
- 2026-11-26: A cap: no count cap, and a rate bound on a run's tab opens. Provisional until the review gate, since it
  bears on the user's 2026-11-21 ruling. (autonomous, provisional, addition)
- 2026-11-26: The saved layout's tab list: write the lowest version that holds the pane. (autonomous)
- 2026-11-26: A new pane's empty tab: a placeholder exists only while the pane holds no file, and the first open
  replaces it with a new tab owned by the opener. A drop selects the last dropped file's tab. (autonomous)
- 2026-11-26: What Cmd-T means to a program: refused, through its own hook, with a message naming `open` or `send`.
  (autonomous)
- 2026-11-26: The map's unsaved edits: unsaved work per tab, and one question per close act, UTERM-042's set closes
  included. (autonomous)
- 2026-11-26: Opening a file a tab already shows: adds another tab. (autonomous)
- 2026-11-26: What a hidden image tab keeps: what a detached pane keeps, with hidden backdrops yielding to on-screen
  content in any pane. (autonomous)
- 2026-11-26: A hidden tab's running work: pauses unless on screen, delivers alerts at once, and still serves its
  program's decodes. Filed `20261126-detached-image-zoom-wait-never-settles` for the same gap on detached panes.
  (autonomous)
- 2026-11-26: Coherence review. Fixed: after the caller's tab closes, a command with no tab is refused, never moved;
  the pressure guard still grants each lease's floor and resumes stopped loads at normal; the `send` label now says a
  program holds at most one data tab. Routed checks for drivers' own-pane grants, reopened tabs, the rate bound's key,
  and hidden text and map tabs. Added risks on the published contracts, program-opened tab memory, which is accepted,
  and UTERM-006 M5. Tagged as additions: the pressure state guard, unsaved work per tab, cross-pane backdrop reclaim,
  and the refusal hook for a program's tab open. (autonomous, addition)
- 2026-11-26: What a program may reach, reopened by the coherence review: a hand-over through the caller-owning contract
  would be wiped by every control change and refuse deployed callers. Reach now follows how the program came to the
  pane: a driver reaches every tab of its own pane, and group panes keep per-tab owners that survive control changes.
  (autonomous, addition)
- 2026-11-26: Coherence re-check. Fixed: a sort past its floor under pressure is refused with a notice naming pressure,
  and runs at normal; a missing return to normal falls back to today's rule instead of a ceiling; the rate bound keys
  on the run's grant, and on the source pane or sending app for routed opens under UTERM-018; a driver's new run starts
  with no caller's tab. Restated the published-contract risk with every refusal the design makes. (autonomous)
- 2026-11-26: Closing re-check: the caller's tab resets on the caller's next `open` as well as its next run, so the
  decision matches M1. Routed checks for the sort bug, the sort notice, a revoked driver's rate bound, and UTERM-018
  M5. This last fix came after the final pass, and no critic pass has checked it. (autonomous)
- 2026-11-26: Review gate, first answers: the user kept the rate bound on program tab opens, hidden image backdrops
  giving way to on-screen content, and per-tab owners. "What a program addresses" is still open at the gate: the user
  prefers that commands name a tab, and asked how a program finds and tracks its tabs.
- 2026-11-26: Review gate: the user chose that a program's command names the tab it acts on, replacing the
  provisional rule that acted on the caller's tab. It reopens how deployed callers behave, and adds how a program finds
  a tab to name.
- 2026-11-26: Review gate: every caller names a tab now, since no wire carries a compatibility promise before 1.0;
  commands take only an identity; a caller's own-tab alias and a find query return identities; "not open" and "not
  yours" share one error; aliases follow one documented naming convention. The version reset is its own proposal.
- 2026-11-26: Split with the user's approval. The rules that reach every applet moved to UTERM-064, and the reset of
  every wire to version 0 is UTERM-063. This proposal keeps the viewer side and depends on both.
- 2026-11-26: Review gate: kept all. The user kept the viewers' `open` command, the memory-pressure state guard,
  unsaved work reported per tab, and the refusal with directions for a program's blank-tab request.
- 2026-11-26: The user accepted the proposal.
- 2026-11-26: ADR candidate: a program knows the identity of every place it makes or fills, without guessing. The
  user asked for it at the review gate. Outcome: written as ADR-16, proposed.
- 2026-11-26: ADR candidate: stable tab identity across the program boundary. `adr-impact` found that no ADR covers tab
  identity for any applet. Outcome, 2026-11-26: Declined: applies ADR-16, and UTERM-064's amendment to ADR-02.
- 2026-11-26: ADR candidate: whether an open into an occupied pane adds or replaces, across applets. Outcome,
  2026-11-26: Declined: it fails Architecture. The rule governs where an open lands, which UTERM-018 decides for every
  open, and only the viewers change here. The browser already adds a tab.
- 2026-11-26: Scheduled as M1-M6 in queue.md, at the end. The row waits on UTERM-063 and UTERM-064.
- 2026-11-26: The proposals this one impacts were amended to match. UTERM-018 adds a tab on a routed open, a batch
  works like a drop, its replaced-document Reopen is withdrawn, and its M3 to M5 start after this proposal's M5.
  UTERM-009 carries its superseded-in-part markers. UTERM-040's pin commands name a tab. UTERM-041's driver-pane
  exemption covers the whole pane, and viewer group tabs carry the marker by owner. UTERM-042's set close asks Save,
  Don't Save, or Cancel for map tabs with edits. UTERM-054's tab scope counts a driver's own pane as wholly its own,
  and its open question gained tab titles. Two passages now cite UTERM-063 for version 0 instead of "before 1.0".
  UTERM-006 M5 is left to UTERM-065, which already names a tab.
- 2026-11-27: The user retired the `detach` and `reattach` lifecycle events, and ADR-05 is amended to match. No pane is
  ever detached, so the wording that leaned on a detached pane changed. A hidden tab behaves exactly as decided. The
  image viewer keeps its pause and release code, and the text viewer keeps its held file-watch change. Both are the
  applet's own off-screen state now, and nothing in the app calls them until M3 and M4 do.
  - Amended "What a hidden image tab keeps". It said "a hidden image tab keeps what a detached pane keeps today", that
    it releases "through the same code detach runs", and "a detached pane already keeps only its backdrop, so a hidden
    tab follows an existing rule". It now names the image viewer's off-screen code.
  - Amended "A hidden tab's running work". It said "on screen, meaning its pane is attached and the tab is selected".
    On screen now means selected. Its rationale said "ADR-05 stops what the user would notice but cannot see, and a
    hidden tab is not seen", and ADR-05 no longer says that. It also said "The detached-pane zoom wait has the same gap
    today", and that bug is fixed.
  - Amended M3. It said a hidden tab holds its file-watch changes "as a detached pane does".
  - Amended M4. It said a hidden tab releases "through detach's code", and that every gate tests "on screen", "attached
    and selected, not detach alone".
- 2026-11-27: Amended the UTERM-040 Impacts line for UTERM-040's amendment under UTERM-063. It said UTERM-040 "moves
  program pins into the document under schema 2.0". The map's schema stays 0.0, and the change lands in place.

## References

- ADR-02: panes are addressed by stable ID
- ADR-03: restore never runs a program
- ADR-04: applet keys
- ADR-05: close guards
- ADR-06: each applet versions its own payload
- ADR-07: failure isolation
- ADR-08: the main thread never waits on outside work
- ADR-10: helpers run sandboxed
- ADR-11: a command with an effect replies at once
- ADR-13: external wires stay compatible
- ADR-14: a controller controls what it opened
- ADR-15 (proposed): an action means one thing, whoever starts it
- [ADR-16](../adr/ADR-16-a-program-can-name-what-it-made.md) (proposed): a program can name what it made
