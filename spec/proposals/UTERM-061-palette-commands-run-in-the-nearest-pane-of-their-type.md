# UTERM-061: Palette Commands Run in the Nearest Pane of Their Type

**Status:** draft
**Created:** 2026-11-26
**Updated:** 2026-11-26

## Dependencies

- UTERM-002: the command palette, its targeting rules, and its rule for unavailable commands
- UTERM-013: the commands that applet types declare in the registry
- UTERM-018: the "nearest" metric and its tie rule, which UTERM-018 says it builds once and shares. This proposal needs
  only that shared code, not the walk's capability contract or its macOS hand-off. See "Sequencing against UTERM-018"

## Impacts

- UTERM-002 — "Command registry": "A command targets the pane that had focus before the palette activated" gains a
  case. A palette command of another applet type runs in the nearest pane of its type. M1's check "A command that is
  unavailable for the target pane is either hidden or shown disabled, by one rule for all commands" keeps its rule for
  a command with no pane of its type in the window.
- UTERM-013 — "Applet commands": "uniterm builds the menus from the registry: its own commands and the focused
  applet's. The palette lists the same commands." The palette already lists every applet type's commands, dimmed. This
  proposal keeps listing them and makes them run. The menus are unchanged: they still show only the focused applet's
  items.
- UTERM-018 — "Sources": "Each applet's pane-local Open… stays as it is: it always opens in its own pane." A walked
  pane-local Open still opens in the pane that runs it, but that pane is no longer always the one the user focused.
  UTERM-018's metric and tie rule gain a caller that is not an open. M1's checks say only that UTERM-004's rule "can call
  the same code". They need a check that the scripts' nearest-pane rule, which the palette shares, calls M1's metric and
  tie rule. Otherwise M1 can pass while the palette and scripts keep reading-order ties.
- UTERM-005, UTERM-006, UTERM-007, UTERM-008, UTERM-009, UTERM-022, UTERM-001 — every command these applet types
  declare becomes reachable from a pane of another type. Titles shared across types become enabled side by side: "Open…"
  in four viewers, "New Tab" in the terminal and the browser, "Reload" in the browser and the text viewer, the tab
  selection commands in the terminal, the browser, and the Questions pane, and Find in the text and data viewers.

## Summary

The command palette lists every applet type's commands. Today a command whose applet type differs from the focused
pane's shows dimmed and cannot run. With this proposal it runs. The palette finds the nearest pane of that applet type in
the same window, by UTERM-018's metric and tie rule, and runs the command there. A command never acts in another window.
Each applet command's row names its applet type, so the user can tell rows with the same title apart.

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
nearest-pane rule both call. UTERM-018 says its metric and tie rule are shared code, so its M1 must move this function
to them for every caller. See Impacts. The command never
acts in another window. A command whose type matches the focused pane runs there, as today.

- The palette resolves the target to a pane ID and dispatches by that ID, per ADR-02.
- Which panes count as candidates is open. See "Which panes the walk considers".
- Whether this ships before or after UTERM-018 M1 is open. See "Sequencing against UTERM-018".

Rationale: the user chose this direction on 2026-11-26. The palette is window-level, and a row labeled with its applet
type states the target.

### Applet command rows name their applet type

Decision: a command an applet type declares shows the type's declared name on the right of its row, such as "Data
Viewer", in place of "Command". The name comes from the type's declaration, as a tab row's does, so a program cannot set
it. uniterm's own commands keep "Command".

Rationale: the user asked for it in the review of 2026-11-26. It is being built as review polish, ahead of this
proposal, since it holds under any outcome here. M1 checks it either way.

## Design Decisions (Open)

### Which panes the walk considers

The walk needs a rule for which panes of the command's type are candidates.

- A. Every pane of the command's type is a candidate. The nearest one runs the command, and the command's own
  availability check then decides whether it acts or does nothing. This matches UTERM-018's capability contract, which
  is "static only" and "never asks the pane", so the walk never routes on pane state the user cannot see. A command that
  is unavailable on the nearest pane does nothing there, as it would with that pane focused.
- B. Only panes where the command reports itself available. A farther pane wins when the nearest cannot run the command.
  For example, Restart REPL from a terminal skips a live REPL next to it and restarts an ended REPL farther away. It
  routes on pane state the user cannot see, which UTERM-018 rejects for opens.

Under A, a row's enabled state comes from the command's check on the walked pane, so an unavailable nearest pane shows
the row dimmed. Neither option yet says whether a pane inside a group a controller owns is a candidate. UTERM-018 M1
keeps a user open out of such a pane, and the scripts' nearest-pane rule filters its candidates by authorization before
ranking.

### Where the walk lives, and which surfaces walk

The same registry entry runs from the palette, its menu item, its key, and the status bar's controls. Programs never
reach the registry: scripts and controllers go through the control dispatcher's schema commands.

- A. The walk lives in the palette's choose path. Menu items and keys keep acting on the focused pane. Menus show only
  the focused applet's items today, so they gain nothing to walk.
- B. The walk lives in the registry's run path, so keys walk too. Different applet types may share a chord, such as
  Cmd-T for the terminal's and the browser's New Tab, so a key with no matching focused pane has no single command to
  walk.

### When the palette resolves the target

- A. At choose time. Choosing hides the palette and runs the command in one main-thread turn, so the target cannot
  close in between. A command that starts asynchronous UI may outlive its target only when the target can close under
  that UI. Open's file panel is a sheet, and menu items and layout requests are refused under it. No viewer exits on its
  own, and the host API has no call that closes a pane. So no viewer can close under its Open panel today. An applet
  that can exit, such as the REPL, can close under its own sheet.
- B. At refresh time. The row carries its target pane, and the palette's refresh on pane-tree changes picks it again.
  The row can then name its target before the user chooses it. "Whether focus moves" option C needs this.

Today both times agree, since a pane-tree change refreshes the palette at once, and the metric reads only the tree.

When the palette's origin pane closes while the palette shows, a foreign command needs a rule too:

- C. The gone-pane message, as every pane-scoped command gets today.
- D. A walk from the pane the window focuses after the close.

### Whether focus moves to the pane the command ran in

Today the palette returns focus to the origin pane before it runs a command. Choosing a tab is the precedent for
focusing another pane. Under UTERM-036, a routed open's pane takes focus.

- A. Focus moves to the walked pane after the command runs.
- B. Focus stays on the origin pane, and the walked pane flashes or the status bar names it.
- C. The row names its target before the user chooses it. It puts the walked pane's selected tab title, neutralized, in
  the row's detail text. Combinable with A or B. It is the only option that shows the target before a command with no
  undo runs. It needs the target at refresh time. The palette's query matches detail text, so C must also say whether
  that title is matched. If it is, a program that sets a tab title can steer which command rows a query shows.

### When no pane of the command's type is in the window

- A. The row stays dimmed, by UTERM-002's existing rule for an unavailable command.
- B. The row is hidden.
- C. The command opens a new pane of its type beside the focused pane, as UTERM-018 does for a file with no capable
  pane, then runs there. This works for Open, but not for a command that needs content, such as Find.
- D. The row stays enabled, and choosing it posts a status message.

### Which commands walk

Closes are not applet commands. Close Tab and Close Pane are uniterm's, and UTERM-042's tab actions add no applet items
of their own. So none of them walks. Some applet commands still have no guard and no undo: the terminal's Clear Screen,
and the map's Clear Program Pins.

- A. Every applet command walks, by one rule.
- B. Every applet command walks, except one that discards content with no undo. Each command declares whether it may
  walk. This adds a field to the applet command entry.
- C. Only commands that open or show content walk. Each command declares it, with the same new field.

### Titles shared across applet types

"Open…", "New Tab", "Reload", the tab selection commands, and Find each appear under two or more types.

- A. Keep the titles, and rely on the applet name on the right of the row.
- B. Give the pane-local Open a palette title of its own, such as "Open File…". This needs a palette title field on the
  applet command entry, since a registered applet command takes its menu title from its palette title today.
- C. Build palette titles as "<Title> in <Applet Name>". This also needs the new field, or a rule in the palette.

### Ranking a foreign command against the focused applet's own

With every applet's command enabled, a query ranks same-title rows equally, and ties fall to registration order.
Recency is per command, app-wide, worth up to 24 points.

- A. A command of the focused pane's applet type ranks above the same match from another type. This must say whether
  it outranks recency.
- B. Rank same-title commands by distance to their target pane. The focused type is at distance 0, so this includes A.
- C. No change. Recency and match quality alone decide.

### Sequencing against UTERM-018

A nearest-of-type function already exists for scripts. It breaks ties by reading order, then pane ID. UTERM-018 M1
replaces that tie rule for every caller, and UTERM-018 is queued but not started.

- A. Ship on the existing function, extracted so the palette and scripts share it. Ties follow reading order until
  UTERM-018 M1 lands, then change for both callers at once.
- B. Wait for UTERM-018 M1, so the palette ships with UTERM-018's tie rule from the start. M1 also builds the capability
  contract and the macOS hand-off, which this proposal does not need.

### How a command row reads to VoiceOver

UTERM-002 mitigated "a program-set tab title passes for a uniterm command" by showing each entry's kind. Tab rows
already show their applet's name in place of "Tab". With applet names on command rows too, a web page titled "Reload"
and the browser's Reload command both read "Reload, Browser". Sighted users still see different icons, but the icon has
no accessibility description, and the row's accessibility value is its label. Choosing the spoofed row only selects a
tab.

- A. Add the kind to the accessibility value, such as "Browser command" and "Browser tab".
- B. Give the row icon an accessibility description.
- C. No change.

## Risks

- **A command with no undo lands on the wrong pane of the right type** — likelihood: medium, impact: medium.
  With two terminals in the window, Clear Screen chosen from a browser clears the nearer one. The map's Clear Program
  Pins has no undo. Focus moving afterward shows the target only after the command ran.
  Mitigation: "Whether focus moves" option C names the target on the row before the user chooses it. "Which commands
  walk" B and C exclude such commands. One of these must be chosen before acceptance, or the risk accepted.
- **UTERM-018 changes the tie rule after this proposal ships** — likelihood: high, impact: low.
  If this proposal ships first on the existing function, ties change when UTERM-018 lands.
  Mitigation: one shared function owns "nearest", so the change reaches the palette and scripts together. "Sequencing
  against UTERM-018" decides whether the palette ever uses the old tie rule.
- **Two titles read the same to VoiceOver** — likelihood: medium, impact: low.
  Mitigation: "How a command row reads to VoiceOver".

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
- The shared function never ranks from an origin pane that is not in the tree. Today every candidate then ties, and
  reading order picks one silently
- When the palette's origin pane closes while the palette shows, a foreign command behaves as "When the palette
  resolves the target" settles
- The walk exists only on the palette path. A menu item or key for an applet command still acts on the focused pane
  only, unless "Where the walk lives" settles otherwise
- The `applet:` filter chip either includes command rows of that type or keeps its "tabs" wording on purpose
- Each open decision above is settled and built as decided

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
  undecided.

## References

- Run report for the palette, with the best guess on dimming: `spec/reports/20261101-uterm-002-m1-m3-command-palette.md`
- ADR-02: panes are addressed by stable ID
- ADR-04: applet keys act on one applet's content
- ADR-05: a close that would end running work asks first
- ADR-15 (proposed): an action means one thing, whoever starts it
