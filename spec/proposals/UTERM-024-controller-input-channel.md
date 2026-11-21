# UTERM-024: Controller Input Channel

**Status:** accepted
**Created:** 2026-11-15
**Updated:** 2026-11-20

## Dependencies

- UTERM-002, for the command registry, the palette, and the one dispatch point that keys, menus, and the palette share
- UTERM-003, for the `uniterm` Janet module, ScriptWire, and its scope note that defers script-registered commands
- UTERM-004, for controller runs, groups and their members, the disconnected mode, revocation, and the permission kinds
- UTERM-013, for command owners, reserved keys, and the order in which a key finds its command
- UTERM-021, for the `declare-permissions` spelling a new permission kind must define
- UTERM-032, for the rule that each permission meaning names where its kind may appear, which keeps the new kind out
  of packages

## Impacts

- UTERM-026 — "The event model" and "Powers and lifecycle": a controller's groups may span its source window and one
  window it opened, per ADR-14. An event gains `:window` beside `:pane` on ScriptWire. The cleanup "when the window
  closes" runs when the source window closes. Closing the opened window ends neither the commands nor the pending reads.
- UTERM-025 — the whole proposal: this is a required prerequisite of the presentation controller. Its Next Slide and
  Previous Slide are commands declared here, bound to the arrow keys and Page Up and Page Down.
- UTERM-028 — "Any key" and "When commands are live": exec drivers gain the same commands and events. Under UTERM-028,
  a driver's own pane lists its rows and takes its keys even when disconnected, which narrows "Which panes take a
  controller's keys" for that pane alone. At a pane that is both a controller's member and a driver's own pane, both
  sets of rows are listed and keys go to the driver alone, per "Where a controller lives".
- UTERM-031 — retracted. It weighed keys in panes that do not opt in, such as the source terminal. A key pressed in such
  a pane belongs to that pane, so "Which panes take a controller's keys" stands as written.
- UTERM-029 — "Scope: what the presenter requires": Go to Slide needs runtime declaration, which this proposal leaves
  out.
- UTERM-003 — "Scope": supersedes in part its out-of-scope line "Invoking or registering UTERM-002 registry commands
  from scripts". Registering becomes in scope. Invoking stays out. UTERM-003 is implemented, so its text stays, and it
  gains a "Superseded in part by UTERM-024" marker when this proposal is accepted.
- UTERM-013 — "What one shortcut declaration is" and "Which keys uniterm reserves": supersedes in part its two-owner
  model. A controller joins uniterm and applet types as a third key owner, after uniterm's keys and the user's remaps.
- UTERM-004 — "Exec wire format": an invocation is a host event, not an applet event, so "remote callers receive no
  applet events" stands and nothing there is superseded. ScriptWire's version goes up.
- UTERM-030 — "The Markdown page opts in": the text viewer's Markdown body opts in to controller keys, per "Which panes
  take a controller's keys".
- UTERM-019 — "Page events" and "Script helpers": the event read here takes the same cursor, timeout, and
  dropped-count shape, and the helpers read through an explicit reader. See "The event model" and "Names".
- UTERM-022 — "Where the form calls live": the read is a host-side waiting call, as there. See "Where the read lives".
- UTERM-032 — "Names": the new kind relies on its placement rule to stay out of `controller.json`. See "Packages".
- ADR-04 — if the third-key-owner rule becomes an ADR, it is a narrower new one, and ADR-04 gains a reference to it.
  See "How ADR-04 changes".
- UTERM-030 — M1's check "The Markdown body delivers controller keys": UTERM-024 M2 builds the Markdown body's
  opt-in, since M2's checks need a body that opts in. UTERM-030 keeps the decision, and its next review drops or
  repoints that check.

## Summary

A Janet controller declares commands. They appear in the command palette while one of the controller's panes has
focus. A command may be bound to a key, with or without modifiers. When the user invokes one, uniterm records an
event. The controller reads its events and acts on them.

This is a required prerequisite of the presentation controller, UTERM-025. Exec drivers and screen control are not
required, and live in UTERM-028 and UTERM-026. A key pressed in a pane that does not opt in stays with that pane.

## Motivation

A program can already drive applets. A Janet script can lay out panes and send commands to the text viewer. What no
script can do is hear the user. A script gets no events at all, and the built-in applets emit no input events.

A presentation controller shows each slide with `show-markdown`. Today it has no way to learn that the user wants the
next slide while the slide pane has focus. The script can read only its own terminal. That works only while the
terminal has focus, and a presenter steps from the slide, usually with the arrow keys.

The same gap blocks other controllers: a build dashboard with Rerun, a review tool with Approve and Next File, a
debugger with Step. Each is a small set of named actions that the user triggers and the program handles.

## Design Decisions (Settled)

### Scope: what the presenter requires

Decision: this proposal holds only what UTERM-025 cannot work without. That is Janet controller commands declared in
the controller's file, their palette entries, their keys, and the events their invocations produce.

- Commands declared by exec drivers are UTERM-028.
- Keys in panes that do not opt in, such as the source terminal, stay with those panes. UTERM-031 weighed them and is
  retracted.
- Declaring commands at runtime serves only Go to Slide, UTERM-029.
- Pane zoom, full screen, and presenter windows are UTERM-026.

Rationale: people step through slides with the arrow keys and Page Up and Page Down, and clickers send the same keys.
Stepping from the palette alone is not usable for a talk.

### Where a controller lives

Decision: a Janet controller runs in the process the user started in a terminal pane, its source. It commands the
members of the groups it owns, which are the panes its layout requests opened. It does not live in those panes.

- The controller's keys and commands are live only in members of its own groups. A pane the user split off inside the
  group's area is not a member, and neither is a pane of another controller's nested group, per UTERM-004 "Group node
  kind". So no pane has two controllers' keys.
- The source pane is not a member, so the controller's commands are not live there. Its terminal keeps every key, and
  each key goes to the terminal's foreground program. When the controller runs in the foreground, it reads them there
  itself.
- Group membership is by stable node ID, per ADR-02.

Rationale: a controller acts only on what it opened. Keying liveness to membership reuses the rule UTERM-004 already
enforces for commands, and settles nested groups with no extra rule.

### Which panes take a controller's keys

Decision: a controller's keys reach it only in a pane body that opts in, and only while that body has keyboard focus.

- The unit is the kind of body a pane shows, not the applet type. One applet can show several kinds. The text viewer
  shows Markdown, PDF, and plain or rich text, and a PDF can hold form fields the user types into.
- A body kind opts in when it never takes typed text. The opt-in is a decision in that applet's own proposal. The text
  viewer's Markdown body opts in under UTERM-030. Its PDF and text bodies do not. The terminal, the REPL, and the browser
  do not, since each takes typed text the host cannot always see.
- Keyboard focus must be in the content itself. A find field, a sheet, or the command palette has focus elsewhere, so
  it keeps its keys.
- A pane the user disconnects through its chrome keeps all its keys, per ADR-09's rule that remembered permission does
  not override a disconnected pane.

Rationale: uniterm cannot tell in general when a pane is taking text input. A browser cannot see focus inside a web
page without page script. Opting in body kinds that are known safe means a controller never takes keys from a body nobody
vetted. A key reaches a controller only from a body that takes no typed text. Keys typed for one body still reach the
controller once the body becomes one that opts in, whoever swapped it, per "A body that changes while the pane has
focus". Amended 2026-11-20; see Decision Log.

### Any key

Decision: a controller may bind any key, with or without modifiers. Each controller binds the keys its job needs, such
as UTERM-025's arrows and Page Up and Page Down.

- uniterm's reserved keys, the user's remaps, and the focused applet's own keys win over a controller's key. See
  "Against the applet's own keys" and "How keys reach the controller". M2 proves a remap onto a plain arrow still
  wins. A key that loses is dropped, and the user is told.

Rationale: the input channel is general. The opt-in rule, not a key list, decides which body's keys reach a
controller, so a list would only limit controllers with no safety gain. Keys typed for a body that swapped to one that
opts in reach the controller, whatever it binds. The user chose this. Amended 2026-11-20; see Decision Log.

### When commands are live

Decision: a controller's palette entries and its keys go live on the same rule. They are live while keyboard focus is
in the content of a member pane that is not disconnected. A key is live only in an opted-in body kind.

- A command is live whenever that state holds, whatever caused it. A layout request that makes the focused pane a
  member, or a declaration that arrives while focus is already there, makes it live at once. A program's change and the
  user's are the same change. See "A body that changes while the pane has focus". Amended 2026-11-20; see Decision Log.
- A command that is not live is not listed in the palette. Its keys reach the pane as if it did not exist.
- The palette judges liveness by the pane whose content had keyboard focus when the palette opened, since opening the
  palette moves focus out of the pane.
- Each pane where a controller's keys are live shows that the controller is taking keys, and the user can revoke the
  controller from there. See "The key indicator".

### Palette only, with the controller named

Decision: controller commands appear in the palette and are bound to keys. They have no menu bar item. Every palette row
for a controller command names the controller it came from, in the text pane chrome shows for it. uniterm draws that
text with the kind of program and its PID. A claimed ID never appears without them. A controller cannot style that name
or leave it out. Amended 2026-11-16; see Decision Log.

Rationale: a palette row that names its controller cannot pass for uniterm's own command, and the user knows which
program acts. UTERM-022's requester header is the precedent. A command's key is carried where the key arrives, so it
needs no menu item. The user chose palette only, and asked that rows say where they came from.

### Powers and lifecycle

Decision: these follow from accepted ADRs.

- Declaring commands is a power of its own. Pane control does not grant it, per ADR-09. See "Names".
- An invocation is recorded when the user acts. The read only waits for recorded events, so it may hold a pending
  reply, per ADR-11. Recording never waits on the controller, per ADR-08.
- When the run ends, the grant is revoked, or the window closes, the controller's commands leave the palette and the
  keys at once. Pending reads fail, and any buffered events are discarded, per ADR-09 and ADR-11.
- A controller that stalls or crashes ends only itself. The palette and the keys never wait on it, per ADR-07.
- No command, key, or event is saved with a layout. A restored group has no commands until a live controller declares
  them, per ADR-03.

### Version skew

Decision: ScriptWire refuses an unknown version at the hello, as it does today.

- A new helper with an old app, or an old helper with a new app: the run fails at the hello before any effect, with
  the message to relaunch uniterm. The helper is the bundle's own, so a relaunch heals it.
- A declared file that names the new permission kind or declares commands is refused whole by an older build.
- A file store holding an approval of the new kind makes an older build treat that whole store as newer. See "Stores
  that older builds read" and Risks.

Rationale: the helper and the app ship in one bundle, so exact-match refusal costs nothing but a relaunch.

### Where the read lives

Original question: a host call like UTERM-022's form calls, or a pending reply in the applet dispatcher like
UTERM-019's `next-events`.

Decision: a ScriptWire host call. ScriptHost holds the pending read for the connection. (autonomous)

- The host fails a pending read through its one path for ended authority, the same path that run end, revocation,
  a closed connection, and the source session's end already take.
- Before a read completes, the host checks again that the caller still holds the power to declare commands and is the
  same run. A caller that fails the check gets the read failed as ended, never the events.
- A read counts against its connection's in-flight calls, not against a window's pending applet replies.

Rationale: the host already knows the caller, its run, and its authority. No applet stands behind a controller's
commands, so a dispatcher reply would need a stand-in target. The dispatcher cancels any pending reply whose applet is
gone, so a stand-in would have to be kept alive by hand. It would also share a window's cap of 64 with browser reads,
so a busy browser could starve the presenter. A push stream was also weighed. The helper reads one reply at a time, and
the host disconnects a peer whose write queue fills, so a slow controller would be cut off. Converged in 1 pass.

### The event model

Original question: a per-run cursor buffer like UTERM-019, or a single-reader queue. Either way: the bound, whether a
drop raises an error in Janet by default, and what an event carries.

Decision: a per-run cursor buffer, in UTERM-019's shape. (autonomous)

- The buffer holds at most 256 events. A full buffer drops its oldest events and counts them. It never grows past its
  bound and never waits on the controller.
- A read takes a cursor and a timeout. It replies when events past the cursor exist or the timeout passes. The reply
  carries the events, the new cursor, and how many events were dropped since the cursor.
- A read only looks. A failed or lost reply loses nothing, and several readers can each keep a cursor.
- An event carries the command's name, the node ID of the member pane whose content had focus, and the input: the
  palette, or the key that triggered it. Node IDs are unique within a window, and a controller's groups are all in its
  own window, per UTERM-004 "Same window only".
- The raw read returns the dropped count. The shipped Janet helper raises a structured error carrying that count, as
  UTERM-019's helpers do.

Rationale: a read with no effect satisfies ADR-11 with no extra mechanism. A queue that removes on delivery loses the
user's input when a reply is lost. A queue whose next read names the last event it saw is a cursor that also deletes,
so it gives up several readers and adds nothing. Raising on a drop makes a stalled controller fail loudly rather than
skip input silently. Converged in 1 pass.

### Registry mechanism

Original question: how controller commands are added and removed at runtime, how their availability follows group
membership, and how the controller's name looks in a palette row and in search.

Decision: `CommandRegistry` stays fixed after launch. Controller commands live in one store the whole app shares, keyed
by run. (autonomous) Amended 2026-11-20; see Decision Log.

- The host owns which commands each run declared and whether its authority holds. Each window owns membership, through
  its own tree's group owners. A window queries the store when its palette opens and when a key arrives. Nothing is
  mirrored into windows, so a revoked controller can never linger in a window that missed an update.
- Menu building, the menu's key route, and applet key resolution never see controller commands.
- A controller's commands are namespaced by its run. A bad declaration is refused with an error, never a precondition.
- A controller's key is checked against the reserved keys and remaps that are live when the key arrives. The check at
  declaration exists only to warn the user early.
- A palette row for a controller command keeps a kind word uniterm draws, "Controller", in the right-label slot, where
  uniterm's own commands read "Command". The row also names the controller in the text pane chrome shows for it. Search
  matches that name at the detail tier, so it never outranks a title match.

Rationale: controller commands share none of the registry's machinery. They have no menu item, a different owner and
lifetime, and liveness that follows focus. A mutable registry would need runtime special cases in code built
for a fixed set. It traps on a duplicate ID and lists unavailable commands dimmed, where controller commands must not be
listed at all. Per-window mirrors would add a sync step that must finish at once on revocation. The kind word keeps a
program-set name from passing for a uniterm label, which is the reason the label slot exists. Converged in 1 pass.

### How keys reach the controller

Original question: whether the window offers a key to the controller before the focused view, or the opted-in body's
content view offers its keys to the window first.

Decision: the window owns one controller-key decision, and calls it from both points where AppKit delivers a key.
(autonomous)

- For a key that arrives as a key equivalent, the window's menu route asks after remapped and uniterm items. Its place
  against the applet's items follows "Against the applet's own keys".
- For a key that does not arrive that way, the window's `sendEvent` asks before the event reaches the first responder.
  It checks remaps through the same menu matching first, so a remap onto a plain arrow still wins.
- Once one point claims a key, the other never sees it.
- A body only reports that it opts in, through a protocol the window can query. The decision asks only when the first
  responder sits inside an opted-in body's content view of a live member pane. A find field, a sidebar, and the palette
  field fall out by construction.

Rationale: AppKit offers key equivalents, which include Command keys and some Control chords, before `sendEvent` runs.
A `sendEvent` check alone would let AppKit's order, not this design, decide which owner wins. Per-body key overrides
would make every body that opts in repeat the ordering, and a body that called its superclass first would send a key to
both WebKit and the controller. Converged in 1 pass.

### Against the applet's own keys

Original question: the text viewer binds Cmd-F, Cmd-G, Cmd-Shift-G, Cmd-E, and Cmd-R, and a controller can bind the
same key. Whether the applet's key or the controller's key wins.

Decision: the applet's key wins. The controller's key is dropped in a pane whose applet binds the same key, and the user
is told, naming the controller. (autonomous)

- The applet binds a key when one of its live menu items matches it, enabled or not, after the user's remaps. A remap
  that moves Find off Cmd-F frees Cmd-F for the controller. A disabled Reload still keeps Cmd-R from the controller.
- A later uniterm build that gives an applet a new key drops a controller key that held it. The user is told then, as
  ADR-04 already accepts for new window keys.
- The controller's command stays in the palette.
- The full order is uniterm's keys, the user's remaps, the applet's keys, the controller's keys, then the view.

Rationale: a more general owner already drops a less general owner's key and tells the user, and a controller is the
least trusted key owner. The menu stays truthful. If the controller won, Edit > Find would show Cmd-F while Cmd-F ran
something else. Hiding the key in the menu would need menu building to see controller commands, which "Registry
mechanism" rules out. Refusing a colliding declaration would let a uniterm update break a working controller at load.
UTERM-025's keys touch no applet key. Converged in 1 pass.

### What a remembered approval covers

Original question: Trust This Version binds to the file's hash, so any edit asks again. Under Trust This Identity, a
signed new version runs without review when it asks for nothing new, per UTERM-021. Whether a new command, a new key,
or a changed key counts as asking for something new.

Decision: the set of keys a controller takes is the scope of its approval. (autonomous)

- Keys are compared in canonical form, as uniterm's key reservations already treat two spellings of one key as one.
- A version whose key set is the same or smaller reuses the approval. A version that takes a key outside the approved
  set asks again, and the review lists the new keys.
- Commands, their titles, and which command a key triggers are data. The review shows them, and they never widen the
  approval.
- A wider approval covers every subset of its keys. It replaces the narrower stored approval it covers, so a policy
  does not grow with each signed version that adds a key.

Rationale: a key is the one thing a controller takes from the user, so ADR-09's rule that broader scopes need consent
applies to it. A palette entry or a title grants nothing, and each row is already attributed with uniterm's kind word.
What a command does is the controller's code, and identity trust never reviews code. Asking again on retitles or
rebinds would guard nothing and train habitual approval, which ADR-09 names as the harm. Asking again on removals would
contradict ADR-09's rule that a narrower request reuses its approval. Treating the commands as unscoped data would let a
signed update take new keys with no consent. Converged in 1 pass.

### Packages

Original question: whether a controller package's `controller.json` can declare commands.

Decision: no addition. Packages cannot declare commands under this proposal. A `controller.json` that names the new
permission kind is refused, and the error says a package cannot declare commands. (autonomous)

- The refusal comes from UTERM-032's rule that each permission meaning names where its kind may appear. Packages and
  declared files share one permission reader, so a format number alone cannot keep the kind out of packages.
- Left undone: a commanded controller that outgrows one file has no package form. UTERM-021 sends such a script to a
  package, so the presenter cannot become one until a follow-up proposal adds commands to `controller.json`. File that
  proposal when a packaged controller needs commands.

Rationale: the settled "Scope" holds only what UTERM-025 needs, and the presenter ships as a declared file. Package
commands would bring in a new descriptor format, signer and lint support, and a skew row for the package store. They
would also widen the downgrade risk to every package approval. Converged in 1 pass.

### The key indicator

Original question: the slide pane is projected, so a list of the controller's keys shows to the audience. Whether the
mark lives in the pane chrome, in the status bar while the pane has focus, or both.

Decision: the pane's existing control badge takes a distinct look while the controller's keys are live in that pane.
Its tooltip and menu list the keys, and the menu keeps Revoke Controller. (autonomous)

- The listed commands carry the "Controller" kind word, and the list is bounded with a count of the rest.
- The badge's accessibility value says the controller is taking keys.

Rationale: every member pane already shows the badge, so the audience sees nothing new beyond a change of look. The
list shows only on hover or in the menu. The status bar cannot be hidden, so a key list there would show to the
audience for the whole talk. It would also need a window-state segment that follows focus, which no window state does
today. Converged in 1 pass.

### Names

Original question: the permission kind and its declaration spelling, the spelling for declaring commands and their
keys, and the Janet functions. Each follows UTERM-021's "The declaration's data shape" and UTERM-003's verb-noun naming.

Decision: commands are fields of the permission entry, and the helpers read through an explicit reader. (autonomous)

```janet
(declare-permissions {:id "dev.example.presenter" :name "Presenter"}
  {:kind :controller-commands :version 1
   :commands [{:name :next-slide :title "Next Slide" :keys [:right :down :page-down :space]}
              {:name :previous-slide :title "Previous Slide" :keys [:left :up :page-up]}]})
```

- The kind is `:controller-commands`. Command names and keys are keywords, and titles are strings.
- A key with modifiers is one keyword, with modifiers first in a fixed order, such as `:cmd-shift-g`. A key that cannot
  appear in a keyword has a named token, such as `:cmd-left-bracket`. The modifiers are a closed set, so `:cmd--` is
  Cmd-Minus. An unknown key refuses the file.
- The declaration's converter types every field inside `:commands`, so a string where a keyword belongs refuses the
  file. The shared reader cannot tell the two apart once they are JSON.
- The app derives the approval's scope, the canonical key set, from the entry itself.
- A stored approval holds each key in this keyword spelling, which never changes meaning. A later build that folds
  keys differently, such as through another keyboard layout, adds a new version of the kind rather than changing how a
  stored key reads.
- `(uniterm/read-command-events cursor timeout)` is the raw read. It returns `{:events [...] :cursor n :dropped n}`.
- `(uniterm/command-events)` returns a reader that holds its own cursor. `(uniterm/next-command reader &opt timeout)`
  returns one event, or nil on timeout, and raises on a drop. `(uniterm/each-command reader handlers &opt stop)` calls a
  handler per event, as UTERM-019's `each-event` does. Event names come back as keywords, so a handler table keyed by
  `:next-slide` matches.

Rationale: one entry carries both the power and its scope, so the reader, the review, and the store work on the
permission list alone, as UTERM-032's entry does. A second top-level form would sit outside every check UTERM-021
built for the first form, including the merged-duplicate-key check, the lint, and the fuzzer. It would also make new
invalid states expressible, such as the kind with no commands or commands placed after code. A hidden cursor shared by
the helpers would let one helper eat another's events. UTERM-019 rejected that for the same reason. Converged in 1
pass.

### How ADR-04 changes

Original question: a new ADR that supersedes ADR-04, restating its rules with three owners, or a narrower ADR that adds
controller keys and leaves ADR-04's text in force for the other two.

Decision: ADR-04 stays in force unchanged. If the controller-key rule ever becomes an ADR, it is a narrower new one
beside ADR-04, never a replacement. At acceptance the user chose no ADR, so the rule lives in this proposal.
(autonomous) Amended 2026-11-20; see Decision Log.

- No ADR-04 Decision bullet becomes false. A controller comes after uniterm's keys and the user's remaps, and ADR-04's
  applet rule constrains only applets. Only its Context line that keys have two owners goes stale.
- Such an ADR would name the invariants, not the mechanisms. A program that is neither uniterm nor an applet may take keys
  only in panes it controls, after uniterm's keys, the user's remaps, and the applet's keys. It never receives a key
  from content that takes typed text.
- It cites ADR-09 for the separate power, rather than restating it.
- It says what the user can do about a controller key, since a controller command has no menu item to remap. The user
  can remap another command onto the key, which then wins, or revoke the controller.

Rationale: superseding ADR-04 would restate an unchanged Ghostty-config decision. It would also leave every spec that
cites ADR-04 pointing at a superseded record. A narrower ADR keeps a later change to controller keys from
reopening ADR-04. Converged in 1 pass.

### A body that changes while the pane has focus

Original question: liveness latches when focus moves into a member pane, but a key reaches the controller only from an
opted-in body. A user typing into a PDF form field in a live member pane, followed by a controller's `show-markdown`,
swaps the body to Markdown with no new focus change. If the first responder lands in the Markdown view, the next typed
letters go to the controller.

Decision: no latch. A key is judged when it arrives, per "How keys reach the controller". It reaches the controller only
when the first responder then sits in an opted-in body's content of a live member pane. A body change neither arms nor
disarms anything, whether a program or the user made it. (autonomous) Amended 2026-11-20; see Decision Log.

- A change into an opted-in body takes the controller's keys at once while focus is in its content. A change out of one
  ends them at once.
- A message body, such as "Opening…" or the notice that the page's process ended, does not opt in. No key reaches the
  controller while one shows. Keys reach it again once Markdown returns with focus in its content.
- Where the first responder lands after a body change is the applet's own behavior for that change. It is the same
  whoever asked for the change.
- Palette rows do not depend on the body kind, so a body change never adds or removes them.
- So a letter the user types for a PDF form field reaches the controller, when it is bound, once a program swaps the PDF
  for Markdown. The same swap by the user has the same result.

Rationale: a program's operation behaves as the user's. A Markdown body the user brings up takes the controller's keys
at once, so one a controller brings up does too. A latch per body kind treated one change two ways by its cause. The
check at key time already keeps every key to an opted-in body's content.

### Stores that older builds read

Original question: the new kind lands only in file stores: `files.json`, or UTERM-032's store for runs with an input
folder, where the presenter's approval goes. An older build reads such a store as newer.

Decision: no addition. Accept the skew, and state it per store. (autonomous)

- On a build without the kind, `files.json` and UTERM-032's input-folder store read as newer. Every approval in them
  stops working, and that build can neither remember a new approval nor revoke one there. It shows its notice that a
  newer uniterm wrote the file, and it never moves the file aside.
- `policy.json` holds no approval of the kind, since packages cannot declare it, so package approvals keep working.
- Dev and release builds share one store folder, so this is the common case on a development machine.
- UTERM-032 kept its folder policies out of older builds' stores for a list change. A new declarable kind is a
  different case, as UTERM-022 found for `ask-user`. The window closes once a build with both proposals ships.
- Left undone: a reader that skips only the policy it cannot read, instead of the whole store. It would change the
  trust-store contract UTERM-021 owns, and it cannot reach builds already installed.

Rationale: the failure is closed, and no data is lost. A store of its own for commanded approvals would go whole-newer
at the kind's next version, and would override UTERM-032's rule that a folder policy lives whole in its store. Never
remembering the kind would also remove Remember for the run's other powers, including the presenter's folder.
Converged in 1 pass.

## Design Decisions (Open)

None.

## Risks

- **A new ScriptWire version, permission kind, Janet functions, and event shape are published contracts** —
  likelihood: high, impact: medium. Mitigation: ScriptWire refuses an unknown version at the hello, and an unknown
  permission kind fails closed. See "Version skew". The Janet names follow UTERM-019's rule that a name never changes
  meaning and a rename adds a name, and an event gains fields only by adding them.
- **An older build stops honoring every file approval** — likelihood: high on a development machine, low elsewhere,
  impact: medium. After an approval of the new kind is saved, a build without the kind reads `files.json` and
  UTERM-032's input-folder store as newer. It cannot use, remember, or revoke any approval in them. `policy.json` is
  untouched. Accepted: it fails closed with no data lost, as UTERM-022 accepted for `ask-user`, and the approvals come
  back on the new build. See "Stores that older builds read".
- **Navigation-key capture confuses the user** — likelihood: medium, impact: medium. A viewer stops scrolling on the
  arrow keys, and the user does not know why. Mitigation: the key indicator, the scope to the controller's own members,
  and revoking from the pane.
- **A body opts in that takes typed text** — likelihood: low, impact: high. Any key may be bound, so a controller would
  read what the user types there. This includes a later change that lets the Markdown sanitizer pass an element that
  takes text. Mitigation: the opt-in is per body kind, decided in that applet's proposal. M2 checks that the terminal,
  the REPL, the browser, and the viewer's PDF and text bodies never deliver a key, and a test fails if the sanitizer
  ever allows an element or attribute that takes text.
- **A controller key and an applet key mask each other** — likelihood: medium, impact: low. One of them goes dead in the
  controller's panes. Mitigation: the applet's key always wins, and the user is told which controller key was
  dropped. See "Against the applet's own keys".
- **A controller's palette entry passes for uniterm's** — likelihood: medium, impact: medium. Mitigation: the row keeps
  uniterm's "Controller" kind word and the name pane chrome draws. See "Registry mechanism".
- **Adding controller commands at runtime destabilizes the menu and keys** — likelihood: low, impact: medium.
  Mitigation: `CommandRegistry` stays fixed, and controller commands live in a separate store the menu never sees. M1
  tests adding and removing controller commands while uniterm's and the applets' commands keep their keys and menu
  places.
- **The stored key spelling is a published contract** — likelihood: low, impact: high. If a later build read a stored
  key differently, two keys could compare equal and widen an approval without consent. Mitigation: a stored key's
  spelling never changes meaning, and a new folding is a new version of the kind. See "Names".
- **The package refusal waits on UTERM-032's placement rule** — likelihood: medium, impact: medium. UTERM-032 is
  accepted but not built. If UTERM-024 M1 is built first, nothing keeps the kind out of `controller.json`.
  Mitigation: UTERM-032 is a dependency, so the queue orders UTERM-032 M1 before UTERM-024 M1.
- **A waiting read blocks the Janet thread** — likelihood: high, impact: low. A controller cannot serve other work while
  it waits. Accepted: the read takes a timeout. A controller that needs both reads with short timeouts. A Janet event
  loop is out of scope.

## Milestones

### M1: Commands and the event read

**Status:** NOT STARTED

- A Janet controller's declared commands show in the palette, each row naming the controller, only when the palette
  opened from a member pane's content
- Invoking one from the palette records an event, and the controller's read returns it
- A run without the new power is refused before any command is registered
- Ending the run, revoking it, or closing the window removes its commands at once and fails its pending read
- A stalled controller never delays the palette, and its read times out
- Adding and removing controller commands leaves uniterm's and the applets' commands with the same keys and menu places
- A restored layout has no controller commands
- The approval panel lists each declared command and its key
- A pending read fails as soon as the source session ends, without waiting out its timeout
- A pending read whose caller lost the power to declare commands fails as ended and returns no events
- A cursor past the newest event, or from before the run, is refused. The dropped count stays right after the buffer
  wraps
- With focus in a member's find field when the palette opens, the controller's commands are not listed
- A declaration that repeats a command name is refused with an error, and the app keeps running
- Under Trust This Identity, a signed version that takes a key outside the approved set asks again and lists the new
  keys. One that takes the same keys, fewer keys, or the same key spelled another way runs without review
- After a wider key set is approved, every subset of it reuses the approval
- A declaration with more commands or keys than the bound is refused
- Approving a wider key set replaces the narrower stored approval it covers, so a policy does not grow with each signed
  version
- A controller's title is neutralized and bounded in the palette, as tab details are
- A declaration of the new kind without pane control is refused, and its error says to add pane control
- Revoking a controller while the palette is open removes its rows, and choosing a stale row records nothing
- An older command and a newer app refuse each other at the hello. A build without the kind reads a store holding it
  as newer, without moving the file aside
- A `controller.json` that names the new permission kind is refused, and its error says a package cannot declare
  commands
- Every key a key chord can hold has a spelling, and two spellings of one chord compare equal
- A string where a keyword belongs inside `:commands`, or the reverse, refuses the file
- A version that changes only titles, or which command a key triggers, reuses a stored approval
- `next-command` advances its reader past a drop before raising, so the next call does not raise again.
  `each-command` stops by its stop rule. A handler key that names no declared command is refused

### M2: Keys

**Status:** NOT STARTED

Amended 2026-11-20; see Decision Log.

- A controller's plain keys and keys with modifiers invoke its commands while a text viewer member's page has focus
- The same keys reach the pane as before in a pane that is not a member, including one split off inside the group's
  area and the source terminal
- The same keys reach the pane as before in a disconnected member, a terminal, REPL, or browser member, a find field,
  the contents sidebar, and the command palette
- A text viewer member showing a PDF or a text file delivers no key to the controller
- A test fails if the Markdown sanitizer allows an element or attribute that takes text
- A remap that appears after declaration drops the controller's key, and the user is told then
- A dropped controller key is reported once per run, not on every press
- After the controller's `show-markdown` replaces a PDF in a focused member, a bound key reaches the controller at once
  when focus is in the Markdown content, with no click or focus move first
- A member whose last body before a message body was Markdown keeps its keys live when Markdown returns. The bound key
  reaches the controller after the message. Focus never falls to a neighbor pane during the message, and is not pulled
  back if the user moved it elsewhere. An inline Markdown-to-Markdown step never hides the web view
- A program-driven first Markdown body in a focused member takes the controller's keys at once
- A controller's `show-markdown` that lands while the palette is open leaves the controller's rows listed
- A palette-driven step from one PDF member document to the next keeps the controller's rows
- A Markdown member that reopens its file, or reloads after its page's process ended, keeps its keys live through the
  "Opening…" or ended-process message
- The text viewer's Markdown body adopts the opt-in protocol, and its PDF and text bodies do not
- A Command key and a Control chord bound by a controller each reach it, or lose to the applet's key on the same
  chord, by the order "Against the applet's own keys" sets, never by AppKit's delivery order
- A controller key that matches a text viewer item stays dropped while the item is disabled, such as Reload on a slide
  with no file. After the user remaps Find off Cmd-F, the controller's Cmd-F reaches it
- The badge's menu lists the controller's commands with the "Controller" kind word, bounded with a count of the rest,
  and its accessibility value says the controller is taking keys
- A letter key bound by a controller never reaches it from a terminal, REPL, or browser member, or a find field
- With keyboard focus already in a pane that becomes a member, the controller's commands are live at once, with no click
  or focus move first
- A reserved uniterm key and a user's remap win over a controller key, including a remap onto a plain arrow. The
  dropped key is reported to the user
- The key indicator shows on each pane where the controller's keys are live
- A controller key reaches it only after uniterm's keys, the user's remaps, and the applet's keys, and never from
  content that takes typed text

## Decision Log

- 2026-11-15: Screen control moved to its own proposal, UTERM-026. The presenter moved to UTERM-025.
- 2026-11-15: Controller commands are live only while a pane the controller owns has focus.
- 2026-11-15: Plain keys came back from UTERM-027 as required. People step slides with the arrow keys, so a presenter
  without them fails its job.
- 2026-11-15 (addition): lifts the registering half of UTERM-003's out-of-scope line on registry commands.
- 2026-11-15: Removed the claim that a response to a command may move focus "within ADR-12's rules for chosen changes".
  ADR-12 has no rules for chosen changes, and the presenter moves no focus. UTERM-026 owns the question.
- 2026-11-15: Chords moved to UTERM-031. The presenter binds none, and Control chords would let a controller take Ctrl-C
  and line-editing keys from a terminal member. The user chose this. Superseded on 2026-11-16 by "Any key": keys with
  modifiers are back, and UTERM-031 narrows to panes that do not opt in.
- 2026-11-15: Navigation keys reach a controller only in applet types that opt in, while their content has keyboard
  focus. The user chose this over a per-applet text-input hook and a plain focus check.
- 2026-11-15: commands are declared in the controller's file only. The user confirmed it on 2026-11-16. Runtime declaration serves only UTERM-029's
  Go to Slide. The source pane is never live, since it is not a member and chords left. Nested groups need no rule,
  since liveness is by membership.
- 2026-11-15: ADR candidate (cuts across the system): a program that is neither uniterm nor an applet may take keys
  only in panes it controls, after uniterm's keys, the user's remaps, and the applet's keys, and never from content
  that takes typed text. Declined on 2026-11-16: the user chose no ADR, so the rule lives in this proposal.
- 2026-11-16: Any key may be bound, with or without modifiers. The user corrected an agent trim that had limited
  UTERM-024 to the presenter's six keys. The input channel stays general, and UTERM-025 binds only what it needs. The
  opt-in rule keeps typed text from a controller. Keys with modifiers come back too, since the Ctrl-C finding was about
  terminals, which never opt in.
- 2026-11-16: Controller commands appear in the palette only, with no menu item. The user chose this, after the design
  critic flagged that the agent had settled it without asking. Left undone: menu discoverability, and remapping a
  controller command by its menu title.
- 2026-11-16 (agent): the opt-in unit is the kind of body, not the applet type. The design critic found that the
  text viewer's PDF body can hold form fields, so an applet-wide opt-in would let a controller read what is typed into
  them. This narrows the user's choice that the text viewer's page opts in to its Markdown body.
- 2026-11-16: Review start: 2 milestones, 8 settled decisions, 8 risks, no `**Live after:**` lines or row gates, 10
  open questions. Out of scope: exec drivers, keys in panes that do not opt in, runtime declaration, screen control, a
  Janet event loop, and invoking registry commands. At commit "Apply the fourth critique to the presenter hot path".
  The user asked for an autonomous review of the open questions.
- 2026-11-16 (autonomous): added the open question "What a remembered approval covers". The ADR check found that
  UTERM-021 runs a signed new version under a trusted identity when it "asks for nothing new". This proposal never
  says whether a new command or key is new.
- 2026-11-16 (autonomous): the read is a ScriptWire host call that ScriptHost holds per connection.
- 2026-11-16 (autonomous): events go in a per-run cursor buffer of 256, in UTERM-019's shape. Each event carries the
  command, the member pane's node ID, and the input. The shipped helper raises on a drop.
- 2026-11-16 (autonomous): controller commands live in one app-wide store keyed by run. `CommandRegistry` stays fixed
  after launch. A palette row keeps the kind word "Controller" and names the controller as pane chrome does.
- 2026-11-16 (autonomous): the window owns one controller-key decision. It is called from the menu route for key
  equivalents and from `sendEvent` for other keys.
- 2026-11-16 (autonomous): amended "Palette only, with the controller named". It said rows use "the name the transport
  verified, per ADR-09". An unsigned declared file's ID is claimed, not verified. Rows now use the text pane chrome
  shows, which uniterm draws with the kind of program and its PID.
- 2026-11-16 (autonomous): the applet's key wins over a controller's key, judged by the applet's live menu items after
  remaps, enabled or not.
- 2026-11-16 (autonomous): the set of keys a controller takes is its approval's scope. Commands and titles are data.
- 2026-11-16 (autonomous): packages cannot declare commands. UTERM-032's placement rule refuses the kind in
  `controller.json`. Added UTERM-032 to Dependencies for that rule.
- 2026-11-16 (autonomous): the key indicator is a distinct look on the existing control badge, with the keys in its
  tooltip and menu.
- 2026-11-16 (autonomous): names. The `:controller-commands` kind carries its commands as fields. Keys are keywords
  with named tokens for punctuation. The helpers read through an explicit reader: `command-events`, `next-command`, and
  `each-command`, over the raw `read-command-events`.
- 2026-11-16 (autonomous): the third key owner gets a narrower new ADR, and ADR-04 stays in force.
- 2026-11-16 (autonomous): amended M2. It said "The ADR for the third key owner is accepted". A proposal's ADR is
  accepted with the proposal, not at a milestone, so the check is now that the built key path holds the ADR's rules.
  Amended again the same day to state the rules themselves, since whether the ADR is written is still the user's call.
- 2026-11-16 (autonomous): coherence fixes. "When commands are live" now says body kind where it said applet type. The
  third-key-owner rule's text no longer assumes its ADR exists. The stored key spelling is fixed, with its own risk. A
  wider approval replaces the narrower one it covers. UTERM-024 M2 builds the Markdown body's opt-in, since M2's
  checks need it and UTERM-030 depends on UTERM-024. The package refusal's wait on UTERM-032 joins the risks.
- 2026-11-16 (autonomous): added the open questions "A body that changes while the pane has focus" and "Stores that
  older builds read" from the whole-proposal review.
- 2026-11-16 (autonomous): liveness latches per body kind. A program-driven change from a body that takes typed text
  into an opted-in body disarms the keys, and a click in the content arms them. Amended "When commands are live". It
  said a command goes live when focus moves in, "never while focus is already there".
- 2026-11-16 (autonomous): accepted the file-store skew, restated per store and rated high on development machines.
  Left undone: a reader that skips only the policy it cannot read.
- 2026-11-16 (autonomous): re-check fixes to "A body that changes while the pane has focus". Message bodies are
  transparent, so PDF, then "Opening…", then Markdown disarms. Tab and Escape no longer arm the keys, per ADR-12. Only a
  click in the content or a focus move from outside the pane does. Palette rows follow the same rule.
- 2026-11-16 (autonomous): second re-check fixes, not re-checked since the loop's three passes were spent. Focus that
  comes back from the palette or a sheet does not arm the keys. Only a click in the content, or a user move from
  another pane or window, does. A change between bodies that do not opt in keeps the palette rows, and only a change
  into an opted-in body from one that does not opt in disarms.
- 2026-11-16 (autonomous): risk review. The published-contract risk now covers the Janet functions and the event
  shape. The file-store skew is rated high on development machines and accepted. No risk is rated high likelihood and
  high impact.
- 2026-11-16: Review gate: kept all. The user kept the body-swap rule, with its last fixes not re-checked, and left
  the tolerant trust-store reader out.
- 2026-11-16: Accepted. No ADR for the third key owner. Amended "How ADR-04 changes". It said "a narrower new ADR
  that adds controller keys", and now says ADR-04 stays unchanged, with that form kept for any later ADR.
- 2026-11-16: UTERM-031 is retracted, since a key pressed in a pane that does not opt in belongs to that pane. Every
  line that sent work to UTERM-031 now says so instead:
  - The Summary said keys in panes that do not opt in "live in UTERM-028, UTERM-031, and UTERM-026".
  - "Scope: what the presenter requires" said those keys "are UTERM-031".
  - "Where a controller lives" said "UTERM-031 weighs keys there". It now says the source terminal's keys go to its
    foreground program, which is the controller itself when the controller runs in the foreground.
  - The rationale of "How ADR-04 changes" named "UTERM-031's" change as its example.
  - The risk "The third-key-owner rule shifts under UTERM-031" is removed, since no proposal now widens where keys
    reach.
- 2026-11-16: UTERM-028 is accepted. Its Impacts line here now says what it narrows. A driver's own pane lists its rows
  and takes its keys even when disconnected. At a pane that is both a controller's member and a driver's own pane, keys
  go to the driver alone, so a Janet controller's keys leave that member while the driver holds its grant.
- 2026-11-20: ADR-12 was retracted. The user set that a program's operation behaves as the user's. So a program's change
  neither arms nor disarms a controller's keys, and keys are live as soon as they are declared. Every line that rested
  on ADR-12 now follows that rule:
  - Impacts said a focus mark that a controller's zoom moved leaves the zoomed pane disarmed until a click in its
    content. That sentence is removed.
  - "When commands are live" said a command goes live only when the user moves focus in or clicks the content. A layout
    request or a declaration that arrived while the user typed waited for that, per ADR-12. It now says a command is
    live whenever its state holds, whatever caused it.
  - "Registry mechanism" said liveness "latches when focus moves". It now says liveness follows focus.
  - "How ADR-04 changes" said a later ADR would cite ADR-12 for the focus-change rule. That clause is removed.
  - "A body that changes while the pane has focus" said a program-driven change into an opted-in body disarms the keys
    and palette rows. Only a click in the content or a focus move from outside the pane armed them again, and no key
    did. Message bodies were transparent to that latch. It now has no latch. A key is judged when it arrives, and the
    rows never depend on the body kind. It also states the result: a letter typed for a PDF form field can reach the
    controller once a program swaps in Markdown, as after the user's own swap.
  - M2 checked that keys stay off after such a change until a click or focus move. It also checked that a click during
    a message does not arm, that a program-driven first body is disarmed, and that a `show-markdown` under the open
    palette removes the rows. Tab and Escape did not arm, and repeats of a key pressed earlier reached the pane. It now
    checks that keys and commands are live at once and that the rows stay listed. The arming and repeat checks are
    removed. Its marker moved from its last check to the milestone head.
  - References listed ADR-12.
- 2026-11-20: Reworded the rationales of "Which panes take a controller's keys" and "Any key". With no latch, a key
  the user types for a body that swaps to one that opts in reaches the controller. The first rationale said "Because a
  key reaches a controller only where nothing is typed, any key may be bound without the controller learning typed
  text." The second said "The opt-in rule, not a key list, keeps typed text from a controller". Both now say plainly
  that typed keys reach the controller after such a swap, whoever made it. No mechanism was added.

## References

- ADR-02: stable pane IDs
- ADR-03: restored state never runs a program
- ADR-04: uniterm owns key bindings
- ADR-07: failure isolation
- ADR-08: UI responsiveness
- ADR-09: control authority requires authenticated identity and explicit scope
- ADR-11: deferred applet replies never hide effects
