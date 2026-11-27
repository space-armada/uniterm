# UTERM-053: The Browser's Per-Tab Work Never Grows with the Tab Count on the Main Thread

**Status:** accepted
**Created:** 2026-11-22
**Updated:** 2026-11-23

## Dependencies

- UTERM-005, for the browser applet and its tab records
- UTERM-041 M1, for the scrolling tab bar this proposal windows. See "Design against UTERM-041's settled bar, and build
  after its M1".
- UTERM-052 M2, for the record choke point and the saved-state revision this proposal routes through its declared
  change. See "One record choke point serves the refresh and the description".

## Impacts

- UTERM-041 — M1 makes the shared tab bar scroll, and makes `AppletTabBar.update` take published tabs. This proposal
  changes how the same bar creates and updates its items, and changes `AppletTabList`'s shape. M1's input check and
  VoiceOver check hold unchanged. See "Design against UTERM-041's settled bar" and "The bar owns one accessibility
  element per tab".
- UTERM-042 — its tab menu is built on the items this proposal rebinds, and its VoiceOver show-menu action lives on
  the tab element this proposal moves to the bar. See "The bar owns one accessibility element per tab".
- UTERM-048 — its M3 walks up from a hit view to an `AppletTabItem` for its tab ID. A rebound item carries the ID of
  the tab it shows.
- UTERM-051 — it moves the layout decode off the main thread. That leaves this cost on the main thread at launch.
- UTERM-049 — its tab-set open builds a pane from a file of up to 32 MiB, so it is a large-count source this proposal
  bounds.
- UTERM-052 — it bounds the description's encode, and leaves the tab cap to this proposal. This review amended it to
  share this proposal's record choke point, and to build its tab array from the kept records. See "One record choke
  point serves the refresh and the description" and "No tab cap".
- UTERM-058 — the palette's index reads the read-through view by ID and shares the refresh's change type for the
  window's tab report. See "The published list is a read-through view of the applet's tabs".

## ADR Deviations

- ADR-08 "The main thread may do local work whose duration uniterm bounds", no carve-out. A pane has no tab cap, so
  each of these has no stated bound:
  - A restore and a bulk open, such as a tab-set file, build one tab object and record per tab they bring, once. The
    tab objects took 7 ms for 10,000 tabs. A restore also gives each tab its encoded record under UTERM-052. Encoding
    costs about 20 µs per tab, so UTERM-052 M2 reuses the stored payload's own tree where it can.
  - An open or a close does one pass over the tabs after the change point. It moves a pointer and rewrites a stored
    position for each.
  - An event that changes many tabs, such as a grant end over a controller's tabs, does work for each tab it changes.
  - A pane-level event walks every tab once.
  - If VoiceOver asks the bar for every child at once, each such query costs every tab's element. M1 settles whether it
    does. See the risk on assistive queries.

  The user accepted these on 2026-11-22. See "The per-change bound, with the linear parts declared".

## Summary

The browser pane's tab bar and refresh stop doing work for every tab each time something changes. Their main-thread
cost per change stops growing with the tab count. A restore, a bulk open, and a pane-level event stay linear once.

## Motivation

### The walks

`AppletTabBar.update` keeps one `AppletTabItem` view per title. It creates the missing views. Then it sets the index,
title, selection, and both closures on every item. Each of those setters re-sets the item's accessibility identifier,
label, and value, with no check that the value changed. `layout()` sets a frame on every item on every layout pass, and
each update and each resize asks for one. `apply(_:)` walks every item at a theme change.

`BrowserApplet.refresh` cleans every tab's title and hands the list to the bar. It rebuilds the published
`AppletTabList` from every tab. That list is an immutable struct, so changing one entry builds a new one, and its init
scans every tab to check the selection. `refresh` also builds a change snapshot that copies every tab's record, ID, and
title, and compares it with the last one.

The private init cleans every title once for `publishedTabs`. It then calls `refresh()`, which cleans them all again
and overwrites that list.

The window and the palette read the published list. The palette rebuilds its candidates from every tab of every pane
while it shows, and each tab change schedules a rebuild. Scripting walks the list to report tabs. Those host-side walks
stay out of this proposal's scope. See "The window's host-side walks stay out of scope".

### Where a large count comes from

A stored layout can hold any number of tabs. The user's New Tab has no limit. A tab-set file opened by UTERM-049 can
hold a very large number of addresses. A controller may hold 16 open tabs per grant today, and UTERM-039 drops that
limit. A page the user granted can open pop-ups past the first 10. Each open runs a full refresh, so a loop that opens N
tabs one by one costs the main thread work that grows with N².

### The cost

The cost was measured on 2026-11-22 in a debug build, with 10,000 tabs. The bar's first update took 1.17 s. An update
that changed only the selection took 61 ms. Computing the titles took about 99 ms more, per the bug's measurement. The
restoring init took 1.63 s as a whole. Building the tab objects alone took 7 ms. At 50,000 tabs the report measured a
restore of about 11 s.

A refresh follows each load state and title change, including a background tab's. A page chooses how often its title
changes. So a page can make the main thread pay about 160 ms per change in a 10,000-tab pane.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound. The bug is `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`.

### Who shares the bar

The terminal and the questions applet use the same `AppletTabBar`. The terminal updates it at each title a program
sets, and it has no tab cap. The questions applet caps its tabs. A change to the bar reaches all three.

## Design Decisions (Settled)

### Design against UTERM-041's settled bar, and build after its M1

Original question: how this fits UTERM-041. UTERM-041 is accepted, and its M1 has not started. Its scrolling bar is
settled: the bar takes published tabs, hides below two tabs, scrolls by trackpad and shift-scroll, shows that more tabs
lie past an edge, and keeps the selected tab fully in view. The bug `20261121-tab-bar-overflow-hides-tabs` is fixed by
that milestone.

Decision: design the windowing now, against UTERM-041's settled bar. Build it in a milestone that depends on UTERM-041
M1. UTERM-041 M1 and the overflow fix are not held up by this proposal's open questions.

This milestone rebuilds part of what UTERM-041 M1 builds: its per-tab item views and its marker comparison in the
refresh's snapshot. UTERM-041 M1's input check and VoiceOver check hold unchanged, under "The bar holds each applet's
read-through list" and "The bar owns one accessibility element per tab".

Folding the windowing into UTERM-041 M1 was rejected. That accepted milestone, and the overflow fix, UTERM-019 M3, and
UTERM-042 behind it, would then wait on this draft. Waiting for UTERM-041 M1 to land before designing was rejected,
since the bar's contract gives no reason to wait.

### No tab cap

Original question: whether a tab cap is in scope, and which proposal settles it. UTERM-052 left the cap to this
proposal.

Decision: no cap. A pane keeps any number of tabs, and the fix bounds the per-change work for every source of a large
count. A restore still makes one tab object and one record per stored tab, measured at 7 ms for 10,000 tabs, plus each
tab's encoded record under UTERM-052. Memory and
web content processes still grow with the tabs a controller or a granted page opens. That growth belongs to UTERM-039's
deferred rate bound and the idea of suspending background tabs.

A cap was rejected. UTERM-039 ruled that a cap on the total count is the wrong bound, since the user's New Tab has none.
UTERM-049 ruled that a ceiling on opens would lose tabs past it on the next save. A stored pane over a cap would either
lose tabs or need a deferred-tab state that every walk, save, and restore handles. Once the per-change work is bounded,
an opening loop is linear in its count, so the cap would bound little main-thread work.

### The terminal keeps its own walks, which are filed as a bug

Original question: whether the terminal's own per-tab walks are in scope.

Decision: no addition. The terminal adopts the bar's new input, since it shares the bar. Under "The bar holds each
applet's read-through list" it publishes a read-through view, which removes its per-change title array and its computed
published list. Amended 2026-11-22; see Decision Log. Its other walks stay: the per-session calls in its tab refresh,
and the per-session frames in its layout. They are filed as bug `20261122-terminal-tab-changes-walk-every-tab`.

Bounding the terminal too was rejected as an addition this proposal's problem does not need.

### The window's host-side walks stay out of scope, and the palette's cost is filed as a bug

Original question: whether the window's host-side walks are in scope.

Decision: no addition. These stay: a palette rebuild over every tab of every pane, at most 10 times a second while the
palette shows; a filter over every candidate at each keystroke; and a scan of the published list for each call that
names a tab. The host's readers of the published list still change with `AppletTabList`'s shape. The palette's cost is
filed as bug `20261122-palette-rebuild-walks-every-tab`.

Bounding the palette's rebuild was rejected as an addition. It leaves the per-keystroke filter linear, and it needs a
per-tab change report from every applet to the host.

### The per-change bound, with the linear parts declared

Original question: what counts as bounded under ADR-08. ADR-08 asks for main-thread work whose duration uniterm bounds.
It does not say the cost must be constant.

Decision: the bound covers the browser applet and its tab bar, per change.

- A content change is a title, a load state, a marker, or the selection. It costs a constant amount of work per tab the
  event changes, plus the visible bar items. An event that changes many tabs, such as a grant end that changes a script
  group's markers, costs work in proportion to the tabs it changes. A change that names no tab, such as a download's
  progress or a dialog, touches no tab.
- Every tab stores its position. A lookup by ID goes through a map from ID to tab, then reads the position. Neither
  scans.
- A structural change is an open or a close. It costs the same, plus one pass over the tabs after the change point.
  That pass moves each tab's pointer in the storage and rewrites the tab's stored position. It allocates nothing and
  does no string or view work. A bulk insert splices once and makes one pass. Amended 2026-11-22; see Decision Log.
- A restore or a bulk open does work linear in the tabs it brings, once. Each step builds a tab object and a record,
  with no view.
- A pane-level event, such as start or close, walks every tab once.

The window's own work per change is outside this bound: the palette rebuild, which stays out of scope, and the
description's array pass at each call, which UTERM-052 declares.

The linear parts are listed under ADR Deviations, the way UTERM-052 listed its copy per save.

A walk over every tab per change, with cheap steps, was rejected. With no cap it has no stated bound, and a page that
changes its title in a loop still pays it per change. Constant work for every step, restore included, was rejected. It
needs a deferred or lazy tab state, which "No tab cap" rejected, and it reaches into UTERM-051's restore path. A custom
ordered container that makes opens constant was rejected as speculative. Each open already builds a tab object that
costs far more than the pointer moves.

### A windowed bar whose items act by tab ID

Original question: how the bar bounds its per-tab work.

Decision: a hand-built windowed bar inside UTERM-041's scroll view. It keeps only the items that fit, plus a margin, and
rebinds them as the bar scrolls or the selection moves. Each item setter does nothing when its value is unchanged. A
rebound item carries the ID of the tab it shows. Its select and close actions, and any menu opened from it, carry that
ID. The applet finds the tab through its ID map and reads the tab's stored position, with no scan. This changes the
shared bar's select and close contract for the terminal and the questions applet too, and it fixes bug
`20261122-tab-close-button-may-close-a-shifted-tab`. Amended 2026-11-22: the index hint and its scan on a miss are
gone; see Decision Log.

Every item in the bar has one width. That is an invariant of this decision: the visible range follows from the scroll
offset by arithmetic. A later change to per-tab widths, such as pinned or content-sized tabs, must revisit the
windowing.

Setter guards alone were rejected. They keep a view per tab and a walk over every item per change, which the per-change
bound rules out. An AppKit reuse container was rejected. Its defaults take first responder and keep their own
selection, it replaces UTERM-041 M1's scroll view, and its reach for off-screen items is unverified. A single view that
draws every visible tab was rejected. It rebuilds the close button, hover, tooltips, and menus by hand.

### The published list is a read-through view of the applet's tabs

Original question: how the refresh updates only what changed. `tabDidChange` already names the changed tab. UTERM-041
M1 adds markers to the refresh, and one grant end can change many tabs' markers.

Decision: `AppletTabList` becomes a read-only view over the applet's tabs and its selected index. Each tab has one
published entry, an AppletKit object that holds its ID, cleaned title, markers, stored position, and accessibility
element. The entry is recomputed when its own inputs change. Those inputs include the page title and the current
address, not only the stored record, since a page that cannot be stored still has a title. The applet keeps a map from
ID to tab. A change updates that tab's entry, so no second copy of the entries exists to drift.

The refresh takes a change value: one tab, a set of tabs, the selection, an insert at a position, a remove of tabs
named by ID, a change that names no tab, or a pane-level change. The ID map resolves a removed tab's position, so a
remove by ID costs no scan. The window's tab report shares this type, per UTERM-058. It has no form that omits the change, so a call site that forgets to declare
its change fails to compile. A change that names no tab, such as a download's progress or a dialog, updates segments
and touches no tab. The applet reports a tab change when a changed tab's entry differs, and reports a change to the
window whenever the saved-state revision moved, even when no entry changed.

The saved-state revision, moved by the record choke point, replaces the snapshot's record comparison as the signal for
a layout save. The unsent-input marks and the dialog count get their own per-event signals. See "One record choke point
serves the refresh and the description".

The view returns a tab's title and details by ID through the ID map, with no scan. The published entry holds no
details, and the palette searches a terminal tab's working directory, so the view reads details from the applet's tab.

Readers that need a fixed copy take a value snapshot from the view. Equality lives on the snapshot only, so a test that
held the list and compared it later must take a snapshot to compile. Applets with one tab keep a fixed-list form, so
their call sites stay as they are.

A copy of the entries on the applet, updated in place, was rejected. It is a second record of each tab that can drift
from the tabs. A cached cleaned title alone was rejected. It keeps the walk, the list rebuild, and the snapshot per
change, which the per-change bound rules out. Amended 2026-11-23; see Decision Log.

### The bar holds each applet's read-through list

Original question: what the bar takes as input.

Decision: the bar holds the applet's published list, which is a read-through view. At each update, and at each scroll
or layout pass, it reads the live count, the selection, and its visible items. It keeps no copy of a title. The bar
shows exactly the tabs the host sees published, so UTERM-041's single hide predicate still holds. The terminal and the
questions applet hand the bar their published lists the same way. The terminal therefore publishes a read-through view
too, which retires its computed list. See "The terminal keeps its own walks, which are filed as a bug".

A data source protocol was rejected. It is a second way to read the same tabs, so the bar's count could differ from the
published count. A full list per update was rejected, since it walks every entry per change.

The questions applet's bar disagrees with UTERM-041's hide rule today. That is filed as bug
`20261122-questions-bar-disagrees-with-the-shared-hide-rule`. Its answer decides what the questions applet's bar shows
at zero and one question.

### The bar owns one accessibility element per tab

Original question: what VoiceOver reaches in a windowed bar. UTERM-041 M1 checks that a VoiceOver user reaches each
tab's markers and its close button.

Decision: the bar vends one lightweight accessibility element per tab. The element lives on the tab's published
entry. It is built on the first query that reaches it and released with the tab, so a restore builds none and a closed
tab leaves none behind. Each element carries the title, the selection, one child element per marker, a close child, and
UTERM-042's show-menu action. Item views turn their own accessibility off, so an element never hands off to a view as
the bar scrolls. An element's frame comes from its tab's stored position and the one-width arithmetic. Its
scroll-to-visible scrolls the bar. Its press, close, and show-menu act by tab ID. The bar serves its children by range
where AppKit allows it. UTERM-041 M1's VoiceOver check holds unchanged. Amended 2026-11-22; see Decision Log.

Relying on VoiceOver's own scrolling was rejected. Only a manual VoiceOver session can test it, and its fallback leaves
off-screen markers unreachable, including UTERM-019's run-end warning. Exposing only the visible items was rejected for
the same reason: a VoiceOver user would have to change the selection to hear another tab's markers. Reaching markers
through the palette was rejected. UTERM-041 settled that the palette shows no markers. Elements that defer to a visible
view were rejected, since an element would leave the tree as its tab scrolls into view, which can drop VoiceOver focus.

### One record choke point serves the refresh and the description

Original question: whether the three per-tab walks share one fix. The bar re-reads its visible items, so it needs no
change report. The refresh and UTERM-052's description both need to know which tab changed. UTERM-052's save revision
moved from the refresh comparison that this proposal drops.

Decision: one choke point per tab, shared with UTERM-052. A tab's record setter acts only on a real change, where the
old value differs from the new. On that change it rebuilds the tab's encoded record, moves the applet's saved-state
revision, and updates the tab's published entry, all at once. The refresh's declared change moves the revision for a
selection change, an insert, or a remove. The description builds its tab array from each tab's kept record at each
call. UTERM-052 is amended to match.

UTERM-052 M2 builds the record setter and moves the revision at today's selection, insert, and remove sites. This
proposal's M1 then routes those through its declared change and adds the entry update to the same setter. So each
proposal's milestone works on its own, and this one depends on UTERM-052 M2.

The user chose this in the review. A cleared flag with two readers was rejected, since the save can read it after the
refresh cleared it and encode the old record. Keeping UTERM-052's assembled array was rejected. When the user chose,
finding a changed tab's element in it needed a scan of every tab. Stored positions, chosen later, remove that scan. The
array would still be a second record of every tab, and the save's hold on it forces a copy at the first change after
each save. A tracker per walk was rejected, since two records of one fact can drift. Sending a change report to the bar
too was rejected as a report the bar does not need.

## Design Decisions (Open)

None.

## Risks

- **An incremental refresh drifts from a full one, so the published list disagrees with the tabs** — likelihood:
  medium, impact: high.
  Mitigation: the published list reads through to the tabs, so it holds no copy that can drift. An M1 check still
  compares it with a full rebuild after a random sequence of changes.
- **A reused item acts on the wrong tab** — likelihood: medium, impact: high.
  Mitigation: items carry the ID of the tab they show, and the applet resolves it through its ID map. M1 checks close
  a tab through a reused item after an insert, and keep a focused item from being recycled.
- **A stored position goes stale after a structural change misses a tab** — likelihood: medium, impact: high. A stale
  position makes a lookup by ID act on the wrong tab.
  Mitigation: one function owns every insert and remove, and rewrites positions in its pass. The random-sequence check
  compares every stored position with the tab's real place.
- **A replacement for the snapshot misses a background tab's record change, so a layout save is skipped** —
  likelihood: medium, impact: high.
  Mitigation: the record setter moves the saved-state revision, and the refresh reports whenever the revision moved. An
  M1 check navigates a background tab to a page with the same title and sees the change reach the next save.
- **An assistive client asks for every child of the bar at each query** — likelihood: medium, impact: medium. AppKit
  offers ranged reads of an element's children, but whether VoiceOver uses them is unverified. If it does not, each
  query builds or returns every tab's element on the main thread.
  Mitigation: an M1 check queries a range of 20 children at 10,000 tabs and requires at most 20 elements built. A
  manual VoiceOver session records whether VoiceOver asks by range. If it does not, the per-query cost stays in ADR
  Deviations, which this review asks the user to accept.
- **`AppletTabList` changes shape under every applet while UTERM-041 M1 adds markers to it** — likelihood: medium,
  impact: medium.
  Mitigation: this proposal's milestone depends on UTERM-041 M1, so the two changes land in order.
- **The questions applet's bar waits on an open bug** — likelihood: high, impact: low. The bug
  `20261122-questions-bar-disagrees-with-the-shared-hide-rule` needs a design call on UTERM-041. Until it settles, the
  questions applet's bar has no rule for zero and one question.
  Accepted: M1 moves the questions applet to the new input either way. Only what its bar shows at zero and one
  question waits.
- **The 10,000-tab cost rises between UTERM-041 M1 and this proposal's milestone** — likelihood: high, impact: low.
  UTERM-041 M1 adds marker views and accessibility elements per tab before this proposal windows them.
  Accepted: nothing is lost, the cost is the bug's, and a redeploy reverts it.

## Milestones

### M1: Bound the bar and the refresh

**Status:** NOT STARTED

Waits on UTERM-041 M1 and UTERM-052 M2.

- A test counts, for one selection change at 10,000 tabs, the item views rebound, the titles cleaned, and the list
  entries rebuilt. Each count is at most a constant that does not depend on the tab count
- A test shows that a restore of 10,000 tabs creates a bounded number of item views, and that a layout pass sets at most
  that many frames
- A test shows that a resize and a theme change at 10,000 tabs each touch a bounded number of items
- A test shows that a title that changes while its tab is off screen shows when the tab scrolls into view
- A test shows that closing a tab through a reused item closes that tab, by ID, after another tab was inserted before
  it. The same holds for a terminal tab
- A test shows that scrolling never recycles the item that holds keyboard focus
- A test shows that a tab's accessibility element is the same object before and after the tab scrolls into view
- A test shows that a momentum scroll shows no blank or stale item, and that a pooled item takes the current palette
  when it is rebound
- A test shows that navigating a background tab to a page with the same title reaches the next save, and that unsent
  input and dialogs still report theirs
- A test shows that a download's progress update at 10,000 tabs touches no tab and moves no revision
- A test shows that a reader holding a value snapshot sees it unchanged after the tabs change. Reading the view at a
  position past the live count returns nil
- A test shows that a grant end updates markers only on that controller's tabs, and does work in proportion to them
- A test shows that assigning an equal title moves no revision and reports no tab change
- A test shows that a scroll or layout pass after a tab removal, and before the next update, binds no index past the
  live count
- A test shows that the bar's held list does not keep the applet alive after the pane closes
- A test queries a range of 20 of the bar's children at 10,000 tabs and finds at most 20 elements built. A restore of
  10,000 tabs builds no element
- A test shows that after an insert before an off-screen tab, its element is the same object and reports its new
  position
- A test shows that the show-menu action on an off-screen tab's element opens that tab's menu, and that a menu opened
  from an item acts on its tab after the item is rebound. If UTERM-042 M2 has not landed, this check moves to the As
  built block as a note for UTERM-042 M2, which then owns it
- A test shows that a script-opened tab at 10,000 tabs, from a page near the start, visits a bounded number of tabs to
  find its script group's end, outside the position pass
- A test shows that closing 9,999 tabs at once, as Close Other Tabs does, rewrites each surviving position once
- A test shows that each tab's element carries `tab-N` and `tab-close-N` from its stored position, that the marker
  identifiers follow it, and that `TabsUITests` passes unchanged
- A test shows that a terminal tab is still found in the palette by its working directory
- A test shows that at 10,000 tabs, the browser view's `contains`, `selectTab(id:)`, and its read of a tab's title and
  details by ID each resolve through the ID map with no scan
- A test shows that a remove reaches the refresh as the removed tabs' IDs, including a Close Other Tabs over 9,999
  tabs
- A test shows that after an insert and a remove in the terminal and in the questions applet, every entry's stored
  position and element frame match the tab's real place
- A test compares the incremental published list, and every tab's stored position, with a full rebuild after a random
  sequence of opens, closes, bulk opens, title changes on pages that can and cannot be stored, address-only changes, a
  lost content process, and selections
- A test counts, for each of 1,000 opens one by one, the tab objects built, the titles cleaned, and the item views
  touched. Each count is at most a constant that does not depend on the tab count
- A test shows that opening a 10,000-address tab set creates a bounded number of item views, and that a page's held
  tabs open in one splice
- The bar, the refresh, and the restoring init are timed at 1,000, 10,000, and 50,000 tabs, before and after, in the
  As built block. A tab-set open of a 32 MiB file of minimal addresses is timed there too

## Decision Log

- 2026-11-22: Filed as a draft from bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`. A triage run
  reproduced the cost, estimated the fix as large with non-trivial decisions, and the user chose to open a proposal.
- 2026-11-22: Revised after a design critique. The second title cleaning comes from the private init, not from `wire`.
  The 160 ms figure now cites the bug's 99 ms for the titles. The Motivation names the missed per-tab costs, the
  sources of a large count, and the other applets on the bar. The cap moved out of the bar question. Added candidates:
  designing against UTERM-041's settled bar, an AppKit reuse container, setter guards labeled as a shortcut, and the
  complete incremental refresh. The refresh candidate that claimed one tab's cost was false while `AppletTabList` and
  the snapshot stay linear, so it was folded into the complete one. Added questions for the bar's input, VoiceOver
  reach, the ADR-08 bound, the terminal, and the host walks. The VoiceOver risk became an open question. The
  measurement milestone could not fail, so its timing moved into the As built block. The checks now count work, not
  time.
- 2026-11-22: Review start: 1 milestone, 0 settled decisions, 3 risks, no `**Live after:**` lines or row gates. The
  palette and scripting walks are out of scope unless a question brings them in. The user asked for an autonomous
  review of the draft as of "Revise UTERM-053 after its design critique".
- 2026-11-22: Design against UTERM-041's settled bar, and build after its M1; UTERM-041 M1 joins Dependencies.
  (autonomous) Converged in 1 pass.
- 2026-11-22: No tab cap; UTERM-052 leaves the cap here. (autonomous) Converged in 1 pass.
- 2026-11-22: The terminal keeps its own walks, filed as a bug. (autonomous) Converged in 1 pass.
- 2026-11-22: The host-side walks stay out of scope, and the palette's cost is filed as a bug. (autonomous) Converged in
  1 pass.
- 2026-11-22: Corrected the controller source in the Motivation: 16 tabs per grant today, until UTERM-039 M1. Added
  UTERM-049's tab-set open as a large-count source, with an M1 check. Accepted the interim cost between UTERM-041 M1
  and this milestone as a risk. (autonomous)

- 2026-11-22: The per-change bound, with the linear parts declared under ADR Deviations for the user to accept at the
  gate. (autonomous) Converged in 1 pass, on an option the critic added: the listed per-change option could not be met
  literally, since opens and closes move pointers in the tab array, and it left the restore's linear cost undeclared.
  The Summary now says the bound is per change. The open check now counts work per open.
- 2026-11-22: A windowed bar whose items act by tab ID with an index hint, and a stated one-width invariant.
  (autonomous) Converged in 1 pass, on the critic's refinement: ID-only actions would scan every tab per click.
- 2026-11-22: The published list is a read-through view of the applet's tabs, and the refresh takes a declared change.
  (autonomous) Converged in 1 pass, on an option the critic added. It removes the drift and the index lookup that a
  second copy of the entries needs.
- 2026-11-22: Dropped a finding that a controller's open walks every owned tab to check its limit. UTERM-039 M1 removes
  that limit check. (autonomous)
- 2026-11-22: The bar holds each applet's read-through list; the terminal publishes one too, which amends "The terminal
  keeps its own walks" to retire its computed list. (autonomous) Converged in 1 pass.
- 2026-11-22: The bar owns one accessibility element per tab, keyed by ID, and never hands off to a view.
  (autonomous) Converged in 1 pass, on the critic's refinement of the per-tab element candidate.
- 2026-11-22: Dropped "a move" from the bound and the checks. The browser has no tab move, only inserts and removes.
  (autonomous)
- 2026-11-22: One record choke point serves the refresh and the description, and UTERM-052 is amended to match. The
  user chose it when asked mid-review, since it changes a settled decision of accepted UTERM-052. The critic added
  the option.
- 2026-11-22: Coherence pass. Its growth check fired: the per-change bound kept adding cases to find a tab's position
  from its ID. The user chose to narrow the bound. An open or close may rewrite each shifted tab's stored position in
  its one linear pass. Amended "The per-change bound", "A windowed bar", "The published list", and "The bar owns one
  accessibility element per tab" to match. The index hint and its scan on a miss are gone, and lookups go through an
  ID map and the stored position.
- 2026-11-22: The record choke point is built by UTERM-052 M2, at today's selection, insert, and remove sites. This
  proposal's M1 routes those through its declared change, so M1 depends on UTERM-052 M2. (autonomous)
- 2026-11-22: Accessibility elements live on each tab's published entry, built on first query and released with the
  tab. They carry UTERM-042's show-menu action. (autonomous)
- 2026-11-22: Fixed the coherence pass's text findings: the stale flag wording, the stale open-question references,
  "UTERM-052 bounds" for the description, and Impacts for UTERM-042 and UTERM-048. Added the multi-tab change and the
  conditional assistive query to ADR Deviations. Routed checks to M1 for a change that names no tab, a same-title
  navigation, non-storable titles and address changes, grant-end work, the held tabs' splice, show-menu, element
  identity, and the terminal's close. Accepted the questions applet's wait on its bug as a risk. (autonomous)
- 2026-11-22: Re-check pass converged. Corrected the restore's cost to include each tab's encoded record, about 20 µs
  per tab under UTERM-052. Routed checks to M1 for the script-group lookup, a many-tab close, the `tab-N` identifiers,
  the terminal's directory in the palette, positions in the terminal and the questions applet, and a view read past
  the live count. The show-menu check passes to UTERM-042 M2 if that lands second. (autonomous)
- 2026-11-22: The user accepted the ADR-08 deviation for the restore, bulk opens, the position pass at an open or close,
  multi-tab changes, pane-level events, and the conditional assistive query.
- 2026-11-22: The terminal publishes a read-through list. (addition) The user kept it at the gate.
- 2026-11-22: Review gate: kept all.
- 2026-11-22: ADR candidate "Each change costs constant work per item it changes, with linear parts declared as
  ADR-08 deviations": Declined. ADR-08 and its deviation entries already carry it.
- 2026-11-22: ADR candidate "Tab actions name a tab by ID, resolved when they run": Declined. ADR-02 states the
  principle for pane nodes, and this proposal applies it.
- 2026-11-22: Accepted by the user after the review.
- 2026-11-22: Scheduled as UTERM-053 M1 in queue.md.
- 2026-11-23: Amended for UTERM-058, which the user approved at its review gate. "The published list is a read-through
  view" said the change value holds "an insert or remove at a position". A remove now names tabs by ID, since
  UTERM-058's palette index is keyed by ID and shares this type for the window's tab report. The view also returns a
  tab's title and details by ID, since the published entry holds no details and the palette searches a terminal tab's
  working directory. M1 gains checks for both, and for the browser's `contains` and `selectTab(id:)` resolving through
  the ID map. The decision's marker had read "Amended 2026-11-22 for stored positions and the change that names no
  tab; see Decision Log."

## References

- ADR-08: UI responsiveness
- Bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`
- Bug `20261121-tab-bar-overflow-hides-tabs`
- UTERM-039: controller browser tabs are not capped
- UTERM-041: the uniform tab marker slot
- UTERM-049: save and open browser tab sets
- UTERM-051: the launch reads the layout off the main thread
- UTERM-052: the browser's description never encodes tabs on the main thread
