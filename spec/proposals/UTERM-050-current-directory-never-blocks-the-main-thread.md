# UTERM-050: The Current Directory Never Blocks the Main Thread

**Status:** accepted
**Created:** 2026-11-22
**Updated:** 2026-11-27

## Dependencies

- UTERM-001, for the applet contract and the pane tree
- UTERM-004, for `list-panes` and the new-pane and new-tab commands that read the directory

## Impacts

- UTERM-048 — M2 waits on this proposal's M1. Its settled decision "The current directory in the polled snapshot" names this
  work as its dependency. The panel shows whatever the fixed property returns. Under "How an applet meets the rule" that
  is the path as held, with no unknown state.
- UTERM-051 — its restore decode and this proposal's "How an applet meets the rule" both touch the terminal's restore.
  The directory check moves into the session start, so the decode can move off the main thread either way.

## Summary

An applet's `currentDirectory` stops checking the file system on the main thread, and so does every main-thread check of
the same directories by the code that uses them. The rule goes into the applet contract, so no applet can break it
later. The property returns the path as held. One resolver checks a directory off the main thread before a terminal
starts in it or a panel opens in it. A fourth libghostty patch removes libghostty's own main-thread open of the start
directory. A terminal tab that waits on its folder shows that it is waiting. `list-panes` reports the path as held
under a new key, in place, and retires `:directory` from its reply. No version bumps, which UTERM-063 keeps at 0.
Amended 2026-11-27; see Decision Log.

## Motivation

Bug `20261122-terminal-directory-check-blocks-main-thread` records the problem. A shell can report through OSC 7 a
directory on a network mount that stopped answering. A viewer can also show a file whose folder sits on such a mount.
`currentDirectory` then calls `FileManager.fileExists` on that path, and the call does not return until the mount
times out.

Every reader of the property runs on the main actor. They are `list-panes`, a new pane or tab beside the applet, and the
open panel's starting folder. The terminal's reopened tab and its restore check their saved directories the same way,
without reading the property. Each one can freeze every window.

ADR-08 says the main thread never waits on work whose duration uniterm does not bound. A check against a path the
user's shell or file chose has no bound. The terminal already moves its link checks off the main thread for this
reason. `currentDirectory` is the same kind of check, and it was missed.

The bug was found by reading the code. It was not reproduced, because that needs a mount that stops answering.

## Design Decisions (Settled)

### Whether the rule covers every applet or only the terminal

The terminal checks a reported path. The data, map, text, and image viewers check the folder of their open file the
same way. The property is not the only main-thread check of these paths. `OpenPanelRequest` checks the start folder
again before an open panel runs. The terminal's restore and its reopened tab check the saved directories through
`RestoreDirectory.resolve`, without reading the property. Separately, the viewers' pane-local Open runs `stat` on the
main actor on the file the user just picked, through `SourceStartDirectory.of`. The candidates were:

- Every applet's `currentDirectory`, and every main-thread check of the same paths by the code that uses them: the
  open panel's start folder, the terminal's restore, and its reopened tab. This is the reader list in Motivation.
- The same, plus the `stat` of a file the user just picked in a viewer's Open. That path is not a current directory,
  and the panel had just listed it, so its mount answered a moment before.
- Every applet's `currentDirectory` only. The open panel's own check, restore, and reopen keep checking on the main
  thread.
- Only the terminal's `currentDirectory`. The viewers keep their checks, since a file the user opened is less likely to
  sit on a dead mount. This leaves the same freeze reachable from a viewer.

Decision: every applet's `currentDirectory`, and every main-thread check of a directory that came from the property or
from a saved tab. Decided autonomously on 2026-11-22. The list is:

- the five `currentDirectory` implementations
- the terminal's `init(workingDirectory:)` and `init(program:workingDirectory:)`. Every new pane, new window, launcher
  choice, and layout reaches them through the app's applet factory, so they carry the split-pane case Motivation names
  first
- the terminal's restore init and `reopenTab`
- `OpenPanelRequest`'s start folder, for File > Open and a pane's own Open
- the map viewer's save panel, which starts in `currentDirectory`

Covering the property alone moves the freeze without removing it. A split beside a dead-mount terminal would pass the
raw path to `init(workingDirectory:)`, which checks it on the main thread. Terminal-only coverage conflicts with ADR-08,
which rules out deciding unbounded waits case by case.

The `stat` of a picked or dropped file is the same kind of defect, but it is not a current directory. It runs from each
viewer's drop handler as well as its Open, so a drag from any app reaches it. It is filed as its own bug,
`bugs/20261122-picked-file-start-directory-stat-on-main-thread.md`, and is not part of this proposal.

### How an applet meets the rule

Two facts from the pinned libghostty bear on every candidate. Surface creation opens and stats the start directory
synchronously (`src/apprt/embedded.zig`, about lines 527-545), and uniterm creates surfaces on the main thread. So a
path handed to libghostty unchecked freezes the app inside libghostty, and letting the start fail is not a fallback.
The subprocess also checks the directory on libghostty's IO thread and, when it cannot access it, inherits the app's
own directory (`src/termio/Exec.zig`, about lines 945-988). That is not uniterm's reported, then starting, then home
order.

libghostty already drops an OSC 7 report whose host is not this machine (`src/termio/stream_handler.zig`, about lines
1569-1583). So the existence check matters for ssh only when a remote shell reports `localhost`.

Each viewer's property today returns its file's folder, else its start directory, each checked. A property that
returns one unchecked path gives a resolver only the folder. A folder that is gone then falls to home instead of to the
start directory. Keeping that step would need the property to return an ordered list of candidates, which changes the
applet contract.

Even after an off-main check, libghostty opens the directory again on the main thread at surface creation. A mount that
dies between the check and the surface, or one that is slow but alive, still makes the main thread wait there. Only a
change to libghostty removes that wait. uniterm already carries three patches to the pinned libghostty in
`ThirdParty/ghostty-patches/`. A fourth could drop the open and stat in `embedded.zig` and set the working directory
from the string. The subprocess's own access check stays on the IO thread. A wrapper that runs `cd` inside the child is
not a way around it: libghostty picks its shell integration from the command's first word, so OSC 7 reporting would
stop.

A terminal that starts its session late changes some synchronous promises. `reopenTab` promises that a session that
fails to start leaves no tab and keeps the closed-tab entry, and today it removes the entry right after the start.
`focus()` makes the session's view first responder, and returns early when the tab has no session. Then, after a
split, the new pane is marked focused while the old pane's terminal keeps the keyboard, and keys typed during the wait
reach the old shell. Script `open-tab` is already `async` and reports a session that fails to start as refused.

The candidates were:

- `currentDirectory` returns the path as the applet holds it, after the absolute-path string test, with no file-system
  work. Every caller that uses the path as a place resolves it off the main thread before acting: a new pane, window,
  or tab, a launcher's choice, a layout, restore, reopen, and an open or save panel's start folder. One shared resolver
  runs uniterm's reported, then starting, then home order. Checks of the same path share one check in flight, which
  bounds the threads a dead mount can park. About ten of these call sites are synchronous on the main actor today. Each
  becomes a request and a later reply, and must look the pane up again when the reply comes, as `open-pane` already
  does. A new pane or tab appears only once its check answers. No type tells a checked path from a raw one, so a
  later caller that forgets to resolve sends a raw path into libghostty. The viewers lose the step from a gone folder
  to their start directory, and libghostty's own main-thread open stays.
- `currentDirectory` returns the held path with no file-system work, as above. The terminal applet resolves every
  directory it is given off the main thread, in the same order and with the same shared check in flight, and starts
  its session only when the check answers. The window's call sites stay synchronous: split, new window, the launcher,
  layout, and script `open-pane`. Nothing looks a pane up again. The open and save panels resolve their start folder
  inside flows that are already `async`. Script `open-tab` awaits the session start, so it still reports a failed
  start as refused. A reopened tab keeps its closed-tab entry until its session starts, and the entry stays when the
  start fails. A tab waiting on its check takes first responder, so typed keys never reach another pane's shell. A
  new pane's session failure is already reported late today, since `start(origin:)` runs after placement and posts a
  notice. A tab with no session already exists, for a program-mode tab awaiting Run. The viewers lose the step from a
  gone folder to their start directory. libghostty's own open at surface creation stays on the main thread, so a mount
  that dies or slows between the check and the surface can still freeze the app.
- The same, plus the fourth libghostty patch that drops the main-thread open and stat at surface creation. No main
  thread wait on the directory is left. The patch is a change to a pinned dependency, and each libghostty bump must
  carry it.
- Either of the two above, with `currentDirectory` returning an ordered list of candidate directories instead of one
  path. The resolver walks the list. The viewers keep their step from a gone folder to their start directory. It
  matters when a viewer's folder is gone but its start directory exists, as for a file a script sent, whose start
  directory is the receiving pane's earlier directory. It widens the applet contract.
- Each applet keeps a cached verdict on whether its path is a directory. The applet refreshes the verdict off the main
  thread when its path changes, with one refresh in flight per applet. The property returns the path only while the
  verdict says directory. A path not yet checked reads as unknown. A user who runs `cd` into a share and splits at once
  gets a new pane in home, since the verdict is still pending. A mount can die after the verdict, so a terminal start
  still needs its own off-main check before it hands the path to libghostty. The consumer changes of one of the other
  candidates are needed here too, and the cache adds state to five applets on top of them. It keeps the property's
  current promise, that a returned path was a directory when last checked.

Decision: the terminal resolves its own start directory off the main thread, with a fourth libghostty patch that drops
the main-thread open and stat at surface creation. Decided autonomously on 2026-11-22.

- `currentDirectory` returns the path as the applet holds it, after the absolute-path string test, and does no
  file-system work. The contract's doc comment says the path may be gone or unreachable, and that a caller using it as
  a place resolves it off the main thread.
- The terminal resolves every directory it is given off the main thread, in the reported, then starting, then home
  order, and starts its session when the check answers. Checks of the same path share one check in flight. The app has
  one resolver, which the terminal, the window, and the panels share. Only it can produce the directory a launch hands
  to libghostty, so a raw path reaching libghostty is a compile error, not a forgotten step.
- The window's call sites stay synchronous. The open and save panels resolve their start folder inside their existing
  `async` flows.
- Reopen Closed Tab and script `open-tab` check the folder off the main thread first, and only then open the tab and
  start its session. Their promises stay as they are: a reopen that fails keeps its entry and the walk goes on to the
  next older close, and a refused `open-tab` leaves no tab. On a dead mount, Reopen shows a status message until the
  mount answers. Amended 2026-11-22; see Decision Log.
- Every other new tab or pane appears at once and waits for its check. A waiting tab takes first responder.
- The patch joins the three in `ThirdParty/ghostty-patches/`. libghostty's subprocess access check stays, on its IO
  thread. libghostty falls back silently in two places: its IO-thread access check, and the child's `chdir`, whose
  result it ignores (`src/Command.zig`, about line 217). The patch makes both fall back to a home directory uniterm
  passes with the launch, instead of the app's own directory, and sets `PWD` to the directory the shell starts in. The
  home travels in its own surface config field, never in the child's environment or as a user setting. It is the same
  home the resolver falls back to, so every fallback lands in one place, and no library behavior picks the folder out of
  sight. Amended 2026-11-22; see Decision Log.
- The viewers drop the step from a gone folder to their start directory. A new pane from a viewer whose folder is gone
  starts in home. Keeping that step needs a list in the contract for one rare case, the file a script sent, whose start
  directory is the receiving pane's earlier directory. "Not every attribute needs plumbing" in the project's
  instructions argues against it.

Callers resolving the path themselves turn about ten synchronous call sites into requests and replies. Nothing stops a
later caller from skipping the resolve. Without the patch, a slow but live mount, or one that dies after the check,
still freezes the main thread inside libghostty. ADR-08 asks such a wait to name its bound, and it has none. A cached
verdict needs the same consumer work, and sends a split made right after `cd` to home.

The patch adds a change to a pinned dependency, which each libghostty bump must carry. One wait stays after it: a mount
that dies between uniterm's check and libghostty's IO-thread check parks that thread, and closing the pane joins it on
the main thread. See Risks.

### What `list-panes` reports for a directory

`currentDirectory` now returns the path as held, with no check. Today `list-panes` reports a directory only when it
existed at the moment of the call. `list-panes` rides ScriptWire, and programs other than the bundled command use that
wire too. The tabs in the same reply carry no directory. `list-panes` answers synchronously today. Script `open-pane`
and `open-tab` already answer later, after an off-main check. The candidates were:

- Report the path as held. The field's doc and the scripting docs say it may be gone or unreachable. A script that
  needs a folder that exists checks it itself.
- Resolve each pane's path off the main thread before replying, with the same shared check, and report it only when it
  is a directory. The call answers later. On a dead mount the script's call waits until the mount answers, and the app
  stays responsive.

Decision: `list-panes` reports the path as held, with no check.

**Decided by:** user, 2026-11-23

Mechanism: the held path takes a new key in the `list-panes` reply, and `:directory` is retired from that reply. Nothing
is checked or resolved before the reply. ScriptWire is at 0 under UTERM-063, so the reply changes in place after
UTERM-063 M2. A changed meaning takes a new name, and the old name is retired. The field is also part of the scripting
API, and `uniterm/api-version` stays at 0. The new key's name is chosen when M1 is built. Amended 2026-11-27; see
Decision Log.

**Decided by:** proposal bookkeeping (run best guess), 2026-11-27

- The `list-panes` doc and the scripting docs say the path may be gone, unreachable, or from another machine whose
  shell reported `localhost`.
- A script that still reads `:directory` gets nothing. That is what a gone folder gives it today. Passing it back to
  `open-pane` opens the pane in the caller's directory, as before. A script that wants the path reads the new key and
  checks the folder itself.
- Resolving before the reply would hold back the whole listing whenever one pane sits on a dead mount. `list-panes`
  builds one reply over every pane, and a script has no other way to list them. The check would also be stale by the
  time the script used the path. So `:directory` is not kept with a check.

### How the rule is enforced

The candidates were:

- A doc comment on the contract's member only.
- A doc comment, plus tests. Each applet has a test that its `currentDirectory` returns a path that does not exist,
  which shows the property does not filter by existence. The terminal's resolver and each panel's start folder have a
  test that injects an existence check which blocks, and shows the main actor stays free while it waits.
- A doc comment, plus one contract test over the built-in applet catalog, plus the resolver and panel tests above. The
  contract test is a table keyed by applet type. It builds each built-in applet over a path that does not exist and
  expects `currentDirectory` to return the raw path or nil. A guard expects the table's keys to equal the catalog's type
  IDs, so a new applet type fails the suite until it is added.

The settled mechanism already makes one misuse a compile error: only the terminal's resolver can produce the directory
a launch hands to libghostty.

Decision: the doc comment, the catalog-wide contract test with its guard, and the resolver and panel tests. Decided
autonomously on 2026-11-22. Per-applet tests cover only today's five applets. A later applet that checks the file system
in its property, with no test of its own, would leave the suite green. The guard makes that applet fail the suite. A
test over a path that does not exist shows the property does not filter by existence. It cannot show the property never
calls the file system, since a `stat` whose result is ignored passes it. The doc comment carries that part of the rule.

### What a new terminal shows while its directory check waits

This follows from the mechanism question. On a live disk the check answers in microseconds. On a dead mount it may not
answer until the mount times out, and a hard NFS mount may never answer. ADR-08 says such a result arrives later, and
the UI needs a pending state. The settled mechanism places the pane or tab at once, since the window's call sites stay
synchronous, so a pane that appears only after the check is ruled out. The waiting tab takes first responder. Closing
it while it waits has no surface to tear down, so the close does not wait. A next directory in the order must still
come from the resolver. The candidates were:

- The shell starts when the check answers, in the resolved directory. Until then the tab shows that it is waiting for
  its folder, names the folder, and drops typed keys. The user can close it.
- The same, with a bound. After a fixed wait, the resolver moves to the next directory of the order, and the shell
  starts there. The tab says which folder did not answer. A check still parked on the dead mount keeps its thread until
  the mount answers.
- The first candidate, plus a "Start in Home Folder" button in the waiting view, as the program-mode tab's Run prompt
  has a Run button.

Decision: wait with no bound, drop typed keys, and offer a "Start in Home Folder" button. Decided autonomously on
2026-11-22.

- The waiting view names the folder, bounded and cleaned the way the status bar cleans program-chosen text. The path
  comes from OSC 7, which any program can set.
- Typed keys never reach a shell while the tab waits. Keys typed for the share, such as `rm -r build`, must not run in
  home. Only an explicit press of the button starts the shell in home.
- The button asks the resolver for home, so the resolver still chooses every directory a launch receives.
- A wait with no button leaves a window restored onto a dead mount stuck. Split, new tab, and new window from its panes
  all inherit the dead path, and the only way out is to close the window. A fixed bound starts the shell in the wrong
  place when a live share is slow to wake, such as an autofs or SMB mount on first access. The next split then lands in
  the share, so the result looks random.

### What an open or save panel does while its start folder is checked

The scope decision moves the open panel's and the map's save panel's start-folder check off the main thread. Each runs
inside a flow that is already `async`: a pane's own Open, File > Open, and the map's Save As. Nothing appears until the
check answers. On a dead mount, File > Open beside the pane does nothing visible. An untitled map's Save, and the Save
answer to the unsaved question that a pane close, a window close, or a quit asks, reach the map's Save As. The close or
quit then waits on the check with no panel on screen, and so with no Cancel, until the mount answers. A panel's start
folder runs no command, so a wrong start folder costs only a click. The candidates were:

- Wait for the check with no bound, and show a status message while it waits.
- Wait at most a short fixed time, then open the panel in the home folder when the check has not answered. A check
  still parked keeps its thread until the mount answers.
- Open the panel in the home folder at once whenever the folder is not already known to answer, and skip the wait.

Decision: wait at most two seconds, then open the panel in the home folder, and post a status message that names the
folder that did not answer. Decided autonomously on 2026-11-22.

- Two seconds is long enough for a local folder or a healthy share to answer, and short enough not to read as a freeze.
  A disk that takes longer to spin up opens the panel in home, which costs one click. Tests inject the clock.
- The status message cleans the folder name as the waiting view does.
- Waiting with no bound leaves a close or quit stuck with no Cancel on a hard mount, so the only way out is Force Quit.
  ADR-08's rationale names that loss of control.
- Opening in home unless the folder is known to answer needs a cache of which paths answered. Nothing keeps one, and
  without it every Open starts in home, even on a healthy local folder.
- This does not conflict with the terminal's unbounded wait. A panel's start folder runs no command, and later splits
  do not inherit it.

## Design Decisions (Open)

None.

## Risks

- **A consumer starts a process in a directory that is gone** — likelihood: medium, impact: low.
  Mitigation: the terminal's resolver falls back from the reported directory to the starting one, then home, and the
  panels fall back to home. A test covers each. A directory that dies between uniterm's check and libghostty's
  IO-thread check also lands in home, through the fourth patch.
- **A mount dies between uniterm's check and libghostty's IO-thread check** — likelihood: low, impact: high.
  The IO thread then parks in its access check. Closing that pane frees the surface on the main thread, which joins the
  IO thread, so the app freezes until the mount answers. ADR-08 asks a main-thread wait to name its bound, and this one
  has none. Accepted: the window is the moment between two checks that run back to back, and closing a pane whose
  running shell is stuck on a dead mount may already freeze the same way, filed as
  `bugs/20261122-closing-pane-on-dead-mount-may-join-io-thread.md`. Only a change in how libghostty tears down a
  surface removes it, and that is outside this proposal.
- **A libghostty bump drops or breaks the fourth patch** — likelihood: medium, impact: medium.
  Mitigation: the build applies every patch and fails when one does not apply. M1's test or trace that surface
  creation touches no directory on the main thread runs again on each bump.
- **AppKit touches a panel's start folder on the main thread after uniterm's check** — likelihood: low, impact: high.
  A mount that passes the check and then dies could still stall the panel inside AppKit. uniterm is not sandboxed, so
  the panels likely run in the app's process. Mitigation: the M1 panel check traces or times AppKit's use of the start
  folder on a folder that blocks. If AppKit touches it, the review that finds it reopens the panel decision.
- **Checks parked on many dead paths use up threads** — likelihood: low, impact: medium.
  A window restored with tabs in several folders of one dead mount parks one check per distinct path. Mitigation: the
  resolver runs on a dispatch queue with a stated cap, and a live local check still answers while others are parked.
  M1 checks both.
- **UTERM-051 changes the same restore path** — likelihood: medium, impact: low.
  UTERM-051, still a draft, may move each applet's restore decode off the main thread. The terminal's restore init is
  where this proposal moves the directory check into the session start. Mitigation: the directory check lives in the
  terminal's session start, not in the decode, so either order of landing works. This proposal names UTERM-051 in
  Impacts.

## Milestones

### M1: The property does no file-system work

**Status:** NOT STARTED

The property returns the path as held. The Pane Inspector and `list-panes` stop freezing. Until M2 lands, a new pane
or a panel still checks the same path on the main thread, as it does today.

- No applet's `currentDirectory` does file-system work on the main thread
- The contract's doc comment on `currentDirectory` states the rule, and says the path may be gone or unreachable
- A contract test over the built-in applet catalog builds each applet over a path that does not exist and expects
  `currentDirectory` to return the raw path or nil. Its table's keys equal the catalog's type IDs
- ScriptWire stays at 0 and does not bump. `list-panes` reports the held path under a new key, and `:directory` is
  retired from the reply, so no program reads a held path under the old meaning. Nothing is checked before the reply
- `uniterm/api-version` stays at 0, and the `list-panes` doc and the scripting docs say the held path may be gone or
  unreachable
- A test passes a `list-panes` reply with no `:directory` to `open-pane` and expects the pane to open in the caller's
  directory
- A new tab with no directory named still falls back to the starting directory, then home, when the reported one is
  gone. It never hands libghostty a raw path the property returned

Amended 2026-11-27; see Decision Log.

### M2: One resolver checks a directory off the main thread before use

**Status:** NOT STARTED

- The terminal's two directory initializers, its restore, and `reopenTab` check no directory on the main thread
- The open panel's start folder and the map's save panel resolve off the main thread. When the check has not answered
  in two seconds, the panel opens in home and a status message names the folder, cleaned
- A panel flow whose pane or window closed during the check shows no panel and replaces no source
- At most one start-folder wait runs per pane or window, so a second Cmd-O during the wait starts no second panel
- A tab waiting on its check counts as live, so a pane whose tabs all wait does not close
- A check reply that arrives after its tab or applet closed starts no session. The tab is looked up again by its ID
- The resolver runs on a dispatch queue, not on Swift's cooperative pool, so checks parked on a dead mount do not stall
  other async work. It replaces the off-main check that script `open-pane` and layouts use, so the app has one resolver
- Script `open-pane` with no directory and a layout's named directories are checked once, off the main thread
- Reopen Closed Tab checks the folder before it reopens. A closed-tab entry leaves the reopen list while its check
  waits, so pressing reopen twice reopens it once. A failed reopen keeps the entry and the walk goes on to the next
  older close, as today. On a dead mount, a status message says the reopen is waiting for its folder
- Script `open-tab` checks the folder before it opens the tab, and a refused `open-tab` leaves no tab
- A late session start takes first responder only when the waiting view still held it. A tab or pane a script opened
  never takes focus
- A waiting tab whose session fails to start is removed, and a pane whose last tab fails follows today's exit path
- A waiting tab saves the directory its shell started in, and reports it as its `currentDirectory` once started. While
  it waits, it saves and reports the directory it was asked for
- A check reply that arrives after the "Start in Home Folder" press starts no second session
- The type that carries a resolved directory lives in a module both the terminal and the REPL use, and the REPL gets
  home through the resolver. A build check or test shows a raw string cannot reach the session start
- The resolver answers a live local check while checks on a dead path are parked, and its cap on parked checks is
  stated
- A missing directory named by a layout or by script `open-pane` is still refused, and is checked once
- The catalog contract test injects the resolver once the terminal starts through it, so its expected values do not
  depend on timing
- A reopen that completes after its check waited takes focus and selection only when focus has not moved since the
  press
- After a reopen's check answers, the walk collects the closes again and checks that pane actions are still enabled. A
  failure then moves on to the next older close in the current list
- A closed-tab entry waiting on its reopen check is hidden from the reopen list but still saved with the layout. The
  depth trim does not evict it, and a failure puts it back in its stamp order
- The resolver and its resolved-directory type live in a module the window, the panels, the terminal, and the REPL can
  all reach. Reopen and script `open-tab` hand the terminal an already resolved directory, which starts the session at
  once with no second check
- The doc states what a check beyond the resolver's cap does, and a live local check still answers within the cap
- A panel's start-folder check that answers after the panel opened in home neither moves that panel nor opens another
- The view a waiting tab shows accepts first responder, so keys typed while it waits reach no other pane's shell
- The panel's start-folder resolve takes an injected existence check. Each blocking-check test blocks on a semaphore,
  not a sleep
- The waiting view names its folder, bounded and cleaned as the status bar cleans program-chosen text
- The waiting view's "Start in Home Folder" button starts the shell in home only on an explicit press. A typed key does
  not press it

### M3: libghostty no longer touches the start directory on the main thread

**Status:** NOT STARTED

The fourth libghostty patch. It needs M2, since only the resolver hands a directory to libghostty once the open is
gone.

- The libghostty patch removes the open and stat at surface creation, and a test or trace shows nothing else in surface
  creation touches the directory on the main thread
- When libghostty's IO-thread access check fails, the patched fallback starts the shell in the home uniterm passed with
  the launch, not in the app's own directory. A test with an injected home that differs from the process's `HOME` shows
  the fallback uses uniterm's
- A failed `chdir` in the child also falls back to the passed home before exec, and `PWD` names the directory the shell
  starts in
- The passed home travels in its own surface config field. It does not appear in the child's environment, does not
  change the child's `HOME`, and is not a user config key
- The doc states what the child does when the passed home itself cannot be entered

## Decision Log

- 2026-11-22: Filed as a draft from the triage of `20261122-terminal-directory-check-blocks-main-thread`. The bug's two
  fix options are carried as the open question "How an applet meets the rule".
- 2026-11-22: Review start: 1 milestone, 0 settled decisions, 2 risks, 0 `**Live after:**` lines or row gates, no
  out-of-scope statements. Baseline is the commit "Draft UTERM-050 to settle how currentDirectory stops blocking the
  main thread". The user asked for an autonomous review of the open questions. The premise holds by code trace: all
  five applets run `FileManager.fileExists` inside `currentDirectory`, and every reader runs on the main actor. The
  hang itself is not reproduced. The open questions now carry the facts the review found: libghostty opens the start
  directory on the main thread at surface creation, and restore, reopen, and the open panel check the same paths
  without the property. The draft's own recommendations came out of the question text, so the critic ranks blind.
  The draft recommended every applet for scope, and the doc comment with tests for enforcement. Added the question
  "What a new terminal shows while its directory check waits", which the libghostty finding opens.
- 2026-11-22 (autonomous): "Whether the rule covers every applet or only the terminal" settled as every applet's
  property plus every main-thread check of the same directories: the terminal's two directory initializers, restore,
  reopen, the open panel's start folder, and the map's save panel. Converged in 1 pass. The review first leaned to also
  covering the `stat` of a picked file. That path is not a current directory, so it went to its own bug instead.
- 2026-11-22 (autonomous, addition): "How an applet meets the rule" settled as a terminal that resolves its own start
  directory off the main thread, plus a fourth libghostty patch that drops the main-thread open at surface creation.
  The property does no file-system work. Converged in 3 passes. The review first leaned to the terminal-owned start
  without the patch. The critic showed that libghostty's own open would still freeze on a slow or dying mount. The
  patch is the addition: a change to a pinned dependency, carried on every bump. Pass 2 added the closed-tab entry rule,
  first responder for a waiting tab, and an `open-tab` that awaits its start. Pass 3 added the type that lets only the
  resolver hand a directory to libghostty. The viewers' step to their start directory is dropped, against an ordered
  list in the contract.
- 2026-11-22 (autonomous): "What `list-panes` reports for a directory" settled as the path as held, with a bump of
  `uniterm/api-version`, since a script that passes a gone directory back to `open-pane` is now refused. Converged in
  1 pass. The question first said the tabs in the reply carry the raw directory. They carry none, and the text is
  corrected.
- 2026-11-22 (autonomous): "How the rule is enforced" settled as the doc comment, a contract test over the built-in
  catalog with a guard on its keys, and the resolver and panel tests. Converged in 1 pass. The review first leaned to
  tests per applet, which a new applet type would skip.
- 2026-11-22 (autonomous, addition): "What a new terminal shows while its directory check waits" settled as a wait with
  no bound that drops typed keys, with a "Start in Home Folder" button. Converged in 1 pass. The review first leaned to
  the wait without the button. A window restored onto a dead mount would then stay stuck until closed. The button is
  the addition: a user action the proposal did not plan.
- 2026-11-22: Coherence review, full pass. The critic found that a tab appearing before its session can start kept
  adding special cases: a late failure, a reopen walk that cannot go on to older closes, a script `open-tab` refused
  after its tab appeared, a focus rule, and what a waiting tab records. Asked the user whether to keep, narrow, or drop
  "a new tab or pane appears at once". The user narrowed it: Reopen Closed Tab and script `open-tab` check the folder
  first, so their existing promises hold, and everything else appears at once. "How an applet meets the rule" is
  amended in place. Before, it said script `open-tab` awaits the session start, and a reopened tab keeps its entry until
  its session starts.
- 2026-11-22 (autonomous): Coherence review fixes. Moved the waiting-view decision under Settled. Corrected the sent
  file's start directory, which is the receiving pane's earlier directory, not the sending pane's. Routed to M1: the
  late-start focus rule, late failure, what a waiting tab records, the double-start guard, where the resolved-directory
  type lives, the resolver's cap, layouts and `open-pane` still refusing a missing directory, and a timing-free catalog
  test. Kept "drop typed keys" against a finding that keys typed during a normal local check would be lost. Replaying
  them would run keystrokes typed minutes earlier once a slow mount answers.
- 2026-11-22 (autonomous): Added and settled "What an open or save panel does while its start folder is checked", a gap
  the coherence review found. Settled as a two-second wait, then the home folder with a status message. Converged in 1
  pass. Routed to M1: no panel for a closed pane, and one wait per pane or window. Filed two bugs the critic found
  beside it: `bugs/20261122-quit-skips-unsaved-work-when-nothing-runs.md` and
  `bugs/20261122-map-save-reads-file-on-main-thread.md`.
- 2026-11-22 (autonomous): Risk review. Dropped the cached-verdict risk, since no cache was chosen. Added five risks: the
  race between uniterm's check and libghostty's, the patch on each libghostty bump, AppKit touching a panel's start
  folder, threads parked on many dead paths, and UTERM-051 changing the same restore path. The race is accepted at low
  likelihood and high impact. No mitigation exists in uniterm, and the same freeze may already exist on close, filed as
  `bugs/20261122-closing-pane-on-dead-mount-may-join-io-thread.md`. The rest are mitigated. No one-way doors: the
  `api-version` bump is a versioned contract, and every change reverts with a redeploy. Added UTERM-051 to Impacts, and
  corrected the UTERM-048 Impact, which expected an unknown state.
- 2026-11-22 (autonomous): Re-check pass 1 converged with no design-level defect. Routed six checks to M1: a late
  reopen's focus, the walk after a wait, a waiting entry that survives a save, one resolver reachable from every
  caller, a check beyond the cap, and a panel's late reply. "How an applet meets the rule" now names the one resolver
  the app shares, where it said the terminal's resolver.
- 2026-11-22: Review gate: kept all. The user kept the fourth libghostty patch and the "Start in Home Folder" button.
  Raised per "Applet Attributes": in the race between uniterm's check and libghostty's, libghostty starts the shell in
  the app's own directory. The user chose home, through the same patch. "How an applet meets the rule" is amended in
  place. Before, it said only that libghostty's access check stays on its IO thread. M1 gained a check for the
  fallback.
- 2026-11-22: ADR candidate (cuts across the system): a directory an applet reports is only a hint, and every use of it
  as a place resolves it off the main thread. Declined: applies ADR-08 "The main thread never waits on work whose
  duration uniterm does not bound."
- 2026-11-22: ADR candidate (cuts across the system): every directory handed to libghostty comes from one resolver.
  Declined: lifted to its invariant, it is ADR-08's rule again. The resolver is a mechanism that meets it.
- 2026-11-22: Accepted.
- 2026-11-22 (autonomous): After acceptance, checked the gate's fallback change against libghostty. The child's
  environment comes from the app's own environment, so its `HOME` can differ from the home uniterm's resolver uses.
  The decision now says the patch falls back to a home uniterm passes with the launch. Before, it said the shell's
  `HOME`. The user's choice, that every fallback lands in home, is unchanged. Refreshed the Summary to the settled
  design. Corrected Motivation, which said restore and reopen read the property. They check the same directories
  without it. Confirmed that the build fails when a patch does not apply, which the patch-bump risk relies on.
- 2026-11-22 (autonomous): Re-check pass 2 did not converge. The child's `chdir` in libghostty ignores its result, so
  a directory removed after the access check still started the shell in the app's directory. The patch now covers that
  site too, and sets `PWD` to the directory the shell starts in. Routed to M1: the carrier field, `PWD`, and what
  happens when the passed home fails. This was the proposal loop's third pass, so the fix was not re-checked.
- 2026-11-22: Split the one milestone into three, at the user's choice. M1 makes the property do no file-system work,
  with the catalog test and the `api-version` bump, which unblocks UTERM-048 M2. M2 adds the shared resolver, the
  waiting tab, Reopen and `open-tab`, and the panels. M3 is the libghostty patch. No check was dropped. M1 gained one
  check: a new tab still falls back to home rather than hand libghostty the raw path, so M1 alone does not regress the
  fallback.
- 2026-11-22: Scheduled as UTERM-050 M1-M3 in queue.md.
- 2026-11-23: Amended "What `list-panes` reports for a directory" and M1, from UTERM-056's review. The user chose that a
  ScriptWire version covers what is inside a reply, and that this proposal bumps ScriptWire and keeps the existence check
  for version 14. The text said "`list-panes` rides only ScriptWire, whose sides ship together, so ADR-13 does not
  apply", and "report the path as held, and bump `uniterm/api-version`".
- 2026-11-27: From UTERM-063. ScriptWire and `uniterm/api-version` stay at 0, so this proposal bumps
  neither. The held path lands in place after UTERM-063 M2, and a held `:directory` that may be gone takes a new key,
  or `:directory` keeps its old meaning.
  - Amended the Summary. It said "`list-panes` reports the path as held, with a bump of `uniterm/api-version`."
  - Amended M1. It said "ScriptWire's version is bumped. When UTERM-056 has landed, a version 14 connection still gets
    `:directory` only for a folder that exists, with no main-thread check" and "`uniterm/api-version` is bumped".
  - Left "What `list-panes` reports for a directory" as written. The user chose its bump and its version 14 rule on
    2026-11-23, and UTERM-063 reverses both. The entry below settles it.

- 2026-11-27: Brought in line with UTERM-063 at the user's direction. "What `list-panes` reports for a directory" said
  "so ADR-13 P1 applies" and quoted the api-version rule "A change that breaks a script changes it." It now says
  ScriptWire and `uniterm/api-version` stay at 0 and the reply changes in place. The rest of the proposal was read
  against the same rule and agrees: the Summary, Impacts, M1, and Risks name no version bump.
- 2026-11-27: The user confirmed that UTERM-063 is correct where it meets this proposal. "What `list-panes` reports
  for a directory" drops its version bumps. Its Pending override line is removed. The user's choice of 2026-11-23, to
  report the path as held, stands. (run best guess) The mechanism is this run's reading of UTERM-063's rule: the held
  path takes a new key, and `:directory` is retired from the `list-panes` reply. No check runs and nothing is resolved
  before the reply, so a dead mount cannot hold back the listing. A script that still reads `:directory` gets nothing,
  which is what a gone folder gives it today. The key's name is chosen when M1 is built. The decision said before:
  "report the path as held, and bump `uniterm/api-version` and ScriptWire's version." Its bullets said before: "A
  connection on ScriptWire 14 keeps today's rule, with `:directory` only for a folder that exists. The check runs off
  the main thread. Whichever of this and UTERM-056 lands second builds it." and "The bump is needed because a script
  that passes `:directory` back to `open-pane` can now be refused. Today a gone folder leaves the field out, so such a
  script passes nil and the pane opens in the caller's directory. Now the field is present, and `open-pane` refuses a
  directory that does not exist." M1's checks and the Summary changed to match. The Summary said "with a bump of
  `uniterm/api-version`." M1 said "ScriptWire's version is bumped" and "`uniterm/api-version` is bumped".

## References

- ADR-08: UI responsiveness
- `bugs/20261122-terminal-directory-check-blocks-main-thread.md`
- UTERM-048: Pane Inspector, whose M2 depends on this
