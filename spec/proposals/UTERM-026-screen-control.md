# UTERM-026: Presenter View and Screen Control

**Status:** accepted
**Created:** 2026-11-15
**Updated:** 2026-11-27

## Dependencies

- UTERM-001, for the pane tree and windows
- UTERM-002 and UTERM-013, for a pane zoom command and its key
- UTERM-004, for groups, controller authority, saved layouts, and "Same window only"
- UTERM-021, for declaring the new powers
- UTERM-032, for the rule that each permission meaning names where its kind may appear, which keeps the three new kinds
  out of packages
- UTERM-024, for controller commands, which a group across two windows must keep working
- UTERM-025, for the presentation controller and its deck format
- UTERM-036, for a layout request's last new pane taking focus

## Impacts

- UTERM-004 — "Same window only": a presenter view needs a controller's panes in two windows. UTERM-004 is implemented,
  so this would supersede that rule in part.
- UTERM-004 — "What anchors trust": its "window close ... removes the owner's authority" holds for the source window.
  Closing an opened window ends only its own groups, per "Authority across windows". This supersedes that bullet in part.
- UTERM-001 — M3's rule that a shell that exits closes its own pane and focus moves to a neighbor: a window that closes because its last applet ended follows that
  rule unchanged, per "Focus".
- UTERM-028 — "How invocations reach the driver": its invocations carry UTERM-024's event fields. The `:window` field this proposal adds is
  ScriptWire only, so the exec wire does not change.
- UTERM-004 — "Layout requests": every request is anchored at a pane the program may address. The window power's
  layout holds only new panes and has no anchor, per "A second window". This supersedes that rule in part.
- UTERM-024 — "Powers and lifecycle": its cleanup when "the window closes" assumes a group in one window. Per
  "Authority across windows", it runs when the source window closes, and closing an opened window ends neither the
  commands nor the pending reads.
- UTERM-024 — "The event model": an event carries a bare node ID, justified by "Same window only". Per "A second
  window", an event names its pane with a window reference too.
- UTERM-025 — "Slides only": speaker notes return through this proposal.
- UTERM-033 — "In-flight proposals widen what Allow turns on": per "Saving and restoring", an adopted group's members
  take part only in their own window, and the notes window's group is never offered.

## Summary

Speaker notes the audience cannot see, and the screen control a presenter view needs: a pane that fills its window,
full screen, and a second window on another display. A user's Pop Out Pane, which moves a live pane into a window of its
own for a screen share, rides along behind a spike. This is a nice-to-have. The presentation controller works without
it, showing slides only.

## Motivation

In one window, the audience sees every pane. A presenter with notes needs the slides on the projector and the notes on
the laptop, which takes two windows. Showing only the slide pane also needs a pane that fills its window. uniterm has
neither today, for a script or by hand.

`spec/ideas.md` "Share a pane or tab in a screen share" wants a pop-out window that holds one pane, for a video call. It
needs a second window too, so this proposal holds both. The two share only the window, so each gets a mechanism of its
own. Amended 2026-11-16; see Decision Log.

## Design Decisions (Settled)

### A second window

Original question: a user-level Pop Out Pane command that a controller may request, which also serves the screen-share
idea, or a controller power to open a window that holds panes it opens fresh. Also: whether a pane moves to the new
window or opens fresh there, since moving a live pane carries the unknowns of the "Move tabs between panes" spike in
`spec/ideas.md`. And how a group spans two windows.

Decision: both mechanisms, each serving one need. A controller power opens a fresh window for the notes. A user command
pops out a live pane, behind a spike. (autonomous)

- The presenter opens a new window holding a fresh notes pane, which stays on the laptop. The original window keeps
  UTERM-025's layout, the terminal with the slide beside it, and goes to the projector. So a demo in any pane or tab of
  that window is projected as it is.
- The new window holds a group node of its own with the same live owner. One owner may own groups in two windows.
- Only a connection may own groups in two windows. An exec driver's owner ID is unique only within its window, which
  holds every group the driver owns, per `GroupOwner`. A driver never gets the window power.
- The new window has no anchor. Its layout holds only new panes, and needs no remote-controlled pane already open. This
  amends UTERM-004 "Layout requests" in part for the window power alone.
- A command event names its pane with a window reference beside the node ID, as every other pane reference on the wire
  already does. UTERM-024's event model carries a bare node ID and justifies it by "Same window only".
- Pop Out Pane is a user command only. It moves the focused pane, live, into a new window of its own. No controller may
  request it. It waits on a spike milestone that moves a live terminal surface and a live web view. If the spike rules
  the live move out, the Pop Out milestone is dropped with the user's approval, and the presenter view is unaffected.

Rationale: the projector must show the demo, and UTERM-025 left the demo in whatever pane or tab the user picks. No code
moves a pane between windows, so a slide window on the projector would leave the demo on the laptop. Fresh notes on the
laptop leave the projected window as UTERM-025 built it. The screen-share idea in the Motivation needs a live pane in a
window of its own, and a fresh pane would kill the shell or reload the page. The two needs share only "a window", so
neither mechanism serves the other. A Pop Out alone would block the presenter view on an unproven spike. A
controller-requested Pop Out serves no current caller. A host-owned notes panel outside the pane tree would need its own
key route and serve nothing else. Converged in 1 pass.

### Pop Out Pane after the spike

Decision: defer how a moved pane keeps its bindings, what undo means after a move, and how close stamps work across
windows until the spike reports. (autonomous)

**Revisit:** when the live-move spike milestone records its result

- A moved pane keeps its node ID only if the destination window's IDs allow it. Every binding keys on window and pane:
  launch authority, session roots, the controllers acting from a pane, and every pane reference a script holds. The
  Pop Out milestone must re-key them or end them, and ADR-02 needs a reading for a change of window.
- Removing a pane from a group removes that group's authority over it, per UTERM-004. A popped-out member leaves its
  group.
- A grant's source window is the window of the pane the run started from. Popping out that pane changes it, so the
  re-keying covers the source window too.

Rationale: each of these depends on what a live move preserves, which only the spike shows. Settling them first would
design against an unknown.

### Speaker notes

Original question: how a slide marks its notes in UTERM-025's deck format: an HTML comment, a fenced block with a
`notes` tag, or a heading such as `Notes:`. Where the notes pane lives: the second window.

Decision: a tagged HTML comment. A block-level comment whose text starts with `notes:` holds the slide's notes. The notes
show in the notes window. (autonomous)

- A block-level comment is one that starts a line with at most three spaces of indent, outside a fence, by the rule
  UTERM-025's slide splitter already applies. An inline comment inside a paragraph is never notes.
- The tag is `notes:`, matched without regard to case, after any whitespace that follows `<!--`. Several tagged comments
  on one slide join in order, with a blank line between them.
- Untagged comments stay hidden everywhere, as today.
- The notes comment is sent to the slide as an empty comment, so the slide's block structure does not change. The notes
  count against the notes pane's own size cap, not the slide's.

Rationale: a comment renders as nothing in the slide view and the document view today, so a deck with no marker reads
the same, as UTERM-025's risk "Users copy the example's deck format" requires. A fenced `notes` block or a `Notes:`
line renders as slide text in any deck without a marker, and under the UTERM-025 example. So a forgotten marker shows
the notes to the audience. Taking every comment would also turn Marp directives and commented-out drafts into notes.
Slidev's last-comment rule has the same failure for a commented-out last bullet. A sidecar notes file would need file
access past UTERM-032's grant, and its notes drift when slides move. reveal.js's `<aside class="notes">` renders its
text on the slide, since the sanitizer drops the tag and keeps its content. Converged in 1 pass.

### Pane zoom

Original question: whether zoom is a user command that every pane has, a controller power, or both. How the other panes
behave while one is zoomed, per ADR-05's lifecycle events. Where keys go when zoom hides the pane that had focus. A zoom
key is a window key uniterm owns, and the user may remap it, per ADR-04.

Decision: zoom is a pane operation. A user command, Zoom Pane, zooms the focused pane, plus a controller zoom under a
permission kind of its own. A controller's zoom behaves as the user's zoom, so the zoomed pane takes focus. Amended
2026-11-27; see Decision Log.

- Zoom is a view state of the window over an unchanged tree. Zoom only hides the other panes. They get no lifecycle
  event and keep running, and audio or video playing in one carries on.
- The user's zoom acts on the focused pane, so it never hides focus.
- `(uniterm/zoom-pane pane)` zooms a remote-controlled member of the caller's group. The zoomed pane takes focus, in the
  key window or any other. In a window that is not key, that window's focus mark moves to the zoomed pane. So returning
  to the window, by a click or by Cmd-`, never lands on a hidden pane.
- `(uniterm/unzoom-pane pane)` ends a zoom of a member of the caller's group, whoever made it. Zoom state belongs to the
  pane. A controller never ends a zoom on a pane it does not own.
- A controller's zoom stays after its run ends or is revoked, and the user ends it with Zoom Pane.
- The refusals are distinct: already zoomed, and not a member. The reply and `list-windows` say which pane is zoomed and
  who made the zoom.
- A window holds one zoom at a time, so a second zoom is refused as already zoomed, whether or not the window is key.
- The kind is `:pane-zoom`, named by kind alone and at edition 0, in declared files only. A package that names it is refused, and an exec driver
  never gets it. The approval says the controller may hide your other panes in the windows it controls.
- The user ends zoom with Zoom Pane again, a split, a close, or a focus move to a hidden pane.
- A script's `open-pane` is the user's split. So it ends zoom, and its new pane takes focus.
- A layout request that makes a new pane is a set of the user's splits made at once, per UTERM-036. So it ends zoom,
  and its last new pane takes focus. A layout request that makes no new pane behaves as the same rearrangement by the
  user would (best guess).
- Any other program change that touches only hidden panes keeps zoom. Removing or replacing the zoomed pane ends zoom.
- A zoomed window shows that panes are hidden, so the user never takes them for closed.
- Zoom Pane is a window key uniterm owns, and the user may remap it, per ADR-04. The presenter's start message names the
  command, not a key.

Rationale: the user chose a controller zoom at the review gate, keeping the Motivation's "for a script". The user's
zoom leaves the keyboard in the zoomed pane, so a controller's zoom does the same. The keyboard then never sits in a
hidden pane, in the key window or any other. Moving a window's focus mark to the zoomed pane keeps a later return
from landing on a hidden terminal. The user chose that zoom state belongs to the pane, so the presenter's toggle ends a
zoom the user made on the slide. A controller still never ends a zoom on a pane it does not own. A zoom that waits for
the user's click would add a pending effect for a click that already serves. Ending zoom on any program change would
show the audience hidden panes when another script changes a hidden pane mid-talk. A script's `open-pane` still ends
zoom, as the user's split does. The user set that a layout request's new panes behave as the user's splits, so a layout
that makes a new pane ends zoom too. Another script's layout mid-talk therefore shows the audience the hidden panes.
Riding on pane control would widen every stored pane-control approval with no consent, against ADR-09. Converged in 1
pass, and the user chose it.

### Authority across windows

Original question: ADR-09 limits a grant to its authorized window. A group across two windows needs a superseding or
amending ADR, and a superseding of UTERM-004's "Same window only" in part. Also: what the user sees and can revoke in
each window, and what happens to the controller's panes in one window when the other window closes.

Decision: ownership sets default control. A controller may control, by default, the windows and panes its run opened,
and everything else only through the user's explicit grant. So a grant reaches its source window plus the windows its
run opened through the window power, within its targets and powers. ADR-14 records this and supersedes ADR-09.
UTERM-004's "Same window only" is superseded in part the same way. (autonomous) The user named the ownership principle
on 2026-11-17; see Decision Log.

- Each window's pane badges list the controller, and Revoke in either window ends the run in every window. Both already
  work this way, since a badge reads the owner from its own window's tree and Revoke fans out to every window.
- Closing an opened window ends authority over its groups only. The run keeps its commands and its pending reads, and
  keeps stepping in the source window. This amends UTERM-024 "Powers and lifecycle", whose cleanup runs when "the
  window closes", to mean the source window.
- The user's close of an opened window is final for that run. The run cannot open another window afterwards. Left
  undone: after an accidental close, the notes stay gone until a rerun.
- Closing the source window ends every grant, as today.

Rationale: an accidental close of the notes window on the laptop must not stop the talk, since a rerun opens a second
slide pane and starts from slide 1. A fresh grant per window would still break "Same window only", would add a prompt
mid-setup, and would contradict Revoke, which ends a run everywhere. Reading ADR-09's one window as a set needs a
superseding ADR in any case, and UTERM-004 is implemented, so its text cannot change in place. A run that could reopen
a window the user closed would override the user's close until Revoke. Converged in 1 pass.

### Window and display control

Original question: whether a controller may make its window full screen and move it to a display. Each needs its own
power under ADR-09, with a permission kind and its declaration spelling under UTERM-021. Pane control must not grant it.

Decision: one placement kind lets a controller move its source window to a display and make it full screen. Windows the
run opens are placed when they open, under the window power. (autonomous)

- The presenter's display is the primary display, the one the arrangement settings give the menu bar. The audience
  display is the other one, when exactly two displays are in use and they do not mirror each other. With three or
  more, no audience display is named. Amended 2026-11-16; see Decision Log.
- Placement happens only when the run places the source window and opens the notes window. A display change later in
  the talk, such as turning on mirroring, is the choice of whoever made it, and uniterm does not move the windows again.
- The presenter moves the source window to the audience display first, and then opens the notes window on a display
  that is not the audience's.
- When the displays form a mirror set, or only one display exists, or no audience display can be named, the notes
  window does not open. The presenter says why, and the slides still work.
- With "Displays have separate Spaces" off, the host skips full screen, since it would hide the notes. It sizes the
  window to the audience display instead. The reply names the outcome, and the presenter says why. Amended 2026-11-16;
  see Decision Log.
- The approval names the effect: the controller moves your window, which holds your own panes, to another display.

Rationale: run from the laptop, as a presenter usually is, a notes window placed beside the source window lands on the
projector, in front of the audience. Placing the source window first, on a display named by a rule, keeps the notes
off the projector without a step the user must remember. The primary display marks the display the user works at. A
laptop keeps the built-in display primary when a projector joins, and a desktop Mac or a closed laptop keeps the desk
monitor primary. A rule keyed on the built-in display would send the notes to the projector on a Mac with no built-in
display in use. Left undone: a user who made the projector primary gets the notes there. Full screen and display moves serve one placement, and no user
would grant one and refuse the other, so two kinds would add an approval row and a spelling with no one to set them
apart. Powers over opened windows only leave the source window, the one the audience sees, to the user. No power leaves
the Summary's full screen to the user, and places the notes before the user can move anything. A notes window placed
on the built-in display, with the user dragging the source window, was weighed late and could not win: it leaves full
screen and placement to the user. A Swap Displays command, to recover from a wrong display guess, would be an addition
and is left out. Converged in 1 pass.

### Saving and restoring

Original question: whether zoom state and a two-window group are saved with a layout, under ADR-06's versioning and
ADR-03.

Decision: neither. The layout envelope does not change. (autonomous)

- A relaunch restores every window unzoomed.
- Each window saves its own groups as today, with no link between the notes window's group and the source window's. A
  group with no source pane already round-trips in the current envelope.
- Under UTERM-033, an adopted group's members take part only in their own window. The notes window's group has no source
  pane, so UTERM-033 never offers it, and no run can act in a window it did not open. A rerun opens a fresh notes
  window. A reclaimed source group gives its run authority in the source window only, until the run opens a window of
  its own.
- Left undone: zoom is lost on relaunch, and the user closes a stale notes window by hand.

Rationale: a link that let a rerun reclaim the notes window would give a run authority over a window it did not open,
against "Authority across windows". It would also stretch UTERM-033's rule that adoption starts from the group's source
pane. A reclaimed notes window would sit where its saved frame put it, though the audience display is named only when a
window opens. Saving zoom would restore the user's view, but costs an envelope bump, and a downgrade then keeps the
whole layout aside. After a relaunch the hidden panes are the user's own, and terminals come back empty, so restoring
zoom guards little. Not saving a window the run opened would add a provenance rule to the save path and break
UTERM-001's rule that persistence restores every window. Converged in 1 pass.

### Focus

Original question: where the keyboard goes after a zoom, and after a window opens, goes full screen, moves, or closes.
Whether a controller's change differs from the same change made by the user.

Decision: a controller's zoom, open, full screen, or move behaves as the same action by the user. Amended 2026-11-20;
see Decision Log.

- Zoom Pane leaves focus in the zoomed pane. A controller's zoom does the same, per "Pane zoom". In a window that is
  not key, it moves that window's focus mark to the zoomed pane.
- Pop Out Pane's new window becomes key with the moved pane focused.
- The notes window opens as a window the user opens does. It becomes key, and its notes pane takes focus.
- Placement treats focus as the user's full screen or move of the source window does.
- A window closes the same way whether the user closed it or its last applet ended, and macOS picks the next key
  window.

Rationale: a program's operation is the same operation as the user's, and it behaves the same way. So no change needs
a rule for who made it, and the host never has to tell whether a call answers a command the user invoked. Every close
takes one path, so a window's close needs no rule of its own.

### Names and version skew

Original question, added in review: the declaration spellings of the window power and the placement kind, per
UTERM-021's data shape and UTERM-003's verb-noun naming. The Janet functions that open a window and place the source
window. And each new kind's skew in both directions.

Decision: noun-first kinds and verb-noun calls, as clipboard reads and writes pair them today. Packages cannot declare
either kind. (autonomous)

- The kinds are `:window-open` and `:window-placement`, each named by kind alone. "Pane zoom" adds `:pane-zoom` under
  the same rules, and every skew line below covers all three kinds. Amended 2026-11-27; see Decision Log.
- `(uniterm/open-window layout)` opens a window holding only new panes, on a display that is not the audience's. It
  returns the window and pane references.
- `(uniterm/place-window)` moves the caller's source window to the audience display. It takes no options. The host
  chooses full screen, or a window sized to the display. The reply names the outcome: full screen, sized for shared
  Spaces, mirrored displays, one display, or no audience display.
- `open-window` replies with the same distinct refusals when no display can take the notes.
- A run may open one window. A second `open-window` is refused, so with "Authority across windows" a run never holds
  more than its source window and one opened window.
- `uniterm/list-windows` returns the source window first, with its record unchanged, so UTERM-025's read of its own
  mode stays right. An opened window follows it, marked as opened. Its record has no `:pane` or `:control`, since no
  caller pane sits there. `uniterm/list-panes` takes an opened window's reference too.
- A command event keeps `:pane` and adds `:window` beside it, so scripts that read `:pane` keep working. The field is on
  ScriptWire only. An exec driver never spans windows, so its events under UTERM-028 carry no window.
- The `:window-open` approval says the controller may open one window of its own, holding only panes it opens.
- A `controller.json` that names either kind is refused, and its error says a package cannot declare it.

Version skew:

- ScriptWire is at 0 under UTERM-063, so the added `:window` field lands in place after UTERM-063 M2, with no new
  version. An older program's message is read with its old meaning or refused by name, and a replaced helper is refused
  by the identity check. Amended 2026-11-27; see Decision Log.
- An older build refuses a declared file that names either kind, before any effect.
- An approval of either kind is kept unread by a build that does not know it, and every other approval keeps working,
  as UTERM-024 "Stores that older builds read" states under UTERM-067. Amended 2026-11-26; see Decision Log.
- The layout envelope does not change. A notes window's group, which has no source pane, round-trips through the
  current envelope and every older one that has groups.

Rationale: the kind names follow `clipboard-read` and `host-launch`, and the calls follow `open-pane` and
`read-clipboard`. A full-screen option would give a script a knob over a choice the host makes, since a script cannot
see the Spaces setting or the displays, so the reply carries the outcome instead. Refusing the kinds in packages costs
no caller, since the presenter is a declared file. One `present` call
would merge two powers the settled design keeps apart. Folding placement into `open-window` would leave no way to
place the source window without opening a window. Converged in 1 pass.

## Design Decisions (Open)

None.

## Risks

- **Widening a grant past one window widens what a controller can reach** — likelihood: medium, impact: high.
  Mitigation: "Authority across windows" settles the scope, and ADR-14, which supersedes ADR-09, records it. A run opens at most one window, which holds only panes of its own group, and revoking covers both windows.
- **The macOS "Displays have separate Spaces" setting** — likelihood: medium, impact: medium. When it is off, a full
  screen window on one display blanks the other, and the notes window is lost. Mitigation: the host reads the setting,
  sizes the window to the audience display instead, and its reply says so.
- **The notes land on the audience's display** — likelihood: low, impact: high. A wrong guess about which display is
  the audience's shows the notes to the room. Mitigation: the primary display is the presenter's, and three or more
  displays, a mirror set, or one display open no notes window. A display change made mid-talk, such as turning on
  mirroring, can show the notes. Accepted for that case: whoever changes the displays chooses what they show, and a
  host that watched and hid the window would leave a group nobody can reach.
- **Notes text leaks onto a slide** — likelihood: low, impact: medium. A `-->` inside the notes ends the comment, and the
  rest renders on the slide. Mitigation: the presenter refuses such a deck at start and names the line.
- **An older build stops honoring approvals of the new kinds** — likelihood: high on a development machine, low
  elsewhere, impact: low. A build with UTERM-067's reader that does not know them keeps those approvals unread, and
  every other approval keeps working. Accepted, as UTERM-024 accepts it for its own kind: it fails closed. Amended
  2026-11-26; see Decision Log.
- **New published contracts** — likelihood: high, impact: medium. The kinds `:window-open`, `:window-placement`, and
  `:pane-zoom`, the calls `open-window`, `place-window`, `zoom-pane`, and `unzoom-pane` and their replies, the zoom
  report in `list-windows`, the opened-window record in `list-windows`, the
  event's `:window` field, and the deck's `notes:` tag outlive any rename,
  since decks and declared files are written against them. Mitigation: a name never changes meaning, and a rename adds a
  name, as UTERM-019 and UTERM-024 hold. A deck's tag needs no version, since a tagged comment renders as nothing in any
  presenter that does not read it.
- **The live-move spike rules out Pop Out** — likelihood: medium, impact: low. Mitigation: the presenter view does not
  depend on it, and M4 is dropped with the user's approval.
- **An accidental close of the notes window loses the notes for the talk** — likelihood: low, impact: medium. Accepted:
  a run that could reopen a window would override the user's close. The slides keep stepping, and a rerun brings the
  notes back.

## Milestones

### M1: Pane zoom

**Status:** NOT STARTED

Amended 2026-11-27; see Decision Log.

- A pane fills its window and returns, and the other panes keep their state
- Zoom sends a hidden pane no lifecycle event. Its applet keeps running, and a playing video or audio carries on while
  hidden
- A layout request that makes new panes in a zoomed window ends zoom, and its last new pane takes focus, as the user's
  splits do
- A script's `open-pane` in a zoomed window ends zoom, and its new pane takes focus, as the user's split does
- A zoomed window shows that other panes are hidden
- Zoom Pane is remappable
- `zoom-pane` zooms a remote-controlled member. It is refused, with a distinct reply for each, when the window is
  already zoomed, key or not, and when the pane is not a remote-controlled member
- The source pane and a disconnected member get the not-a-member reply
- In the key window, a controller zoom of a member while another pane holds focus applies, and the zoomed pane takes
  focus
- In a window that is not key, a controller zoom applies even while another pane holds the focus mark, and the mark
  moves to the zoomed pane
- Zoom Slide pressed in the notes window zooms the slide in the projector window while the terminal there holds the
  focus mark. The mark moves to the slide, and returning with Cmd-` puts the keyboard in the slide
- A controller zoom that lands while a sheet is up on its window applies. The sheet's answer still acts on the pane it
  asked about, and after the sheet closes the keyboard lands in the zoomed pane
- `list-windows` reports the zoomed pane and who made the zoom: the user, this run, or another controller, unnamed. A
  disconnected caller, which sees only its binding, gets no zoom report
- A run that owns the zoomed pane, including a rerun given the group, can end any zoom on it. A run that does not own
  the pane gets the not-a-member reply
- The `:pane-zoom` approval says the controller may hide your other panes in the windows it controls
- `unzoom-pane` ends a zoom of the caller's member that the user made with Zoom Pane, and is refused for a zoom on a
  pane the caller does not own
- A controller's zoom stays after Revoke or the run's end, and Zoom Pane ends it
- A `controller.json` that names `:pane-zoom` is refused, and a declared file that names it runs
- When the zoomed pane's applet ends on its own, zoom ends, and focus follows UTERM-001's rule for that close
- A split, and a focus move to a hidden pane, each end zoom
- A relaunch restores a window that was zoomed with every pane shown

### M2: Presenter view

**Status:** NOT STARTED

Amended 2026-11-20; see Decision Log.

- The presenter shows its slide on one display and the speaker notes in a second window on the other
- The presenter declares a Zoom Slide command, in the palette and on a key, live in the slide pane and the notes pane.
  It toggles the slide's zoom, whoever made it. Nothing zooms until the user invokes it, and a step never zooms
- When the user has zoomed another pane in the projector window, Zoom Slide gets the already-zoomed reply, and the
  presenter says that Zoom Pane in the zoomed pane ends it
- Run from a window on the laptop's built-in display with one projector attached, the presenter moves the window to the
  projector and opens the notes window on the laptop
- On a Mac with a desk monitor as the primary display and a projector, and no built-in display in use, the notes open
  on the desk monitor
- With three or more displays, no notes window opens, and the presenter says why
- Revoke from a badge in the notes window ends the run in both windows
- A second `open-window` from one run is refused
- `list-panes` takes the opened window's reference
- An exec driver cannot use `open-window`, and its events carry no `:window`
- A declared file that names both new kinds runs, while a `controller.json` that names either is refused, and its
  error says a package cannot declare it
- The `:window-open` approval says the controller may open one window of its own
- When the presenter ends by Stop, Ctrl-C, or Revoke, the notes window keeps its last notes and the source window stays
  where it was placed
- `place-window` replies once the window has finished moving and any full-screen change has ended, so `open-window`
  measures settled displays
- A deck whose notes on any slide are over the notes pane's cap opens no pane, and its error lists each such slide
- The `notes:` tag matches in any case, and several tagged comments on one slide join in order
- A deck with no tagged notes places the source window and opens no notes window
- A reclaimed source group acts in the source window only
- With mirrored displays or one display, the notes window does not open, the presenter says why, and the slides work
- With "Displays have separate Spaces" off, the source window fills the projector without full screen, and the notes
  window stays visible
- Making the source window full screen or moving it treats focus as the user's full screen or move of that window does
- The approval for the placement kind says the controller moves a window that holds the user's own panes
- Closing the notes window leaves the presenter stepping in the source window, and the run cannot open another window
- Closing the source window clears ownership in the notes window
- `uniterm/list-windows` returns only the source window, first and with its existing fields unchanged beside the zoom
  report, then the one window the
  run opened. The opened window's record carries its reference, its title, and the opened mark, with no `:pane` or
  `:control`
- The notes window opens as a window the user opens does: it becomes key, and its notes pane takes focus
- `place-window` and `open-window` reply with a distinct outcome for full screen, shared Spaces, mirrored displays, one
  display, and no audience display
- A command event from a pane in the notes window carries that window's reference, and `:pane` still holds the node ID
- A notes comment that closes with `-->` followed by more text on the same line is refused at start, with the slide
  and line named, so no notes text leaks onto a slide
- A `-->` after a slide's tagged notes comment closes, outside fences and code spans and with no `<!--` between, is
  refused at start the same way. A prose arrow such as `Client --> Server` before the notes passes
- The presenter's display is the one macOS reports as primary, at origin (0,0), never the display that holds the key
  window, so moving the source window does not change it
- Started with one display, the presenter says that a rerun after connecting the projector brings the notes, and a
  refused `open-window` does not use up the run's one window
- A tagged notes comment renders nothing in the slide view and in the deck opened as a document
- A comment between two paragraph lines, or between two list items, renders the slide the same with its notes taken out
- An inline comment tagged `notes:` inside a paragraph is not notes
- A deck that has comments but no tagged ones starts, and the start message says how to tag notes

### M3: Live-move spike

**Status:** NOT STARTED

- A live terminal surface and a live text viewer web view each move to a new window and keep rendering, input, and
  focus. The result, including any failure that rules the move out, is recorded in the As built block

### M4: Pop Out Pane

**Status:** NOT STARTED

- The user's Pop Out Pane moves the focused pane, live, into a window of its own, and a shell running in it keeps
  running
- No controller can request a Pop Out
- The new window becomes key with the moved pane focused, and a popped-out member leaves its group
- A popped-out window whose shell ends closes like any window

## Decision Log

- 2026-11-15: Filed as a nice-to-have split from UTERM-024.
- 2026-11-15: Speaker notes moved here from UTERM-025. The user chose to keep notes off the presenter's hot path.
- 2026-11-16: Review start: 2 milestones, 0 settled decisions, 2 risks, no `**Live after:**` lines or row gates, 7 open
  questions. No out-of-scope statements. At the commit "Settle and accept UTERM-025's deck format, ending, layout, and
  slide size". The user asked for an autonomous review of the open questions.
- 2026-11-16 (autonomous): the ADR check added constraints to three open questions. A zoom key is a remappable window
  key, per ADR-04. A window's close must say what happens to the group's panes in the other window. A window a program
  opens, makes full screen, or moves takes no keyboard, and its close drops focus on no neighbor, per ADR-12.
- 2026-11-16 (autonomous): filed the bug `20261116-script-opened-pane-takes-focus`. A pane a script opens with
  `uniterm/open-pane` takes keyboard focus, against ADR-12. Pane zoom and the second window build on the same rule.
- 2026-11-16 (autonomous): filed the bug `20261116-ended-applet-close-gives-neighbor-keyboard`. A focused pane whose
  applet ends on its own gives the keyboard to a neighbor, against ADR-12's rule for an unchosen close.
- 2026-11-16 (autonomous): a second window. A controller power opens a fresh notes window for the laptop, and the
  original window goes to the projector. A user-only Pop Out Pane moves a live pane, behind a spike. Only a connection
  may own groups in two windows. The window's layout needs no anchor, and the command event gains a window reference.
  Converged in 1 pass. A slide window on the projector, a Pop Out alone, and a host notes panel were weighed. The critic
  found that a slide window on the projector leaves the demo on the laptop.
- 2026-11-16 (autonomous): deferred Pop Out's bindings, undo, and close stamps until the live-move spike reports.
- 2026-11-16 (autonomous): speaker notes are block-level HTML comments tagged `notes:`. Converged in 1 pass. Any
  comment, the last comment, a fenced `notes` block, a `Notes:` line, a sidecar file, and `<aside class="notes">` were
  weighed.
- 2026-11-16 (autonomous): pane zoom is a user command only. Converged in 1 pass. A controller power could fire only
  after the user clicked the slide pane, where the user's key already works. This narrows the Motivation's "for a
  script" for zoom. A program change that touches only hidden panes keeps zoom.
- 2026-11-16 (autonomous): authority across windows. A new ADR supersedes ADR-09, with a grant limited to the source
  window plus the windows the run opened. Closing an opened window ends only its groups, and the user's close is final
  for the run. Converged in 1 pass. Closing either window ending the run, a grant per window, and reading ADR-09's one
  window as a set were weighed.
- 2026-11-16 (autonomous): window and display control. One placement kind moves the source window to the audience
  display and makes it full screen, before the notes window opens. Converged in 1 pass. The critic found that the
  settled check placed the notes "on a display other than the source window's", which puts them on the projector when
  the presenter runs from the laptop. Replaced that M2 check. No power, powers over opened windows only, two separate
  kinds, and one kind over every window were weighed. A Swap Displays command is an addition and is left out.
- 2026-11-16 (autonomous): added the open question "Names and version skew". The critic found that no new kind has a
  spelling or a skew decision.
- 2026-11-16 (autonomous): saving and restoring. Neither zoom nor a link between the two windows' groups is saved, and
  the envelope does not change. UTERM-033 never offers the notes window's group. Converged in 1 pass. Saving zoom, a
  group link, both, and not saving an opened window were weighed. Added UTERM-033 to Impacts, since its risk "In-flight
  proposals widen what Allow turns on" needed this statement before acceptance.
- 2026-11-16 (autonomous): focus. Only uniterm's own user commands count as chosen. An unchosen close leaves no pane in
  any window as first responder. Converged in 1 pass. A controller's response to a command counting as chosen, and a
  window-level rule only, were weighed.
- 2026-11-16 (autonomous): names and version skew. Kinds `:window-open` and `:window-placement`, calls
  `uniterm/open-window` and `uniterm/place-window`. The host decides full screen and the reply names the outcome.
  Packages cannot declare either kind. Converged in 1 pass. Verb-first kinds, one `present` call, and placement folded
  into `open-window` were weighed.
- 2026-11-16 (autonomous): amended "Window and display control", settled earlier in this review. It said "the
  presenter skips full screen" and "sizes the window". A script cannot see the Spaces setting, so the host now decides
  and its reply names the outcome.
- 2026-11-16 (autonomous): extended the bug `20261116-ended-applet-close-gives-neighbor-keyboard` with its cross-window
  variant. A single-pane window whose applet ends closes, and macOS hands the keyboard to another window's pane.
- 2026-11-16 (autonomous): coherence review, full pass. Fixes:
  - Amended "Focus". It said a window or pane that closes because its applet ended leaves no pane in any window as
    first responder, and that `exit` in a popped-out shell counts as unchosen. That changed UTERM-001's rule for every
    shell's `exit`, which the user never decided. The close rule now stays UTERM-001's and the filed bug's, and M1 lost
    the check that built it.
  - Amended "Window and display control". It said the audience display is the source window's display when that one
    is not built in. On a Mac with no built-in display in use, that sent the notes to the projector. The menu bar now
    names the presenter's display, and three or more displays name no audience display.
  - Amended the Motivation. It said the screen-share pop-out "is the same mechanism, so one design should serve both".
    The decisions found the two share only a window. The Summary now names Pop Out.
  - "Names and version skew" now states the one-window bound, the `list-windows` and `list-panes` records for an opened
    window, the `:window-open` approval text, and that `:window` is ScriptWire only.
  - Added Impacts lines for UTERM-001, UTERM-028, and UTERM-004 "What anchors trust". Added six risks: notes on the
    audience display, notes leaking onto a slide, the file-store skew, the new published contracts, the spike ruling
    out Pop Out, and an accidental close of the notes window. Reworded the first risk's mitigation, since the ADR is
    written with this proposal.
  - Routed nineteen checks to M2, three to M1, and one to M4.
- 2026-11-16 (autonomous): coherence re-check, pass 2: not converged. The full pass's fix had promised that a display
  change mid-talk never brings the notes onto the audience display, with no decision behind it. Took the no-addition
  fix: placement happens only at start, and a display change made later is the choice of whoever made it. Removed the
  M2 check and accepted the case in the risk. Watching display changes and hiding or closing the window were weighed,
  and each would leave a group nobody can reach. The presenter's display is now named as the primary display, since
  every display shows a menu bar when "Displays have separate Spaces" is on. Routed three checks to M2, merged a
  duplicate, and added the reply outcomes and the opened-window record to the published-contracts risk.
- 2026-11-16 (autonomous): ADR candidate (departs from the past, cuts across the system): a controller's authority
  reaches only its source window and the windows its run opened, and closing an opened window ends only that window's
  share of it. It supersedes ADR-09's one-window limit. Written as ADR-14 on 2026-11-17, with the claim lifted to the
  user's principle: ownership sets default control, so a controller controls what its run opened.
- 2026-11-16 (autonomous): coherence re-check, pass 3: converged. Routed four checks to M2: a narrower stray `-->`
  refusal, the primary display named as macOS reports it, the one-display message and an unspent window after a
  refusal, and one place for the opened-window record.
- 2026-11-16 (autonomous): risk review. Every risk carries a likelihood, an impact, and a mitigation or an acceptance.
  None is high likelihood and high impact. The one-way doors are the new published contracts, listed with their
  recovery rule. Added the risk that the ended-applet focus bug stays open, mitigated by an M4 check that needs its fix.
  Two risks are accepted: the file-store skew, as UTERM-024 accepts it, and an accidental close of the notes window.
- 2026-11-16: Review gate: the user overturned "Pane zoom", from a user command only to the user command plus a
  controller zoom under a permission of its own, refused while focus sits in a pane it would hide. The user kept Pop Out
  Pane in this proposal. Reopened the zoom mechanism, and the names and skew for its new kind.
- 2026-11-17: controller zoom. `zoom-pane` zooms a remote-controlled member that holds its window's focus, and
  `unzoom-pane` ends only a zoom its caller made. The kind is `:pane-zoom`, declared files only. The user chose this
  after the critic converged in 1 pass. A zoom that hides a focused member, an unzoom of any zoom in the window, an
  unzoom of a user's zoom on a member, zoom with no unzoom, and zoom riding on pane control were weighed. Amended "Pane
  zoom", which said "a user command only", and "Focus" and "Names and version skew" to match. Added UTERM-032 to
  Dependencies, a risk for the focus guard, and eight checks to M1.
- 2026-11-17 (autonomous): re-check after the review gate: converged. Routed checks to M1 for the full refusal list,
  the zoom report in `list-windows` and who made the zoom, and the approval text. The source window's record keeps its
  existing fields beside the zoom report. Moved the presenter's refusal message to M2, since the presenter's zoom
  trigger is the user's call.
- 2026-11-17: zoom state belongs to the pane. A controller may end a zoom of its own member, whoever made it, and never
  a zoom on a pane it does not own. The user chose this, so the presenter's Zoom Slide toggles a zoom the user made with
  Zoom Pane. Amended the controller-zoom decision of the same day, which said `unzoom-pane` "ends only a zoom its caller
  made". Ending the slide's zoom shows the window's other panes, which the user hid by zooming.
- 2026-11-17: the presenter zooms only when the user invokes its Zoom Slide command, from the palette or its key, in
  any of its member panes. Nothing zooms on a step. The user chose this, and noted that zoom is a pane operation, not a
  slide feature.
- 2026-11-17: a controller's zoom is refused only while the keyboard sits in a pane it would hide. In a window that is
  not key, it applies and moves that window's focus mark to the zoomed pane. The user chose this after asking why Zoom
  Slide from the notes window would be refused, and ruled out leaving the mark on a hidden terminal. Amended the
  controller-zoom decision, which refused a zoom unless the target was its window's focused pane, key or not. Amended
  "Focus" to match.
- 2026-11-17 (autonomous): re-check of the user's zoom choices: converged. A window holds one zoom, refused as already
  zoomed whether or not it is key. Qualified the focus-guard risk and its M1 check to the key window. Routed checks to
  M1 for a zoom in a window that is not key, a zoom under a sheet, arming after Cmd-`, and a rerun given the group. Routed
  checks to M2 for Zoom Slide while the user has zoomed another pane, and clearer refusal wording.
- 2026-11-17 (autonomous): ADR candidate (cuts across the system): a program's effect never counts as the user's choice
  under ADR-12, even when it answers a command the user invoked. Declined: the user did not pick it, and ADR-12's
  wording covers most of it.
- 2026-11-17: the user named the principle behind cross-window authority: ownership, meaning who opened the window or
  pane, is who may control by default. "Authority across windows" and ADR-14 now state it, with the window rule as one
  case of it.
- 2026-11-17 (autonomous): a final check found that a controller can zoom in a window that is not key with no command
  from the user. UTERM-024 arms a pane's keys on a focus move from another window, so a later Cmd-` would have put the
  controller's keys under keystrokes meant for the hidden terminal, against ADR-12. A mark a controller's zoom moved now
  leaves the zoomed pane's keys disarmed until a click in its content. The user's choice that the keyboard lands in the
  zoomed pane stands. Also corrected the UTERM-028 Impacts line, which cited a heading UTERM-028 does not have. Checked
  "Names and version skew" against ADR-13, which lets ScriptWire keep its exact match.
- 2026-11-17: Accepted. The user chose it after the review gate. ADR-14 is written and accepted, and ADR-09 is
  superseded.
- 2026-11-19: ADR-12 no longer has a rule on closes. Every close hands the keyboard to the neighbor. Amended the "Focus"
  bullet on a window whose last applet ended. It said before: "A window that closes because its last applet ended
  follows the rule for a pane that closes that way. UTERM-001 settles that rule, and the bug
  `20261116-ended-applet-close-gives-neighbor-keyboard` holds the open call on an end the user did not cause. Its fix
  covers a window's close as well as a pane's. This proposal does not change that rule." Dropped the risk that the
  ended-applet focus bug stays open. M4's check changed from "hands the keyboard to no other window's pane, per the fix
  of the bug" to closing like any window.
- 2026-11-20: ADR-12 was retracted. The user retracted it and set that a program's operation behaves as the user's.
  The decisions below rested on ADR-12, so each now follows that rule. Removed ADR-12 from References.
  - Amended "Pane zoom". It said a controller zoom is refused while the keyboard sits in a pane it would hide, in the
    key window, with "focus elsewhere" among the refusals. It also said a mark a controller's zoom moved leaves the
    zoomed pane's keys disarmed until a click, even after Cmd-`. The user chose the refusal on 2026-11-16 and
    2026-11-17 under ADR-12, and this replaces it. A controller's zoom now applies in any window, and the zoomed pane
    takes focus, as it does after the user's Zoom Pane (best guess). The user's Zoom Pane never targets a pane without
    focus, so the direction does not settle that case. The disarm rule is gone. The original question no longer cites
    ADR-12, and the rationale no longer rests on it. The decision's three markers became one.
  - Amended "Pane zoom" on `open-pane` in a zoomed window. It said a pane `open-pane` adds opens hidden and detached,
    and zoom stays. A script's `open-pane` now takes focus as the user's split does, and the user's split ends zoom, so
    a script's `open-pane` ends zoom. Another script's `open-pane` mid-talk therefore shows the audience the hidden
    panes. A layout request keeps its old text.
  - Rewrote "Focus". It said only uniterm's own user commands count as chosen, and every controller effect is unchosen.
    So a controller's zoom applied in the key window only to the focused pane, the notes window opened without becoming
    key with keys live only after a click, and placement kept the key window and its first responder. Now a
    controller's zoom, open, full screen, or move behaves as the same action by the user. The notes window becomes key
    with its notes pane focused, as a window the user opens does (best guess). Placement treats focus as the user's
    full screen or move does. Which window is key after it is not settled here. The original question and rationale
    were rewritten to match. The decision's 2026-11-19 marker became this one.
  - Dropped the risk "A controller gets past the zoom's focus guard", whose mitigation needed the fix of the bug
    `20261116-script-opened-pane-takes-focus`. That bug was removed, and the guard is gone.
  - Amended M1. Removed the focus-elsewhere refusal, the check that a zoom right after `open-pane` is refused, the
    check that a palette row's zoom reads the focus mark, and the disarmed keys after Cmd-`. Added checks that a
    controller zoom in the key window takes focus and that `open-pane` ends zoom.
  - Amended M2. Removed the check that Zoom Slide is refused while the projector window's keyboard sits in the
    terminal. The checks that opening the notes window and placing the source window keep the key window became checks
    that each behaves as the user's action.
- 2026-11-20: A program's layout request now behaves as a set of the user's splits made at once, per UTERM-036. The
  user set that its new panes behave as the user's splits, and the last new pane takes focus. This settles the layout
  request that the entry above left with its old text.
  - Amended "Pane zoom". It said "A pane a layout request adds opens hidden and detached", so zoom stayed. A layout
    request that makes a new pane now ends zoom, as the user's split does, and its last new pane takes focus. A layout
    request that makes no new pane behaves as the same rearrangement by the user would (best guess). The rationale now
    says another script's layout mid-talk shows the audience the hidden panes.
  - Amended M1. The check "A layout request in a zoomed window keeps zoom, and its new panes open hidden" now checks
    that such a request ends zoom and its last new pane takes focus. No check covers a layout that makes no new pane.
- 2026-11-21: Scheduled as UTERM-026 M1-M4 in queue.md.
- 2026-11-23: From UTERM-056's acceptance. A skew line said "The helper and the app match exactly at ScriptWire's hello,
  so a mismatched pair runs no call", and had no version for the added `:window` field.
- 2026-11-26: Amended the skew bullet on file stores, the kind decision's rationale, and the older-build risk for
  UTERM-067, which puts every approval in one store and keeps an entry a build cannot read. The bullet said before: "A
  file store holding an approval of either kind reads as newer on an older build, as UTERM-024 'Stores that older
  builds read' accepts. `policy.json` holds neither kind, since packages cannot declare them, so package approvals keep
  working." The rationale said refusing the kinds in packages "keeps `policy.json` readable on older builds". The risk
  was "An older build stops honoring every file approval", rated medium impact, and is now rated low.
- 2026-11-27: The user retired the `detach` and `reattach` lifecycle events, and ADR-05 is amended to match. Hiding a
  view sends an applet nothing, whether a window is hidden, minimized, or covered, or zoom hides a pane. A hidden
  window's applets already keep running, as macOS apps do, and zoom hides a view the same way. Stopping sound would also
  change a pane's state when the user only asked for a bigger view of another pane.
  - Amended "Pane zoom". Its first bullet said "Zoom is a view state of the window over an unchanged tree. The hidden
    panes get detach, and reattach when zoom ends." The hidden panes now get no lifecycle event and keep running.
  - Amended M1. Its check said "Zoom sends detach to each hidden pane and reattach when it ends, and a playing video or
    audio pauses while hidden". It now checks that a hidden pane gets no event and its video or audio carries on.
- 2026-11-27: From UTERM-063. ScriptWire is at 0 and does not bump, and each permission kind has an internal edition in
  place of a version. The added `:window` field lands in place after UTERM-063 M2.
  - Amended "Names and version skew". Its skew line said "The added `:window` field is a new ScriptWire version, per
    ADR-13 P1, and a connection on an older version does not get it." Its kinds were "each at version 1".
  - Amended "Pane zoom". It said "The kind is `:pane-zoom`, version 1".
- 2026-11-27: Brought in line with UTERM-063 at the user's direction. "Names and version skew" said the new kinds are
  "each named by kind alone and at edition 0", and that "the helper and the app run no call when their versions differ:
  at ScriptWire's hello, or at the helper's begin once UTERM-056 has landed". The kinds carry no version, and the hello
  cannot tell builds apart at 0. The text now says the kinds are named by kind alone, and that an older program is
  refused by name at its first changed message.

## References

- ADR-03: restored state never runs a program
- ADR-05: applet lifecycle
- ADR-06: layout file versioning
- ADR-09: control authority requires authenticated identity and explicit scope, superseded by ADR-14
- ADR-14: a controller controls what it opened, within authenticated identity and explicit scope
