# UTERM-041: A Uniform Marker Slot for Every Tab

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-27

## Dependencies

- UTERM-005, for the browser's tab ownership by a controller's grant
- UTERM-037, for the browser's remote commands as they now behave
- UTERM-004, for pane control, grants, and the pane's control badge

## Impacts

- UTERM-019 — "What a Run Leaves in Its Tabs". Its sentence that a tab's "remote-control marker goes away" at run end
  (about line 502) most likely refers to the pane badge. UTERM-004 CONTROL-1 and UTERM-005 "Control" define the
  "remote-control marker" as the pane badge. Separately, UTERM-019 designs a second, per-tab marker for tabs not
  rebuilt at run end (about lines 509, 522, and 888). That marker says a controller's code may still run in the tab,
  offers a rebuild, and outlives the grant. This proposal's slot must hold it, so UTERM-019 M3's marker waits on this
  proposal's M1. UTERM-019 is updated once this proposal is decided. M1 builds the run-end kind, and UTERM-042 offers its action from the tab's menu. UTERM-019
  M3 publishes the marker and implements "Rebuild Tab", per "Interactive markers". It gains these checks: choosing
  "Rebuild Tab" runs the rebuild through the unsent-input question, and a spared tab shows the run-end marker in the
  tab bar or at the pane level.
- The terminal and browser applets: the shared tab bar they use gains a marker slot.

## Summary

Every tab of every pane gets one place to show markers, drawn the same way everywhere. A pane whose tab bar is hidden,
or whose applet has no tabs, counts as its one tab and shows its markers beside the pane's control badge. The first
marker shows authority: a tab is marked while a controller's live grant can act on it.

## Motivation

A controller can drive some of a browser pane's tabs and not others. UTERM-005 lets a controller act only on tabs it
opened, and the user's own tabs sit beside them. Today the pane's control badge says only that the pane is under
control. Nothing says which tabs the controller can reach.

UTERM-019 designs a second per-tab marker for tabs a run leaves behind. It warns that a controller's code may still
run in the tab, and it outlives the grant. As designed today, it never shares a tab with the authority marker. It
appears when the grant ends, and a later grant owns only tabs it opens itself. The slot still holds a list. A list
costs nothing while a tab carries one marker, and it stays right when a later kind can coincide with another.

The user asked for a uniform slot rather than a browser-only mark. Any tab of any pane can show markers, even in pane
types that do not use them yet. When markers are needed, there is one way to display them.

Today the shared tab bar (`Packages/UnitermKit/Sources/AppletKit/AppletTabBar.swift`) takes plain titles through
`update(titles:selected:canOpenTab:)`. Each tab item holds only a title and a close button. A published tab
(`AppletTab`, in `AppletKit/AppletTab.swift`) carries an ID, a title, and search details, and nothing else. The pane's
control badge (`WindowKit/PaneFrameView.swift`) is a 20-point antenna in the pane's top-right corner, drawn by the
window.

The badge also covers the tab bar's trailing end. The browser already makes room for it. `BrowserApplet+Remote.swift`
sets `content.badgeReach`, and `BrowserView.swift` sets `tabBarTrailing.constant = -badgeReach`. The terminal forwards
the reach to the shared bar's `trailingReserve`. See "Keeping the tab bar clear of the control badge" and the linked
bug.

## Design Decisions (Settled)

### A published tab carries its markers, and shared code draws them

Decision: a published tab carries a list of markers. The shared tab bar draws them in a fixed slot in each tab item.
The host draws the markers of a pane's one tab when the pane shows no tab bar. Chosen by the user on 2026-11-21.

- An applet reports markers through the tabs it already publishes. The host learns of a change through the existing
  tab change notice. Drafting detail, not the user's choice. See "Who computes the authority marker".
- An applet with no tabs publishes one tab, as today, and its markers show at the pane level. Drafting detail, not the
  user's choice.
- An applet never draws a marker itself. Drafting detail, not the user's choice.

Rationale: one look everywhere, and a new applet gets the slot by publishing tabs, as it already must.

### The authority marker follows what a live grant can act on

Decision: the first marker is authority. A tab carries it while a controller's live grant can act on that tab, and it
clears when the grant ends. Chosen by the user on 2026-11-21.

- In a browser pane, only the tabs the controller opened carry it, per UTERM-005 "Control". Drafting detail, not the
  user's choice.
- In an applet that takes commands or sent content on its one tab, such as a text viewer, that tab carries it while a
  live controller may address the pane. A terminal tab never carries it, since a terminal takes neither. See "What
  'can act on' covers" and "Access mode or live controller". Once UTERM-062 gives the viewers tabs, a viewer tab in a
  group pane carries it only when the controller owns that tab, as in a browser. Amended 2026-11-21 and 2026-11-26; see
  Decision Log.
- The marker follows the grant, never the content. A tab the controller opened loses it when the grant ends, and a tab
  the user opened never carries it. Drafting detail, not the user's choice.

Rationale: the marker states the tabs a granted program can act on. It shows authority, which ADR-15 keeps apart from how an
action behaves, so it does not make a program's work look different.

### A pane with no tab bar shows its marker beside the control badge

Decision: when the tab bar is hidden for a single tab, or the applet has no tabs, the pane's one tab shows its markers
just to the leading side of the pane's control badge. Chosen by the user on 2026-11-21.

- A click on a marker there acts as it does in the tab bar. See "Interactive markers". Amended 2026-11-21; see
  Decision Log.

Rationale: the badge says the pane's control state, and the marker says a live program can act on the pane's one tab.
Folding the two into one icon would give one icon two meanings. Amended 2026-11-21; see Decision Log.

### The markers' look

Decision: each marker is an SF Symbol in peach, drawn in the marker slot at 12 points or larger. Chosen by the user on
2026-11-21, after seeing every candidate rendered at real size and under color-blindness simulations in the mockup at
https://claude.ai/artifact/MNi6hZgjP6eBsqDc3rFVaP. A review may not change it without the user's consent.

- A tab a live grant can act on: two gears, filled (`gearshape.2.fill`).
- UTERM-019's run-end marker: the same filled gears with a slash through them. The slash is drawn in code over the
  symbol, since no slashed gear exists as an SF Symbol. Its accessibility label differs from the live marker's. The
  risk "A drawn slash looks off" records what the user accepted with it.
- The controlling tab or pane, per "Marking the pane doing the controlling": the chip (`cpu`), with the joystick
  (`arcade.stick`) as the backup.
- The pane's control badge keeps its antenna.

Rationale: two filled gears read as a mechanism at work and stay clear at tab size, and the chip reads as a program.
The run-end marker changes the live marker's own shape rather than adding a second mark beside it, which would change
another marker's meaning. A recolor, a dimmed form, or an outlined form either collapses into the live marker under
color blindness, fades at 12 points, or differs only by stroke weight when seen alone. At 10 points the chip reads as
a plain square, so the slot draws no marker smaller than 12 points.

- Drafting detail, not the user's choice: tab titles are untrusted text, so the marker sits in a region the title
  cannot reach. M1 checks that each symbol resolves on macOS 26.0, the app's minimum. The symbols were confirmed on
  macOS 26.6.2.

### Interactive markers

Original question: UTERM-019's run-end marker offers a rebuild, and it outlives the grant, when the badge may be
hidden. Decision 3 said a click on a pane-level marker opens the control menu. That menu belongs to the badge and may
have nothing to offer once the grant has ended. What does clicking a marker do in the tab bar? What does clicking a
pane-level marker do when the marker has no badge to belong to? Where does a pane-level marker sit when no badge
shows? Without an answer, UTERM-019's rebuild marker cannot use this slot.

Decision: each marker kind either has actions or has none. A click on any marker is inert, so it selects the tab like
the rest of the item. A kind's actions are offered in the tab's right-click menu, in a section headed by the marker's
meaning, per UTERM-042 "Where the menu opens". No action runs on a click on the marker. Every marker has a tooltip that
says what it means. (autonomous) Amended 2026-11-21; see Decision Log.

- The authority marker has no actions. It shows only while the pane is remote-controlled, so the badge always sits
  beside it, and the badge's menu already offers control.
- UTERM-019's run-end marker has one action, "Rebuild Tab". The rebuild still goes through UTERM-019's unsent-input
  question.
- A published marker carries only its kind and which of the kind's actions are available. The chip also carries the
  controller names the host supplied, per "What a click on the chip does". The authority marker also carries the
  owners it stands for, as the host identified them, per UTERM-042 "How the host learns which owners a tab's authority
  marker stands for". AppletKit derives each kind's symbol, accessibility label, meaning, and action titles from the
  kind. So two applets cannot word one kind differently, and no applet text, such as a title, reaches the menu.
  Amended 2026-11-21; see Decision Log.
- The host draws the pane-level marker. A new `Applet` call asks the applet to perform a marker's action on one of its
  tabs. The host and the applets ship in one binary, so the call has no version skew. Amended 2026-11-21; see Decision
  Log.
- When no badge shows, the pane-level markers take the badge's corner. The asking badge sits leading of the markers,
  so the markers keep the control badge's side and move only when that badge appears or goes. Amended 2026-11-27; see
  Decision Log.
- Only the run-end marker can show without a badge, such as on a disconnected pane that sits in no group and has no
  controller acting from it. No user action dissolves a group. It dissolves when its last member leaves.

Rationale: a run-end tab can be spared for a post-result page that holds no unsent input. A click that rebuilt at once
would then destroy that page with no question, since a rebuild never resends a form. A menu puts a deliberate choice
between a stray click and the rebuild. Opening the control menu from the authority marker would repeat the badge that
always sits beside it. Converged in 1 pass.

### Access mode or live controller

Original question: decision 2 marks a tab while a live grant can act on it. Its terminal bullet and the M1 check said
every tab of a remote-controlled pane. The two differ when remote control is enabled and no controller is connected.
`controllers(of:)` is empty then (`MainWindowController+Control.swift`, about line 50). The candidates were to follow a
live controller's grant, or to follow the pane's access mode.

Decision: the authority marker uses the same check the command path uses, run for each granted owner. A tab carries it
when a command from a granted owner, addressed to that tab, would be accepted now. The pane must be remote-controlled.
A connection must act from the pane, or own a group that holds the pane as a member (`isAuthorized`,
`WindowScripting.swift`, about line 653, which now asks `connectionMayAddress` in
`MainWindowController+Control.swift`). An exec driver counts beyond its own pane: it must own a group that holds the
pane, and the user must not have revoked it (`MainWindowController+Exec.swift`, about lines 278 and 449, with
`driverMayAddress` asking the same questions for the marker). In a browser, the owner must also own the tab.
(autonomous) Amended 2026-11-21; see Decision Log.

- A driver's own pane carries no authority marker. The driver commands it through its attached channel, which is not
  a grant, and it keeps that channel after the user revokes it. The pane's exec strip and the badge's "Driver:" line
  already show it. A driver attaches to a pane, not a tab, and reaches every tab of its own pane, as UTERM-062 "What a
  program may reach in a viewer pane with tabs" settles. So the exemption covers every tab of a driver's own pane, also
  once the image and map viewers hold several tabs. Amended 2026-11-26; see Decision Log.

- With remote control enabled and no controller connected, no tab is marked.
- `controllers(of:)` is not the source. It keeps a group owner after the user disconnects a member pane, so Revoke
  Controller stays offered. Every command to that pane is refused, so a marker from it would misstate authority.
- The pane a controller acts from passes the check. When its applet takes commands, it carries the authority marker.
  See "Marking the pane doing the controlling".

Rationale: decision 2 says "while a controller's live grant can act on it". Access mode would mark tabs no program can
touch, and it would change the user's wording. Reusing the command path's own check keeps the marker and the
authority from drifting apart, which is the mitigation the risk "The marker misstates what a grant reaches" names.
Converged in 1 pass.

### What "can act on" covers

Original question: `listPanes` (`WindowScripting.swift`, about line 115) returns every tab's title in an authorized
pane, the user's own tabs included. So the marker cannot mean "everything the program can reach". The candidates were
to define the marker as "the applet's tab commands accept this tab", or to narrow `listPanes` to the tabs the grant
covers.

Decision: the authority marker means a command addressed to this tab is accepted, whether the applet or the host runs
it. For a one-tab pane, sent content counts, since `send` replaces that tab's content through the host. Pane-level
reads and effects belong to the badge, such as listing tab titles or opening a new tab. (autonomous)

- A terminal tab never carries the authority marker. A terminal owns its input (`InputOwning`), refuses sent content,
  and takes no applet commands.
- Decision 2's rationale says the marker states the tabs a program can act on, not everything it can reach.

Rationale: this covers every path that changes a tab. "The applet's tab commands" alone would leave a text viewer
unmarked while a controller can replace its content with `send`. Narrowing `listPanes` would change a script wire that
outside programs call to fix a definition. Converged in 1 pass.

### Keeping the tab bar clear of the control badge

Original question: this is a scope addition. It fixes a layout fault that this proposal does not create. The badge
sits in the pane's top-right corner, over the new-tab button when a tab bar shows. The browser keeps clear of it. The
terminal did not, and the bug is now fixed. See `bugs/20261121-terminal-tab-bar-ignores-control-badge.md`. The
candidates were no addition, the terminal forwarding the reach, the shared bar taking the reach, and moving the
new-tab button to the leading side.

Decision: no addition. This proposal leaves the bar as it is, and the bug waits. (autonomous)

- The fault does not reach the marker slot. The bar's tabs show in a viewport that ends at the bar's `trailingReserve`
  and at the new-tab button, so no tab or marker passes under the badge. A scrolling tab bar keeps that rule, and the
  selected tab scrolls fully into view, so the slot is not covered at rest.
- The shared tab bar takes the reach as `trailingReserve`, which serves every applet with a bar. The terminal and the
  browser both forward it.

Rationale: the proposal neither creates nor worsens the fault, and the bug file keeps it on record. Converged in 1
pass.

### Who computes the authority marker

Original question: decision 1 says an applet reports markers. Only `CallerOwning` applets hear about grants, today
just the browser, through `adoptFirstTab` and `grantDidEnd` in `TabOpening.swift`. Every other applet gets only
`controlDidChange(PaneControl)`, which holds access, driver, and generation, with no controller set. A terminal, text
viewer, image viewer, map, or REPL cannot know a live grant. The candidates were the host computing every tab's
marker, `PaneControl` gaining live-controller state, and keying the marker to access mode.

Decision: the host computes, for each pane, the set of granted owners whose commands it would accept there, per
"Access mode or live controller". It also applies its own check of whether the pane's applet takes commands or sent
content, the same test `send` runs (`sendTarget` in `WindowScripting.swift`, about line 304). The set is empty for an
applet that takes neither, such as a terminal. One new `Applet` call hands the set down. A `CallerOwning` applet marks
a tab when the tab's owner is in the set. Any other applet marks its tabs when the set is not empty, through a shared
AppletKit helper. The applet then publishes the markers in its tabs, per decision 1. (autonomous)

- The host pushes the set from the place that already recomputes the badge on every control change
  (`refreshControlMarks`, `MainWindowController+Control.swift`, about line 291).
- The set does not ride on `PaneControl`. The browser ignores a `controlDidChange` whose generation is unchanged, and
  a controller connecting does not change the generation.
- The host and the applets ship in one binary, so the call has no version skew.

Rationale: each half of the check stays where the command path already runs it. The host owns authorization and
whether an applet takes input. The browser owns which tabs an owner opened. Having each applet decide whether it takes
commands could drift from the host's own test, which is the risk "The marker misstates what a grant reaches".
Converged in 1 pass.

### One marker or several in a slot

Original question: whether a tab shows every marker it carries, side by side, or one at a time with an order between
kinds. The candidates were every marker in a fixed order up to a cap, every marker each its own control, and the
highest-ranked marker with the rest in the tooltip.

Decision: a tab shows every marker it carries, in a fixed order by kind. Each marker is its own hit target and
tooltip, and none acts on a click, per "Interactive markers". A tab carries at most one marker of each
kind, so the slot needs no cap. The title truncates to make room. (autonomous)

Rationale: this is the plain behavior. It costs nothing while a tab carries one marker, which holds for every tab in a
tab bar today. It stays right where two coincide: a driven, remote-controlled image or map pane can carry the chip and
the authority marker at the pane level. A cap with an overflow menu serves no current case. Showing
only the top marker would hide the authority marker, or bury an actionable one in a tooltip. Converged in 1 pass.

### How the host knows the tab bar is hidden

Original question: decision 3 needs the host to know when a pane's tab bar is hidden. Every applet already follows one
rule. Before M1, the terminal hid its bar below two tabs (`TerminalApplet.swift`, in the update of its bar), and the
browser did the same (`BrowserView.swift`, in `show(tabTitles:selected:)`). The questions applet showed the shared bar
at a fixed height, always, with one tab per pending question (`QuestionsView.swift`, its height constraint). Every
other applet publishes exactly one tab and
has no bar. The candidates were a written contract that one published tab means no bar, and the applet reporting bar
visibility.

Decision: shared code enforces the rule. The shared tab bar takes published tabs, per M1, and hides itself when given
fewer than two. One AppletKit predicate decides it, and the host reads the same predicate from the published list to
draw the pane-level marker. Each applet's own hide line goes away. (autonomous)

- The questions applet follows the rule too. Its bar hides below two pending questions, and the bar's space goes with
  it. An empty book publishes one placeholder tab, so it shows no bar either. Amended 2026-11-23; see Decision Log.

Rationale: a written contract would leave a future applet free to show a one-tab bar. Its pane-level marker would
then draw twice. Enforcing the rule in the code M1 already changes makes that misuse impossible at no added contract.
Converged in 1 pass.

### Marking the pane doing the controlling

Original question: today the pane a controller acts from, such as the terminal running `uniterm run`, shows the same
antenna badge as a controlled pane. `PaneControlMark.controllers` holds "each controller with authority over the pane,
the ones acting from it included" (`WindowKit/PaneFrameView.swift`). Only the tooltip and menu text differ, with a
"Controller:" line. The user asked whether the controlling pane gets a marker, and which. This is an addition: it
widens what the proposal marks. The candidates were no addition, and a controlling marker in the same slot on the tab
the controller runs in, drawn as the chip per "The markers' look".

Decision: the chip marks the controller's tab. It goes on the tab whose session the controller is bound to. That holds
for a controller started in the tab and for one granted the pane explicitly. Each is bound to one session root and
ends when that session ends (`ScriptHost.swift`, about line 1017). An exec driver is bound to its pane, not a tab, so
its chip shows at the pane level, beside the control badge, whether or not the pane shows a tab bar. Amended
2026-11-26; see Decision Log.
Chosen by the user on 2026-11-21, at the review gate, over the review's "no addition". (addition)

- This brings in recording each session root's tab, which `App/AppDelegate.swift` (about line 250) drops today, and
  a per-tab entry in what the host hands each applet. See "When the chip shows" and "Who computes the authority
  marker".
- A chip at the pane level, whatever the tabs, would not say which tab of a multi-tab terminal holds the controller.
  It would also put a pane-level mark beside a visible tab bar, against decision 3.

Rationale: the badge looks the same on the pane that drives and the pane that is driven. The chip says which tab a
controller acts for.

### When the chip shows

Original question: the chip goes on the tab whose session a controller is bound to. A controller can be bound and live
while it holds no authority, such as when the user disconnects its source pane and it owns no group. When does the
chip show?

Decision: the chip shows while the controller passes the same checks its commands pass. The user has not revoked it,
its peer is unchanged, and its binding holds. Its own pane is remote-controlled, or it owns a group. A driver's chip
shows while it is attached, not revoked, and owns a group. Chosen by the user on 2026-11-21, converged in 1 pass.
(addition)

- A script running in a fresh, disconnected terminal tab shows no chip. The badge still names it, so Revoke stays
  reachable. This follows authority like every other marker, and it is not a fault.
- A REPL's attached helper shows no chip while its pane is disconnected.

Rationale: a chip that stayed after Revoke Controller would state authority the user just took away. Showing it for
every connected script would put one on every REPL pane with its helper attached.

### How the host hands the chip down

Original question: the settled "Who computes the authority marker" has one new call hand each applet its pane's
granted owners. The chip is per tab, and the host knows the tab once each session root records its tab. Does the same
call carry it?

Decision: the same call carries, beside the owner set, the tabs that hold a controller, with each controller's name as
the host supplies it. The applet publishes a chip on those tabs. Chosen by the user on 2026-11-21, converged in 1
pass. (addition)

Rationale: one update per control change keeps the two markers from disagreeing for a frame.

### What a click on the chip does

Original question: the authority marker is inert, and the run-end marker opens a menu. Does the chip have actions?

Decision: the chip is inert. A click selects the tab. Its tooltip names each controller acting for the tab, as the
host names them in the badge's "Controller:" lines, so the user can pair each tab with a name. Revoke stays in the
badge's menu. Chosen by the user on 2026-11-21, converged in 1 pass. (addition)

- The chip's marker carries the names the host supplied, and the applet passes them through unchanged. This amends
  "Interactive markers", whose markers otherwise carry only their kind and available actions.
- Its tooltip lists every controller bound to the tab's session that passes the chip's checks, since two scripts
  started from one shell share a root. Its meaning text fits a driver too, which is not bound to a session.
- Actions on markers and tabs, such as revoking one controller or going to the controlling tab, are a separate
  proposal the user asked for. It goes through its own design review.

Rationale: an inert chip matches the authority marker and needs no new action path. A menu with Revoke would add
revoking one controller from pane chrome, and an action path from the applet back to the host.

### How an explicit grant picks its tab

Original question: an explicit grant binds to the pane's newest live session (`sessionRoot` in `ScriptHost.swift`,
about line 1101), not to a tab the user picks. The chip makes that binding visible. Should it change?

Decision: no change. The grant binds to the pane's newest running session, and the chip shows on that tab. Closing that
tab ends the grant. Chosen by the user on 2026-11-21.

Rationale: raised under the project's rule on implicit state flow. Changing the grant flow belongs to UTERM-004's
area and is outside this proposal.

### Whether the pane-level marker shows when it repeats the badge

Original question: the badge shows when the pane is not disconnected, an exec driver's run has started (`driver !=
.none`), an owner or an unowned group is set, a controller is connected, or a control intent is saved
(`PaneFrameView.swift`, about lines 65-68). The authority marker follows a grant, so the two do not always appear
together. Decision 3's rationale said the marker shows "its content is the controller's", while decision 2 says the
marker "follows the grant, never the content". The candidates were showing the pane-level marker only when it adds
information, always, or folding it into the badge.

Decision: the pane-level marker shows whenever the pane's one tab carries a marker, as decision 3 says. Decision 3's
rationale now says the marker shows that a live program can act on the pane's one tab. (autonomous)

Rationale: the marker never repeats what the badge's look says. A one-tab text viewer with remote control on and no
controller shows the same peach antenna as one a live owner holds. The marker is the only visible difference.
Showing it only when it adds information would erase that difference, and it would need a rule that compares the two.
No pane type has a marker that always agrees with the badge, so folding has no case to cover. Converged in 1 pass.

### VoiceOver

Original question: how a marked tab and the pane-level marker read to VoiceOver. The candidates were the tab's
accessibility value naming its markers, and each marker being its own accessibility element.

Decision: each marker is its own accessibility element, labeled with its meaning. Every marker is an image, since none
acts on a click. The tab's accessibility value stays "selected" or "unselected". The pane-level markers are elements
beside the badge, inside the pane's group. (autonomous) Amended 2026-11-21; see Decision Log.

Rationale: one rule covers every kind and both positions. A pane with no tab bar has no tab element to name a marker
in, so a rule built on the tab's value would leave the pane-level authority marker silent. The meaning sits in its own
element, which the untrusted title cannot reach. Converged in 1 pass.

### Markers outside the tab bar

Original question: the palette lists published tabs (`MainWindowController+Palette.swift`, about lines 145 and 165). The
candidates were showing markers in palette rows, and leaving them out and saying so.

Decision: markers show only in the tab bar and at the pane level. The palette shows none. So that every tab's
markers can be seen, the shared tab bar scrolls when its tabs do not fit. The user scrolls it with a trackpad or a
shift-scroll, and it scrolls the selected tab fully into view. It adds no scroll control, since the trailing end is
where the control badge sits. This fixes `bugs/20261121-tab-bar-overflow-hides-tabs.md`. (autonomous, addition)
Amended 2026-11-21; see Decision Log.

- Out of scope: markers in the palette, or on any other surface that lists tabs.
- The bar shows that more tabs lie past either edge.

Rationale: every tab the bar shows already shows its markers, and a pane with no bar shows them at the pane level. So
the palette adds information only for tabs past the bar's edge. Those tabs are the overflow bug, and the bug's cost is
highest for UTERM-019's run-end marker. That marker is the only warning that a run's code may still read what the user
types, and UTERM-019 spares a tab on the condition that it keeps the marker. A spared tab past the edge would carry no
warning anywhere. Markers in the palette would patch that only while the palette is open. Peach on the palette's
selected blue row also measures about 1.2:1 in the dark theme and 1.65:1 in the light one. A row is one accessibility
element labeled with its untrusted title, which breaks the VoiceOver decision's rule. Scrolling fixes the cause in the
component M1 already rewrites. An overflow menu would be a second list of tabs that needs markers too. Shrinking tabs
has no floor that fits every count of tabs. Waiting on the bug instead would hold all of UTERM-019 M3 behind a bug
with no owner. Converged in 2 passes, and in 1 more when reopened by the coherence review.

## Design Decisions (Open)

None.

## Risks

- **The marker misstates what a grant reaches** — likelihood: low, impact: high. A marker on a tab the grant cannot
  act on, or missing from one it can, tells the user the wrong thing about a program's power. Only the browser
  enforces per-tab grants today. Mitigation: the host computes the marker with the same checks the commands run, for
  connections and drivers alike, and the browser adds the same ownership state its commands check. See "Access mode
  or live controller" and "Who computes the authority marker".
- **A shared contract changes for every applet with tabs** — likelihood: high, impact: low. `AppletTab` and the tab
  bar gain a field and a slot that every applet compiles against. Accepted: a tab without markers draws as today.
- **ADR-15 is still proposed** — likelihood: low, impact: low. Decision 2's rationale leans on it. ADR-14 also carries
  the authority argument. Mitigation: the decision rests on ADR-14 if ADR-15 changes.
- **UTERM-019 M3 inherits this slot** — likelihood: medium, impact: medium. If this proposal settles the slot without
  an action, UTERM-019's rebuild marker cannot use it. Mitigation: "Interactive markers" gives a marker kind its
  actions, and M1 builds the contract that carries and performs them.
- **A title imitates a marker** — likelihood: low, impact: medium. A page can set a title that looks like a marker,
  and the user reads authority that is not there. Mitigation: the marker sits in a region the title cannot reach,
  per "The markers' look".
- **A drawn slash looks off** — likelihood: medium, impact: low. The slash is drawn in code over `gearshape.2.fill`.
  A gap painted in the tab's background color shows as a halo when the background differs, such as a selected tab or
  the other theme. A slash that does not match the thickness, gap, and top-left to bottom-right direction of Apple's
  own slashed symbols looks foreign beside them. A macOS release that redraws the gears can leave the slash out of
  register. Accepted by the user on 2026-11-21. A custom symbol template made in the SF Symbols app avoids all three,
  if the slash later needs it.
- **An overflowed tab hides its marker** — likelihood: medium, impact: high. Tabs past the tab bar's trailing edge
  cannot be seen today. A controller tab there would show no authority marker. A spared run-end tab there would show no
  warning that a run's code may still read what the user types, and the badge may say nothing about that tab.
  Mitigation: M1 makes the bar scroll and keeps the selected tab fully in view, per "Markers outside the tab bar".
- **The chip lands on the wrong tab** — likelihood: low, impact: medium. The chip's tab comes from a new record of
  each session root's tab. A wrong or stale entry would tell the user a controller acts for a tab it does not.
  Mitigation: the record is written from the session's own start report and removed when the session ends, and M2's
  checks cover binding, restart, an explicit grant's tab, and session end.
- **A scrolling bar changes the tab bar's accessibility tree** — likelihood: medium, impact: low. A scroll view around
  the items may add an element, which could change the VoiceOver order or the elements `TabsUITests` finds.
  Mitigation: M1's VoiceOver and `TabsUITests` checks run against the scrolling bar.

## Milestones

### M1: The marker slot and the authority marker

**Status:** DONE

- A published tab carries a list of markers, and a tab without markers draws as today
- The shared tab bar draws a tab's markers in a fixed slot, and its title truncates to make room
- A browser tab the controller opened carries the authority marker while the grant lives, and loses it when the grant
  ends
- A browser tab the user opened never carries it
- A terminal tab never carries the authority marker, in a remote-controlled pane with a live controller too
- A text viewer's one tab carries it while a live controller may send to the pane, and loses it when the user
  disconnects the pane, even while the group's owner stays connected
- A pane with remote control enabled and no controller connected marks no tab
- A pane with no tab bar shows its one tab's markers beside the control badge. With no badge showing, a test-published
  run-end marker takes the badge's corner, and the pane-level marker moves only when the badge's visibility changes
- With the new-tab button hidden, a selected browser tab's marker slot stays clear of the badge
- Every marker shows a tooltip that says what it means
- A click on the authority marker selects the tab and opens no menu
- AppletKit's kind table holds the authority kind and UTERM-019's run-end kind. Each kind has its symbol, its
  meaning, its accessibility label, and its action titles. The run-end kind draws the slash over `gearshape.2.fill`
  and has the "Rebuild Tab" action
- A published marker carries its kind and its available actions, and the new `Applet` call performs an action on a
  tab. A click on a run-end marker, in a tab bar or at the pane level, opens no menu and calls nothing. UTERM-042
  offers "Rebuild Tab" from the tab's menu through the call. UTERM-019 M3 then publishes the run-end marker and
  implements the rebuild, without changing the slot
- A click on an inert pane-level marker does not reach the applet content beneath it
- Every applet type that takes applet commands or sent content, in a pane a live owner may address, publishes the
  authority marker. An applet takes them when it handles applet commands, or replaces its source and does not own its
  input
- The marker does not change while a window question is open, or while a command waits for a power the user must
  grant. Only authorization decides it
- A marker change publishes the tabs and sends `appletTabsDidChange`. The browser's `refresh()` compared titles, IDs,
  and selection only (`BrowserApplet.swift`, about line 1456), so it must compare markers too
- Every `tabOwners` change updates the marker on the same turn. That covers open, adopt, grant end, control change,
  and tab close
- The host redraws the pane-level marker from `appletTabsDidChange`, which before M1 only recorded the focused tab
  and refreshed the palette
- `AppletTabBar.update` takes published tabs, and the bar hides itself below two tabs through the one AppletKit
  predicate the host also reads. The browser's bar height follows the same predicate
- A questions pane with one pending question shows no tab bar and no blank strip where it was. An empty questions pane
  shows no bar and no placeholder tab. Two pending questions show the bar with both tabs
- The reach reported through `hostBadgeReachDidChange` includes the pane-level marker
- A marker stays whole at the 80-point narrowest tab
- When the tabs do not fit, the bar scrolls by trackpad and shift-scroll, and it shows that more tabs lie past an edge.
  It has no scroll control
- The selected tab is fully in view, its marker slot included and clear of the new-tab button. This holds after the
  user selects it from the keyboard or the palette, after a tab opens, and after the pane resizes
- A driven image or map pane shows no authority marker, whether it is disconnected or remote-controlled with no
  connection
- A browser tab a driver's layout adopted loses its marker when the user revokes the driver
- A tab's markers are keyed by kind, so a tab cannot carry two markers of one kind, and they draw in a fixed order
- A browser tab an exec driver's layout adopted carries the authority marker while the driver lives and is not revoked
- Connecting or revoking a controller, with no other change, updates the marker on the same turn
- Each marker is its own accessibility element with its meaning as its label and a stable identifier keyed by tab
  index and kind. The tab's value stays "selected" or "unselected", and `TabsUITests` passes unchanged
- With VoiceOver, a user reaches each tab's markers and its close button, and hears each marker's meaning next to its
  tab. If elements nested in the tab cannot be reached, the markers become sibling elements ordered right after their
  tab
- The pane-level markers are accessibility elements inside the pane's group, beside the badge or in its place
- A UI test captures a browser pane with a marked and an unmarked tab, and a single-tab pane with its marker beside
  the badge

**As built:**

- The command path and the marker now share one check. `isMember` and `connectionMayAddress` in the window's control
  code answer whether a connection's command would be accepted on a pane. For an exec driver, `driverStanding` (run
  ended, run revoked) and `driverMemberRefusal` (not a member, pane disconnected) answer the two steps. The driver's
  per-command check words each refusal from them, and `driverMayAddress` joins them for the marker. A package test
  runs a live run, a disconnected member, a revoked run, an ended run, and a member the run no longer owns through a
  real driver command, and the marker's owner set agrees with the command each time. The owner set holds
  `AppletCaller(grant:)` values, the same key the browser's `tabOwners` use, for connections and for drivers.
- The first fix of [the tab bar overflow bug](../bugs/20261121-tab-bar-overflow-hides-tabs.md) and of [the questions
  bar bug](../bugs/20261122-questions-bar-disagrees-with-the-shared-hide-rule.md) landed here. The terminal's badge
  bug was already fixed. The overflow regression test, 8 tabs in a 500-point bar, was written after the scrolling bar.
  A copy of the old bar, renamed and run through the same 8 tabs in 500 points, then failed as the bug says: the 7th
  and 8th tabs ended at 576 and 658 points, past the bar's edge. The copy was deleted after the run.
- The bar's wheel handling needed a scroll view subclass. A wheel turned with Shift held has no sideways part, so the
  subclass scrolls the tabs by its up and down part. A sideways trackpad swipe uses AppKit's own scrolling.
- A tab that carries both kinds at the 80-point narrowest width keeps both markers whole and gives up its whole title.
  One marker leaves about 24 points for the title.
- Nothing publishes the run-end kind yet, so its UI captures use a debug-only fixture applet, `fixture-marked`. It
  joins the existing fixture registry, which a debug build loads only when `UNITERM_TEST_APPLETS` is 1, so no release
  build carries it. A planted layout restores it as one tab at the pane level, in the badge's corner with no badge
  showing, or as a two-tab bar whose second tab carries the kind. UTERM-019 M3 replaces the fixture with the real
  publisher.
- A controller acting from a pane, with no group, marks that pane. A test against a real scripting host proves it,
  and proves that disconnecting the pane or closing the connection clears the mark.
- The data viewer takes the shared helper though no control mode reaches it, so its marker stays off until one does.
- Left to the user: hearing each marker's meaning and reaching the markers and the close button with VoiceOver, with
  the sibling-element fallback if nesting fails, and confirming each symbol resolves on macOS 26.0. The package tests
  ran on a newer system and cannot prove 26.0. The slash's look beside Apple's own symbols is also the user's to judge.
- The UI tests and captures, `MarkerUITests` and the changed `QuestionsUITests`, compile but had not run when M1 was
  committed. Three runs timed out entering Automation Mode. The checks they hold, the captures and the scrolling by
  trackpad and shift-scroll, wait on the next UI run.
- The decisions and text this work changed are amended in place. See the Decision Log entries of 2026-11-27.

### M2: The controlling chip

**Status:** NOT STARTED

- Each session root records the tab it runs in, and forgets it when the session ends
- A controller started in a terminal tab shows the chip on that tab, and an explicit grant's chip shows on its root's
  tab
- When a session ends, its chip clears on the same turn. A controller started in a restarted session shows the chip on
  that same tab
- The chip appears on the turn a connection binds, and an exec driver's chip shows on its pane's one tab
- The chip updates on the same turn when the user disconnects the source pane of a controller that owns no group, when
  a group's owner changes, and when a driver's group is dissolved
- A script whose ancestry lapses loses its chip on its next call, when it is unbound
- AppletKit's kind table gains the chip kind, with its symbol, meaning, and label, and no actions. `cpu` resolves on
  macOS 26.0, and the chip stays whole at 12 points in an 80-point tab
- The terminal and the REPL take the new call and publish the chip, though their owner set is always empty
- A driven, remote-controlled image or map pane can carry the chip and the authority marker. Both show beside the
  badge in a fixed order, and the reach sent through `hostBadgeReachDidChange` covers both
- A VoiceOver user hears the controller names the chip's tooltip shows
- A script in a disconnected terminal tab that owns no group shows no chip, while the badge names it
- Revoking a controller removes its chip on the same turn, while its connection stays open
- A revoked driver that owns no group shows no chip
- A REPL's attached helper shows no chip while its pane is disconnected
- A click on the chip selects the tab and opens no menu
- The chip's tooltip names every controller bound to the tab's session that passes the chip's checks, as the badge
  names them
- The chip and the authority marker arrive in the one host call, so a control change never shows one current and the
  other stale
- A one-tab pane shows its chip at the pane level, beside the badge
- A UI test captures a two-tab terminal whose second tab runs a controller, with the chip on that tab only

## Decision Log

- 2026-11-21: Drafted from the user's request for a uniform per-tab marker slot, with an authority marker first. The
  user chose that the marker follows what a live grant can act on, that a published tab carries its markers for shared
  code to draw, and that a pane with no tab bar shows its marker beside the control badge.
- 2026-11-21: Critique pass (autonomous). Fixed facts: the browser's tab bar already clears the badge, and only the
  terminal ignores it. UTERM-019's "remote-control marker" most likely means the pane badge, and UTERM-019 separately
  designs a per-tab run-end marker, so UTERM-019 is now a dependency. Marked the agent's mechanisms under each settled
  decision as drafting detail. Added open questions: access mode or live controller, who computes the authority
  marker, whether the pane-level marker repeats the badge, interactive markers, what "can act on" covers, markers
  outside the tab bar, and how the host knows the tab bar is hidden. Extended the questions on one marker or several,
  the look, badge clearance, and VoiceOver. Added three risks and the M1 implementation checks. Filed a bug for the
  terminal's tab bar. No settled decision was reversed.
- 2026-11-21: Re-check fixes. UTERM-019 moved out of Dependencies, since its run-end marker waits on this slot, not
  the reverse. Corrected three facts in open questions: the badge's show conditions, today's shared rule that one
  published tab means no bar, and what host-computed markers would change. The two M1 checks that drafting detail had
  settled now wait on their open questions. The user named cursor with rays as the leading look, not yet settled.
  (autonomous)
- 2026-11-21: Final re-check fixes, not re-checked: the host-computed candidate now names the host-to-applet call it
  needs, and the joystick is corrected to an SF Symbol. The critique loop ran three passes. What remains is open
  questions for `/proposal-reviewer`. (autonomous)
- 2026-11-21: Added "Marking the pane doing the controlling" at the user's question, labeled an addition. The user
  likes the robot, the game controller, and the steering wheel for the look.
- 2026-11-21: The user's leading look: filled two gears for a controlled tab, outlined two gears for UTERM-019's
  run-end marker, and the cpu chip for the controlling tab with the joystick as backup. Not yet settled.
- 2026-11-21: The user dropped outlined gears for the run-end marker and asked for a variant of the filled gears that
  stays legible at tab size and visible with color blindness. Simulations rule out a recolor. A slash or a warning
  badge remains.
- 2026-11-21: The user chose a slash drawn through the filled gears for UTERM-019's run-end marker, over a warning
  badge, since a badge adds a second mark that changes another marker's meaning. Still to be confirmed in review.
- 2026-11-21: The user kept the slash drawn in code over a custom symbol template, and accepted its three risks:
  a halo on a mismatched background, a mismatch with Apple's slash style, and drift when macOS redraws the gears.
- 2026-11-21: The markers' look moved from open to settled at the user's direction. The user chose it after seeing
  each candidate rendered at real size and under color-blindness simulations: filled gears for a controlled tab, the
  same gears slashed for UTERM-019's run-end marker, and the chip for a controlling tab. A review may not change it
  without the user's consent.
- 2026-11-21: Review start: 1 milestone, 4 settled decisions, 6 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the 11 open questions, at the commit "Settle
  UTERM-041's marker look as the user chose it".
- 2026-11-21: Corrected "Marking the pane doing the controlling": its candidates offered glyph pairings the settled
  look replaced, and its unverified fact is now checked. The app does not know which tab runs a controller.
- 2026-11-21: Interactive markers: a marker with actions opens a small menu at the marker, and a marker with none is
  inert. The authority marker has none, and UTERM-019's run-end marker offers "Rebuild Tab". A published marker carries
  its actions, and a new `Applet` call performs one. (autonomous)
- 2026-11-21: Access mode or live controller: the marker uses the command path's own authorization check for each
  live controller, not access mode and not `controllers(of:)`. (autonomous)
- 2026-11-21: What "can act on" covers: a command addressed to the tab is accepted, by the applet or the host, with
  sent content counting. A terminal tab never carries the authority marker. (autonomous)
- 2026-11-21: Keeping the tab bar clear of the control badge: no addition. The badge covers the new-tab button, not
  the marker slot. (autonomous, addition)
- 2026-11-21: Amended decision 2's applet bullet. It said: "In an applet whose grant covers every tab, such as a
  terminal, every tab of a remote-controlled pane carries it." It now marks a one-tab applet that takes commands or
  sent content, and never a terminal, per "What 'can act on' covers". Its rationale said the marker "states exactly
  what the program can reach". It now says "the tabs a program can act on", since `listPanes` reads every tab's title.
  (autonomous)
- 2026-11-21: Amended decision 3's click bullet. It said: "Clicking a marker there opens the same control menu the
  badge opens." It now defers to "Interactive markers". (autonomous)
- 2026-11-21: Who computes the authority marker: the host computes each pane's set of live owners its commands would
  accept, filtered by whether the applet takes commands or sent content, and hands it down through one new call. The
  browser intersects it with the tabs each owner owns. (autonomous)
- 2026-11-21: Amended "Access mode or live controller" to cover exec drivers. It said "run for each live controller",
  with only the connection check. A driver's layout adopts a browser tab and commands it under its own check, so the
  marker would have missed a tab a program can act on. (autonomous)
- 2026-11-21: One marker or several in a slot: every marker, in a fixed order by kind, at most one per kind, with no
  cap. (autonomous)
- 2026-11-21: Corrected the Motivation. It said: "That marker is the reason the slot holds a list. The authority
  marker and the run-end marker can sit on one tab at once." As designed today they never share a tab, since the
  run-end marker appears when the grant ends and a later grant owns only tabs it opens. (autonomous)
- 2026-11-21: How the host knows the tab bar is hidden: the shared tab bar hides itself below two tabs through one
  AppletKit predicate, which the host also reads. (autonomous)
- 2026-11-21: Marking the pane doing the controlling: no addition. If added, the chip goes on the tab whose session the
  controller is bound to. (autonomous, addition)
- 2026-11-21: Whether the pane-level marker shows when it repeats the badge: it always shows when the pane's one tab
  carries a marker, as decision 3 says. (autonomous)
- 2026-11-21: Amended decision 3's rationale. It said: "the badge says the pane is under control, and the marker says
  its content is the controller's." It now says the marker shows that a live program can act on the pane's one tab,
  since decision 2 says the marker follows the grant, never the content. (autonomous)
- 2026-11-21: VoiceOver: each marker is its own accessibility element, and the tab's value stays as it is.
  (autonomous)
- 2026-11-21: Filed `bugs/20261121-tab-bar-overflow-hides-tabs.md`: tabs past the tab bar's trailing edge cannot be
  seen or clicked, so their markers show nowhere.
- 2026-11-21: Markers outside the tab bar: none. Markers show only in the tab bar and at the pane level, stated as out
  of scope, and the risk of an overflowed tab hiding its marker is accepted on the filed overflow bug. (autonomous)
- 2026-11-21: Coherence fixes. Amended "Interactive markers": a published marker carried its kind, its meaning, and
  its actions. It now carries its kind and its available actions, and AppletKit derives the rest from the kind, so no
  applet text reaches the menu. M1 now builds the kind table with the run-end kind, so its action path has a real kind
  to test. Routed four checks to M1: applets that take commands count, every applet type is covered, transient
  refusals do not change the marker, and an inert pane-level marker eats its click. (autonomous)
- 2026-11-21: Whether an exec driver's own pane carries the authority marker: it does not. Amended "Access mode or live
  controller" from "each live owner" to "each granted owner", with a driver counting beyond its own pane and only
  while not revoked. Its listed conditions had contradicted its principle for a driver on its own pane. Decision 2's
  rationale now says "the tabs a granted program can act on". Marking the driver's own pane would keep the marker
  after the user revokes the driver, against decision 2's "clears when the grant ends". (autonomous)
- 2026-11-21: Reopened "Markers outside the tab bar" in the coherence review. Its accepted risk left a spared run-end
  tab past the bar's edge with no warning, against UTERM-019's condition that a spared tab keeps its marker. Its
  reload workaround was also false, since UTERM-019 replaced reload with rebuild. It now keeps markers out of the
  palette, and M1 makes the shared tab bar scroll, with no scroll control, keeping the selected tab in view. This
  brings in the fix for `bugs/20261121-tab-bar-overflow-hides-tabs.md`. The risk "An overflowed tab hides its marker"
  is now rated impact high and mitigated. (autonomous, addition)
- 2026-11-21: Re-check passed with no design-level defect. Routed two checks to M1: a pane-level marker's place with
  no badge, and a browser tab's marker slot clear of the badge when the new-tab button is hidden. (autonomous)
- 2026-11-21: Risk review: every risk carries a likelihood, an impact, and a mitigation or an acceptance. No one-way
  door: markers are never stored, and the new calls stay inside one binary. No risk is both high likelihood and high
  impact. (autonomous)
- 2026-11-21: Growth question: the user kept decision 2's grant rule, with its one exception. A driver's own pane shows
  no authority marker, since the driver commands it through its attached channel, not a grant.
- 2026-11-21: Review gate: the user kept the scrolling tab bar, terminal tabs never carrying the authority marker, and
  decision 3's reworded rationale. The user changed "Marking the pane doing the controlling" from no addition to the
  chip on the controller's tab. (addition)
- 2026-11-21: When the chip shows: while the controller passes its commands' own checks, revocation included. A
  driver's chip follows the grant rule. (addition)
- 2026-11-21: How the host hands the chip down: the same new call carries the controlling tabs and their names.
  (addition)
- 2026-11-21: How an explicit grant picks its tab: no change, the pane's newest running session, raised as implicit
  state flow.
- 2026-11-21: What a click on the chip does: inert, a click selects the tab, and the tooltip names each controller.
  The chip carries host-supplied names, an amendment to "Interactive markers". The user asked for a separate proposal
  on marker clicks and tab right-clicks with actions such as revoking or going to the controlling tab. (addition)
- 2026-11-21: Added M2 for the chip, since it needs each session root's tab recorded, which M1 does not.
  (addition)
- 2026-11-21: Final re-check passed with no design-level defect. Corrected two stale sentences: "One marker or several"
  now notes a driven image or map pane can carry two markers at the pane level, and "The markers' look" no longer
  calls the chip conditional. Routed eight checks to M2. The proposal loop ran its three passes. (autonomous)
- 2026-11-21: Added the risk that the chip lands on the wrong tab, mitigated by M2's checks. (autonomous)
- 2026-11-21: ADR candidate (cuts across the system): any on-screen sign of a program's authority is derived from the
  same check that enforces it. Declined: ADR-14 holds the authority principle, and this proposal records the reason.
- 2026-11-21: ADR candidate (cuts across the system): an authority sign carries no text an applet, page, or title
  supplies. Declined: this proposal records it with its reason.
- 2026-11-21: Accepted by the user.
- 2026-11-21: Amended "Interactive markers" and "VoiceOver" from UTERM-042's review, where the user chose one mouse
  path for a tab's actions: the tab's right-click menu. "Interactive markers" said: "A click on a marker with actions
  opens a small menu at the marker. The menu's first line says what the marker means, and its items are the kind's
  actions." Every marker is now inert on a click, and a kind's actions are offered in the tab's menu under the
  marker's meaning. Its bullet said: "The host draws the pane-level marker and its menu." "VoiceOver" said: "A marker
  with actions is a button that opens its menu. An inert one is an image." Every marker is now an image. M1's run-end
  check now says a click on the marker opens no menu. "One marker or several" said a marker with actions "opens its
  menu", and the Impacts line said M1 builds the run-end kind "and its menu". Both now match.
- 2026-11-21: Amended "Interactive markers" from UTERM-042's review: the authority marker also carries the owners it
  stands for, as the host identified them. Only the browser knows which owner opened a tab. Without the owners, the
  host could not name the controller behind a tab's marker in a pane with two owners.
- 2026-11-21: Scheduled as M1-M2 in queue.md.
- 2026-11-23: Correction of fact, from the triage of bug `20261122-questions-bar-disagrees-with-the-shared-hide-rule`.
  "How the host knows the tab bar is hidden" said: "(`BrowserView.swift`, about lines 232-235), and every other applet
  publishes exactly one tab and has no bar." The questions applet shows the shared bar at a fixed height, always, with
  one tab per pending question. The user chose that it follows the shared hide rule, over keeping its bar as a named
  exception. The decision gained a bullet saying so, and M1 gained a check for one, zero, and two pending questions.
- 2026-11-26: From UTERM-062, which gives the viewers tabs. The driver-pane exemption rested on each driven viewer having
  one tab, and said it needed another look for a multi-tab applet. It holds at the pane level: a driver reaches every
  tab of its own pane, so every tab there is exempt. In a group pane, a viewer tab carries the authority marker only
  when the controller owns it, as a browser tab does. Where a driver's chip shows in a pane with a tab bar is not
  settled here.
- 2026-11-26: A driver's chip shows at the pane level, beside the control badge, also when UTERM-062 gives its pane a
  tab bar. The user chose this over a chip on every tab and a chip on the selected tab. A driver is bound to the pane,
  and the chip then never moves as tabs open, close, or change selection.
- 2026-11-27: Pane-level order (autonomous, a best guess of the M1 run). The pane-level markers sit directly leading
  of the control badge and take its corner when it is hidden. The asking badge sits leading of them. Placing the
  asking badge between the markers and the badge would move the markers when a question comes and goes, against "move
  only when the badge's visibility changes". "Interactive markers" gained a bullet saying so. If the user wants the
  asking badge next to the control badge, the markers move one slot leading of it.
- 2026-11-27: Correction of fact, from M1's implementation. Each fragment below is quoted as it stood.
  - Motivation said: "The terminal ignores `hostBadgeReachDidChange`." The terminal forwards the reach to the shared
    bar's `trailingReserve`, and the bug was fixed on 2026-11-22.
  - "Keeping the tab bar clear of the control badge" said: "The terminal does not." and "The bar lays the last tab out
    to end 30 points short of the bar's trailing edge (`AppletTabBar.swift`, about line 183), and the badge covers only
    the new-tab button there. Once the bar scrolls, per "Markers outside the tab bar", a terminal tab can pass under
    the badge while the bar scrolls. Terminal tabs carry no markers, and the selected tab scrolls fully into view, so
    the slot is not covered at rest." and "When the bug is fixed, the shared tab bar taking the reach is the fix that
    serves every applet with a bar." The bug was fixed and the shared bar takes the reach, so the bullets now say so.
  - "Interactive markers" said: "after the user disconnects the pane and dissolves its group." No user action
    dissolves a group. It dissolves when its last member leaves.
  - "Whether the pane-level marker shows when it repeats the badge" said: "an exec driver is attached" and
    "`PaneFrameView.swift`, about lines 43-45". The badge shows once a driver's run has started (`driver != .none`),
    not when a driver is merely attached. The lines are 65-68.
  - M1 said: "The host redraws the pane-level marker from `appletTabsDidChange`, which today only refreshes the
    palette". The call also records the focused tab as recent.
  - Stale line citations are updated: "WindowScripting.swift`, about line 635" is about line 653, now behind
    `connectionMayAddress`. "`MainWindowController+Exec.swift`, about lines 278 and 445" is about lines 278 and 449.
    `listPanes` "about line 93" is about line 115. "`WindowScripting.swift`, about line 282" is `sendTarget`, about
    line 304. "`MainWindowController+Control.swift`, about line 216" is about line 291.
    "`MainWindowController+Palette.swift`, about line 138" is about lines 145 and 165. "`ScriptHost.swift`, about line
    1043" is `sessionRoot`, about line 1101. "`BrowserApplet.swift`, about line 1457" is about line 1456. "How the
    host knows the tab bar is hidden" cited "`TerminalApplet.swift`, about line 729", "`BrowserView.swift`, about
    lines 232-235", and "`QuestionsView.swift`, about line 53". It now names those places as they stood before M1,
    since M1 removed them. The citations inside "Marking the pane doing the controlling" (about lines 1017 and 250), a
    decision the user chose, are left as the user chose them. Line 1017 and the `AppDelegate.swift` record are for M2
    to verify.

## References

- UTERM-004: pane control and the control badge
- UTERM-005: the browser applet's controller-owned tabs
- UTERM-019: the run-end marker this proposal's slot must hold
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): grants and what a controller opened
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): authority, the one thing kept apart
- `bugs/20261121-terminal-tab-bar-ignores-control-badge.md`: the terminal's tab bar under the badge
