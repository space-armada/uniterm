# UTERM-042: Actions for Tabs and Their Markers

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-26

## Dependencies

- UTERM-041 M1, for M2: the marker slot, the published markers, the kind table, and the call that performs a marker's
  action
- UTERM-041 M2, for M3: the controlling chip and each session root's tab
- UTERM-004, for pane control, the control badge, and Revoke Controller. It is implemented, so M1 can start now

UTERM-019's run-end marker is not a dependency. M2 tests "Rebuild Tab" with a test-published marker, and UTERM-019
M3 builds on M2. Amended 2026-11-21; see Decision Log.

## Impacts

- UTERM-041 — "Interactive markers" says the authority marker has no actions, and "What a click on the chip does"
  makes the chip inert. "Where the menu opens" keeps both, and makes the run-end marker inert too, so its "Rebuild
  Tab" moves to the tab's menu. "VoiceOver" then has no marker that is a button. "Interactive markers" also says a
  published marker carries only its kind and its available actions. "How the host learns which owners a tab's
  authority marker stands for" makes the authority marker carry its owners too. UTERM-041 is amended for each, with a
  Decision Log entry.
- UTERM-004 — the badge's control menu. "Which controllers a tab's menu names" adds one revoke item per controller
  beside the pane-wide Revoke Controller. "Palette commands: wording and target" renames that item and its palette and
  File menu command "Revoke All Controllers". "How a go-to target is told apart" adds a driver's owner number to its
  name in the badge's lines.
- UTERM-019 — "What a run leaves in its tabs". Its run-end marker's "Rebuild Tab" is offered in the tab's right-click
  menu and as a palette command, per "How marker-kind actions join the menu". A click on the marker itself offers
  nothing.
- UTERM-043 — it names "Revoke Controller" and plans pause items in this proposal's menu and palette. "Palette
  commands: wording and target" renames the pane-wide item "Revoke All Controllers".
- UTERM-024, UTERM-025, UTERM-028, and UTERM-039 — each names the pane-wide revoke in its decisions, risks, or
  checks. Each now says "Revoke All Controllers", per "Palette commands: wording and target".

## Summary

A tab and its markers get one menu of actions. It holds revoking one controller, going to the tab a controller runs
in, going to the tabs a controller can act on, and ordinary tab actions such as Close Tab. Every action is also a
command in the command palette, so the keyboard reaches it.

## Motivation

UTERM-041 marks which tabs a controller can act on, with two gears, and which tab a controller runs in, with the chip.
Both markers are inert. The user can see the relationship but cannot act on it from where it shows.

Today the only control actions sit in the pane badge's menu (`WindowKit/PaneFrameView.swift`, about lines 348-374).
Its Revoke Controller ends every controller of the pane at once (`revokeController(_:)`,
`MainWindowController+Control.swift`, about line 121). The host can already revoke a single connection
(`ScriptHost.revokeControllers(_:)`, which takes a set). Nothing in pane chrome offers that.

Nothing takes the user from a controlled tab to the tab driving it, or the other way. The palette's `chooseTab`
(`MainWindowController+Palette.swift`, about line 203) already focuses a pane and selects a tab. A go-to action can
build on that.

Tab items take no right-click today. `AppletTabBar.swift` has no `rightMouseDown`, `menu(for:)`, or context menu. A
click on the item selects the tab, and its close button takes its own click.

The palette already lists commands beside tabs. Each command runs against the palette's target pane through a
`CommandContext` (`MainWindowController+Palette.swift`, about lines 87-104).

## Design Decisions (Settled)

### Which actions are in scope

Decision: the menu holds four kinds of action. Chosen by the user on 2026-11-21.

- Revoke one controller, rather than every controller of the pane.
- Go to the tab a controller runs in, from a tab it controls.
- Go to the tabs a controller can act on, from the tab it runs in.
- Ordinary tab actions, such as Close Tab. See "Which general tab actions".

Rationale: the markers show a relationship between tabs. These actions let the user follow it and end it where it
shows.

### Every action is a palette command

Decision: each action in the menu is also a command in the command palette, so the keyboard reaches it. Chosen by the
user on 2026-11-21.

Rationale: a menu opened by a click leaves keyboard users out. The palette already runs commands against its target
pane.

### Where the menu opens

Original question: a left-click on a marker, a right-click on a tab, or both. The user leaned toward one of the first
two, since two mouse interactions for one menu are not needed.

Decision: a right-click or Control-click on a tab item opens one menu for that tab. It holds the tab's marker actions
and the ordinary tab actions. It is the only mouse path to them. Every marker is inert on a left-click, so a click on it
selects the tab like the rest of the item. That includes a marker kind with actions, such as the run-end marker.
(autonomous) Amended 2026-11-21 at the review gate; see Decision Log.

- This amends UTERM-041 "Interactive markers", whose marker kind with actions opened its own small menu on a click.
- The menu acts on the tab it was opened on, by that tab's ID, whether or not the tab is selected. Opening it does not
  select the tab.
- Panes with no tab bar and VoiceOver take their own questions below.

Rationale: a right-click on a tab is the macOS convention for tab actions, and it reaches every tab, marked or not. A
left-click on a marker reaches only marked tabs, so a tab with no marker would have no menu for the ordinary tab actions
the settled scope puts in it. Doing both would give one menu two mouse paths. The user settled on one mouse path, and
the run-end marker's own menu was a second path to its action, so it goes too. Converged in 1 pass, then amended at the
review gate.

### What revoking one controller ends

Original question: ADR-14 says "Revocation ends the grant in every window it reaches." The candidates were the
controller's whole grant in every window, and only its reach into this pane. A driver keeps its attached channel to its
own pane after revoke.

Decision: revoking one controller ends that controller's whole grant, as the badge's Revoke Controller does for each
controller it ends. For a connection, its live grant and waiting calls end host-wide, and its groups lose their owner
in every window. For a driver, its run is marked revoked, its clipboard grant ends, and its groups lose their owner. A
driver keeps the channel the user attached to its own pane, as with the badge. The badge's pane-wide item stays.
(autonomous)

- Every other controller of the pane keeps its grant, its groups, and its waiting work. Today a group's owner ending
  withdraws every launch waiting in each released pane, whoever staged it. A one-controller revoke must withdraw only
  the revoked owner's launches.
- A driver's owner number is unique only within its window, so a driver is named by its window and its owner.
- The Controllers & Permissions window already revokes one connection alone the same way
  (`ControllersWindowController.swift`, about line 329). This brings that to pane chrome, and covers drivers too.
- How the item says that a driver's attachment stays is part of "Palette commands: wording and target".

Rationale: this is the plain behavior. It matches ADR-14, the badge, and the Controllers window, and it adds no state.
A revoke for this pane alone would need new per-controller, per-pane refusal state and a deviation from ADR-14. The
controller's group would still name it as owner, so UTERM-041's authority marker would keep showing on a pane it can no
longer reach. Ending a driver's attached channel too would make the one-controller revoke stronger than the pane-wide
one. Converged in 1 pass.

### Going to a tab across windows, and targets that close

Original question: does go-to raise another window? Does "go to controlled tabs" list them or cycle through them? What
does an action do when its target closes while the menu is open? A controller granted a pane explicitly is bound to the
pane's newest session, per UTERM-041 "How an explicit grant picks its tab", so go-to lands on that tab.

Decision: go-to resolves its target first. When the target is in another window, it then raises that window. Then it
focuses the pane and selects the tab. "Go to controlling tab" has one item per controller of the tab. "Go to
controlled tabs" is a submenu with one item per tab the controller can act on, across windows. It leaves out the tab
the menu was opened on. Each target is held by window, pane, and tab ID, never by index. When a target is gone at the
time it is chosen, nothing changes, and a notice in the menu's window says the tab has closed. (autonomous)

- Each submenu item names its target as "How a go-to target is told apart" settles. Amended 2026-11-21; see Decision
  Log.
- ADR-12, which once limited focus moves, is retracted. A go-to is the user's choice in any case.

Rationale: a run can open a window of its own, per ADR-14. A go-to limited to one window would have no target from a
tab in that window. A single item that steps through the tabs hides which tabs exist, and its place between uses is
hidden state. A silent no-op is a failure with no feedback. Converged in 1 pass.

### Which controllers a tab's menu names

Original question, raised by the review: the menu's revoke and go-to items name controllers. Are they every controller
of the pane, or only those the tab's markers stand for? The candidates were every controller of the pane on every tab,
the controllers behind the tab's markers alone, and those plus per-controller revoke items in the badge's menu.

Decision: a tab's menu names the controllers its own markers stand for. They are each owner behind the tab's
authority marker, and each controller behind its chip. The badge's menu also gains one revoke item per controller of
the pane, beside its pane-wide Revoke Controller. Each does what "What revoking one controller ends" settles.
(autonomous, addition)

- A tab with no marker names no controller in its menu.
- No menu names a controller the user has already revoked.

Rationale: tab-level actions stay on the tab, and pane-level authority stays on the badge, as UTERM-041 "What 'can act
on' covers" splits them. Some controllers have authority over the pane and no marker on any tab. One is the owner of a
group that holds a terminal pane, since terminal tabs never carry the authority marker. Another is a driver that holds
a clipboard grant and owns no group. It shows no chip and its own pane carries no authority marker. Without the badge's
items, such a controller could be revoked alone only from the Controllers & Permissions window, which covers
connections only. Listing every controller of the pane on every tab would offer go-to and revoke on a tab the
controller cannot act on, such as a browser tab the user opened. The addition is the badge's per-controller items.
Converged in 1 pass.

### How the host learns which owners a tab's authority marker stands for

Original question, raised by the review: only the browser knows which owner opened each of its tabs. A published
marker carries only its kind and its available actions, per UTERM-041 "Interactive markers". Nested groups can give a
browser pane two granted owners. The host then cannot name the owner behind a tab's authority marker. It also cannot
build "Go to controlled tabs" for one controller.

Decision: a published authority marker carries the owners it stands for, as the host identified them when it handed
the owner set down. The applet passes them through unchanged, as the chip passes its names through. The host builds
each menu's authority-marker items, and the lists of tabs an owner can act on across windows, from the tabs each pane
publishes. This amends UTERM-041 "Interactive
markers" the way "What a click on the chip does" already did. (autonomous)

- This covers the authority marker. The chip's controllers come from host state, per "Where the host gets the chip's
  controllers". Amended 2026-11-21; see Decision Log.

Rationale: the browser already decides which owner a tab belongs to when it marks the tab. Carrying that owner in the
marker keeps one source for the marker and the menu, so the two cannot disagree. The identities come from the host, so
no applet text reaches the menu.

### Where the host gets the chip's controllers

Original question, raised by the coherence review: a tab's menu names the controllers behind its chip, for revoke and
go-to. The published chip carries display names only, and names collide. Two drivers of one program both read
"<program> (driver)", and a driver's owner number is unique only within its window. The candidates were the host's own
state, the published chip carrying identities, and resolving the names.

Decision: the host builds a tab's chip items from its own state. That is the per-tab controller set it hands down for
the chip, keyed by window and owner. The published chip is not read for this. (autonomous)

Rationale: unlike the authority marker, nothing about the chip is known only to the applet. The one host computation
feeds both the chip and the menu, so they cannot disagree. A stale published chip cannot offer a controller the user
just revoked. Carrying identities in the chip would amend UTERM-041 a second time for no capability the host lacks. A
name cannot pick one of two drivers that share it. Converged in 1 pass.

### How a go-to target is told apart

Original question, raised by the coherence review: go-to items name a target tab across windows. The settled text said
each names its target's window and pane. Every main window is titled "uniterm", so a window has no visible name. A
pane's visible name is its applet's title, which a page or a program can set. The candidates were window sections
numbered by the Window menu's order, a numbered window title, the tab title alone, and "this window" or "another".

Decision: an item's title is the tab title, neutralized as the palette neutralizes it. Its subtitle, drawn where no
title text reaches, names the applet type and the tab's details, as the palette's tab entries show them. Items sit
under host-drawn section headers, one per window: "This Window" first, then the other windows, numbered in the Window
menu's order. The palette's go-to entries carry the same window and applet type in their detail. (autonomous)

- A driver's revoke entry also names its window and applet type. Wherever the host names a driver, the name carries
  the driver's owner number, which is unique within its window, as "<program> (driver N)". So two drivers of one
  program in one window read differently in the badge, the chip's tooltip, and every entry. A tab title cannot tell
  them apart, since a page or a program can set it and a fresh viewer's title is fixed. Amended 2026-11-21; see
  Decision Log.

Rationale: the need is telling look-alike tabs apart, such as two "zsh" tabs in two windows. It is not a defense
against a spoofed title. Every target in a controller's go-to list is already in that controller's reach, a go-to only
moves focus, and the user sees where it landed. A header such as "Window 2" maps to nothing else on screen, since the
Window menu lists every window as "uniterm". The user checks by choosing it, which is cheap because a go-to changes
nothing else. Numbering windows in their titles would make the numbers checkable. It would also change a contract
across the app, in the Window menu, Mission Control, and window cycling, which nobody asked for. The tab title alone
would leave same-titled tabs in two windows impossible to tell apart. Converged in 1 pass.

### How marker-kind actions join the menu

Original question: UTERM-041 gives a marker kind its actions, and its run-end kind has "Rebuild Tab" in a small menu at
the marker. The candidates were folding every kind's actions into this menu, keeping each marker's own menu beside this
one, and keeping them out of this menu.

Decision: the tab's menu holds the actions of each marker kind the tab carries, in a section headed by that marker's
meaning, from UTERM-041's kind table. A marker has no menu of its own, per "Where the menu opens". So "Rebuild Tab" is
in the tab's menu, and it is a palette command for the target pane's selected tab. (autonomous) Amended 2026-11-21 at
the review gate; see Decision Log.

- The palette command is available when the selected tab publishes a marker that offers it. It runs through the same
  `Applet` call UTERM-041 added, and through UTERM-019's unsent-input question.
- The menu builds from host state and the tabs' published markers, and an applet action returns at once, per ADR-08.

Rationale: one menu holds everything a tab offers, and the keyboard reaches "Rebuild Tab" only as a palette command.
The tab bar takes no keyboard focus. The run-end marker is the only warning that a run's code may still read what the
user types, so its rebuild should have a keyboard path. The section heading carries the meaning line the marker's own
menu carried, and the menu still puts a deliberate choice between a stray click and the rebuild. The user settled on
one mouse path, the tab's right-click, so the marker's own menu goes.

### Which general tab actions

Original question: candidates included Close Tab, Close Other Tabs, Close Tabs to the Right, Duplicate Tab, and Move
Tab to a New Pane, and whether each applet adds its own items.

Decision: the menu holds Close Tab, Close Other Tabs, and Close Tabs to the Right. Each acts on the menu's tab by ID.
One new `Applet` call closes a set of tabs by ID. It asks one question for the whole set when any of them would ask
on its own close, such as a running command, edited input, or a download. The question lists each such tab's reason,
as a pane close lists `runningLabels`. A declined question closes
none of them. When the set holds a map tab with unsaved edits, the question offers Save, Don't Save, and Cancel, and
lists every such tab, per UTERM-062 "The map's unsaved edits across tabs". Amended 2026-11-26; see Decision Log. Applets add no items of their own. (autonomous)

- Each tab's close button already closes its own tab and asks first, inside the applet. The new call exposes that to
  the host by ID.
- Duplicate Tab and Move Tab to a New Pane are out of scope. A duplicate would carry a terminal's working directory
  into a new tab, which the project's rule on applet attributes makes an explicit decision of its own. A move needs a
  new contract to hand a live tab from one applet to another.
- ADR-04 governs any key binding. A menu item needs none.

Rationale: these follow the platform's tab menus, and the one question matches how a pane close already asks. An applet
keeps one question at a time, so asking once per tab would need a sequence and a rule for a refusal halfway. Applet
commands act on the selected tab, so an applet's own items would run on the wrong tab from a background tab's menu.
Converged in 1 pass.

### VoiceOver

Original question: UTERM-041 makes each marker its own accessibility element, and the tab's value stays "selected" or
"unselected". How is the menu reached by VoiceOver? The candidates were each menu item as a custom action on the tab,
the standard show-menu action, and the palette alone.

Decision: the tab element supports the standard show-menu action (VO-Shift-M). It opens the same menu as a
right-click, on the same tab, without selecting it. (autonomous)

- The pane-level entry is part of "Panes with no tab bar".

Rationale: show-menu is the platform's own way to reach a context menu. Custom actions would speak tab titles, which
are untrusted text, as action names, and they would flatten the go-to list's grouping by window and pane. The palette
alone would make the user select the tab first, which the menu avoids. Converged in 1 pass.

### Panes with no tab bar

Original question: UTERM-041 shows a one-tab pane's markers at the pane level, beside the badge. How does the user open
this menu there, and does it merge with the badge's menu? The candidates were the badge's menu holding the tab's items,
a right-click on the pane-level markers, no pane-level entry, and a right-click on the badge as well.

Decision: a right-click or Control-click anywhere on the pane-level marker cluster opens the one tab's menu, the same
menu a tab item opens. Close Other Tabs and Close Tabs to the Right show disabled there. The pane-level marker elements
support the standard show-menu action for VoiceOver. A left-click on a pane-level marker does nothing, as on any
marker. (autonomous)

- Close Tab there does what Close Tab or Pane does. When the applet has no tab to close, it closes the pane and asks
  the same way.
- A one-tab pane with no marker has no mouse entry to the tab menu. Its controllers' revokes are in the badge's menu,
  and its other actions are palette commands.
- Every marker is an image to VoiceOver, since none opens a menu of its own. UTERM-041 "VoiceOver" made a marker with
  actions a button, so it is amended with "Interactive markers". A pane-level marker also answers show-menu.

Rationale: the pane-level markers stand in for the tab, so the same gesture opens the same menu. Drivers attach only
to the image and map viewers, which have one tab each. So a driver's chip always shows at the pane level, and without
this entry its go-to items would have no mouse path where the chip shows. Folding the tab's items into the badge's menu
would repeat each revoke item in one menu, and the items would move when a second tab opens. A badge that opened two
menus by mouse button would give one control two meanings. A one-tab pane with no marker loses only Close Tab, which
Cmd-W already does. Converged in 1 pass.

### Palette commands: wording and target

Original question: the palette runs a command against its target pane. Does a command act on the target pane's
selected tab? How does a one-controller revoke read beside the badge's pane-wide one? When a tab has several
controllers, how does the user pick one?

Decision: tab actions act on the target pane's selected tab. Controller actions are dynamic palette entries, built the
way the palette builds its tab entries. Each entry holds its owner's or target's identity. For the target pane, the
palette lists (autonomous):

- one "Revoke <name>" entry per controller the badge's menu names
- one "Go to <name>'s Tab" entry per controller behind the selected tab's authority marker
- one entry per tab that a controller behind the selected tab's chip can act on, in any window. Its title names the
  controller and the target, as "Go to <tab> for <name>", and its detail carries the target's window and applet type.
  A target in this window gets its own entry too, since the palette's plain tab entries do not say which tabs a
  controller can act on. Amended 2026-11-21; see Decision Log.
- "Close Other Tabs", "Close Tabs to the Right", and "Rebuild Tab", as commands on the selected tab. Close Tab is the
  existing "Close Tab or Pane"

The pane-wide command and the badge's item are renamed "Revoke All Controllers". Every one-controller revoke, in the
badge's menu, the tab's menu, and the palette, names its controller in its title. A subtitle, or the palette entry's
detail, states its reach. For a driver in its own pane, that reads that it ends its groups and grants and keeps driving
this pane. Elsewhere it says the grant ends everywhere. A driver's entry also names its window and applet type, per
"How a go-to target is told apart", since two drivers of one program share a name. Amended 2026-11-21; see Decision
Log. An entry whose owner or target is gone when it is chosen changes nothing and posts
a notice, as a gone tab does.

Rationale: the user picks a controller by typing its name, and every choice is reachable without a mode the palette
lacks. The rename keeps "Revoke Controller" from reading as one controller beside "Revoke <name>", which is the risk
"Two revokes with different reach". Commands available only for a tab with one controller would leave a tab with two
controllers no keyboard path, against "Every action is a palette command". Converged in 1 pass.

- The rename reaches the File menu's command, the badge's item, and the tests that look for "Revoke Controller".
- The command keeps its ID, `uniterm.revoke-controller`, so a key binding or the palette's recent list still finds it.

## Design Decisions (Open)

None.

## Risks

- **Two revokes with different reach** — likelihood: medium, impact: medium. The badge's Revoke Controller ends every
  controller of the pane, and this proposal's ends one. A user who learns one may misjudge the other. Mitigation: the
  pane-wide item becomes "Revoke All Controllers", and each one-controller item names its controller, per "Palette
  commands: wording and target".
- **A revoke from the wrong tab** — likelihood: low, impact: medium. A menu opened on one tab that ends a grant
  reaching many windows can surprise the user. Mitigation: the item names the controller, and its subtitle states its
  reach, per "Palette commands: wording and target".
- **A bulk close outruns reopen** — likelihood: low, impact: low. Close Other Tabs on more idle tabs than an applet
  keeps for reopen closes them with no question, and the oldest cannot be reopened. Terminal and browser keep 20.
  Accepted: a tab that would ask on its own close, such as one running a command, holding edited input, or
  downloading, still asks, and the platform's own Close Other Tabs does
  the same.
- **The design rests on unbuilt UTERM-041 work** — likelihood: medium, impact: medium. M2 needs UTERM-041 M1's tab
  bar, its markers, its kind table, and the marker action call, and M3 needs UTERM-041 M2's chip. None is built. A later change
  to UTERM-041's marker payload would change this design. Mitigation: M1 needs none of it and ships first. The one
  payload change this proposal needs is recorded in UTERM-041 once this review ends, per Impacts.
- **An action on a target that is gone** — likelihood: medium, impact: low. A tab or pane can close while the menu is
  open. Mitigation: actions hold stable identities, per ADR-02. When the target is gone, nothing changes and a notice
  says the tab has closed, per "Going to a tab across windows, and targets that close".

## Milestones

### M1: Revoking one controller from the badge

**Status:** NOT STARTED

Builds only on control code that exists today.

- The badge's menu has one revoke item per controller of the pane, drivers included, beside the pane-wide item
- Revoke for one controller ends that controller's grant as "What revoking one controller ends" settles, and leaves
  every other controller of the pane in place
- Revoking one controller of a pane that holds another owner's waiting launch leaves that launch in place. A failing
  test shows `bugs/20261121-owner-end-withdraws-other-owners-launches.md` first, with nested groups, since that bug is
  not confirmed
- No menu or palette entry names a revoked controller, including a connection bound by ancestry that keeps its
  connection open. A failing test shows `bugs/20261121-revoked-controller-stays-on-badge.md` first
- A driver is named, listed, and revoked by its window and owner, so two windows' drivers with one owner number never
  mix
- Every one-controller revoke names its controller, and its subtitle or detail states its reach. A driver's entry also
  names its window and applet type
- A driver's name carries its owner number wherever the host names it. Two drivers of one program driving two fresh
  map panes in one window give revoke entries that read differently
- "Revoke Controller" reads "Revoke All Controllers" in the badge, the palette, and the File menu
- The palette lists one "Revoke <name>" entry per controller the badge's menu names. An entry whose owner is gone when
  chosen changes nothing and posts a notice

### M2: The tab menu, marker actions, and closing tabs

**Status:** NOT STARTED

Builds on UTERM-041 M1, which rewrites the shared tab bar and publishes markers. UTERM-019 M3 builds on this
milestone, so the run-end marker never ships without a way to rebuild its tab.

- A right-click or Control-click on a tab item opens its menu. A right-click on a background tab acts on that tab and
  does not select it
- Close Tab, Close Other Tabs, and Close Tabs to the Right close the tabs they name through one call. When any of them
  needs asking, one question lists each tab's own reason, edited input and downloads included, and declining closes
  none. Close Other Tabs never closes the menu's tab
- Which tab is selected after a close from a background tab's menu matches what the tab bar's close button leaves
- A close declined because the applet already has a question up tells the user so
- "Close Other Tabs" and "Close Tabs to the Right" are palette commands on the selected tab. Close Tab is the existing
  "Close Tab or Pane"
- VO-Shift-M on a background tab opens its menu without selecting it, and VoiceOver speaks each item
- An action whose target closed while the menu was open changes nothing, and a notice in the menu's window says the
  tab has closed
- Building the menu never waits on an applet or a script
- A tab carrying the run-end marker offers "Rebuild Tab" in its menu, and the palette's "Rebuild Tab" is available only
  when the selected tab offers it. Both go through UTERM-019's unsent-input question. A test-published run-end marker
  covers this until UTERM-019 M3 publishes the real one
- A left-click on any marker, the run-end marker included, selects the tab and opens no menu. A right-click or
  Control-click on a marker in a tab item opens the tab's menu
- A right-click or Control-click anywhere on a one-tab pane's marker cluster, gaps included, opens the tab's menu, with
  Close Other Tabs and Close Tabs to the Right disabled. A left-click there opens nothing and does not reach the applet.
  VO-Shift-M on a pane-level marker opens the menu
- Close Tab in a one-tab pane's menu does what Close Tab or Pane does, and asks the same way

### M3: Controllers in the menu

**Status:** NOT STARTED

Builds on M2 and on UTERM-041 M2, for the chip.

- A published authority marker carries the owners it stands for, and the applet passes them through unchanged
- In a browser pane with two granted owners, each tab's menu names only the owner that opened it, and each owner's
  "Go to controlled tabs" lists only its own tabs
- A tab's menu names only the controllers its markers stand for. Its authority items come from the published tabs,
  intersected with the host's live owners. Its chip items come from host state, and they match the controllers the
  chip's tooltip names on the same turn as a control change
- Go to the controlling tab resolves the target, raises its window when it differs, focuses that pane, and selects that
  tab. Go to controlled tabs reaches each tab the controller can act on, in every window, and never mixes two windows'
  drivers that share an owner number
- A go-to item's title is the neutralized tab title, its subtitle names the applet type and the tab's details, and it
  sits under its window's header. The list leaves out the tab the menu was opened on
- A go-to whose target is gone changes nothing, and a notice in the menu's window says so. It never raises the other
  window first
- The palette lists the go-to entries "Palette commands: wording and target" settles, same-window targets included.
  Typing a controller's name finds every go-to entry for that controller
- A UI test opens the menu on a controlled browser tab and on a controller's terminal tab, and runs go-to both ways

## Decision Log

- 2026-11-21: Drafted at the user's request during UTERM-041's review, which kept that proposal's markers inert. The
  user chose the four kinds of action and that every action is a palette command. The user leans toward one mouse
  entry point rather than two.
- 2026-11-21: Review start: 1 milestone, 2 settled decisions, 3 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the 8 open questions, at the commit "Draft
  UTERM-042 for one action menu on a tab and its markers".
- 2026-11-21: Where the menu opens: a right-click or Control-click on a tab opens the tab's menu. Markers keep
  UTERM-041's left-click behavior, so UTERM-041 needs no amendment. (autonomous)
- 2026-11-21: What revoking one controller ends: its whole grant, as the badge's Revoke Controller ends each
  controller, with a driver keeping its attached channel. Other owners' waiting launches in the pane stay. (autonomous)
- 2026-11-21: Going to a tab across windows: go-to resolves its target, raises its window, focuses the pane, and
  selects the tab. Controlled tabs are listed in a submenu, and a gone target posts a notice. Corrected the risk "An
  action on a target that is gone" and M1, which said a gone target does nothing silently. (autonomous)
- 2026-11-21: Filed `bugs/20261121-owner-end-withdraws-other-owners-launches.md`: an owner's end withdraws every launch
  waiting in its released panes, whoever staged it. Not confirmed.
- 2026-11-21: Which controllers a tab's menu names: those its markers stand for, and the badge's menu gains one revoke
  item per controller of the pane. (autonomous, addition)
- 2026-11-21: How the host learns which owners a tab's authority marker stands for: the marker carries them, as the
  chip carries its names. This amends UTERM-041 "Interactive markers". (autonomous)
- 2026-11-21: How marker-kind actions join the menu: the tab's menu holds them too, and the marker keeps its own menu.
  "Rebuild Tab" becomes a palette command. (autonomous)
- 2026-11-21: Which general tab actions: Close Tab, Close Other Tabs, and Close Tabs to the Right, through one new call
  that closes a set of tabs by ID and asks once. Duplicate and Move are out of scope. (autonomous)
- 2026-11-21: VoiceOver: the tab element's show-menu action opens the tab's menu. (autonomous)
- 2026-11-21: Added the risk "A bulk close outruns reopen", accepted. (autonomous)
- 2026-11-21: Panes with no tab bar: a right-click on the pane-level marker cluster opens the one tab's menu, and the
  markers answer VoiceOver's show-menu. (autonomous)
- 2026-11-21: Palette commands: dynamic entries per controller and per go-to target, tab actions on the selected tab,
  and the pane-wide revoke renamed "Revoke All Controllers". (autonomous)
- 2026-11-21: Coherence review. Amended "Palette commands: wording and target": it listed a controlled tab only when
  the palette's own tab entries did not, which left same-window targets with no controller-scoped entry. Every target
  now gets one. Corrected the UTERM-019 Impacts line, which said "Rebuild Tab" may fold in, and added UTERM-043 to
  Impacts for the rename. (autonomous)
- 2026-11-21: Where the host gets the chip's controllers: from host state, not the published chip. Narrowed "How the
  host learns which owners..." to the authority marker. It said the host builds "every menu" from published tabs.
  (autonomous)
- 2026-11-21: How a go-to target is told apart: the neutralized tab title, a subtitle with the applet type and the
  tab's details, and a header per window. Amended "Going to a tab across windows" and the palette decision. They said
  each item names its target's "window and pane", which have no host-drawn names, and the reason was disambiguation,
  not spoof defense. (autonomous)
- 2026-11-21: Split M1 by dependency into M1 one-controller revoke, M2 the tab menu and closing tabs, and M3 the
  marker's actions. Routed checks for each close's reasons, the selection after a close, a declined close, stale
  published owners, the chip items, and a Control-click on a run-end marker in a tab. Added the risk "The design rests
  on unbuilt UTERM-041 work". (autonomous)
- 2026-11-21: Re-check fixes. Each palette go-to entry for a chip's controller now names that controller in its title,
  so typing the name finds it. A driver's revoke entry no longer says it is named like a go-to target. Two drivers of
  one program in one window are told apart by their panes' tab titles. (autonomous)
- 2026-11-21: Risk review: every risk carries a likelihood, an impact, and a mitigation or an acceptance. No risk is
  both high likelihood and high impact. No one-way door: menus and markers are never stored, every changed contract
  stays inside one binary, and the renamed command keeps its ID. (autonomous)
- 2026-11-21: Final re-check fix, not re-checked: the proposal loop ran its three passes. Two drivers of one program in
  one window were to be told apart by their panes' tab titles. A fresh map or image pane has a fixed title, and a page
  or a program can set it, so the entries could match. A driver's name now carries its window-unique owner number
  wherever the host names it. (autonomous)
- 2026-11-21: Review gate: the user kept the badge's per-controller revoke items (addition), the rename to "Revoke All
  Controllers", a driver's owner number in its name, and the authority marker carrying its owners.
- 2026-11-21: Review gate: the user restated one mouse path for a tab's actions, the tab's right-click. Amended "Where
  the menu opens": it said a marker kind with actions "keeps its own small menu". Every marker is now inert on a
  left-click. Amended "How marker-kind actions join the menu": it said "Rebuild Tab" is in both the marker's menu and
  the tab's. It is now in the tab's menu and the palette only. This amends UTERM-041 "Interactive markers" and
  "VoiceOver".
- 2026-11-21: Amended UTERM-041 "Interactive markers", "VoiceOver", "One marker or several", its Impacts, and its M1
  run-end check: every marker is inert on a click, and the authority marker carries its owners.
- 2026-11-21: Accepted by the user.
- 2026-11-21: Moved four checks from M3 to M2: "Rebuild Tab" in the tab menu and the palette, a left-click on any
  marker opening nothing, the right-click on a one-tab pane's markers, and Close Tab in a one-tab pane. They need only
  UTERM-041 M1, not its chip. UTERM-019 M3 now builds on M2, so its run-end marker never ships without a way to
  rebuild the tab. Dependencies dropped UTERM-019, which would have made the two proposals depend on each other, and
  now names which UTERM-041 milestone each of M2 and M3 needs. M2 is now "The tab menu, marker actions, and closing
  tabs", and M3 is "Controllers in the menu".
- 2026-11-21: Scheduled as M1-M3 in queue.md.
- 2026-11-26: From UTERM-062, which gives the map viewer tabs. A set close that includes a map tab with unsaved edits
  asks Save, Don't Save, or Cancel for every such tab in one question, instead of Close or Cancel. The rationale in
  "Panes with no tab bar" that drivers attach only to one-tab viewers no longer holds once UTERM-062 lands. Where a
  driver's chip shows then is not settled here.

## References

- UTERM-041: the marker slot, the chip, and the call that performs a marker's action
- UTERM-004: pane control, the badge, and Revoke Controller
- UTERM-019: the run-end marker and "Rebuild Tab"
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): revocation ends a grant in every window it reaches
- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): stable node identity
- [ADR-08](../adr/ADR-08-ui-responsiveness.md): the main thread never waits on another process
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): key bindings
