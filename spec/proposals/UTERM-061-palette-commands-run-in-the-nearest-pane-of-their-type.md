# UTERM-061: Palette Commands Run in the Nearest Pane of Their Type

**Status:** accepted
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-002: the command palette, its targeting rules, and its rule for unavailable commands
- UTERM-013: the commands that applet types declare in the registry
- UTERM-018: the "nearest" metric and its tie rule, which UTERM-018 says it builds once and shares. This proposal needs
  only that shared code, not the walk's capability contract or its macOS hand-off. It does not wait on UTERM-018:
  whichever of the two lands first builds the shared code. See "Sequencing against UTERM-018"

## Impacts

- UTERM-002 — "Command registry": "A command targets the pane that had focus before the palette activated" gains a
  case. A palette command of another applet type runs in the nearest pane of its type. M1's check "A command that is
  unavailable for the target pane is either hidden or shown disabled, by one rule for all commands" keeps its rule for
  a command with no pane of its type in the window. "The palette list holds still" changes how the palette treats a
  change it did not cause: rows update in place and never move, where today they list again. A click on a row that is
  not selected now selects it, and only a click on the selected row runs it.
- UTERM-013 — "Applet commands": "uniterm builds the menus from the registry: its own commands and the focused
  applet's. The palette lists the same commands." The palette already lists every applet type's commands, dimmed. This
  proposal keeps listing them and makes them run. The menus are unchanged: they still show only the focused applet's
  items.
- UTERM-018 — "Sources": "Each applet's pane-local Open… stays as it is: it always opens in its own pane." A walked
  pane-local Open still opens in the pane that runs it, but that pane is no longer always the one the user focused.
  UTERM-018's metric and tie rule gain a caller that is not an open. M1's checks say only that UTERM-004's rule "can call
  the same code". They need a check that the scripts' nearest-pane rule, which the palette shares, calls M1's metric and
  tie rule. Otherwise M1 can pass while the palette and scripts keep reading-order ties. Whichever of UTERM-018 M1 and
  this proposal's M1 lands first builds the shared metric and tie rule, and the other reuses them. Scripts' ties change
  to UTERM-018's tie rule with whichever ships first.
- UTERM-005, UTERM-006, UTERM-007, UTERM-008, UTERM-009, UTERM-022, UTERM-001 — every command these applet types
  declare becomes reachable from a pane of another type. Titles shared across types become enabled side by side: "Open…"
  in four viewers, "New Tab" in the terminal and the browser, "Reload" in the browser and the text viewer, the tab
  selection commands in the terminal, the browser, and the Questions pane, and Find in the text and data viewers.
- UTERM-062 — its tab selection commands for more applet types multiply the same-titled rows, such as "Select Tab 3".
  The ranking penalty on foreign rows and the `applet:` chip carry them.
- UTERM-064 — its open question "Targets that pick a place when the command arrives" may remove `{:nearest}`. The
  palette's caller of the shared function stands without it. If `{:nearest}` goes, the scripts' caller and the M1
  checks on it go with it.

## Summary

The command palette lists every applet type's commands. Today a command whose applet type differs from the focused
pane's shows dimmed and cannot run. With this proposal it runs. The palette finds the nearest pane of that applet type in
the same window, by UTERM-018's metric and tie rule, and runs the command there. A command never acts in another window.
Each applet command's row names its applet type, so the user can tell rows with the same title apart. While a foreign
row is selected, the palette outlines the pane it will run in. Choosing it focuses that pane, then runs the command. A
foreign row ranks below the focused applet's own match, and a row with no pane of its type says why. The palette list holds still
while it shows: a change the user did not cause updates rows in place and never moves them.

## Motivation

The user typed "open" in the palette with a data viewer focused. The palette showed "Open File or Folder", "Open File or
Folder With", four rows titled "Open…", "Open Location", and "Reopen Closed Tab or Pane". Three of the "Open…" rows and
"Open Location" were dimmed. Nothing said which applet each row belonged to, or why most could not run. The rows are the
pane-local Open that the data, text, image, and map viewers each declare, and the browser's Open Location.

Dimming came from a run's best guess on 2026-11-01, recorded in that run's report as "An unavailable command is shown
disabled, not hidden. If wrong, the palette filters them out instead." Applet types did not declare their own commands
yet. UTERM-013 added them later, so most dimmed rows now belong to an applet type that is not focused. They are not
commands that cannot run for a moment.

Today the user reaches such a command by focusing a pane of its type first, then running it. For Open, File > Open also
routes a file by type. This proposal saves that focus step for every applet command.

### How UTERM-002's targeting rules read

UTERM-002 is implemented, so its text stays as written. The rules that bear on this proposal read as follows:

- "A palette command acts on the pane that had focus before the palette activated" is a design decision with no
  rationale of its own. It says which pane a command is aimed at. It does not say that a command may never reach
  another pane.
- "When that pane is gone, a pane-scoped binding posts a status message instead of acting on another pane" covers one
  case only: the pane that had focus closed while the palette showed. It is not a general ban on acting elsewhere.
- No principle in UTERM-002 bars a command from acting in another pane or tab. The nearest stated reason sits in the
  rationale for Cmd-W: a tab close at an idle prompt neither asks nor undoes. So the concern behind the gone-pane rule
  is that an irreversible action must not land, by silent fallback, on a pane the user did not aim at.
- The palette belongs to a window, not to a pane or a tab. The user's boundary is that a palette command must never
  confusingly act in another window. Acting in another pane of the same window is within UTERM-002's intent.
- "Either hidden or shown disabled, by one rule for all commands" leaves the choice open. Dimming was the best guess
  above.

A command the user picks from a row labeled with its applet type has a target the user chose. It is not a silent
fallback. That is the difference between this proposal and the gone-pane case.

## Design Decisions (Settled)

### A palette command of another applet type runs in the nearest pane of its type

Decision: when the focused pane's applet is not of a command's type, choosing the command in the palette runs it in the
nearest pane of that type in the same window. "Nearest" is one shared function that the palette and the scripts'
nearest-pane rule both call. It is UTERM-018's metric and tie rule, built by whichever of the two proposals lands first.
See "Sequencing against UTERM-018". The command never acts in another window. A command whose type matches the focused pane runs there, as today.

- The palette resolves the target to a pane ID and dispatches by that ID, per ADR-02.
- Which panes count as candidates: see "Which panes the walk considers".
- Which surfaces walk: see "Where the walk lives, and which surfaces walk".
- When the shared function is built: see "Sequencing against UTERM-018".

Rationale: the user chose this direction on 2026-11-26. The palette is window-level, and a row labeled with its applet
type states the target.

### Applet command rows name their applet type

Decision: a command an applet type declares shows the type's declared name on the right of its row, such as "Data
Viewer", in place of "Command". The name comes from the type's declaration, as a tab row's does, so a program cannot set
it. uniterm's own commands keep "Command".

Rationale: the user asked for it in the review of 2026-11-26. It landed as review polish, ahead of this proposal, since
it holds under any outcome here. M1 checks it either way.

### Which panes the walk considers

Original question: which panes of the command's type are candidates. Candidates: every pane of the type, so the
command's own availability check on the nearest one decides whether it acts; or only panes where the command reports
itself available, so a farther pane wins when the nearest cannot run it. Neither said whether a pane inside a group a
controller owns is a candidate.

Decision: every pane of the command's type in the window is a candidate, except a pane inside a group a controller
owns. The walk never asks a pane whether it can run the command now. The command's own availability check on the walked
pane decides the row's enabled state, so an unavailable nearest pane shows the row dimmed, as it would with that pane
focused. A user who wants to run the command in a controller-owned pane focuses it first, as today.

Rationale: routing on live availability would pick a pane by state the user cannot see. UTERM-018's capability contract
rejects that for opens, and its Restart REPL case here restarts the wrong REPL. Controller-owned panes stay out because
of what a controller can read. A walked Open Location focuses the address bar of a browser tab, and a tab a controller
opened stays readable by that controller, address included, after the user navigates it. A typed address could then
reach the controller, even with the pane outlined. UTERM-018 M1 also keeps a user open out of such a pane, so the two walks agree.
(autonomous)

### Where the walk lives, and which surfaces walk

Original question: whether the walk lives in the palette's choose path, or in the registry's run path so that menu
items and keys walk too.

Decision: only the palette walks. One resolver on the window controller names the target pane for a command from an
origin pane, by the candidate rule above and the shared metric and tie rule. The palette calls it for a row's enabled
state and again when the row is chosen. The registry's run path is unchanged. It receives a context aimed at the
resolved pane's ID.

Rationale: no other surface can present a command of another applet type. The menus hide every applet item whose type
is not the focused one, and a key matches only a visible item, so a key or menu item never carries a foreign command. A
walk in the run path would gain no surface. It would also meet the gone-pane guard there, and walking from a missing
origin ties every candidate and picks one silently. A resolver used only at choose time would leave every foreign row
dimmed, since the row's enabled state is read at refresh. Keeping the walk out of keys also keeps ADR-04's rule that
applet keys act on one applet's content. (autonomous)

### Sequencing against UTERM-018

Original question: ship on the existing nearest-of-type function, whose ties follow reading order until UTERM-018 M1
lands, or wait for UTERM-018 M1.

Decision: this proposal's M1 builds UTERM-018's shared metric and tie rule, unless UTERM-018 M1 has built them already.
Whichever of the two lands first builds the function, and the other reuses it. The palette and the scripts' nearest
rule call it from the start. Scripts' ties change from reading order to UTERM-018's tie rule when it ships.

Rationale: the only option that never ships the pick UTERM-018 rejected. In a flat row [A|B|C] with origin C, every pane
is two edges away, and reading order picks A over the adjacent B. UTERM-018's tie rule is pure tree topology, tested on
fixture trees, and needs none of UTERM-018's capability contract or macOS hand-off, so building it here is not
over-building. Waiting would defer the palette for a reason that is only where the code lives. The change to scripts'
ties is UTERM-018's accepted change to UTERM-004's tie rule, shipped earlier. It is not a change of meaning under ADR-13
P1: the script API documents `{:nearest kind}` as the nearest pane the caller may control, with no tie order, and no
message or reply field changes. (autonomous)

### Whether focus moves to the pane the command ran in

Original question: whether focus moves to the walked pane, and whether the user sees the target before the command
runs. Candidates: focus moves after the run; focus stays on the origin and the walked pane flashes or the status bar
names it; the row names its target by the walked pane's tab title in its detail text; focus moves before the run, as
choosing a tab row does; and an outline on the walked pane while its row is selected.

Decision: while a foreign command's row is selected, the palette outlines the walked pane in the window behind it. The
outline differs visibly from the focus marker, which the origin pane still wears. Moving the pointer over a row selects
it. A click runs only the selected row. A click on any other row selects and outlines it, and a second click runs it.
So a clicked row was always outlined before it ran, even when typing re-sorted the list under a resting pointer or the
palette opened under it. Amended 2026-11-26; see Decision Log. When the row is chosen, the palette hides without restoring focus,
focuses the walked pane, then runs the command, as choosing a tab row does.

Rationale: the run is then exactly the user's workaround today, "focus that pane, then run", so every command keeps its
own focus behavior and one action has one behavior, as UTERM-036 gives a routed open's pane focus. Focus after the run
breaks commands that take the keyboard: focusing a browser with a loaded page makes its web view first responder, so
Open Location's address bar loses the keyboard. Focus that stays would stay for Reload and move for Open Location and
Find, since the pane area follows the first responder. A tab title in the row cannot tell two "zsh" terminals apart, and
detail text is matched by the query, so a program that sets a title could steer which command rows show. The outline
shows the target before a command with no undo runs, and it carries no program-set text. (autonomous)

The whole-proposal check found that rows moving under a resting pointer let a click run a row that was never outlined.
The user kept the outline on 2026-11-26, once the list stopped moving on its own.

### The palette list holds still

Original question: while the palette is open, how it handles a change it did not cause, such as a terminal retitling
itself, a pane opening or closing, or a layout change. Today each such change lists the palette again and re-sorts it.
Candidates: rows hold their place and update in place; or a full snapshot until the user types.

Decision: a change the user did not cause never adds, removes, or reorders rows. It updates a row where it stands: its
title text, its dimmed state and reason, and its outlined target pane. A row whose tab or pane closed stays put, and
choosing it says it has closed, as the gone-tab and gone-pane messages do. A new tab does not appear until the user
types. Typing or deleting a character sorts the list afresh.

Rationale: the user chose it on 2026-11-26. A tab running one program after another retitles itself all the time, and a
list that keeps re-sorting cannot be read or pointed at. A full snapshot would show titles and enabled states that are
no longer true. It fixes today's palette whatever this proposal decides, so it landed as review polish, ahead of this
proposal, in "Hold the palette list still while it shows". M1 checks it either way. (addition)

### When the palette resolves the target

Original question: resolve at choose time, or at refresh time with the row carrying its target. And when the palette's
origin pane closes while the palette shows: the gone-pane message, or a walk from the pane the window focuses after the
close. The question said both times agree today, since a pane-tree change refreshes the palette at once. That does not
hold for a controller ending: releasing its groups changes ownership without refreshing the palette.

Decision: the row carries the pane ID the resolver named at refresh, which the outline shows. Choosing the row resolves
again. When the result differs from the row's pane, the row takes the new pane in place, the outline moves to it, and
the palette says so instead of running. When the origin pane has closed, a foreign command posts the gone-pane message, as every
pane-scoped command does today, and the message names the pane the palette opened from.

Rationale: the command never runs in a pane other than the one the user saw outlined. Resolving again at choose rechecks
the controller-owned exclusion at the moment of the run, which a refresh that missed a controller ending would not.
Walking from the newly focused pane, or re-anchoring the whole palette, lands a command by silent fallback on a pane the
user did not aim at. With origin terminal T1 gone and T2 focused, Clear Screen would clear T2. That is the case
UTERM-002's gone-pane rule exists to stop, and the origin type's own rows already refuse it. (autonomous)

### Which commands walk

Original question: every applet command walks by one rule; every one except a command that discards content with no
undo, each declaring whether it may walk; or only commands that open or show content. Closes are uniterm's commands,
not applet commands, so none walks.

Decision: every applet command walks, by one rule. The applet command entry gains no field.

Rationale: the outline shows which pane a command will run in before the user chooses it, so a walked Clear Screen is as
visible as Clear Screen in a focused pane. A per-command field would be a judgment nothing checks, and its default
either lets the next discard command walk blind or quietly narrows every new command. Only open-or-show commands would
drop Reload, Back, Zoom, and Find Next, most of the value. Undo for Clear Screen and Clear Program Pins would fix the
discard at its root, for the focused pane too, but it brings undo machinery to the map and the terminal, which this
proposal does not hold. (autonomous)

### When no pane of the command's type is in the window

Original question: the row stays dimmed; the row is hidden; the command opens a new pane of its type and runs there;
or the row stays enabled and choosing it posts a message.

Decision: the row stays dimmed, by UTERM-002's rule for an unavailable command, and shows uniterm's own reason, such as
"No Text Viewer pane in this window". When every pane of the type sits in a controller-owned group, the reason says so.
The query never matches the reason, and VoiceOver reads it.

Rationale: the Motivation's complaint is that nothing said why a row could not run, and dimming alone leaves that. A
hidden row breaks UTERM-002's one rule for all commands, and in the controller-owned case it hides a command whose pane
is on screen and one focus away. An enabled row
that does nothing on Return breaks the convention that a dimmed row cannot run. A new pane works only for Open, which
File > Open already routes by type. The reason stays out of matching, since any in-order run of the query's letters
matches, so "No Terminal pane in this window" would show Clear Screen for a query of "open". (autonomous)

This leaves undone: a row dimmed because the walked pane's own check fails shows no reason, as a dimmed row of the
focused pane's type shows none today. Applet commands declare no reason text.

### Titles shared across applet types

Original question: "Open…", "New Tab", "Reload", the tab selection commands, and Find each appear under two or more
types. Candidates: keep the titles and rely on the applet name on the right of the row; give the pane-local Open a
palette title of its own; or build palette titles as "<Title> in <Applet Name>".

Decision: keep the titles. The applet name on the right of the row, which a program cannot set, and the outline on the
walked pane tell same-titled rows apart. The `applet:` filter chip admits that type's command rows as well as its tabs,
and its placeholder and empty notices stop saying "tabs", so the user can narrow the four "Open…" rows by typing.

Rationale: the rows already read apart, and the label keeps its width while a title truncates. A palette title of its
own fixes only Open, and "Open File…" would sit beside uniterm's "Open File or Folder" while the panel accepts folders
too. A suffix of "in <Applet Name>" repeats the label in the part that truncates, and a program-set tab title such as
"Reload in Browser" mimics it exactly. Without the chip, the user can only arrow through same-titled rows.
(autonomous)

### Ranking a foreign command against the focused applet's own

Original question: whether a command of the focused pane's applet type ranks above the same match from another type,
whether same-title commands rank by distance to their target pane, or neither.

Decision: an applet command whose type differs from the focused pane's scores lower than its match and recency would
give it, by more than the largest recency boost. Every other row, uniterm's commands and tabs included, keeps today's
score. The list sorts by one total key: score, then recency rank, then distance, then registration order, then title.
Distance is the edge distance from the origin to the row's resolved pane for a foreign row, zero for every other row,
and the largest value for a row with no candidate pane. With no query, the order is unchanged. Amended 2026-11-26; see
Decision Log.

Rationale: Return should do what the key in the focused pane does. With no change, a text viewer focused, a browser in
the window, and "reload" typed, the browser registered first and Return reloads it. Recency alone cannot keep the
focused type ahead, since every run path records it: Cmd-0 in a terminal, then "actual" typed with an image viewer
focused, would reset the terminal. A pairwise "focused type first" rule is not a strict weak ordering once recency is in
the score, and a bonus for the focused type would push the pane-local Open above uniterm's routed Open for a query of
"open". One score term on foreign rows avoids both. Edge distance then orders foreign ties by nearness instead of
registration order. It is one total key, so the sort stays a strict weak ordering when a uniterm row ties a foreign
row, and every non-foreign row keeps today's order. A user who runs one foreign command often presses one arrow key past the focused type's
row, which matches what the key would do. (autonomous)

### How a command row reads to VoiceOver

Original question: a web page titled "Reload" and the browser's Reload command both read "Reload, Browser". Candidates:
add the kind to the accessibility value; give the row icon an accessibility description; or no change.

Decision: the row's accessibility value carries its kind with its applet name, such as "Browser command" and "Browser
tab", for every kind of row. A foreign command row also names, in accessibility text, the pane it will run in. The name
comes from the layout, such as "Terminal 2 of 2", never from a tab title or other program-set text. The query never
matches it. As the selection moves, VoiceOver hears the selected row's label, value, and target. When the palette does
not announce that today, M1 makes it.

Rationale: UTERM-002 mitigates "a program-set tab title passes for a uniterm command" by showing each entry's kind, and
the kind label exists so a program-set title can never pass for a command. Under VoiceOver, naming applet types on
command rows already withdrew that. "No change" keeps the withdrawal. The outline is visual only, so "Every applet
command walks" rests on a cue a VoiceOver user does not get. Naming the target restores it, without program-set text. An
icon description adds a symbol name, a weaker cue than "Browser command". Announcing the selection, if the palette does
not today, fixes an existing palette gap that this proposal exposes. (autonomous, addition)

## Design Decisions (Open)

None.

## Risks

- **A command with no undo lands on the wrong pane of the right type** — likelihood: low, impact: medium.
  With two terminals in the window, Clear Screen chosen from a browser clears the nearer one. The map's Clear Program
  Pins has no undo either.
  Mitigation: the walked pane is outlined while its row is selected. Pointing selects a row, and a click runs only the
  selected row, so a click never runs a row the user did not see outlined. VoiceOver hears the target pane's name. Choosing resolves again and refuses on a
  mismatch, so the command never runs in a pane other than the one shown.
- **Scripts' ties change when the shared tie rule ships** — likelihood: high, impact: low.
  A script's `{:nearest kind}` with two equally near panes may resolve to a different pane than reading order picked.
  Accepted: UTERM-018 settled this change for every caller, and accepting it approved the change to UTERM-004's tie
  rule. The script API documents no tie order, and no message or reply changes. The test that pinned reading-order ties
  becomes the regression test for the new rule.
- **UTERM-064 removes `{:nearest}` while this proposal is in flight** — likelihood: medium, impact: low.
  Its open question "Targets that pick a place when the command arrives" may drop the scripts' nearest target.
  Mitigation: the palette's caller of the shared function does not depend on it. If `{:nearest}` goes first, M1 drops
  its scripts checks, and the shared function keeps the palette as its caller, with UTERM-018's walk to follow.
- **UTERM-018 M1 lands second and builds a second copy of the metric and tie rule** — likelihood: low, impact: low.
  UTERM-018's text said only that UTERM-004's rule "can call the same code". It did not say to reuse a function this
  proposal built, or to check that the scripts' rule calls it.
  Mitigation: this proposal's M1 reuses the function when UTERM-018 M1 came first. UTERM-018 M1 gained the matching
  check on 2026-11-26.
- **Two rows read the same to VoiceOver** — likelihood: low, impact: low.
  Mitigation: every row's accessibility value names its kind, and a foreign row names its target pane, per "How a
  command row reads to VoiceOver".

## Milestones

### M1: Palette commands run in the nearest pane of their type

**Status:** NOT STARTED

- Each applet command's row shows its applet type's declared name, and uniterm's own commands show "Command"
- With a data viewer focused and a text viewer elsewhere in the window, choosing the text viewer's Open in the palette
  opens the panel for that text viewer pane, and the file lands there
- The palette and the scripts' nearest-pane rule call one extracted metric-and-tie function, and two panes of the type
  equally near resolve to the pane that function names
- A command never runs in a pane of another window, even when the window has no pane of its type
- A row the walk enables runs when chosen. A row refused at run time says why in the status bar, including a command
  whose own check fails after the last refresh, which today returns silently
- The shared function reports to its caller when the origin pane is not in the tree, and never ranks from it. The
  palette then posts the gone-pane message. A script whose source pane is gone keeps today's answer: its authorized
  candidates in reading order, then pane ID
- With the origin gone, a foreign row stays enabled with no outline and no no-pane reason, so choosing it can post the
  gone-pane message
- When the palette's origin pane closes while the palette shows, choosing a foreign command posts the gone-pane
  message, and the message names the pane the palette opened from, not the walked pane
- While a foreign command's row is selected, the walked pane wears an outline that differs visibly from the focus
  marker, in both the docked and the floating palette placement
- Moving the pointer over a row selects it. A click on the selected row runs it, and a click on any other row only
  selects and outlines it. After typing "clear" with the pointer resting over the list, a click runs nothing until the
  row under the pointer is selected
- The outline clears on every way the palette hides, Escape, a click outside, a placement change, and a sheet among
  them, and when the selection moves to a row that is not foreign
- A walked pane partly under the floating palette still shows its outline
- When the user types after the origin pane has gone, a foreign row sorts with the largest distance, as a row with no
  candidate does
- With a text viewer focused, after the pointer has passed over a foreign row, typing "reload" and pressing Return
  reloads the text viewer, since typing clears the selection
- One click on a filter keyword row still completes its keyword. Pointing at or clicking a dimmed row leaves the
  selection unchanged
- Only real pointer movement selects a row. A re-sort after typing, an arrow-key scroll past the visible rows, and an
  in-place update never move the selection to the row under a resting pointer
- When the selected row turns dimmed in place, the selection moves to the next selectable row below, else above, so
  Return never runs a dimmed row. When that row is foreign, its outline shows before any Return
- While the palette shows, a terminal that retitles itself, a pane that opens or closes, and a layout change move no
  row. Typing a character sorts the list afresh
- Choosing a foreign row checks the command on the resolved pane, then focuses that pane, then runs the command. With a
  browser page loaded, the walked Open Location leaves the keyboard in the address bar
- When the pane resolved at choose differs from the row's pane, the row takes the new pane in place and the palette says
  so instead of running
- Any owner's release of its groups while the palette shows, a controller's end or a driver run's end, updates rows in
  place, so enabled states, reasons, and outlines that depend on group ownership are current
- A dimmed row with no candidate pane shows uniterm's reason. The query never matches that reason, and VoiceOver reads
  it
- With two terminals in the window and a browser focused, choosing Clear Screen clears the outlined terminal
- The walk exists only on the palette path. A menu item or key for an applet command still acts on the focused pane
  only
- A row's enabled state and its run use the same resolved pane, so a foreign row the walked pane can run shows enabled
- The extracted function takes its candidates from the caller. The scripts' authorization filter and the palette's
  controller-owned exclusion stay in their own callers, and a script can never reach a pane outside its grant through
  it
- When the origin pane sits inside a controller's group, the walk still skips that group's panes, and the command runs
  in the nearest pane outside every controller-owned group
- When every pane of the command's type sits in a controller-owned group, the row's reason says so
- When UTERM-018 M1 has already built the shared metric and tie rule, this milestone reuses them and builds no second
  copy
- A script's `{:nearest kind}` with two equally near panes resolves by UTERM-018's tie rule, and the test that pinned
  reading-order ties is rewritten to prove it
- The `applet:` filter chip admits command rows of its type as well as its tabs, and its placeholder and empty notices
  no longer say "tabs"
- With a text viewer focused and a browser in the window, typing "reload" and pressing Return reloads the text viewer
- With Cmd-0 just pressed in a terminal and an image viewer focused, typing "actual" and pressing Return acts in the
  image viewer
- With a viewer focused and neither Open run recently, typing "open" still selects uniterm's Open File or Folder first
- With UTERM-062's tab selection commands in place, "select tab 3" selects the focused pane's command first
- Among foreign rows whose scores tie, the one whose resolved pane is nearer lists first
- When the focused type's row is dimmed, Return on the selected foreign row runs it in its outlined pane
- Every row's accessibility value names its kind, uniterm's commands and tabs of undeclared types included, and a filter
  row's value does not read as an empty kind
- A foreign command row's accessibility text names its target pane by a layout-derived name, never a program-set title,
  and the query never matches it
- VoiceOver hears the selected row's label, value, and target as the selection moves, checked with VoiceOver first

### M2: The user's check

**Status:** NOT STARTED

- The user runs foreign commands from the palette in the running app, and confirms the rows read clearly and each
  command lands where expected

## Decision Log

- 2026-11-26: Drafted from the user's review of the data viewer. The user chose to run foreign applet commands in the
  nearest pane of their type, within the window, over hiding or dimming them.
- 2026-11-26: Recorded how UTERM-002's targeting rules read, in Motivation. UTERM-002 is implemented, so the reading
  lives here, and UTERM-002's References links to it.
- 2026-11-26: Applet names on command rows are being built ahead of this proposal as review polish.
- 2026-11-26: First critique pass. Fixed: the walk no longer filters candidates by live availability, which moved to an
  open question. Removed a quote attributed to ADR-15 that it does not contain. Removed the claim that closes walk:
  they are uniterm's commands, not applet commands. Replaced the gone-target decision, whose case could not happen,
  with an open question on when the target resolves. Narrowed the dependency on UTERM-018 to its shared metric. Added
  the risk of a no-undo command landing on the wrong pane, and the VoiceOver question.
- 2026-11-26: Second critique pass. Fixed: the settled decision named UTERM-018's tie rule while the plan allowed
  shipping on the existing one. It now names the shared function, and the choice moved to "Sequencing against
  UTERM-018". An M1 check that every enabled row runs contradicted UTERM-002's gone-pane message, so it now says a
  refused row explains why. Added the origin-gone rule as options, and facts on controller-owned groups, the sheet, and
  matching a target's title.
- 2026-11-26: Third critique pass converged. Corrected the fact that a program can close a viewer under its Open
  panel: none can. Routed two M1 checks, and noted the check UTERM-018 M1 needs for the shared tie rule.
- 2026-11-26: ADR candidate: a command may act in a pane other than the focused one, and which surfaces may do so.
  `adr-impact` rated it cross-cutting and hard to unwind, but premature while "Where the walk lives" is open. Outcome:
  undecided. Declined on 2026-11-26: it fails Architecture. Only the palette routes a command away from the focused
  pane, so it shapes one component, and a redeploy undoes it. ADR-04 already covers keys.
- 2026-11-26: Review start: 2 milestones, 2 settled decisions, 3 risks, no `**Live after:**` lines or row gates; out
  of scope: acting in another window, and changing the menus. The user asked for an autonomous review of the draft as
  committed in "Draft UTERM-061 so palette commands run in the nearest pane of their type".
- 2026-11-26: Every pane of the command's type in the window is a candidate, except a pane inside a group a controller
  owns, and the walked pane's own check decides the row's enabled state. (autonomous)
- 2026-11-26: Only the palette walks, through one resolver that names the target pane for both a row's enabled state and
  its run. Menus and keys never present a foreign command. (autonomous)
- 2026-11-26: This proposal's M1 builds UTERM-018's shared metric and tie rule unless UTERM-018 M1 has already, so the
  palette never ships with reading-order ties. A raised ADR-13 skew concern did not hold: the script API documents no
  tie order, and no message or reply changes. (autonomous)
- 2026-11-26: Added options D (focus before the run) and E (outline the walked pane while its row is selected) to
  "Whether focus moves", with the facts that break focus after the run and focus that stays.
- 2026-11-26: Focus moves to the walked pane before the command runs, and the walked pane is outlined while its row is
  selected, with pointing selecting a row. (autonomous)
- 2026-11-26: A foreign row carries the pane resolved at refresh, and choosing resolves again and lists again on a
  mismatch. A closed origin gives the gone-pane message. Corrected the question's claim that every tree change
  refreshes the palette: a controller ending does not. (autonomous)
- 2026-11-26: Every applet command walks, by one rule. Undo for the two Clear commands was weighed and left out as
  outside this proposal. (autonomous)
- 2026-11-26: A row with no candidate pane stays dimmed and shows uniterm's reason, which the query never matches.
  (autonomous)
- 2026-11-26: Shared titles stay, and the `applet:` chip admits that type's command rows. (autonomous)
- 2026-11-26: Foreign applet rows score below their match and recency by more than the largest recency boost, and
  distance to the resolved pane breaks remaining ties. (autonomous)
- 2026-11-26: Every row's accessibility value names its kind, a foreign row names its target pane by layout, and the
  selected row is announced as the selection moves. The announcement is a fix to an existing palette gap.
  (autonomous, addition)
- 2026-11-26: Growth check on the guarantee that a foreign command's target shows before it runs. The whole-proposal
  check found a click could run a row that moved under a resting pointer. The user said the list must not keep
  re-sorting. The user chose that rows hold their place and update in place, kept the outline, and asked for the stable
  list to be built now as polish. (addition)
- 2026-11-26: Coherence fixes. The ranking's distance tie-break was intransitive when a uniterm row tied a foreign row,
  and read literally it broke the "open" check. It is now one total key; it said "Among rows whose scores still tie,
  the distance from the origin to each row's resolved pane decides, after recency rank and before registration order.
  A row with no candidate pane sorts last among them." A mismatch at choose now updates the row in place, where it said
  "the palette lists again". The candidate rule's rationale no longer says controller-owned panes are ones "the user did
  not aim at", which the outline contradicts. "No pane of its type" no longer claims a pane "one focus away" when there
  is none. The first settled decision no longer says UTERM-018 M1 must build the function. Added UTERM-062 and UTERM-064
  to Impacts.
- 2026-11-26: Second growth check on the same guarantee. The re-check found that typing re-sorts the list under a
  resting pointer, so a click could still run a row never outlined. The user chose that a click runs only the selected
  row, and a click on any other row selects it. "Whether focus moves" said "the rows-hold-still rule keeps the row
  under a resting pointer the one it selected."
- 2026-11-26: A script whose source pane is gone keeps today's `{:nearest}` answer, its authorized candidates in
  reading order, instead of the failure the "never ranks from a missing origin" check would have caused. The shared
  function reports the missing origin, and each caller keeps its own behavior. (autonomous)
- 2026-11-26: Review gate: kept all. The user kept the VoiceOver kind, target, and selection announcement, and building
  the shared tie rule here when this proposal lands first. The user also asked for UTERM-018 M1 to gain the reuse
  check, which was added there.
- 2026-11-26: ADR candidate (cuts across the system): a user's action never places the user's content in a pane a
  controller owns. Declined: it applies ADR-14's premise that what a controller opened holds nothing the user placed
  there, and only two places, this walk and UTERM-018's, follow it.
- 2026-11-26: Accepted after its review.

## References

- Run report for the palette, with the best guess on dimming: `spec/reports/20261101-uterm-002-m1-m3-command-palette.md`
- ADR-02: panes are addressed by stable ID
- ADR-04: applet keys act on one applet's content
- ADR-05: a close that would end running work asks first
- ADR-15 (proposed): an action means one thing, whoever starts it
