# UTERM-002: Command Palette

**Status:** implemented
**Created:** 2026-10-31
**Updated:** 2026-11-26

## Dependencies

- UTERM-001

## Impacts

- UTERM-001 — "How applets publish tabs": the applet contract gains a tab list, a change signal, and tab IDs
- UTERM-001 — "Command source": every key binding, including those of M1, M2, M5, and M7, moves onto the command
  registry, except the standard edit actions
- UTERM-003 — "How applets publish tabs": the scripting API may expose the same entries and tab IDs
- UTERM-003 — "Command source": scripts may invoke registry commands and register their own, on the main thread
- UTERM-005 through UTERM-010 — "How applets publish tabs" and "Applets without tabs": every applet publishes at least
  one tab. Image, map, and canvas applets publish one tab for their whole session, with the per-tab duties the
  contract carries

## Summary

Each window gets a command palette region. The palette can float or dock. It finds and jumps to any tab of any applet
in the window, and runs commands.

## Motivation

A window can hold many panes, and each applet can hold many tabs. Finding one by eye gets slow. A palette gives one
keyboard path to every tab and every command.

## Design Decisions (Settled)

### The palette is a region

The palette is a region, as defined in UTERM-001. Its role is fixed. Its mode and position are settings.

### Two modes

- **Floating.** Hidden by default. A hotkey shows it over the window. It takes focus while shown.
- **Docked.** Always visible at the top or the bottom of the window. It does not take focus until the hotkey activates
  it.

### Applets publish their tabs

Applets make their tabs findable in the palette. Choosing an entry focuses that pane and switches to that tab. When a
tab closes, its entry disappears.

### Commands

The palette also runs commands, such as split pane, close pane, and new window. Commands and tabs share one search.

### How applets publish tabs

Original question: register and unregister calls, the palette querying applets when it opens, or an observable model
the palette subscribes to?

Decision: a live query from the pane tree.

- The applet contract gains a current tab list and a change signal. Each tab descriptor carries a tab ID, a title, and
  detail fields such as a working directory.
- A tab ID is never reused, even across a relaunch, so a stale ID never resolves to a different tab. Tab IDs are not
  persisted. Amended 2026-11-01; see Decision Log.
- The palette walks the window's pane tree for its entries. While it shows, it re-reads a pane's list on that pane's
  change signal. It re-walks the tree on the content area's layout-change signal, the same one layout persistence
  saves on.
- An entry targets a pane by its stable pane ID, per ADR-02, and a tab by its tab ID. Never by a row, tree path, or tab
  index.
- Choosing an entry whose pane or tab is gone changes nothing else. It refreshes the list and posts a status message.
- Every pane in the tree is on screen. A closed pane is out of the tree, so its tabs do not appear. Amended 2026-11-02;
  see Decision Log.

Rationale: the applet's own state is the only source, so nothing can go stale and nothing needs unregistering. A query
on open breaks "when a tab closes, its entry disappears" in docked mode, where the palette may stay active for a long
time. Register and unregister keeps a second copy of tab state that drifts when a pane is torn down on an error path.
An observable model is one way to build the change signal, not a separate design. A per-pane signal alone cannot
report a pane created while the palette shows, such as by a split or an undo, so the layout-change signal covers that.

This extends UTERM-001's applet contract. UTERM-001 expected the contract to change when a second consumer arrived.

### Command source

Original questions: whether commands are declared in Swift only, or also in Janet once UTERM-003 lands; and whether
the palette should eventually call the Janet API for every command.

Decision: a uniterm command registry in Swift, shared by the palette and uniterm's key bindings. Amended 2026-11-02;
see Decision Log.

- Each command has a stable ID, a title, a run action, and an availability check.
- A command targets the pane that had focus before the palette activated, the same pane Escape returns to. It never
  targets the palette itself.
- A run action is synchronous and runs on the main thread. An action may start UI, such as the applet chooser or a
  close confirmation, and return before the user answers.
- A key binding and its palette command run the same registry action. Outside the palette's field, Cmd-W and the
  palette's close command behave the same, including UTERM-001's close confirmations. UTERM-001's key bindings move
  onto the registry, except the standard edit actions.
- The standard edit actions are not registry commands. Cut, copy, paste, select all, undo, and redo stay responder-chain
  items, per UTERM-013. A registry command would act on the pane, not on a find field or address bar inside it.
- While the palette's search field has focus, text-editing chords go to the field: cut, copy, paste, select all, undo,
  and redo. This follows UTERM-001's rule that Cmd-Z in a focused text control undoes the edit.
- A key, a menu item, and the palette all reach a command's action through one dispatch point in the window. It applies
  the palette's rules below, so a key and a menu item chosen with the mouse cannot differ.
- This proposal builds Swift commands only. The palette runs commands through the registry, never through the Janet
  API.
- UTERM-003 may invoke registry commands, and may register its own. That work belongs to UTERM-003. A Janet caller
  hops to the main thread to run an action.

Rationale: one run action per command keeps the palette from drifting from the key binding's meaning, such as Cmd-W
closing a tab rather than the pane. Routing every Enter through Janet would tie the palette to a VM whose thread model
UTERM-003 has not settled. It runs under a watchdog, and UTERM-004's control levels would gate built-in commands
meant for the user. Declaring Janet commands here would make this proposal wait on a draft.

Leaves undone: this proposal does not make app menus read the registry. UTERM-013 does that, and adds a default key
and a menu home to each entry.

### Hotkey default

Superseded in part by UTERM-014; see Decision Log.

Original question: the default hotkey for each mode.

Decision: Cmd-Shift-P for both modes. One action, "activate the palette", toggles it.

- In floating mode it shows the palette, and pressing it again hides it.
- In docked mode it focuses the palette, and pressing it again unfocuses it.
- Hiding or unfocusing returns focus to the pane that had it before activation.

Rationale: macOS terminals never pass Cmd chords to the pty, so a Cmd chord cannot collide with a terminal program's
shortcut. Cmd-Shift-P is free among UTERM-001's bindings and matches VS Code, Sublime Text, and Ghostty's own palette.
Cmd-K is clear screen, which UTERM-001 binds. Cmd-P breaks the Print convention. A hotkey per mode would make users
relearn it when they switch modes. The macOS Page Setup convention on Cmd-Shift-P does not apply, since uniterm has no
print path.

### Hotkey configurability

Superseded in part by UTERM-014; see Decision Log.

Original question: whether the hotkey is configurable in this proposal.

Decision: the palette action is a menu item with a fixed title, "Show Command Palette", and Cmd-Shift-P as its key
equivalent. Users rebind it through System Settings > Keyboard > App Shortcuts, which remaps a menu item by its title.
No in-app binding setting is built here. General key-binding customization would be its own proposal. Amended
2026-11-01; see Decision Log.

Constraint: the palette's key equivalent must reach uniterm before a focused terminal surface takes the key. ADR-04
already clears libghostty's own bindings. Every uniterm binding except the standard edit actions runs a registry
command, per "Command source". Whether a binding is delivered as a menu key equivalent or by a key handler is an
implementation detail. Either way it must not shadow a user's App Shortcuts remap without the user seeing it in the
menu.

Rationale: it follows the platform convention and is discoverable from the menu bar. It builds no settings surface. A
recorder for this one shortcut would need a collision check that knows every uniterm binding, including later ones, and
would drift when bindings are added. A general binding system adds scope well past the palette.

Leaves undone: there is no in-app rebinding. A remap onto another uniterm binding, or onto a Ctrl or Option chord a
terminal program uses, gets no collision warning.

### Search scope

Original question: whether the palette searches only the current window, or every window.

Decision: the current window only. The palette lists the tabs of its own window's pane tree. Reaching a tab in another
window means switching windows first, such as with Cmd-`.

Rationale: the Summary scopes the palette to "any tab of any applet in the window", and the publishing decision walks
the window's pane tree. Searching every window would be a scope addition. It would need an app-level window-list
signal, so that a window closing behind the palette drops its entries. It would also need a window identity that
UTERM-001 does not define. This choice is not a one-way door. A later proposal can add a window identity to each entry.

Leaves undone: no cross-window tab search.

### Ranking

Original question: how results rank, by fuzzy match, recency, or both.

Decision: both, with match quality first.

- A fuzzy subsequence match filters and scores entries over titles and detail fields. A title match outranks a match
  only in detail fields.
- Recency breaks ties and adds a bounded boost. The bound keeps a strong match above a weak recent one.
- An empty query lists tabs by most recent focus, then commands by most recent run. Entries with no recency follow:
  tabs in tree order, commands alphabetically.
- Recency is kept in memory for the life of the process and is never persisted. Command recency is one list for the
  app.
- Each entry shows whether it is a tab or a command.

Rationale: jumping back to a recent tab is the main use, and recency serves it without letting a recent weak match
win. Recency alone ranks a recently run "Close Window" above an exact "Close Pane". Fuzzy alone buries the tab the
user just left. Persisting command recency would add a stored contract read across app versions, with no failure it
fixes. Tab IDs do not survive a relaunch anyway. Programs set tab titles, so a tab titled "Close Window" must not pass
for a command.

### Other key bindings while the palette's field has focus

Original question: text-editing chords go to the field. What do the other registry bindings do while the field has
focus, such as Cmd-W, Cmd-T, or Cmd-D?

Decision: Cmd-W dismisses the palette. Every other binding except the palette's toggle dismisses it, then runs as if
it had not been open.

- Cmd-W hides a floating palette and unfocuses a docked one. Focus returns to the pane that had it before activation.
  This is a dispatch rule, not a command aimed at the palette.
- The palette's own toggle hides or unfocuses it, per "Hotkey default", and runs nothing else.
- Any other registry binding dismisses the palette the same way, then runs its action on the pane that had focus
  before activation.
- When that pane is gone, a pane-scoped binding posts a status message instead of acting on another pane.

Rationale: users press Cmd-W to dismiss what is in front. Running close instead would remove the current tab, and a
tab close at an idle prompt neither asks nor undoes. Consuming every binding would make Cmd-Q, Cmd-N, and Cmd-, do
nothing while the field has focus. Running bindings while the palette stays focused would make it compete for focus
with the applet chooser and close confirmations.

### Applets without tabs

Original question: an applet with no tabs, such as a later image viewer, would publish an empty list, and its pane
could never be reached from the palette. Should every pane be reachable, and how?

Decision: the applet contract requires at least one tab. An applet with no switchable sessions publishes one tab that
stands for its whole session, with its own tab ID, title, and detail. An empty tab list cannot be represented.

Rationale: UTERM-001's program-mode terminal already works this way, with one tab and no new-tab action. "Closing an
applet's last tab is a pane close" and the hidden one-tab bar then apply unchanged. The palette and UTERM-003 need no
second entry kind. Listing panes beside tabs would show every single-tab pane twice. Listing only tabs would leave
some panes unreachable, against the Motivation.

### Default mode and dock edge

Original question: which mode is the default, and which edge a docked palette uses by default.

Decision: floating by default. A docked palette defaults to the top edge. Mode and edge are two plain settings. When a
docked palette and the status bar share an edge, the status bar is outermost, at the window edge, and the palette sits
inward, next to the content. Amended 2026-11-02; see Decision Log.

Rationale: floating costs no window space, and the write-up asks for as much space as possible. A top edge matches
the palette and omnibox convention. Making the palette follow the status bar's edge would couple two settings and
need a third "auto" value. The stacking order covers a palette and a status bar on the same edge, whatever the status
bar's default is. The palette sits inward so that its results open from the panes' edge and stay beside the panes they
cover.

### What an inactive docked palette shows

Original question: what a docked palette shows while inactive, and where its results list appears when it activates.
A list that grows the region resizes the content area, which resizes every terminal in the window.

Decision: while inactive, a docked palette shows a one-line field whose placeholder names the hotkey. On activation,
the results list appears as an overlay anchored to the field, drawn over the pane content. The content area keeps its
size. A click outside the field and the overlay deactivates the palette. The press is then delivered to the view under
it, so a terminal that reports the mouse to its program receives it, and that view takes focus as it would for any
click. A click on something that takes no focus returns focus to the pane that had it before activation. Switching the
mode or the edge while the palette is active deactivates it and returns focus to that pane. Amended 2026-11-02; see
Decision Log.

Rationale: growing the region would resize every terminal on each activation and deactivation. vim redraws, shells
reprint prompts, and scrollback reflows. It could also push panes below their minimum size. An overlay keeps search
the same as in floating mode, as M3 requires. A strip of recent tabs would either re-sort on every focus change or go
stale, and it would keep program-set titles on screen as click targets. An always-visible list takes rows from every
window.

## Design Decisions (Open)

## Risks

- **The palette hotkey collides with a shortcut in a terminal program** — likelihood: low, impact: medium.
  Mitigation: the default is a Cmd chord, which macOS terminals never pass to the pty. The hotkey is a window-level
  shortcut, not a system-wide one. A user remap onto a Ctrl or Option chord can still collide, and gets no warning.
- **Stale tab entries after an applet crashes** — likelihood: low, impact: low.
  Mitigation: entries come from a live query of the pane tree, so a torn-down pane takes its entries with it. An entry
  whose target is gone refreshes the list instead of acting.
- **The default hotkey becomes muscle memory** — likelihood: high, impact: low.
  Accepted: Cmd-Shift-P matches the common palette convention, so a later change is unlikely to be wanted.
- **The menu item title is a contract for users' App Shortcuts remaps** — likelihood: medium, impact: low.
  A rename, or a localization, silently drops every remap. Mitigation: the title is fixed and does not change with the
  palette's state. A rename is a deliberate change noted in release notes.
- **UTERM-003 calls the main-thread registry from a Janet thread** — likelihood: medium, impact: medium.
  UTERM-003's thread model is open. A Janet thread that blocks on a main-thread action, while the main thread waits on
  Janet, would deadlock or stall the UI. Mitigation: run actions and availability checks never wait on Janet. Run
  actions return once any UI they start is shown. UTERM-003 must settle how a script awaits an action without
  blocking the main thread, and how a Janet-registered command reports availability without the main thread waiting.
- **Moving UTERM-001's built key bindings onto the registry is rework** — likelihood: medium, impact: low.
  UTERM-001 is queued first, so its bindings exist before this proposal starts. Accepted: M1 moves them, and
  UTERM-001's binding checks still pass after the move.
- **A program-set tab title passes for a uniterm command** — likelihood: medium, impact: medium.
  Mitigation: each entry shows its kind. Titles and detail fields show with control and bidi characters neutralized.

## Milestones

### M1: Floating palette with commands

**Status:** DONE

Superseded in part by UTERM-014; see Decision Log.

Amended 2026-11-01; see Decision Log.

- A hotkey shows and hides a floating palette over the focused window
- Typing filters a list of built-in commands, and Enter runs the selected one
- Escape hides the palette and returns focus to the pane that had it
- "Show Command Palette" is a menu item with Cmd-Shift-P, and its title does not change while the palette shows
- With a terminal focused, Cmd-Shift-P reaches uniterm, not the terminal surface
- A palette command acts on the pane that had focus before the palette activated
- The palette's close command and Cmd-W outside the palette behave the same, including their confirmations
- With the palette's field focused, Cmd-W dismisses the palette and closes nothing. Cmd-T runs on the pane that had
  focus before activation, after the palette hides
- UTERM-001's key binding checks still pass once its bindings run through the registry
- The standard edit actions stay responder-chain items, not registry commands
- With the palette's field focused, Cmd-V pastes into the field and Cmd-Z undoes the field's edit, not a pane close
- When the pane focused before activation closes while the palette shows, Escape focuses a defined pane, and a
  pane-scoped command posts a status message instead of acting on another pane
- Hiding the palette never takes focus back from the applet chooser, a close confirmation, or a new window that a
  command opened
- A command that is unavailable for the target pane is either hidden or shown disabled, by one rule for all commands
- With the field focused, Cmd-Shift-P hides the palette and does not show it again
- After an App Shortcuts remap of "Show Command Palette" onto a chord another uniterm binding uses, the remapped item
  wins, including with a terminal focused
- File > Close chosen with the mouse runs the same registry action as Cmd-W
- With the field focused, a menu item chosen with the mouse behaves the same as its key binding
- A click outside the floating palette hides it and focuses what was clicked

**As built:**

The registry lives in a `Commands` area of WindowKit, not a new module. Its context carries the window
controller and the target pane, and the palette view needs the window's theme and pane area. A separate module would
need protocol indirection for nothing. UTERM-013 can extract it when applets register their own commands.

Every UTERM-001 binding is a registry command owned by uniterm, including the app ones (New Window, Settings, Hide,
Quit, Minimize) and the terminal ones. Terminal text size and clear reach the pane through a small AppletKit protocol
that the terminal applet implements. The menu items for them use selectors that the terminal view does not answer.
Otherwise the responder chain would reach the view first and skip the registry. The select-tab-by-number commands exist
but are not listed in the palette.

The palette-focused rules live in the window controller's dispatch point and not in the key route, so a menu item chosen
with the mouse behaves like its key. The key route in the window sends a key to the live menu item before the views,
and a remapped item wins over a default on the same key. The launcher that holds the keyboard is offered Cmd-1 to
Cmd-9 first. AppKit rewrites a menu item's key equivalent when a user remap applies, so the route reads the live items.

Constants, all recorded here and nowhere else: the palette is 560 points wide, never wider than the window less 16 on
each side, and sits 12 below the top of the pane area. It shows up to 8 rows of 28 points under a 40 point field. The
matcher scores 16 per matched character, with 12 for each consecutive pair, 10 for a word start, 8 for the first
character, 40 for a contiguous match, 40 more for a prefix, and up to 24 off for skipped characters. A title match sits
a tier above a detail-only match. Recency adds 24 for the newest command and 6 less for each older one. The registry
remembers 8 commands, and only commands the palette lists count toward that, so tab-number presses do not push them out.

The key route compares the character a key types, not the raw key. Cmd-Shift-= matches Bigger Text, which names "+",
and Delete matches Dismiss Message, which names 0x08. Shift is dropped from the comparison for keys that are not letters
or digits. Cmd-} and Cmd-Shift-] are not unified. An item and a key that differ in the character they type do not match.

Unavailable commands show disabled, ranked like any other, and Enter skips them. The arrow keys skip them too. A
pane-scoped command whose pane is gone counts as available, so choosing it posts a status message and acts on no other
pane. A press outside the palette that lands on something taking no keyboard returns the keyboard to the focused pane.

Two defects surfaced and were fixed. Cmd-Z in a field editor that keeps its own undo manager did nothing, so the window
now undoes through the editor's manager. The app's own Quit item is no longer AppKit's, so it did not disable itself
while a quit question was open, and a second Cmd-Q cancelled the question. It now disables itself the same way.

Residuals: a remap onto another uniterm binding or a terminal's Control chord gets no collision warning, as decided. The
hide path that must not take the keyboard from a sheet is covered by a unit test of the rule and by the close and quit
UI tests, not by a test that drives a sheet over a showing palette. The palette lists "Toggle Message History" under a
fixed title, while the menu item still retitles itself.

### M2: Tab search

**Status:** DONE

Amended 2026-11-02; see Decision Log.

- Every terminal tab in the window appears in the palette
- Choosing a tab focuses its pane and switches to that tab
- A closed tab no longer appears, including one that closes while the palette shows
- A pane created while the palette shows, such as by a split or an undo, has its tabs appear
- Enter acts on the highlighted entry's pane and tab IDs, even when the list re-sorts between the arrow key and Enter
- A burst of tab title changes does not move the selection or stall typing
- Choosing an entry whose tab is gone refreshes the list and posts a status message
- The tabs of a closed pane do not appear, including those of a pane that closes while the palette shows
- Tab IDs never repeat across launches without persisted state. A restored tab gets a new ID, and an old ID resolves
  to gone
- On an empty query, the highlighted entry is the most recent tab other than the current one
- A prefix or contiguous title match outranks a recent scattered subsequence match
- A title match outranks a match found only in a tab's working directory
- Each entry shows whether it is a tab or a command. Tab titles and detail fields, such as an OSC 7 working directory,
  show with control and bidi characters neutralized
- Choosing a tab leaves focus on that tab, not on the pane that had focus before activation
- An entry for an applet's single implicit tab reads in a defined way, such as by the applet's title
- Tabs restored from the layout file, and commands never run, follow recent entries in a defined order

**As built:**

The applet contract gains a tab list and a change signal. A list holds a first tab and any others, so an empty list
cannot be built. It names the selected tab, and each tab carries an ID, a title, and detail strings. The terminal
publishes every tab, background ones too, with the directory its shell last reported. The launcher and the placeholder
publish one tab each for their whole life, titled by the applet's own title. The host learns of a change through a new
signal that fires for any tab, which the old change signal never did for a background tab. An applet selects a tab by
ID, and answers false when the tab is gone.

A tab ID pairs an epoch picked at random once per launch with a counter. IDs are not saved, and a restored tab is a
new tab with a new ID. Two launches can count to the same number, so only the epoch tells their IDs apart. An old ID
resolves to gone.

The palette walks the pane tree in order for its tab entries each time it lists. It re-lists at once when the text
changes or the tree changes shape. It re-lists on the tab signal and on the layout-change signal after a 100 millisecond
hold, and changes that arrive during the hold join the pending list. The window's own description comparison is not
used, since it ignores a title change that the saved description does not carry. Entries target a pane ID and a tab ID.
The highlighted entry is kept by ID across a re-list, so Return acts on the tab that was highlighted.

Choosing a tab whose pane or tab is gone leaves the palette up, lists again, and posts a warning. Choosing a live tab
hides the palette without taking the keyboard back, selects the tab, and focuses its pane, so the tab ends with the
keyboard. A pane that is gone and a tab that is gone take the same path.

Ranking reuses M1's matcher and constants. A tab's recency counts as a boost on the same scale as a command's, 24 for
the newest and 6 less for each older one, so a recent scattered match stays below a prefix or contiguous title match,
which the matcher lifts by 80. Tab recency lives in memory, holds the 64 most recent tabs, and is pruned of closed tabs
each time the palette lists. A tab is recent when it is the selected tab of the focused pane at the moment it takes
focus or becomes selected. A change in a background tab never counts. With no query, the order is tabs focused before,
then commands run before, then tabs never focused in tree order, then the other commands by title. The current tab, the
one showing in the pane that had focus before the palette, is listed and marked. With no query, the first choice is the
first tab other than the current one, in that order. A query of only spaces counts as no query. Typing, or clearing the
text, picks the first choice again. A re-list from a tab or layout change keeps the highlight by ID. With no other tab,
it is the first other entry that can run.

Rows show a kind word at the right, "Tab" or "Command". A tab row also shows its details after the title in a dimmer
style. Titles and details pass through one neutralizer before they are matched or shown. It turns control characters and
line breaks into spaces, collapses runs of spaces of any width, drops the bidirectional controls and the other
invisible format characters, and caps the text at 120 unicode scalars. A title with nothing left reads "Untitled". It
keeps the zero width joiner inside an emoji sequence, so those stay whole. Details are joined with a space and searched
as one string.

Narrowed: the hidden-pane check was stale and is now stated for closed panes, per the Decision Log. The UI tests cover a
background tab, the keyboard following the choice, a neutralized title, and a tab that closes while the palette shows.
A real split or undo while the palette shows is covered by unit tests only.

Residuals: a program-mode tab waiting to run is listed by its program name. The 100 millisecond hold is a guess, and
no measurement backs it. The current tab sits at the top of the empty-query list, and the first choice skips it by rule,
not by position. The terminal's own title cap counts characters, not scalars, so only the palette bounds a title of many
combining marks.

### M3: Docked mode

**Status:** DONE

Superseded in part by UTERM-014; see Decision Log.

Amended 2026-11-02; see Decision Log.

- The palette docks at the top or the bottom of the window
- A docked palette does not take focus until the hotkey activates it
- Switching between floating and docked keeps search behavior the same
- Pressing the hotkey on an active docked palette unfocuses it and returns focus to the pane that had it
- On activation, the overlay's empty-query order reflects recency at that moment
- A click outside the overlay on something that cannot take focus, such as a status bar segment or a divider, returns
  focus to the pane focused before activation
- Whether the deactivating click also reaches the clicked terminal, such as a mouse-reporting vim, is defined
- The docked palette counts toward the window's minimum size from the pane tree
- When the docked palette and the status bar dock at the same edge, they stack in one defined order
- A top-docked palette does not sit under the traffic lights or break dragging by the top edge
- Clicking an inactive docked palette activates it
- Activating a docked palette does not resize the content area or any terminal
- The results overlay stays within the content area, grows away from the docked edge, and draws above terminal
  surfaces
- A click outside the active overlay deactivates the palette and focuses what was clicked
- The placeholder names the menu item's current key equivalent, including after an App Shortcuts remap
- Switching mode while the palette is active leaves it in a defined state, with focus on the field or on the prior pane
- The mode and dock position are settings in the Settings window, and an invalid value falls back to the default with
  a status bar warning

**As built:**

The field and the results are two views, and both modes use both. The field sits in the window: in a hidden card near
the top of the pane area when floating, and in a strip against an edge when docked. The results are a card of their own,
placed beside the field and above every other view in the window. They open away from the docked edge, and downward
for a floating palette. A floating palette's results are now a separate card 4 points below the field. M1 drew them as
one card with a divider. The search, the ranking, and the dispatch rules are the same objects in both modes, and a test
pins that a docked and a floating palette list the same entries for the same text.

A docked palette is a region of its own, with a new role, installed and moved through the same calls as the status bar.
It leaves the window's region list when the mode is floating. Its strip is 48 points thick: the 40 point field with 6
points on the window's side and 2 on the pane side. It counts toward the window's minimum size through the same sum as
the status bar. The strip lies inside the safe area, below the title bar, so the traffic lights stay clear and a drag
by the top edge still moves the window.

On one edge the status bar is outermost and the palette sits inward, decided in the region stack and pinned for both
edges and both install orders. The message history now starts at the pane area's edge rather than at the bar, so a
palette on the bar's edge is not covered by it.

An inactive docked field refuses the keyboard, even from a click, and a click on it or its card asks the window to
activate. Activation reads the focused pane and its recency at that moment. Deactivation, by the hotkey, Escape, Cmd-W,
or any other dismiss path, clears the text and returns the keyboard to the prior pane through the path M1 built for
hiding. The strip outside the field takes no click while inactive. Making it a target would have reactivated the palette
on the same press that deactivated it.

The overlay is bounded by the pane area on its far side, so a short window shortens the list. It does not resize the
pane area or any pane, which tests compare before and after activation.

The deactivating click is delivered to the view under it. A UI test turns on mouse reporting in a shell and sees the
press arrive. A unit test pins that the palette steps aside before the press is dispatched. A click on the status bar or
another view that takes no keyboard returns the keyboard to the focused pane, by M1's path.

A mode or edge change while the palette is active deactivates it and returns the keyboard to the prior pane. The change
usually comes from the Settings window, so the field would otherwise hold a keyboard in a window that is not key. The
new placement starts inactive.

The placeholder of an inactive docked palette reads "Search tabs and commands" and then the menu item's key in
parentheses, such as "(⇧⌘P)". It reads the live item in the main menu when the palette is placed, when it deactivates,
and when its window becomes key. A remap that applies to the item shows from then on. An active palette reads "Search tabs
and commands", as a floating one does. A menu item with no key leaves the parentheses out.

Two settings, `paletteMode` and `paletteDockEdge`, take plain strings, so `defaults write` sets them. Each has a row in
the Settings window. A value that is not one of the choices falls back to floating or to the top, and the window posts
one warning for each. The stored text is not rewritten. A change from the Settings window or from outside the app moves
every open window live.

Constants: the field, width, margins, inset, and rows are M1's. The values this milestone adds are the 4 point gap
between a floating palette's field and its results, and the 48 point docked strip, with 6 points on the window's side
and 2 on the pane side.

Residuals: the placeholder is not refreshed when a remap changes while the window is already key, until the palette is
next activated or the window is next key. A palette docked on the status bar's edge puts the history over the pane area
and under the palette's results, which is untested for overlap. The UI tests cover the top and bottom edges, the live
Settings switch, a remap, and a status bar click. A split pane under the overlay is not covered.

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Review start: 3 milestones, 4 settled decisions, 2 risks, 0 live-after lines or row gates; no
  out-of-scope statements; full review of the 4 open questions, autonomous mode, at commit 92da487.
- 2026-11-01: Split the open sections into six questions: tab publishing, command source, hotkey default, hotkey
  configurability, search scope, and ranking. (autonomous)
- 2026-11-01: Applets publish tabs through a live query of the pane tree, with a per-pane change signal, the
  layout-change signal, and process-lifetime tab IDs. Entries target stable pane and tab IDs. Converged in 1 pass.
  (autonomous)
- 2026-11-01: Commands live in a Swift registry shared with uniterm's key bindings. They target the pane focused
  before the palette, and never run through Janet. Converged in 1 pass. (autonomous)
- 2026-11-01: The hotkey is Cmd-Shift-P in both modes, as one toggle. Converged in 1 pass. (autonomous)
- 2026-11-01: The hotkey is a fixed-title menu item, rebindable through macOS App Shortcuts. No in-app setting.
  Converged in 1 pass. (autonomous)
- 2026-11-01: Rewrote the hotkey collision risk to low likelihood, since Cmd chords never reach the pty. Lowered the
  stale-entry risk to low. Added the muscle-memory risk (accepted) and the menu-title risk (mitigated). (autonomous)
- 2026-11-01: Search covers the current window only. Cross-window search is left undone, since it is a scope
  addition. Converged in 1 pass. (autonomous)
- 2026-11-01: Results rank by fuzzy match with a bounded recency boost, kept in memory only. Each entry shows its kind.
  Converged in 1 pass. (autonomous)
- 2026-11-01: Coherence review, full pass. Amended "How applets publish tabs": tab IDs were unique only within the
  running process; now they are never reused across a relaunch, since UTERM-003 may hand them to scripts that outlive
  a launch. Amended "Command source": text-editing chords go to the palette's field, since the binding rule as written
  sent Cmd-V and Cmd-Z to the pane behind it, against UTERM-001 M7. Run actions may start UI and return. Reworded the
  dispatch constraint, since the registry now owns uniterm's bindings. Routed the other findings to M1, M2, and M3.
  Added four open questions: other bindings while the field has focus, applets without tabs, default mode and dock
  edge, and what an inactive docked palette shows. (autonomous)
- 2026-11-01: Tagged the command registry as an addition. It moves UTERM-001's key bindings onto a shared registry, a
  refactor of accepted work, to keep the palette and the bindings from drifting. The fixed-title menu item is the
  first app-menu decision in any proposal. (autonomous, addition)
- 2026-11-01: Added risks for UTERM-003 calling the main-thread registry (mitigated), rework of UTERM-001's bindings
  (accepted), and tab titles posing as commands (mitigated). (autonomous)
- 2026-11-01: With the palette's field focused, Cmd-W dismisses the palette, and other bindings dismiss it and then
  run on the prior pane. Scoped the Cmd-W sameness rule to outside the field. Converged in 1 pass, after moving off
  hide-then-run for Cmd-W, which would close a tab with no dialog and no undo. (autonomous)
- 2026-11-01: The applet contract requires at least one tab. A tabless applet publishes one tab for its whole
  session. Converged in 1 pass. (autonomous)
- 2026-11-01: The palette is floating by default, and a docked palette defaults to the top edge. Converged in 1 pass.
  (autonomous)
- 2026-11-01: An inactive docked palette shows a one-line field. Results appear as an overlay, so the content area
  never resizes. Converged in 1 pass. (autonomous)
- 2026-11-01: Tagged "Applets without tabs" as an addition. It puts a one-tab requirement, with the per-tab duties, on
  the applets of UTERM-005 through UTERM-010. (autonomous, addition)
- 2026-11-01: Re-check pass. The bindings rule made the palette's own hotkey hide and reshow it, against "Hotkey
  default". Added a carve-out: the toggle hides or unfocuses and runs nothing else. Extended the Janet-thread risk to
  availability checks. Rewrote an M3 check that assumed an inactive docked palette shows a list. Routed the other
  findings to M1, M2, and M3. (autonomous)
- 2026-11-01: Final re-check pass converged. Stated in the bindings decision's lead that the toggle is excepted. The
  Janet-thread risk also hands UTERM-003 how a Janet command reports availability. (autonomous)
- 2026-11-01: Risk review: every risk carries a rating and a mitigation or acceptance. None is high likelihood and
  high impact. Tab IDs are not persisted, and the applet contract is internal, so neither is a one-way door. The menu
  title contract and the UTERM-003 exposure are listed. (autonomous)
- 2026-11-01: Review gate: kept all. The user kept the command registry, the palette menu item, and the one-tab
  requirement.
- 2026-11-01: ADR candidate (cuts across the system): every key binding, palette command, and later script call runs
  one registry action per command. Declined: the user chose not to write it.
- 2026-11-01: ADR candidate (cuts across the system): every applet publishes at least one tab, and tab IDs are never
  reused, even across a relaunch. Declined: the user chose not to write it.
- 2026-11-01: Accepted.
- 2026-11-01: Scheduled as UTERM-002 M1-M3 in queue.md.
- 2026-11-01: Amended "Command source" and M1 to match the accepted UTERM-013, before M1 starts. "Command source" said
  every UTERM-001 binding moves onto the registry. Now the standard edit actions stay on the responder chain, and M1
  gains a check that says so. Its "Leaves undone" said menus driven from the registry would be a scope addition with
  no menu decision behind it. It now says UTERM-013 makes menus read the registry. The decision's marker moved from the
  text-editing bullet to the decision's lead, so it covers both amendments. "Hotkey configurability" and the Impacts
  line on UTERM-001 said every uniterm binding runs a registry command. Both now leave out the standard edit actions.
- 2026-11-02: Amended "Command source" (work-queue best guess): a key, a menu item, and the palette reach an action
  through one dispatch point in the window, which applies the palette's rules. The decision said only that a binding
  and its command run the same action. The key route alone would have left a menu item chosen with the mouse outside
  the palette rules. Also recorded in M1's As built: the registry lives in WindowKit, and the palette sizes and ranking
  constants are the implementation's.
- 2026-11-02: Amended "How applets publish tabs" and M2 (work-queue best guess), a correction of fact. Both said the
  tabs of hidden grace-tier panes do not appear. UTERM-001 M10 removed hidden panes, so every pane in the tree is on
  screen and a closed pane is gone. The bullet now says that. The M2 check is restated for a closed pane, including one
  that closes while the palette shows. UTERM-013 rejected a similar check for the same reason.
- 2026-11-02: M2 best guesses (work-queue best guess). The contract signal is a new host call that fires for any tab,
  not a change to the existing change signal, which feeds the status bar and layout saving for the selected tab only.
  The list type cannot be empty, per "Applets without tabs". Tab IDs are a random per-launch epoch plus a counter. The
  palette holds back tab-signal and layout re-lists for 100 milliseconds and joins a burst into one. Typing and a tree
  change re-list at once. The current tab is listed, and the empty-query first choice skips it. Tab recency is kept for
  the 64 most recent tabs. Titles and details are neutralized once, before matching, so what the user searches is what
  shows.
- 2026-11-02: M3 best guesses (work-queue best guess). Amended "Default mode and dock edge" and "What an inactive docked
  palette shows". The first said M3's stacking order covers a palette and a status bar on one edge, with no order. It now
  puts the status bar outermost and the palette inward, next to the content, so the results open from the panes' edge.
  The second said only that a click outside the overlay deactivates and focuses what was clicked. It now says the press
  is delivered to the view under it, including a mouse-reporting terminal, that a click on something that takes no focus
  returns focus to the prior pane, and that a mode or edge change while active deactivates the palette and returns focus
  to the prior pane. The placeholder reads the menu item's live key. The results are a card of their own in both modes,
  so a floating palette's results sit 4 points below the field instead of in one card with it. The palette's sizes and
  insets are the implementation's and are recorded in M3's As built.
- 2026-11-02: Implemented. M1 to M3 are done, and the row review's fixes landed.
- 2026-11-02: Superseded in part by UTERM-013. M1's As built describes the shapes M1 shipped: terminal text actions
  through a small applet protocol, the launcher's first offer of Cmd-1 to Cmd-9, and a key match that keeps Cmd-} and
  Cmd-Shift-] apart. UTERM-013 M1 replaced them with terminal-owned commands, menus built from the registry, and a
  canonical key form.
- 2026-11-02: Superseded in part by UTERM-014. "Hotkey default" and M1 put the palette on Cmd-Shift-P, an autonomous
  choice. The user had asked for Cmd-K, so UTERM-014 moves the palette to Cmd-K and drops Clear Screen's key. M3 put
  a top-docked strip below the title bar with a 40-point field. UTERM-014 moves it into the title bar row and resizes
  the field and results.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`
- [UTERM-061](UTERM-061-palette-commands-run-in-the-nearest-pane-of-their-type.md): how this proposal's targeting
  rules read, including the scope of the gone-pane rule and the origin of dimmed unavailable commands
