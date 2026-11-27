# UTERM-048: Pane Inspector

**Status:** accepted
**Created:** 2026-11-22
**Updated:** 2026-11-27

## Dependencies

- UTERM-003, for `list-panes`, whose builder M1 moves onto the shared snapshot. It is implemented
- UTERM-004, for pane control, groups, owners, and controller runs. It is implemented
- UTERM-013, for the command registry that places the inspector in the menu and the palette, and for shortcut
  ownership
- UTERM-041 M1, for M3: the tab IDs its tab bar items carry, and for M5: the markers a published tab carries
- For M2: the fixes of `bugs/20261122-terminal-directory-check-blocks-main-thread.md`, so `currentDirectory` does no
  blocking file-system work on the main thread, and of `bugs/20261122-approval-text-leaves-zero-width-scalars-raw.md`,
  so the shared escape helper covers zero-width scalars

## Impacts

- UTERM-041 — "One snapshot, and scripts see a fixed subset" and M5. Once its markers exist, the snapshot carries them
  and the inspector shows them. `list-panes` does not gain them through this proposal. M3's tab hit-test also touches
  the shared tab bar that its M1 changes, per "Who answers a tab hit-test".
- UTERM-042 — M3 "Pick mode". Pick mode swallows every mouse-down, so a right-click in pick mode never opens its tab
  menu.
- UTERM-003 — "One snapshot, and scripts see a fixed subset". The `list-panes` builder moves onto the shared snapshot,
  and its output does not change.
- UTERM-041 — "Markers outside the tab bar" puts markers only in the tab bar and at the pane level, and leaves other
  surfaces that list tabs out of its own scope. M5 lists each marker's kind and actions as raw state in the panel. It
  draws no marker as an indicator, so the everyday surfaces stay as UTERM-041 settles.
- UTERM-026 — "Pop Out Pane". A pane moved to another window may get a new node ID. The panel's target is held by
  window and node ID, so a picked pane that pops out shows as gone.
- UTERM-043 — its suspended controller state. The panel's controller rows show a run's identity, not whether it is
  suspended. Showing that would be a field of its own, with its own decision.

## Summary

A floating Pane Inspector panel shows everything uniterm knows about a pane and its tabs. That covers the applet
contract fields, the window's state for the pane, and the applet's own internals. It shows hidden state raw, such as
the layout and undo payloads, so the user can debug what flows between panes and launches. The panel follows the
focused pane by default. A target button picks any pane or tab with a click, as an eyedropper picks a color.

## Motivation

uniterm holds a lot of per-pane state the user cannot see. Some of it is shown in pieces. The title shows in the tab
bar, and the control badge's menu summarizes control. The rest shows nowhere:

- An applet's description, which a layout file saves and undo restores (`AppletDescription.swift`, about lines 7-59).
  Its undo-only part never reaches a file, so no tool shows it today.
- Which controller owns a pane's group, and which controllers may act on it. The badge's menu shows a name only. The
  Controllers & Permissions window lists every run's ID, version, key fingerprint, scopes, and PID
  (`ControllersWindowController.swift`, about lines 243-296). Nothing links a pane to those runs.
- The pane's control generation, which decides whether a permission asked for earlier is stale (`PaneControl.swift`,
  about line 59).
- Each tab's search details, its closed-tab stamps, and whether the applet counts as running something.
- Applet internals, such as a terminal tab's PID, its OSC 7 directory, and its ssh or mosh detection
  (`TerminalApplet.swift`, about lines 33-73), or a browser tab's committed URL, security warning, and owning grant
  (`BrowserTab.swift`, about lines 195-221; `BrowserApplet.swift`, about line 87).

The project's rules say hidden state flow must be raised as an explicit decision whenever it turns up. Finding it today
means reading code or adding logging. An inspector makes it visible in the running app.

Scripts see a slice of this already through `list-panes` (`WindowScripting.swift`, about lines 115-166). The user has
no equivalent.

## Design Decisions (Settled)

### A floating panel

Decision: the inspector is one app-wide floating panel, not an applet in a pane and not a popover. Chosen by the user on
2026-11-22.

- It floats above uniterm's windows and never takes key status from the pane it inspects. A window that resigns key
  tells its terminal surfaces they lost focus (`GhosttySurfaceView.swift`, about lines 178 and 548). A program that
  watches focus reports, such as an editor that saves on focus loss, would then act.
- Since the panel is never key, keys typed while it is in front still reach the key window. Cmd-C always copies the
  key window's selection. Only pick mode installs an app-level key monitor, and only for Esc.
- It opens from a Window menu item and a palette command, registered as an app-scoped command like Show Controllers
  (`StandardCommands.swift`, about lines 150-157).
- AppDelegate owns it, as it owns the Controllers window (`AppDelegate.swift`, about lines 849-865).

Rationale: an applet would take a pane and change the layout it inspects. A popover closes as soon as focus moves, so
it cannot follow focus.

### The panel follows focus, and a target button picks

Decision: by default the panel shows the focused pane of the most recently key main window, and it moves as focus
moves. A target button enters pick mode. A click on a pane or on a tab in a tab bar picks it, and picking turns off
focus following. A follow toggle turns following back on. Chosen by the user on 2026-11-22.

- The target is held by window and node ID, never by a path or an index. A picked pane that closes shows as gone. The
  panel never moves to another pane on its own, since node IDs are never reused (ADR-02).
- Following uses `WindowSet`'s key-window order (`WindowSet.swift`, about lines 229-254), so the panel keeps its target
  while the app is in the background.
- Esc leaves pick mode without picking.
- Picking needs a point-to-pane and point-to-tab hit-test. None exists today. Focus follows the first responder instead
  (`PaneAreaView.swift`, about lines 302-328).

### Pane first, then every tab

Decision: the panel shows pane-level data, then one section per tab. The tab that is selected, or the one picked, is
expanded. The others are collapsed. Chosen by the user on 2026-11-22.

Rationale: inspecting a background tab must not require selecting it, since selecting it changes what is inspected.

### What the panel shows

Decision: contract fields come first. They are the priority. Hidden state is shown raw on purpose, as a goal of the
feature. Chosen by the user on 2026-11-22.

Pane level:

- From the window: window number, node ID, whether the pane is focused, the access mode, the driver kind, the control
  generation, the owning group and its owner, and every controller `controllers(of:)` reports, each with its run's
  identity when it has one (`MainWindowController+Control.swift`, about lines 50-78). A plain script with no run and
  a driver have no verified identity
- From the applet contract: type ID, title, status segments, `isRunningSomething`, `runningLabels`, `unsavedWork`,
  `currentDirectory`, and `closedTabStamps`
- The description: type, version, the payload, the undo-only part, and the verbatim bytes of a pane that could not be
  restored. `AppletDescription`'s Codable form drops the last two, so the panel encodes each part itself

Tab level:

- ID, title, details, and whether it is selected
- Markers, once UTERM-041 adds them (M5)

Titles, details, directories, labels, segments, controller names, payloads, and applet sections are untrusted text,
since a program may set them. How the panel draws them is open, per "Drawing untrusted text raw".

### One snapshot, and scripts see a fixed subset

Decision: one snapshot type holds everything the panel shows. `list-panes` builds on it and projects a fixed set of
fields, which are today's fields. It keeps its ReadAccess gate, its per-caller and per-window scoping, and its
`reported` handling of untrusted text. A field the snapshot gains does not reach scripts without its own decision.
Chosen by the user on 2026-11-22.

Rationale: two builders for the same reads would drift. Passing every snapshot field to scripts would silently widen
what an approved controller may read, which ADR-14 P8 and P10 forbid.

- Skew: `list-panes` output is unchanged, so no wire changes. A field added later lands in place while ScriptWire is at
  0, after UTERM-063 M2, and is a new ScriptWire version from version 1, per ADR-13 P1 and C1. Amended 2026-11-27; see
  Decision Log.

### Refreshing

Decision: the panel updates at once on announced changes: focus, title or segments, tabs, and control. While it is
visible, it also rereads its target about once a second, coalesced into one read per turn. Nothing runs while it is
hidden. Chosen by the user on 2026-11-22.

- Today's change hooks are per window, through `PaneStatusHost` and `MainWindowController`'s callbacks
  (`MainWindowController.swift`, about lines 296-310 and 1443-1459). Control changes have no event, only
  `refreshControlMarks()` (`MainWindowController+Control.swift`, about lines 180-221). The panel needs one app-level
  feed that carries all of them.
- The poll covers description changes, which announce nothing.
- Reading the snapshot is a local main-thread read and changes nothing. It never sends a lifecycle event (ADR-05). It
  never runs a program and never touches an inert restored pane beyond reading it (ADR-03).

### Every applet publishes its own section

Decision: the applet contract gains optional members that publish applet-specific internals as labeled sections, one
for the pane and one per tab, per "Where applet sections draw". They default to empty. Every applet type implements
them, in M4. Chosen by the user on 2026-11-22. Amended 2026-11-22; see Decision Log.

- Each applet publishes only what it already holds, and the member is a synchronous read. Every value M4 lists is
  already in memory (`TerminalApplet.swift`, about lines 33-73; `BrowserTab.swift`, about lines 195-221;
  `BrowserApplet.swift`, about line 87). A future section that needs outside work, such as a foreground-process lookup,
  brings its own decision.
- uniterm does not reach into an applet's internals itself (ADR-05).
- The member does not throw. Every listed value is a plain in-memory read with no failing case. A section that can
  fail arrives with the decision that brings its outside work.

The user asked for this in a separate milestone if it was much work, and folded in otherwise. It is a contract change
with one implementation and one set of checks per applet type, so it is its own milestone.

### Drawing untrusted text raw

The panel shows hidden state raw, on purpose. Program-set text can still hold bidirectional overrides such as U+202E,
newlines, and control characters. A title or payload string could then draw a fake line, such as a forged key
fingerprint, beside real identity data. `list-panes` and the status bar bound such text with `StatusText.bounded`
(`StatusText.swift`, about lines 5-12). The candidates were:

- Show the text raw, but draw control and bidirectional scalars as visible escapes, such as `\u{202E}`. Nothing is
  hidden, and nothing reorders or breaks a line. `LaunchApprovalText.escaped` already does this
  (`LaunchApprovalText.swift`, about lines 46-67), and the Controllers window uses it for controller names.
- Draw each field in its own cell as plain text. A spoof stays inside its cell, but reordering still applies within it.
- Apply `StatusText.bounded`, as the status bar does. It drops what the user came to see.

Decision: both defenses together. Each field draws in its own cell. Its label, such as "Fingerprint", is drawn by the
panel in a cell no program text reaches. Each value is escaped with `LaunchApprovalText.escaped`, which also escapes
zero-width and other default-ignorable scalars such as U+200B and U+FEFF once its filed bug is fixed. Decided
autonomously on 2026-11-22.

- Escaping alone still lets a long title wrap into what looks like a line of its own. Cells alone still reorder text and
  break lines inside a cell. Each covers the other's gap.
- Escaping drops no scalar, so what the panel draws maps back to the exact text. The helper doubles backslashes, so a
  program's own `\u{...}` reads apart from one the panel added. Only the per-field cap shortens a value, and it says so.
- A JSON payload is escaped exactly once. The panel escapes each key and string value, not the encoder's output, so a
  newline shows as one escape and not as `\\n`.
- The panel calls the shared helper, so one escape set serves every window that shows program text. The helper's
  missing zero-width escapes are `bugs/20261122-approval-text-leaves-zero-width-scalars-raw.md`. M2 lands after that
  fix. Amended 2026-11-22; see Decision Log.

### What a pick click does

The candidates were:

- The click only picks. The pane under it gets no click and no focus, as an eyedropper takes no click from the app
  beneath it. A click on a window that is not key must not activate it either.
- The click picks and also focuses the pane, but sends nothing to the applet.

Decision: the click only picks. The pane under it gets no event and no focus. A click on a window that is not key does
not make it key or bring it forward. Decided autonomously on 2026-11-22.

Rationale: inspection must not change what it inspects. Focusing would make the pane's "focused" field always read
true, and the prior focus would be lost. A pick in another window would make that window key. The window that resigns
key then sends its terminals a focus-out (`GhosttySurfaceView.swift`, about lines 548 and 597). That is the case the
floating panel exists to avoid.

- Pick mode swallows the whole click, not only the mouse-down. `GhosttySurfaceView.mouseUp` forwards a release to the
  terminal with no check for a press (`GhosttySurfaceView.swift`, about lines 639-646). A program with mouse reporting
  on would otherwise get a release with no press.
- Pick mode runs only while the app is active, since the panel hides when the app is inactive.

### A cap for raw payloads

A description payload can be large, such as a map's pins or a data viewer's table state. The candidates were:

- Show it whole, in a scrolling, lazily drawn text view. M2 already redraws nothing when a poll reads no change.
- Cap what the panel draws, such as at 256 KB, and say how much was cut.
- Cap what the panel draws, and bound what the poll reads: the poll rereads only cheap fields, and a Refresh control
  rereads the description.

The browser's undo part is the large case. It holds each open tab's WebKit interaction state, and up to 20 closed tabs'
states, as base64 with no size cap (`BrowserDescription.swift`, about lines 40-72).

Decision: the panel caps each field, such as at 256 KB, and says how many source bytes it cut. The cap bounds the
panel's own work, not only what it draws. The panel cuts before it encodes a field to text and escapes it. It cuts on a
scalar boundary and never inside an escape. The poll still reads the whole description, as "Refreshing" settles.
Decided autonomously on 2026-11-22.

- The poll's read adds no new kind of cost. The host already calls `describe()` and compares descriptions on the main
  thread at every applet change (`MainWindowController.swift`, about lines 1371-1373 and 1443-1444). The browser keeps
  its undo part and each tab's interaction record cached between calls (`BrowserApplet.swift`, about lines 397-414;
  `BrowserTab.swift`, about lines 427-436).
- The new cost is the panel's encoding, escaping, and layout of a field. A multi-megabyte base64 string is one line with
  no break opportunities. Without a cap, its layout time grows with WebKit's history record, which uniterm does not
  bound. ADR-08 asks for main-thread work whose duration uniterm bounds. The cap is that bound.
- A Refresh-only description read would show a stale payload as current until the user pressed it. It would also undo
  the settled "Refreshing" decision.

### Who answers a tab hit-test

Pick mode must find the tab under a click. Tab bars live inside applet views. `AppletTabBar` exposes only
`update(titles:selected:canOpenTab:)` and an index-based `onSelect` (`AppletTabBar.swift`, about lines 121-170). It
holds no `AppletTabID`. UTERM-041 M1 has `update` take published tabs, so each item carries its tab ID. UTERM-042 opens
its tab menu from a handler on the item and builds no point-to-tab query. Today the terminal, browser, and Questions
applets use the shared bar, and the host holds no reference to any of them. The candidates were:

- The host walks the view tree. Pick mode hit-tests the click, walks up to the first `AppletTabBar`, and takes the ID of
  the tab item under the point.
- The applet contract gains a `tab(at:)` call with a nil default, and each bar user forwards to its bar. A bar user that
  forgets to forward picks the pane with no error.
- The applet contract gains a required `tab(at:)`. Seven applets return nil and three forward the same way.
- The applet contract gains `tab(at:)` with an AppletKit default that does the view walk inside the applet's view. Its
  override has no current caller.
- Pick mode picks panes only. Leaves undone: picking a tab by clicking it, which the user asked for.

Decision: the host walks the view tree. Pick mode hit-tests the click and resolves the pane first. Within that pane's
applet view, it walks up from the hit view to the first `AppletTabItem`, and takes that item's tab ID. A walk that finds
no tab item picks the pane. M3 depends on UTERM-041 M1, which puts tab IDs on the items. The point-to-tab lookup itself
is M3's own work. Decided autonomously on 2026-11-22.

- Every applet that embeds the shared bar is covered with no code of its own, so no applet can forget to forward. The
  seven applets without a bar need nothing.
- It follows existing practice. The host already maps the view tree to panes (`PaneAreaView.swift`, about lines
  321-328). UTERM-041 "How the host knows the tab bar is hidden" chose enforcement in shared code over a contract member
  for the same reason: a contract leaves a future applet free to get it wrong.
- The walk reads only a shared AppletKit type and the IDs the applet already publishes. It reads none of the applet's
  work or state, so it is not the reach into internals that ADR-05 and "Every applet publishes its own section" rule
  out.
- This is an implicit flow. The host learns the tab from where an applet placed the shared bar, not from anything the
  applet declares. The project's rules ask for such a flow to be raised as an explicit decision. The user chose it at
  the review gate on 2026-11-22, over a contract member.
- One-tab panes hide their bar, per UTERM-041. A click there finds no tab item and picks the pane, whose one tab the
  panel already expands.

### A keyboard shortcut

The candidates were:

- No shortcut. The menu item and the palette command are enough for a debugging tool. The user can still bind one in
  macOS App Shortcuts, which ADR-04 lets win.
- An app-scoped chord, such as Cmd-Option-I, which browsers use for their inspector. App-scoped commands already carry
  keys (`StandardCommands.swift`). UTERM-013 decides who owns it, and the browser applet may want the chord for the
  Web Inspector UTERM-020 hides.
- An app-scoped chord on a key no browser uses for its inspector, such as Cmd-Option-P.

Decision: no default shortcut. The Window menu item and the palette command open the panel. A user who wants a key
binds one in App Shortcuts. Decided autonomously on 2026-11-22.

- The remap path works today. The reserved keys are read from the live menu after remaps, and a remap wins dispatch.
- A default chord would be a window key, reserved in every pane under ADR-04. Any later applet command on that chord
  would lose it. Cmd-Option-I is also the chord browser users press for a Web Inspector, and the macOS Inspector chord
  in Finder and Pages. A debugging tool does not earn that reservation.
- Adding a default later is free. Taking one back after users learn it is not.
- The menu item's title stays fixed whether the panel is open or closed. App Shortcuts matches items by title, so a
  Show and Hide swap would break a user's remap.

### Copying the snapshot

This adds scope. The candidates were:

- No addition. Leaves undone: the panel is never key, so Cmd-C copies the inspected window's selection, not the
  panel's text. Fingerprints stay copyable from the Controllers window, but payloads, undo parts, verbatim bytes, and
  applet sections have no copy path.
- A Copy button per field, which works without key status.
- A Copy as JSON button that copies the whole snapshot. The snapshot may hold paths, URLs, REPL history, and base64
  WebKit state the user would not paste by accident.
- Both a per-field Copy button and a Copy as JSON button.

Decision: a Copy control on each field, which works without key status. It copies the field's full raw value, not the
escaped or capped text the panel draws. Decided autonomously on 2026-11-22.

- A JSON value copies as pretty-printed JSON of that field alone. Verbatim bytes that are UTF-8 copy as that text.
  Verbatim bytes that are not UTF-8 copy as the hex text the panel shows.
- The full value can be large, such as a browser's undo part. The copy encodes it off the main thread, since the
  description's values are Sendable, then writes the pasteboard on the main thread. The main thread's work stays bounded,
  as ADR-08 asks and as the cap decision does for drawing.
- A whole-snapshot Copy as JSON has no named need. It would be a third serialization beside the panel and `list-panes`.
  A format people paste into reports becomes a format in practice, though the applet sections are meant to change
  freely. It would also copy every tab's undo state at once.
- A raw newline or control character pasted into a uniterm terminal hits the terminal's unsafe-paste prompt.
- Whether the control is a button or a menu item on the cell is UI polish, left to implementation.

### The current directory in the polled snapshot

"Refreshing" calls the panel's read a local main-thread read. `currentDirectory` is not one today. The terminal checks
the shell-reported path with `FileManager.fileExists` (`TerminalApplet.swift`, about lines 296-297), and the four
viewers check their file's folder the same way. On a dead network mount such a check never returns. The panel polls
once a second, so it would turn an on-demand hang into one that needs no action. The candidates were:

- M2 depends on a fix that makes `currentDirectory` do no blocking file-system work on the main thread, in every
  applet. The field list and "Refreshing" stay as settled.
- The poll leaves `currentDirectory` out and reads it only on retarget and announced changes. The `cd` into the mount
  is itself an announced change, so the hang stays.
- The panel drops `currentDirectory` and relies on the raw directory in a terminal tab's details. Viewers publish no
  details, so they would lose the field. It also undoes part of "What the panel shows".

Decision: M2 depends on the fix of `bugs/20261122-terminal-directory-check-blocks-main-thread.md`. That fix makes it a
rule of the applet contract that `currentDirectory` does no blocking file-system work on the main thread. The panel
shows whatever the fixed property returns, including an unknown state if the fix brings one. Decided autonomously on
2026-11-22.

- The fix is a dependency, not part of this proposal. It closes the same hang for `list-panes`, new panes, and new
  tabs. How each applet meets the rule is the bug's own design call.
- The panel does not check the path itself. That would copy applet logic into the host, which "Every applet publishes
  its own section" rules out.

### Where applet sections draw

The inspection data M4 lists is mostly per tab, such as a terminal tab's PID or a browser tab's URL. The viewers' file
and position are per pane. "Pane first, then every tab" shows each tab's data under its own section. The candidates
were:

- One member whose sections may name a tab ID. A section naming a tab the applet no longer publishes needs a rule of
  its own, such as drawing at pane level marked stale.
- Pane-level sections only. A picked background tab would expand with none of its internals in it.
- Two members: pane-level sections, and a per-tab call that takes an `AppletTabID`.

Decision: two members. One returns the pane's sections. The other takes a tab ID and returns that tab's sections. Both
default to empty, are synchronous, and do not throw. The host asks only for tabs it read from `publishedTabs` in the
same turn, so a section for a tab the applet does not publish cannot exist. Decided autonomously on 2026-11-22.

- The host can skip collapsed tabs, which bounds the poll's work.
- An applet with one tab, such as a viewer, publishes pane-level sections, and its per-tab call returns nothing.
- Sections stay off `AppletTab`. That type feeds the palette, the tab bar, and `list-panes`, and live values would
  churn its comparisons.

## Design Decisions (Open)

None.

## Risks

- **The panel shows state the user treats as private** — likelihood: medium, impact: low.
  Accepted: showing hidden state is the feature's goal, and the panel only shows the user what their own app process
  already holds. It never sends anything anywhere.
- **A snapshot field leaks to scripts** — likelihood: low, impact: high.
  Mitigation: `list-panes` projects named fields only. A test pins its exact field set, so a new snapshot field that
  reaches it fails the test.
- **Polling costs main-thread time** — likelihood: low, impact: medium.
  Mitigation: the poll runs only while the panel is visible, reads one target, and coalesces. Its `describe()` call
  is one the host already makes at every applet change, and the browser caches its costly parts. The panel's own cost
  is encoding, escaping, and laying out a field, and the per-field cap bounds it.
- **The panel takes key status through a slip** — likelihood: medium, impact: medium.
  Opening it with `makeKeyAndOrderFront`, or a selectable text view in it, would make it key. Terminal programs in the
  inspected window then get a focus-out report.
  Mitigation: an M2 check that opening, clicking, and scrolling the panel sends no focus change to the inspected
  terminal.
- **The shared tab bar changes under three proposals at once** — likelihood: medium, impact: low.
  UTERM-041 M1, UTERM-042, and this proposal's M3 all change `AppletTabBar`.
  Mitigation: M3 depends on UTERM-041 M1 and lands after it, so its lookup reads the item IDs M1 adds and never
  rebuilds them.
- **M2 waits on two bug fixes outside this proposal** — likelihood: medium, impact: medium.
  The directory-check bug's fix still needs a design call: no existence check in the property, or a cached verdict.
  No proposal or queue row owns that call yet. M2 cannot land until it is made and the fix ships.
  Mitigation: both bugs are filed with their options. M1 waits on neither, so the shared snapshot can land first.
  The queue row for M2, once scheduled, names both bugs as its blockers, so the wait shows where the work is planned.
- **A pick click still raises or keys the window under it** — likelihood: low, impact: medium.
  The design relies on an app-level event monitor dropping the click before the window handles it. The window server
  might reorder windows on a mouse-down before that.
  Mitigation: M3's UI test observes it. If it fails, pick mode places a transparent window that never becomes key or
  activates just above each main window, and that window takes the click. Where two uniterm windows overlap, the
  click picks the front one.
- **The inspection member becomes a contract every applet must keep** — likelihood: high, impact: low.
  Accepted: the member is optional with an empty default, and its sections are for display only. Nothing parses them,
  so a section's shape can change freely. It is not a wire.

## Milestones

### M1: The shared snapshot

**Status:** NOT STARTED

- One snapshot type holds a pane's window state, its contract fields, its description, and its tabs
- `list-panes` builds its records from the snapshot, and its output is unchanged for every existing test and fixture
- A test pins the exact field set of a `list-panes` pane record and tab record
- `list-panes` performs no read its projection does not use, so a pane the caller is not shown gets no directory or
  controller read
- Building a snapshot sends no lifecycle event and changes no applet state
- The snapshot holds tab IDs, not script tab numbers. `list-panes` maps IDs to numbers when it projects, and a panel
  read mints no script tab number
- `list-panes` reads no description and no applet section

### M2: The panel, following focus

**Status:** NOT STARTED

- A Window menu item and a palette command open and close the panel, and the item's title does not change between
  the two states
- No default key opens the panel, and an App Shortcuts remap of the menu item opens it with a terminal or a web view
  focused
- Each field's Copy control puts the field's full raw value on the pasteboard in the form "Copying the snapshot"
  settles, and tests write to an injected pasteboard, never the general one
- Copying the largest field keeps its encoding off the main thread
- Only the latest Copy writes the pasteboard, and a copy whose encoding finishes after the pasteboard changed writes
  nothing
- The target is held by a window identity that is never reused in a launch, not by the window server's number
- The panel floats above uniterm's windows and never takes keyboard focus from the inspected pane
- It shows the focused pane of the most recently key window, and it moves when focus moves, within a window and across
  windows
- It shows every pane-level and tab-level field in "What the panel shows", with the selected tab expanded
- The description's payload, undo-only part, and verbatim bytes each show raw
- Each controller the pane lists says what kind it is. A run shows its verified identity. A plain script or a driver is
  never labeled verified, and a descriptor's display name is shown as the controller's claim
- A title, segment, tab, or control change shows in the panel on the same turn
- A description change with no announced event shows within about one second while the panel is visible
- A target whose directory sits on a mount that does not answer leaves the main thread free, and the panel shows what
  the fixed `currentDirectory` returns, including any unknown state
- A poll whose read is unchanged redraws nothing
- No poll runs while the panel is hidden, including when it hides because the app is inactive
- Verbatim bytes that are not UTF-8 show as hex
- Each field draws in its own cell under a label the panel draws, and a program-set newline, bidi override, control
  character, or zero-width scalar in any value draws as a visible escape
- A raw U+202E or newline in a payload key or string value draws as a single escape, not a doubled one
- A quote or backslash inside a payload key or string value cannot read as a JSON delimiter
- The panel reaches the shared escape helper without a second copy of its escape set, and joined scalars such as
  U+200D in an emoji title draw as the fixed helper draws them
- A field over the cap takes time bounded by the cap to show, and the panel says how many bytes it cut
- Opening, clicking, scrolling, and pressing a Copy control in the panel sends no focus change to the inspected
  terminal
- The panel shows over a full-screen uniterm window
- A UI test captures the panel beside a terminal pane and a browser pane with two tabs

### M3: Pick mode

**Status:** NOT STARTED

- The target button enters pick mode, and the pointer shows it
- A click on a pane picks it, and a click on a tab in a tab bar picks that tab and expands it
- Picking turns off following, and the follow toggle turns it back on and shows the focused pane at once
- A pick on a tab in a scrolled tab bar, on its marker, or on its close button picks that tab
- A pick resolves the pane first, and the tab it reports belongs to that pane
- AppletKit exposes one function that maps a hit view to a tab ID, so the host never names the tab item type
- A click on the panel itself during pick mode reaches the panel, and a click on a window that holds no pane picks
  nothing
- No pointer motion or scroll reaches a terminal with mouse reporting on, or a web page, while pick mode is on
- If the overlay fallback is built, each overlay takes clicks over its clear pixels, joins a full-screen window's Space,
  stays below the panel, follows its main window's frame and order, and stays out of the Window menu
- A picked tab ID the applet no longer publishes shows as gone, as a closed tab does
- Esc leaves pick mode without picking, and the focused applet receives no key
- Pick mode swallows every mouse-down, right-clicks included, so no tab menu or applet action runs
- Pick mode also swallows the drag and mouse-up of the click that picks, so a terminal with mouse reporting on gets no
  release
- A pick click focuses nothing, and a pick click on a window that is not key leaves it unkeyed and behind, as a UI test
  observes
- The pick pointer stays shown while it crosses terminal and web views
- Pick mode ends when the app deactivates, the panel closes, or the window under the pointer closes
- A picked pane that closes shows as gone, and the panel does not move to another pane
- A picked tab that closes while its pane stays shows as gone, and the pane stays shown
- A pick in another uniterm window works the same way
- A UI test picks a background tab and shows it expanded without selecting it in its pane

### M4: Per-applet inspection

**Status:** NOT STARTED

- The applet contract has a pane-level member and a per-tab member for inspection sections, each with an empty default
- Every applet type publishes what it holds. The terminal shows each tab's PID, start time, OSC 7 directory, remote
  client, and exit code. The browser shows each tab's current and committed URL, security warning, load state, load
  origin, error page, and owning grant. The viewers show their source file and their position in it, at pane level.
  The REPL, Questions, launcher, and placeholder applets each publish a section of what they already hold, with at
  least one value the panel shows nowhere else, such as the placeholder's reason or the REPL's phase and helper process.
  The As built block names each one's fields
- Sections are Sendable, so Copy can encode them off the main thread, and Equatable, so an unchanged poll redraws
  nothing
- A collapsed tab whose sections the poll skipped shows them on the same turn it is expanded
- Per-tab sections draw inside their tab's section, and pane-level sections draw with the pane's data, in cells, escaped,
  capped, and copyable like every other field, and the poll redraws them
- The per-tab call given an ID the applet does not hold returns nothing and never traps
- The panel never asks for the sections of a picked tab that is gone
- Reading a section is synchronous and starts no outside work
- `list-panes` output does not change

### M5: Markers

**Status:** NOT STARTED

- The snapshot carries each tab's markers, with their kind and actions, once UTERM-041 M1 adds them
- The panel shows them in each tab's section
- `list-panes` output does not change

## Decision Log

- 2026-11-22: Filed as a draft. The user chose a floating panel, following focus with a target pick button, contract
  fields first, hidden state shown raw, one snapshot with a fixed script subset, events plus a slow poll, every tab
  shown, and a section from every applet type.
- 2026-11-22 (addition): moving `list-panes`'s builder onto the shared snapshot changes UTERM-003's script path, which
  the Summary does not name. The user chose the shared snapshot with a fixed script subset.
- 2026-11-22: "Every applet publishes its own section" amended. It said a section needing outside work is read off the
  main thread and shows as pending. Every listed value is already in memory, so that path had no caller and
  contradicted "publishes only what it already holds". The member is now a synchronous read. Its rule "A section that
  fails shows as errored. It never ends the panel or the app" is dropped too, since no in-memory read can fail. The
  member does not throw.
- 2026-11-22: the critique added "Who answers a tab hit-test" and "Drawing untrusted text raw" as open questions. The
  first has no owner in the design. The second weighs the raw-display goal against spoofed lines near identity data.
  The Motivation now credits the Controllers window with showing run identity. What is missing is the link from a pane
  to its runs.
- 2026-11-22: Review start: 5 milestones, 7 settled decisions, 6 risks, no `**Live after:**` lines or row gates; no
  explicit out-of-scope statements beyond `list-panes` gaining no new fields; 6 open questions. The user asked for an
  autonomous review of the proposal as filed in "File UTERM-048: a floating Pane Inspector for pane and tab state".
- 2026-11-22 (autonomous): "Drawing untrusted text raw" settled as per-field cells with panel-drawn labels, values
  escaped as `LaunchApprovalText.escaped` does, plus default-ignorable scalars. Converged in 1 pass.
- 2026-11-22 (autonomous): "What a pick click does" settled as a click that only picks, focusing and activating
  nothing. Converged in 1 pass.
- 2026-11-22 (autonomous): "A cap for raw payloads" settled as a per-field cap that bounds the panel's encode, escape,
  and layout, with the poll unchanged. Converged in 1 pass. The poll's `describe()` cost already exists at every applet
  change, so the bounded-poll option guarded nothing new.
- 2026-11-22 (autonomous): "Who answers a tab hit-test" settled as a host view walk to the tab item under the click,
  within the resolved pane. Converged in 2 passes. M3 now depends on UTERM-041 M1. The question's claim that UTERM-042
  builds a point-to-tab mapping was wrong and is corrected. The view walk is an implicit flow, so the review gate asks
  the user about it.
- 2026-11-22 (autonomous): "A keyboard shortcut" settled as no default key, with App Shortcuts as the path to one.
  Converged in 1 pass.
- 2026-11-22 (autonomous, addition): "Copying the snapshot" settled as a per-field Copy control that copies the full
  raw value, encoded off the main thread. It brings in a pasteboard write from the panel. Converged in 1 pass.
- 2026-11-22 (autonomous): coherence review. "Drawing untrusted text raw" amended. It said the panel keeps its own
  wider escape set and the shared helper's widening is filed apart. Two sets would drift, so the panel now calls the
  shared helper and M2 lands after `bugs/20261122-approval-text-leaves-zero-width-scalars-raw.md` is fixed. Its
  "lossless" bullet now says escaping drops nothing and only the cap shortens a value.
- 2026-11-22 (autonomous): coherence review. Added Impacts for UTERM-041's marker placement, UTERM-026's Pop Out Pane,
  and UTERM-043's suspended state. Added a risk that a pick click still raises a window, with an overlay fallback.
  Routed checks to M1 (no unused reads in `list-panes`), M2 (Copy ordering, a never-reused window identity), and M3
  (one AppletKit hit-test function, clicks on the panel and on paneless windows, no motion or scroll to the content).
- 2026-11-22: Filed `bugs/20261122-terminal-directory-check-blocks-main-thread.md`. The terminal's `currentDirectory`
  stats a program-chosen path on the main thread, and the panel's poll would read it once a second.
- 2026-11-22 (autonomous): the coherence review added two open questions: the directory check in the polled snapshot,
  and where per-tab applet sections draw.
- 2026-11-22: Widened `bugs/20261122-terminal-directory-check-blocks-main-thread.md` to the four viewers and to the
  callers it missed.
- 2026-11-22 (autonomous): "The current directory in the polled snapshot" settled as a dependency of M2 on that bug's
  fix, as a contract rule for every applet. Converged in 1 pass.
- 2026-11-22 (autonomous): "Where applet sections draw" settled as two members, pane-level and per tab. Converged in 1
  pass. The review first leaned to one member whose sections name a tab ID. It needed a rule for a section naming a tab
  the applet no longer publishes. Two members make that state impossible. "Every applet publishes its own section"
  amended: it said "an optional member", and now says one member for the pane and one per tab. Its substance stays.
- 2026-11-22 (autonomous): re-check pass 1 found two defects in this review's own changes. The UTERM-043 Impact
  promised a suspended-state field that nothing builds. It now says the panel does not show it. M4 let four applet
  types keep the empty default, against "a section from every applet type". It now requires a section from each. The
  overlay fallback is now a separate never-key window, since a subview cannot stop its own window from rising. Routed
  checks to M2 (JSON delimiters, one escape set, joined scalars) and M4 (Sendable and Equatable sections, expanding a
  skipped tab).
- 2026-11-22 (autonomous): risk review. Added the risk that M2 waits on two bug fixes, one of which still needs a
  design call. Mitigated by M1 not waiting on either, and by M2's queue row naming both as blockers. No
  one-way doors: every change is in-process, and a redeploy reverts it.
- 2026-11-22 (autonomous): re-check pass 2 converged. Routed checks to M3 for the overlay fallback, if built, and to M4
  for a value each of the four added sections shows nowhere else.
- 2026-11-22: Review gate: kept all. The user chose the host view walk for the tab pick, as an explicit decision on its
  implicit flow, and kept the per-field Copy addition.
- 2026-11-22: ADR candidate (cuts across the system): `currentDirectory` does no blocking file-system work on the main
  thread. Declined: applies ADR-08.
- 2026-11-22: ADR candidate (cuts across the system): a field the shared snapshot gains reaches scripts only by its own
  decision. Declined: applies ADR-14 P8 and P10.
- 2026-11-22: ADR candidate (cuts across the system): program-set text is drawn escaped wherever it sits beside trusted
  UI. Declined: the status bar drops such text instead, so the rule does not hold for every member.
- 2026-11-22: Accepted by the user.
- 2026-11-22: Scheduled as UTERM-048 M1 and UTERM-048 M2-M5 in queue.md.
- 2026-11-23: From UTERM-056's acceptance. The skew line said "ScriptWire's two sides ship together in any case (ADR-13)",
  which holds only for the command's own messages.
- 2026-11-27: From UTERM-063. Amended "Skew". It said "A field added later is a new ScriptWire version, per ADR-13 P1."
  ScriptWire is at 0, so a field added later lands in place after UTERM-063 M2, with no new version.

## References

- ADR-02: node IDs are stable and never reused, so a picked target cannot resolve to another pane
- ADR-05: applets own what their content means, so each publishes its own inspection section
- ADR-08: refreshes stay bounded on the main thread
- ADR-14: P8 and P10 bound what `list-panes` may expose
