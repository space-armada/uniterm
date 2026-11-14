# UTERM-015: Cross-Applet File Opening

**Status:** accepted
**Created:** 2026-11-03
**Updated:** 2026-11-08

## Dependencies

- UTERM-001: the pane tree, the applet contract, and the terminal applet the router places panes in
- UTERM-002's command registry and UTERM-013: File > Open is a registry command, and its key falls under shortcut
  ownership
- UTERM-003 M3: M5's `uniterm open` uses the `uniterm` command and its listener
- UTERM-004 M1 and M3: M4's path-reading power builds on caller identity and shared command dispatch
- UTERM-004 M4: M1's check that a routed split never joins a group a controller owns. Until it lands, the check runs
  against a fixture group
- UTERM-004 M6: M4's grants, M7's approvals for senders other than Apple's openers, and M5's session approval all use
  its approval flow and pending indicator. M5 and M7 start only after it. Until it lands, M2 refuses other senders.
  Amended 2026-11-03; see Decision Log.

## Impacts

- UTERM-006 — "Input sources" and "Control levels": this proposal is the cross-applet proposal its revisit hook asks
  for, and it defines the path-reading power its M4 uses
- UTERM-009 — "Input sources": this proposal is the cross-applet file-opening proposal its revisit hook commits to.
  App-level opening and the data viewer's File > Open binding are decided here
- UTERM-008 — "Input sources" file source: its open panel and drop stay in the pane. Finder and File > Open reach the
  map through the router
- UTERM-008 — "Where pins come from": under "The path-reading power", a driver whose scope does not hold the user's
  file gets no value from it. UTERM-008 was amended so `pin selected` marks a file pin without its ID, and a click on
  one sends no `map clicked`
- UTERM-007 — "The applet contract": its "Open..." command with no key is the pane-local open "Who owns Cmd-O" settles.
  Its documents reach it through the router, and it declares the types it opens
- UTERM-006, UTERM-008, UTERM-009 — "Input sources": each declares a pane-local "Open..." command with no key, as
  UTERM-007 does, and the types it opens with a rank
- UTERM-005 — "Navigation": the browser refuses `file:` because loading it needs a file read scope. That scope is the
  path-reading power defined here, so a later change to the browser's `file:` rule builds on it
- UTERM-004 — "Permission scopes and approval flow": adds the path-reading power to the typed permission set

## Summary

One way for a file to reach an applet from outside its pane. Finder, the Dock, File > Open, a `uniterm open` command,
and Cmd-click in the terminal all hand a file to one router. The router picks an applet from the file's type, places a
new pane beside the pane the request came from, and hands the file to that applet's source-taking entry point. A
folder routed to the terminal opens a new terminal there.

Each entry point has an authority. File > Open and Apple's own openers, such as Finder, are the user's act. Other
programs that open files through Launch Services, and `uniterm open`, need the user's approval, which lasts at most for
the sender's run or the terminal session. A click opens only the target uniterm showed on hover. This proposal also
defines the path-reading power under ADR-09, which lets a controller ask an applet to read a path inside an explicit
directory scope.

## Motivation

UTERM-009 settled that viewers open files from inside their own pane, with an open panel or a drop. It left app-level
opening to one cross-applet proposal, because UTERM-006, UTERM-007, UTERM-008, and UTERM-009 all open files, and
deciding it inside one applet would change the factory every applet implements. Its revisit hook requires this proposal
to be filed before a second viewer among UTERM-006 to UTERM-008 starts its first milestone. UTERM-006 M1 is gated on it
directly.

UTERM-006 also settled that asking an applet to read a path is a power of its own under ADR-09, apart from pane
control. ADR-09 lists no such power, and UTERM-005, UTERM-006, UTERM-007, and UTERM-009 each need the same one. One
definition keeps them from diverging.

Today the app has no file-open path at all. It declares no document types, binds no Cmd-O, has no `uniterm` command,
and ignores link and path clicks in the terminal. Every viewer bound no File > Open shortcut while waiting for this
decision.

## Design Decisions (Settled)

### Scope

This proposal covers how a file reaches an applet from outside that applet's pane, and the power a controller needs to
make an applet read a path.

Out of scope:

- Opening inside a pane, by open panel or drop. Each viewer's proposal settles that, and it stays as settled.
- Byte-stream sources, pipes, and data with no file. UTERM-009's revisit hook keeps them, tied to UTERM-003 and
  UTERM-004.
- A drawer of open documents in one pane. UTERM-006 and UTERM-009 leave it to its own proposal.
- Editing files. Every viewer here is read-only. UTERM-016 makes the map viewer write its own GeoJSON file, through
  its own Save and Save As. Amended 2026-11-05; see Decision Log.
- Opening anything other than a local file or folder, such as a web URL clicked in the terminal.

Rationale: these are the parts UTERM-006 and UTERM-009 handed to a cross-applet proposal, and no more.

### One route from a path to a pane

Every app-level entry point hands its files to one router. The router hands each file to the chosen applet through the
same source-taking entry point the applet's own open panel and drop use. The terminal has no source to replace, so a
folder routed to it creates a new terminal pane with that folder as its explicit start directory. Amended 2026-11-03;
see Decision Log.

Rationale: UTERM-006 rejected a launcher path field because it would be a second route from a path to a pane. One
route means the size limits, the type checks, the bookmark rules, and the error messages each viewer settled apply to
every way a file arrives.

### The path-reading power

Asking an applet to read a path on a controller's behalf is its own power under ADR-09. This proposal defines it once
for every applet, with the shape UTERM-006 settled:

- It is separate from pane control. Control of a pane grants no read, and a read grant controls no pane.
- It carries an explicit directory scope. The canonical path is checked against the scope before anything is
  opened, so an out-of-scope request never touches the file, and never raises a macOS privacy prompt under uniterm's
  name. The open does not block and does not follow a final symlink, and the opened descriptor must be a regular file
  or a folder. The real path of the opened descriptor is then checked again, so a symlink or a rename between check
  and open cannot widen it. Amended 2026-11-03; see Decision Log.
- Errors for paths outside the scope do not tell "missing", "not a supported type", and "denied" apart.
- When a pane's source lies outside the controller's scope, because the user opened it or a restore found it, events
  and replies to that controller carry no path or content detail from it.
- A file the user picks in File > Open, or in a pane's own open panel or drop, is the user's act, not a controller's.
  It needs no grant. Opens that arrive through Launch Services, `uniterm open`, and terminal clicks are not covered by
  this rule, since a program can choose what they name. Their own questions decide their authority. Amended
  2026-11-03; see Decision Log.

Rationale: UTERM-006 settled this shape in review, and the user kept it at the review gate. Without a scope, a script
with no file capability could probe which files exist, and borrow uniterm's macOS privacy grants for Downloads,
Documents, and Desktop. The scope protects controllers that have no file access of their own. A process uniterm
starts, such as a shell or an exec driver, already holds those grants directly, and the scope does not change that.
How a controller gets the power is settled in "How the path-reading power is granted".

### Which entry points open files

Original question: which app-level ways to open a file this proposal builds.

Decision: all of them. Finder Open With, a drop on the Dock icon, File > Open, a `uniterm open` command, and Cmd-click
on a path or a local `file:` hyperlink in the terminal.

- Terminal clicks need uniterm to handle libghostty's open-URL action. It reaches the app through an addition to the
  terminal surface protocol, per ADR-01, never as a libghostty type outside that module.
- A click on a web URL or any other non-file scheme does nothing new. Opening it in a browser is out of scope.
- Who may open by click is its own question, "Who may open by terminal click".
- `uniterm open` can be no stricter than the Launch Services path, per "Opens that arrive through Launch Services".

Rationale: the Motivation's user works at a terminal, and the common case is a file beside the terminal. Finder, the
Dock, and File > Open alone leave that case to the mouse. `uniterm open` covers paths the user types, and clicks cover
paths a program prints. Leaves undone: nothing.

### How a file type maps to an applet

Original question: several applets can read one type, such as `.json` for the data viewer and the text viewer, and
`.geojson` for the map, the data viewer, and the text viewer. How the router picks one.

Decision: each applet type declares the types it opens with a rank, an "Open With" choice overrides one open, and a
per-type choice the user saves overrides the rank.

- Each compiled applet type declares the content types it opens. Each declaration carries a rank from a fixed set:
  owner or alternate.
- Every declared type the system lacks is imported in `Info.plist` with its real conformance, such as `.geojson`
  conforming to `public.json`. Without it, the file resolves to a dynamic type that matches no declaration.
- One match is more specific than another when its declared type conforms to the other's. Rank decides only between
  matches that are equal or that neither conforms to. Two applets claiming the same type at the same rank fail a test,
  so no silent tiebreak ever picks a default. Two unrelated declared types can still tie at run time, when one file's
  type conforms to both. The router then asks the user to pick, and refuses the file with a message when nothing can
  ask. Amended 2026-11-03; see Decision Log.
- When the file's own type matches no applet's declaration, the router also considers every type the system registers
  for the file's filename extension. It pools their claims and picks among them by the same specificity, rank, and tie
  rules. The file's own type wins whenever it matches, and the saved choice still keys on that exact type. A file with
  no extension has no extension types. Amended 2026-11-08; see Decision Log.
- An "Open With" choice in uniterm lists every applet that declares the file's type. It can save the choice for the
  file's exact type, and the user can clear a saved choice.
- A saved choice matches the file's exact resolved type only, never types that conform to it. A choice for `.json`
  therefore never moves `.geojson` away from the map. When it names an applet type that no longer exists, or one that
  no longer declares the type, that open falls back to the rank, and the saved choice is kept for when it returns.
- Only the user's own UI writes a saved choice. No script or controller can write one, and only compiled applet types
  declare types.
- A new applet type declares its types beside its code. Its imported and document types still edit the host's
  `Info.plist`, which the drift test checks.

Rationale: users differ on `.json`. A developer reading config wants it as text, and an analyst wants an API dump as a
table. Picking "Open With" on every open is a standing chore for whichever one the rank does not suit, so the saved
choice has named users. A host table drifts from what each applet's entry point accepts. Asking on every open with
several claimants adds a second chooser after Finder's, and lets any program raise prompts with `open -a`.

### Who owns Cmd-O

Original question: whether Cmd-O belongs to the window, routed, or to each viewer, opening into its pane.

Decision: File > Open is a window command on Cmd-O, always through the router. Each viewer keeps a pane-local Open
command with no default key.

- Cmd-O is a reserved window key under UTERM-013, so it works the same in every pane, the terminal and the launcher
  included.
- The pane-local command replaces the pane's source. UTERM-007 already declares it, as "Open..." with no key. Each
  other viewer declares the same. It is reached from the applet menu and the palette, and the user can remap a key to
  it under UTERM-013.
- Replacing the source of a pane a controller owns is the user's act. That controller gets nothing outside its scope
  from it, per "The path-reading power".

Rationale: an applet-owned Cmd-O leaves the terminal and the launcher, the most common panes, with no keyboard open.
It also changes what Cmd-O does with focus, which UTERM-013's reserved keys exist to prevent. A window command alone
leaves the in-place replace off the palette.

### How the path-reading power is granted

Original question: how a controller gets the path-reading power, and the shape of its scope.

Decision: a typed permission in UTERM-004's set. Its scope is a list of directories, and protected locations inside a
scope directory are excluded unless the scope names them.

- A controller declares the power and its scope at startup. The user approves it through UTERM-004's panel, with
  Allow once, session, and remembered approvals as for every other power.
- The scope is a list of directories.
- A scope directory never covers a macOS-protected location inside it unless the scope names that location. One list
  of protected locations, kept in one place with a test, names Documents, Desktop, Downloads, iCloud Drive, other
  apps' containers, removable and network volumes, and the Photos library.
- Coverage compares effective scopes, with protected locations removed. A request for `~/Documents/x` is broader than
  an approved `~`, so it asks.
- The approval panel names every protected location a scope lies in or names.
- The read scope is its own type, not the directory scope of UTERM-004's host-launch grant. A launched process holds
  its macOS grants directly and needs no exclusion, so one shared type would mean two things in a stored approval.

Rationale: a per-path approval prompts once per slideshow member, and UTERM-004 forbids coalescing Allow once across
different operations, so prompts end in blind approval. One directory with no exclusion lets a scope of `~` silently
borrow uniterm's grants for Documents, which the power's settled rationale rules out. Comparing raw paths would cover
`~/Documents/x` under an approved `~` with no prompt.

### Which file types uniterm registers with Finder

Original question: which document types uniterm declares to Launch Services, and at what rank.

Decision: every type an applet declares is registered at the Alternate rank.

- `Info.plist` declares each type an applet opens, and imports each one the system lacks, per "How a file type maps to
  an applet".
- Every `LSHandlerRank` is Alternate, whatever rank the applet declares. The applet's "owner" rank is uniterm's own
  routing and never becomes Launch Services' Owner rank.
- The router resolves a file's type through the system, never from uniterm's plist, since another app may export a
  type uniterm imports with a different conformance.

Rationale: registering nothing rules out Finder and the Dock, which "Which entry points open files" keeps. The Default
rank can make uniterm the double-click app for `.md` or `.json` on install, without the user choosing it. Alternate
puts uniterm under Open With and displaces no other app.

### Opens that arrive through Launch Services

Original question: Finder Open With and a drop on the Dock icon reach uniterm as an open-documents Apple Event. Any
process of the same user can send the same event with `open -a uniterm <path>` or NSWorkspace. Which senders count as
the user's act.

Decision: Apple's user-facing openers are the user's act. Every other sender needs the user's approval, which is never
remembered past the sender's run.

- The sender is identified from the event's audit token, by code-signing requirement, never by PID, path, or display
  name. Apple's user-facing openers are matched by an Apple-anchored requirement on the signing identifier, such as
  `anchor apple and identifier "com.apple.finder"`: Finder, the Dock, and Spotlight. The `anchor apple` clause holds
  only for code signed by Apple's own anchor, so a third party cannot satisfy it with a copied identifier.
  Generic Apple-signed binaries, such as `osascript`, `python3`, and `/usr/bin/open`, never match. Quick Look and
  Recent Items are not on the list, since M2 found no signed program for either to name an identifier for. Adding one
  needs its measured identifier. Amended 2026-11-03; see Decision Log.
- Opens from those openers are the user's act, and need no grant.
- Until UTERM-004 M6 lands, every other sender is refused, with a bounded, coalesced message naming it.
- After M6, every other sender goes to UTERM-004's pending indicator, named from its verified signing information. The
  user can allow once, or allow for the session. A session grant binds to the sender's audit-token PID and PID
  version, and its label says it covers everything that app sends until it quits, as UTERM-004's OSC 52 approval says
  for a terminal session. Nothing is remembered after the sender quits. M7 builds this.
- A go-between, such as `/usr/bin/open` or a Launch Services helper, and a sender that cannot be identified, get Allow
  once only. M2 checked for an attribute that names the originator, and found none. An event sent by `open -a` carries
  `keyActualSenderAuditToken`, and it names the Launch Services UI agent, not the program that ran `open`. The
  authority therefore reads only the sender's own audit token. Amended 2026-11-03; see Decision Log.
- One event is one operation that names every file in it.
- A prompt for an unknown sender says the sender is unknown and lists every full path.
- A program with Automation consent over Finder can make Finder the sender. The event carries no originator, so this
  cannot be closed. It is accepted under ADR-09's statement that uniterm gives no isolation from the user's own
  processes.
- M2 recorded which sender `open -a` reports, cold and warm. M8 records what a cold-launch Finder open and a warm one
  report. If Finder and `open -a` cannot be told apart, this question reopens. Amended 2026-11-03; see Decision
  Log.

Rationale: accepting every sender lets any program open panes with no grant, which ADR-09 forbids. Refusing every
other sender breaks third-party file managers and launchers with no recovery. Remembered trust in a launcher such as
Alfred or Raycast would trust every script it runs, which ADR-09 forbids for a shared interpreter. UTERM-004 also
remembers only powers a controller declares at startup, and an Apple Event sender declares none. Allow once alone
would ask a launcher user on every open, the habitual approval ADR-09's context warns against. A session grant honestly
labelled, bound to the live sender, follows the pattern UTERM-004 already uses for OSC 52.

### Several files at once

Original question: what happens when Finder or `uniterm open` passes several files. Every viewer shows one source per
pane and refuses an in-pane drop of several files.

Decision: one pane per file, each routed on its own, with a confirmation above a fixed count.

- Mixed types work. Each file goes where the type mapping sends it.
- The batch follows the rule "Where a routed pane goes" settles for a batch, so it never stops halfway with no rule
  for the rest.
- Files that fail produce one summary message, not one each.
- A batch from a sender that needs approval is approved as one operation, per "Opens that arrive through Launch
  Services".

Rationale: the user asked to open every file. Opening only the first drops the rest in an order Finder chose. Refusing
makes a multi-select Open With always fail. The confirmation bounds a pane flood from a program. It is not a setting.

### Folders

Original question: Finder and `uniterm open` can pass a folder. The image viewer accepts one as a slideshow source, and
a terminal could start a shell in it.

Decision: a folder routes like a file, with the folder as its content type.

- Applets declare `public.folder`, never `public.directory`, so a package such as the Photos library or an app bundle
  is refused as an unsupported type.
- The terminal declares folders at the owner rank, so a folder from Finder opens a shell there. Its entry point for a
  routed folder is a new terminal pane created with that folder as its explicit start directory. Amended 2026-11-03;
  see Decision Log. The terminal has no source to replace, so the routed folder is never handed to a
  running terminal.
- The image viewer declares folders at the alternate rank. "Open With" or a saved choice for folders reaches it.

Rationale: the settled type mapping already decides between claimants. A host rule that sends every folder to a
terminal would be a special case beside it. Refusing folders loses opening a terminal on a Finder folder, a common
case.

### Where a routed pane goes

Original question: where the router places the pane a routed file opens in.

Decision: beside the pane the request came from, in a new pane that no controller owns. A new window holds only the
routed pane.

- The anchor is the pane the request came from. A terminal click anchors to the clicked pane. `uniterm open` from a
  terminal session anchors to that session's pane, by the source-pane binding UTERM-004 settles. File > Open anchors
  to the focused pane of the window whose menu ran it. Finder, the Dock, other Launch Services senders, and callers in
  no terminal session anchor to the focused pane of the most recently key window, which is brought forward.
- The routed pane is new and disconnected, and a routed split never joins a group a controller owns. A routed open
  never replaces the source of an existing pane.
- When no window is open, or the split is refused for lack of room, or the window has a sheet attached, the file opens
  in a new window whose only pane is the routed pane. That window starts no shell beside the routed pane, and inherits
  no directory from another window. A routed folder's terminal is the routed pane itself.
- A batch opens in one new window. Each file splits the largest pane, and a file that still finds no room goes to a
  further new window.
- An open that arrives while layout restore runs waits until restore finishes, then follows the same rules.

Rationale: anchoring to the key window would place a pane in a window the caller is not in, which UTERM-003 rejects as
an implicit target and UTERM-004's "Same window only" forbids. Reusing a launcher or an empty pane would hand a routed
file to a pane a controller may already watch through remote control. Opening a new window through the usual path
would start an extra shell, in a directory taken silently from the active window. Sending every Finder open to a new
window would still anchor in-app opens to the key window.

### Start directory and current directory

Original question: uniterm's rules require that current directory flows explicitly, never as hidden state. Which
directory each flow the router adds uses.

Decision: every flow is named here, and each takes its directory from the request itself.

- A routed file's pane starts in the file's folder, wherever the pane lands. A routed folder is the new terminal's
  start directory, per "Folders". When the file's folder later disappears, the viewer's fallback goes with it.
- A routed window's only pane takes its start directory from the routed file or folder, never from another window.
- File > Open's panel starts in the focused pane's `currentDirectory`, as UTERM-006 to UTERM-009's in-pane panels do.
  With no window, or a pane that reports none, it starts in the home folder, never in AppKit's remembered folder.
- `uniterm open` resolves a relative path against the command's own physical working directory before it sends
  anything, so only absolute paths reach the app. The command's working directory itself never crosses the socket.
  A deleted working directory fails in the command, with a message.
- A relative path clicked in the terminal is refused. Only an absolute path or a `file:` hyperlink opens.

Rationale: the file's folder comes from the request, so it is the same in a split and in a new window, and for every
entry point. The focused pane's directory would depend on which pane had focus when a Finder event arrived. A relative
argument to `uniterm open` means what the user's shell means by it, and resolving it in the command keeps any CLI
state out of the app. A clicked relative path may have been printed by a remote `ls` over ssh, or before a `cd`.
Shell integration gives no signal that output came from a remote host, so resolving it against any local directory can
open the wrong file. Leaves undone: clicking `notes.txt` in `ls` output does nothing.

### Who may run `uniterm open`

Original question: opening a pane from a process is a control effect under ADR-09. Which approval a `uniterm open`
request needs.

Decision: a once or session approval scoped to the calling terminal session, as UTERM-004 gives shared-terminal OSC 52.
A caller outside any terminal session gets Allow once only.

- The approval names the terminal session and says it covers every program in that session. A session grant ends when
  the session ends or its pane closes, and a restored pane never carries it.
- The `uniterm` command is uniterm's own helper, a new process on every run. A caller with no terminal session is
  therefore a go-between, and gets Allow once only, as the Launch Services rule gives one. A program inside tmux or
  screen is outside, since the multiplexer's server breaks the ancestry, so it asks on every open.
- Nothing stats, opens, or looks up the type of a path before its open is authorized. The same holds for every
  Launch Services open that needs approval.
- The reply never tells missing, unsupported, and denied apart without the path-reading power for that path.

Rationale: a controller grant would require remote control on the source pane, and the only signed party is uniterm's
own helper, a shared go-between ADR-09 forbids trusting. That is stricter than the Launch Services path, so a refused
program would use `open -a` instead. Treating it as the user's act gives any process panes with no grant, against
ADR-09, and looser than the Launch Services path. A session grant on the helper's PID would cover one call only, under
a false label.

### Who may open by terminal click

Original question: a Cmd-click is the user's gesture, but a program chose the text. An OSC 8 hyperlink's text can read
`README.md` while its target is `file:///Users/me/Documents/tax.pdf`. Who authorizes a click.

Decision: a click is the user's act only on a target uniterm showed before the click, opened only if it is exactly
that file, and never on output that may be remote.

- On Cmd-hover, uniterm shows the target as text: the absolute path, or a hyperlink's target rather than its text.
  Showing it touches no file. libghostty's mouse-over-link action reaches the app through an addition to the terminal
  surface protocol, per ADR-01, beside its open-URL action.
- The click is bound to the string that was shown. After the open, the opened descriptor's real path must match that
  string, after normalizing macOS firmlinks such as `/tmp` to `/private/tmp`, or the open is refused. A printed symlink
  to another file therefore opens nothing.
- Output written while a remote client ran in the foreground keeps a remote marker, even after the client exits. The
  remote clients are `ssh`, `mosh`, and the others M6 lists, and an OSC 7 report that names another host. Where the
  pinned libghostty cannot mark rows, the marker covers the whole pane for the rest of its life. A click on marked
  output shows that the output may be remote and opens nothing.
- M6 names where each signal comes from: the pinned libghostty, an addition to the terminal surface protocol, or a
  process lookup on the pane's child.

Rationale: accepting every click lets a program open any file with no grant, looser than the Launch Services path.
Splitting hyperlinks from bare paths rests on a distinction libghostty does not report, and on reading text a program
can hide. Inserting `uniterm open` on the command line types program-chosen text into whatever owns the terminal, such
as `vim` or a remote shell. Resolving the target on hover would touch a program-chosen path before any authorization.
Signals read at click time miss a remote `ls` that is still in the scrollback after `exit`. Leaves undone: remote
clients M6 does not list, such as `kubectl exec`, `docker exec`, and `ssh` inside a local tmux, still look local. On
a libghostty that cannot mark rows, one remote session turns off clicks in that pane.

## Design Decisions (Open)

## Risks

- **Registering document types takes Finder defaults from other apps** — likelihood: medium, impact: medium. A Default
  rank can make uniterm the default for `.json` or `.md` on install. Mitigation: "Which file types uniterm registers
  with Finder" lists the Alternate rank, and a test checks the plist.
- **Launch Services caches what uniterm registers** — likelihood: medium, impact: low. A type dropped in a later
  release can linger under Open With until Launch Services re-registers the app. Accepted: the stale entry opens
  uniterm, and the router refuses a type no applet declares, with a message.
- **The path-reading power diverges from what a viewer built first** — likelihood: medium, impact: medium. UTERM-009 and
  UTERM-008 are scheduled before this proposal is accepted. Mitigation: neither builds a controller file read before
  this proposal's power exists, and UTERM-006 M4 depends on it.
- **A controller borrows uniterm's macOS privacy grants** — likelihood: medium, impact: high. Once the user lets
  uniterm read Documents, any applet read runs with that grant. Mitigation: the settled directory scope, checked before
  the open and again on the opened descriptor, for controllers with no file access of their own. Accepted for the
  rest: shells and exec drivers uniterm starts hold the grants directly, which the scope cannot change.
- **A hard link inside the scope reaches a file outside it** — likelihood: low, impact: medium. A hard link has no
  other real path, so a path check cannot see that the inode also lives elsewhere. Accepted: making one needs write
  access to a directory in the scope, on the same volume, and the controller already reads what the scope holds.
- **Draft applets change what they claim** — likelihood: medium, impact: low. UTERM-010 is a draft. Accepted:
  declarations live with each applet, so a later claim changes no router code, and an equal-rank claim fails a test.
- **M2's sender measurement reopens the Launch Services decision** — likelihood: medium, impact: medium. If a
  cold-launch Finder open reports a Launch Services helper as its sender, Finder opens would be refused before UTERM-004
  M6 and ask on every open after it. Mitigation: M2 recorded the sender `open -a` reports, and M8 records the sender
  Finder reports, by hand. The decision says to reopen the question if Finder and `open -a` cannot be told apart.
  Amended 2026-11-03; see Decision Log.
- **Parts of the design wait on unbuilt work** — likelihood: high, impact: low. Third-party launchers are refused, and
  `uniterm open` cannot ship, until UTERM-004 M6 and UTERM-003 M3 land. Accepted: Finder, the Dock, File > Open, and
  terminal clicks need neither, and the gating is stated in Dependencies and each milestone.
- **Hover and the remote marker depend on the pinned libghostty** — likelihood: medium, impact: low. Marking rows may
  need a patch or a pin bump. Mitigation: M6 names each signal's source, and without row marks the marker covers the
  whole pane.
- **No viewer applet exists in code yet** — likelihood: high, impact: low. The router cannot be tested against real
  viewers at first. Mitigation: the router's milestones test with fixture applets, as UTERM-004 M4 does.

## Milestones

### M1: The router

**Status:** DONE

- Each applet type declares the content types it opens, and the router picks one applet per file by the rule "How a
  file type maps to an applet" settles
- The router hands each file to the chosen applet's source-taking entry point, the same one its open panel and drop
  use, and a folder routed to the terminal creates a new terminal pane at that folder
- A file no applet declares is refused with a message that names the file and its type
- Working out a routed file's type never opens or blocks on a FIFO or a device node
- Routing works with fixture applets, so it needs no production viewer to test
- A routed pane starts in the file's folder, even when split beside a pane in another folder
- A routed pane opens beside the pane the request came from, never in another window, and never joins a group a
  controller owns, tested against a fixture group and again against UTERM-004's groups once its M4 lands
- A routed new window holds only the routed pane, starts no other shell, and inherits no directory
- A saved choice survives a round trip through an older build, and a corrupt or unknown entry falls back to the rank
- A batch opens in one new window, splitting the largest pane each time, and a window with a sheet attached is
  treated as having no room
- The "Open With" choice lists every applet that declares the file's type, can save the choice for the file's exact
  type, and lets the user clear it
- A saved choice for one type never routes a type that conforms to it, and a saved choice naming a missing applet, or
  one that no longer declares the type, falls back to the rank for that open
- No script or controller can write a saved choice
- A test fails when two applets claim the same type at the same rank, and when a declared type the system lacks is not
  imported with its conformance
- Type resolution and the file-system checks run off the main thread, so a path on a slow network volume never stalls
  the UI. Choosing the pane and changing the window stay on the main thread, since AppKit owns them. Amended
  2026-11-03; see Decision Log.

**As built:**

- The production catalog holds one applet type, the terminal, which opens `public.folder` at the owner rank. No viewer
  is built, so none declares a type. The factory that turns a file into an applet is kept apart from the declaration,
  since the terminal's needs the host's engine. The app attaches it. A routed folder reuses the terminal's ordinary
  start path.
- Fixture types cannot be made through the system's database. A type exported in code, with no registration, conforms
  to nothing, so the router takes its type source and conformance check as an injected input. Router tests use a table
  of fixture types. The catalog tests use the real database, including a check that a package is refused.
- The declared-type check takes the host's imported types as an input. M1 tests it with fixture tables. M2 feeds it from
  `Info.plist`, and adds the drift test.
- The tie rule changed from the plan. See Decision Log, 2026-11-03.
- A symlink is followed before its target is classified, and the type is looked up on the target, since the system
  types a link as `public.symlink`. The router never opens it, and a symlink to a FIFO is refused. The start directory
  keeps the path as the request named it, so a link to a folder starts its terminal at the link, and a linked file
  starts in the link's folder. See Decision Log.
- A pane-group seam on the window answers "no group" until UTERM-004 M4. Ordinary splits report to it and routed splits
  never do. The fixture group proves the difference. The re-run against UTERM-004's groups stays with that milestone.
- The anchor is an input. The most recently key window is M2's.
- The chooser is an alert with a pop-up, an "always use" checkbox, and a clear button. Its model is unit tested. The
  alert's buttons and list are checked without presenting it. M3 wires it to a menu item.
- The saved-choice writers are file-private to the chooser model's file. A test cannot prove a call fails to compile, so
  it proves what the store does with entries it did not write.

### M2: Finder and Dock

**Status:** DONE

Amended 2026-11-04; see Decision Log.

- An open-documents event from an Apple opener opens its file or folder in uniterm, at launch and while running, proven
  with a sender fixture. Open With in Finder and a drop on the Dock icon by hand are M8's
- An open sent by another program follows the authority "Opens that arrive through Launch Services" settles
- Before the authority is built, the sender `open -a` reports is recorded, cold and warm
- The sender is checked by code-signing requirement on the event's audit token, and a sender that already exited is
  treated as unidentified
- A test shows `osascript`, `python3`, and `/usr/bin/open` never match an Apple opener
- Two senders with one PID and different PID versions are different identities, and a lookup for a reused PID fails
- Refusal messages stay bounded and coalesced under a loop of `open -a`
- Every `LSHandlerRank` is Alternate, and uniterm never displaces another app's handler
- Several files open one pane each, with one summary message for the ones that failed, and a confirmation above the
  fixed count
- A routed folder opens a new terminal there, or the applet the type mapping picks, and a package is refused
- An open-documents event that arrives before layout restore finishes waits for it, on every launch outcome
- A Finder open while uniterm is in the background lands in the most recently key window, brought forward and
  unminimized
- The reply to an open-documents event is the same for success, missing, unsupported, and denied
- The app's declared document types match the applet declarations, and a test fails when they drift
- A folder opened from Finder at cold launch opens one terminal there, and no other shell
- Until UTERM-004 M6 lands, senders other than Apple's openers are refused, and the refusal touches no path

**As built:**

- Divergences from the milestone text are in the Decision Log, 2026-11-03, M2 best guesses. Approvals moved to M7. The
  Finder sender record moved to M8, since the Automation consent to drive Finder was denied. The opener list narrowed
  to Finder, the Dock, and Spotlight. The `open -a` measurements and the identifiers are in the same entry.
- Authority is decided when the event arrives, from the event's sender audit token. The sender is often an `open`
  process that has exited by then, so it is unidentified and refused. Only the sender token decides. The actual-sender
  token is logged and ignored.
- A refused open posts one message per 30 seconds in total, naming the first sender in the window. It touches no path.
  A loop of a thousand refusals leaves one message in the history, tested at the coordinator and for the counter alone.
- An event that arrives before the coordinator exists is held in the app delegate with its sender already resolved,
  then handed over. The layout asks the coordinator before it opens a default window, on every launch outcome, and
  the coordinator opens one window after the replay when none is open. Saved windows still restore as saved.
- Most-recently-key tracking is a list of the windows that have been key. When the last key window closes, the one
  before it takes over, and with none ever key the newest window anchors.
- A batch above 10 files asks first. `RoutedOpener.open` owns the question and the threshold, through an injected
  confirmer that defaults to the close dialog, so every entry point asks and a test injects the answer. The
  dialog is not styled for opening, and its accessibility identifier still says close confirmation. Nobody has looked at
  it on screen.
- Unit tests cover the identity checks against the real Finder, Dock, Spotlight, `osascript`, `python3`, and
  `/usr/bin/open` binaries, a lookup with this process's own audit token, and the same token with a bumped PID
  version, which does not resolve. Hand-built Apple Events cannot carry the sender tokens, since the system sets them,
  so the token read is proven live only.
- The drift test reads `App/Info.plist` through a path from the test file and feeds the catalog audit its imported
  types.
- The UI test sends an open from the test runner to the running app. The runner is not an Apple opener, so it proves a
  refusal with a message and no new pane. An accepted open needs Finder as the sender, which no test can be, so the
  accepted path is covered by unit tests with a sender fixture and by the hand checks below.
- No `test-cost` target exists in this repo. New test classes ran in under 1 s each: `LaunchOpenCoordinatorTests` 12
  tests in 0.7 s, `SenderIdentityTests` 9 in 0.1 s, `InfoPlistDriftTests` 7, `OpenAuthorityTests` 5.
- The hand checks, Open With from Finder and a drop on the Dock icon, cold and warm, moved to M8 with the Finder sender
  record. See the Decision Log, 2026-11-03, review fix.
- Bringing a window forward and unminimizing it is proven by a test over a fake window that reports itself minimized.
  The confirmation above 10 files is proven through the injectable confirmer. Neither dialog nor window was looked at
  on screen.

### M3: File > Open

**Status:** DONE

Amended 2026-11-03; see Decision Log.

- File > Open opens a panel and routes the chosen file, by the key ownership "Who owns Cmd-O" settles
- The panel starts in the focused pane's `currentDirectory`, or the home folder when there is none
- A test checks that no built-in applet command claims Cmd-O
- Each viewer's pane-local Open command replaces its source, proven on a fixture applet
- The panel selects several files, and they follow the batch rule

**As built:**

- File > Open is the window command `uniterm.open`, titled "Open File or Folder" in the palette and "Open..." in the
  File menu, section 0, beside New Window. Cmd-O joins the reserved keys through the live menu, so no applet can take
  it. It is an app-scope command, so it also runs with no window. It waits while a sheet holds the window.
- "Open With..." is `uniterm.open-with`, with no key. It takes one file from the panel, then shows M1's chooser for it.
  The chooser lists every applet that declares the type, saves the pick, or clears a saved one. Clearing routes the
  file again by rank. A file no applet declares is refused with the usual message and no chooser.
- The panel lives in AppletKit, so the window command and the viewers' pane-local Open share it. It chooses files and
  folders, treats a package as one file, and always sets its start directory. The start directory is the focused pane's
  `currentDirectory`, or the home folder when there is no window, the pane reports none, or the reported folder is
  gone. It hangs from the anchor's window as a sheet, or runs as a modal with no window. The router runs after the
  panel returns. The panel is injectable. With no window open the panel runs `runModal`, which waits on the user. Its
  loop still pumps events and no other window exists to block, so ADR-08's main-thread bound holds.
- After the panel and the chooser, the commands wait for the sheet to leave the window, up to 25 polls of 20 ms,
  before the router places a pane. The sleep is injected. The router treats an attached sheet as no room, so a sheet
  that lingered would have sent the pane to a new window. A unit test attaches a real sheet that an injected sleeper
  ends and shows the pane lands beside the anchor. A second test never ends the sheet and shows the wait stops at the
  poll limit and the pane opens in a new window. The batch confirmation needs no wait, since a batch always opens in a
  new window. On screen, only the open panel is covered, by the UI test. The chooser sheet is covered by the same wait
  and the unit test, and nobody has watched it.
- Several chosen files follow the batch rule. A selection above the 10-file threshold asks first, through the
  confirmer that `RoutedOpener` owns, which serves both entry points.
- The pane-local Open is `AppletCommand.openSource()` with a `SourceReplacing` protocol. An applet that adopts the
  protocol gets "Open..." with no key in the File menu. It takes one file or folder and calls the applet's
  `replaceSource`. A failure reaches the pane's status bar, and the applet keeps its source. The terminal does not
  adopt it. No viewer exists, so a fixture applet proves it. The start directory comes from one rule that the router and
  this command share, kept in AppletKit. A test over every command set in the built-in catalog fails when an applet
  claims Cmd-O or the terminal declares an Open of its own. The app registers that same catalog list.
- The controller half of this milestone's old fourth check moved to M4. See the Decision Log.
- A UI test presses Cmd-O in a terminal pane, drives the real panel through go-to-folder, and shows a new terminal
  beside the first, in the chosen folder, with no second window. No hook substitutes the panel. The routed pane
  landing beside the anchor proves the sheet is gone by then.
- No `test-cost` target exists in this repo. The new test classes ran in under 0.5 s each in the package suite, and
  `OpenPanelUITests` took 23 s.
- The pane-local Open skips the router's file inspection. A FIFO or device the user picks in a viewer's own panel
  reaches `replaceSource`. The first viewer that adopts `SourceReplacing` must refuse non-regular files, or run the
  same inspection.
- A screenshot of the real panel as a sheet over the window was looked at. Nobody has yet looked at the File menu, or
  at Open With's chooser, on screen.

### M4: The path-reading power

**Status:** NOT STARTED

- Starts after UTERM-004 M1, M3, and M6
- A controller command that makes an applet read a path is refused without the power, and with a path outside its
  scope
- A symlink or a rename between check and open cannot reach a file outside the scope
- Missing, unsupported, and denied paths outside the scope return the same error
- A pane whose source lies outside a controller's scope sends that controller no path or content from it
- Revoking the grant stops queued reads, per ADR-09
- A path outside the scope raises no macOS privacy prompt, and a FIFO or device path never blocks the pane
- Canonicalizing stops at the first component outside the scope, and never stats or reads a link target outside it
- A dangling in-scope symlink to an outside target returns the same error as any other out-of-scope path
- Opening a device node has no side effect, such as a tty becoming the controlling terminal
- An in-scope symlink to an in-scope file opens through its canonical path, rather than failing on no-follow
- Every file a folder source opens for a controller, such as a slideshow member, passes the same check, so a symlinked
  member cannot reach outside the scope
- Scope and path compare as APFS does, so case and Unicode normalization cannot widen or narrow the scope
- An older build refuses a stored approval that holds the path-reading power, and authorizes nothing from it
- A request for a path under a protected location is not covered by an approved scope that only contains it
- The protected-location list has one owner and a test, and the approval panel names every protected location a scope
  lies in or names

### M5: `uniterm open`

**Status:** NOT STARTED

- Starts after UTERM-003 M3, UTERM-004 M6, and this proposal's M4
- `uniterm open <path>` opens the path through the router, with the authority "Who may run `uniterm open`" settles
- `uniterm open a b c` is one approval and one batch, with one summary message for failures
- A session grant ends with its terminal session or pane, and a restored pane never carries it
- A caller outside any terminal session, a tmux pane included, gets Allow once only
- Nothing touches a path before its open is authorized, so an unapproved request never raises a macOS privacy prompt
- A relative path resolves against the command's physical working directory, and a deleted one fails in the command
- The reply carries no file content
- An old `uniterm` command with a new app, or the reverse, is refused at the handshake

### M6: Terminal clicks

**Status:** NOT STARTED

- Cmd-hover on an absolute path or a local `file:` hyperlink shows its target as text, with no file-system access
- Cmd-click opens exactly the shown target through the router, and a printed symlink whose real path differs opens
  nothing
- A path a remote `ls` printed opens nothing, even after `exit` returns to the local shell
- The list of remote clients is written down, and each remote signal's source is named
- A relative path clicked in the terminal is refused
- A `file:` hyperlink naming another host never opens a local file
- A Cmd-click on a web URL or another non-file scheme does nothing
- The open-URL and mouse-over-link actions reach the app through the terminal surface protocol

### M7: Launch Services approvals

**Status:** NOT STARTED

Amended 2026-11-03; see Decision Log. Moved from M2.

- Starts after UTERM-004 M6
- A sender other than Apple's openers goes to UTERM-004's pending indicator, named from its verified signing
  information, and can be allowed once or for the session
- A session grant binds to the sender's PID and PID version, so a reused PID never inherits it
- A batch from a sender that needs approval raises one prompt that names every file and covers the count
  confirmation
- A prompt for an unknown sender says the sender is unknown, lists every full path, and offers Allow once only
- A go-between such as `/usr/bin/open` gets Allow once only
- Nothing is remembered after the sender quits
- Nothing touches a path before its open is approved, so an unapproved open never raises a macOS privacy prompt

### M8: Finder sender record

**Status:** DONE

Amended 2026-11-03 and 2026-11-04; see Decision Log. Moved from M2. This milestone is a check only the user can run.

- The sender a cold-launch Finder open, a warm one, and a Dock drop each report is recorded in the As built block,
  read from the `open-event` line that `log stream --level debug` shows for the `dev.uniterm.app` subsystem
- Finder and `open -a` report senders that tell them apart. When they do not, the user rules on the Launch Services
  decision, which reopens
- A folder dragged onto uniterm's icon in a Finder window, and a folder dropped on its Dock icon, each open, cold and
  warm, in a release build

**As built:**

- The user ran the record by hand on 2026-11-04, Darwin 25.6.0, with a folder. A wrapper streamed
  `/usr/bin/log stream --level debug` for the `dev.uniterm.app` subsystem and kept each step's `open-event` line.
- A folder dragged onto the app icon in a Finder window reports sender `com.apple.finder`, a platform binary with no
  team that matches the Finder opener. That holds cold and warm, in the Debug and the Release build.
- A folder dropped on the Dock icon reports sender `com.apple.dock`, a platform binary with no team that matches the
  Dock opener. That holds cold and warm, in both builds.
- Finder and the Dock are long-lived, so their sender tokens resolved every time. An `open -a` sender is
  `com.apple.open` or an exited process, per M2's record. The sender token tells them apart, so the Launch Services
  decision stands.
- The actual-sender token named `com.apple.coreservices.uiagent` in every step, as it did for `open -a`. It cannot
  tell the senders apart, which agrees with the decision to read only the sender token.
- In the Release build, a terminal opened in the folder on all four steps, as the user reported.
- Spotlight was not measured as a sender. Its identifier is still read from the program only.

## Decision Log

- 2026-11-03: Filed as a draft to meet UTERM-009's revisit hook before a second viewer among UTERM-006 to UTERM-008
  starts its first milestone. Settled only what UTERM-006 and UTERM-009 had already settled: the scope, one route, and
  the path-reading power's shape. Every other choice is an open question.
- 2026-11-03: Critique pass 1. Amended "The path-reading power" in two places. The scope check said only that it ran on
  the opened descriptor, after the open. An out-of-scope path was then opened before it was refused, which could raise
  a macOS privacy prompt under uniterm's name or block on a FIFO. A check of the canonical path now runs before the
  open, and the descriptor check stays. The user's-act rule said any app-level entry point needs no grant. That
  quietly settled `uniterm open` and terminal clicks, whose targets a program chooses, so it now names Finder, the
  Dock, File > Open, and in-pane opening only. Also narrowed the privacy rationale to controllers with no file access
  of their own, added UTERM-008's `pin selected` event to Impacts, put non-file URLs out of scope, added constraints
  on placement, relative and remote paths, and `uniterm open` replies, and routed five checks to M1 and M4.
- 2026-11-03: Critique pass 2. Amended "The path-reading power" again. The user's-act rule still named Finder and the
  Dock, but any same-user process can send the same open with `open -a uniterm`, so the rule would have let a program
  skip whatever authority `uniterm open` gets. The rule now names File > Open and in-pane opening only. Launch
  Services opens became the open question "Opens that arrive through Launch Services". Routed four canonicalization
  and device checks to M4.
- 2026-11-03: Critique pass 3 converged. Added its constraints to "Which entry points open files", "Where a routed
  pane goes", and "Opens that arrive through Launch Services", and routed two checks to M1 and M2.
- 2026-11-03: Review start: 6 milestones, 3 settled decisions, 7 risks, no `**Live after:**` lines or row gates; five
  out-of-scope statements under "Scope"; proposal at the commit "Fold the converged critique's constraints into the
  open questions". The user asked for a design review of the 11 open questions, in autonomous mode.
- 2026-11-03: Which entry points open files: all of them, terminal clicks included. Who may open by click became its
  own open question. Converged in 1 pass. (autonomous)
- 2026-11-03: How a file type maps to an applet: applet declarations with an owner or alternate rank, "Open With"
  for one open, and a per-type choice the user saves, matched on the exact type. Equal-rank claims fail a test, and
  every claimed type is imported with its conformance. Converged in 2 passes, after the critic named the users a saved
  choice serves. (autonomous, addition: a saved per-type choice and an "Open With" chooser with a way to clear it)
- 2026-11-03: Who owns Cmd-O: File > Open is a window command on Cmd-O through the router, and each viewer keeps a
  pane-local "Open..." with no key, as UTERM-007 already declares. Converged in 1 pass. (autonomous, addition: a
  pane-local "Open..." command on UTERM-006, UTERM-008, and UTERM-009)
- 2026-11-03: How the path-reading power is granted: a typed UTERM-004 permission, its own scope type, a list of
  directories, with protected locations excluded unless named and coverage compared on effective scopes. Converged in
  1 pass. (autonomous)
- 2026-11-03: Updated for UTERM-007's acceptance: its "Open..." command is the pane-local open, and the risk about draft
  applets names only UTERM-010. ADR impact review: the settled text conflicts with no ADR. Routed ADR-08's main-thread
  bound to M1, and ADR-01's terminal surface protocol to M6. (autonomous)
- 2026-11-03: Which file types uniterm registers with Finder: every declared type, always at the Alternate rank, with
  types resolved through the system. Converged in 1 pass. (autonomous)
- 2026-11-03: Opens that arrive through Launch Services: Apple's user-facing openers, identified by platform-binary
  code-signing requirement on the audit token, are the user's act. Other senders are refused until UTERM-004 M6, then
  get Allow once or a session grant bound to the sender's PID, never remembered. The judge ruled after three passes
  without convergence. The critic's top moved from Allow once only to remembered trust in signed apps, and then to
  the session grant, as each pass confirmed a new objection. (autonomous, judge, addition: opens from other senders
  join UTERM-004's pending indicator and session tier, and the second half of M2 depends on UTERM-004 M6)
- 2026-11-03: Several files at once: one pane per file, one summary message for failures, and a confirmation above a
  fixed count. A batch needs a rule under "Where a routed pane goes". Converged in 1 pass. (autonomous, addition: a
  count confirmation dialog)
- 2026-11-03: Folders: routed by type as `public.folder`. The terminal opens a new pane with the folder as its explicit
  start directory, and packages are refused. Converged in 1 pass. (autonomous, addition: a terminal entry point that
  creates a pane at a routed folder)
- 2026-11-03: Where a routed pane goes: beside the pane the request came from, in a new disconnected pane. A new window
  holds only the routed pane and starts no shell. Fixed rules for room, sheets, batches, and launch. The critic added
  the source-pane anchor as the complete option. Converged in 1 pass. (autonomous)
- 2026-11-03: Start directory and current directory: a routed file starts in its folder, File > Open starts in the
  focused pane's directory, `uniterm open` resolves relative paths in the command, and clicked relative paths are
  refused. A per-command directory was weighed for clicks. Shell integration cannot tell remote output from local, so
  it could open the wrong file. Converged in 1 pass. (autonomous)
- 2026-11-03: Who may run `uniterm open`: once or session approval for the calling terminal session, and Allow once
  only for a caller outside one. Nothing touches a path before its open is authorized. Converged in 1 pass.
  (autonomous, addition: a terminal-session pane-open approval joins UTERM-004's pending indicator beside OSC 52's)
- 2026-11-03: Who may open by terminal click: a click opens only the target uniterm showed on hover, matched by real
  path after the open, and never on output marked as possibly remote. The marker outlives the remote client. Converged
  in 1 pass, with the critic's fixes to the hover display, the symlink case, and remote scrollback. (autonomous,
  addition: the mouse-over-link action joins the terminal surface protocol, with a hover display and a remote marker)
- 2026-11-03: Coherence review: no weak decisions. Stated each milestone's dependencies on UTERM-003 and UTERM-004,
  so M5 starts only after UTERM-004 M6. Brought the Summary and Dependencies up to the settled design, reworded the
  new-window rule so a routed folder's terminal is the routed pane, added three risks, tagged four untagged additions,
  and routed seven checks to M1, M2, M3, and M5. Amended "One route from a path to a pane", which said every file
  reaches a source-taking entry point. A folder routed to the terminal creates a new pane instead, since the terminal
  has no source to replace. (autonomous)
- 2026-11-03: Coherence re-check converged. Fixed a stale "open" sentence and M1's routing check, and made M1 re-run
  the group check once UTERM-004 M4 lands. Risk review: every risk is rated and mitigated or accepted, none is high
  likelihood and high impact, and the stored choices and the new permission carry skew checks in M1 and M4.
  (autonomous)
- 2026-11-03: Review gate: kept all, including the judge's Launch Services ruling, every tagged addition, and the
  entry points that brought `uniterm open` and terminal clicks into scope.
- 2026-11-03: ADR candidate: uniterm never lends its macOS privacy grants to a program. A scope never covers a
  protected location unless it names it, and no program-supplied path is touched before its open is authorized.
  Declined.
- 2026-11-03: ADR candidate: every way a file reaches an applet from outside its pane goes through one route into the
  applet's own entry point. Waits on UTERM-009's byte-stream source and UTERM-010's design, either of which could
  change what an entry point is. It was also amended in this review for the terminal's folder entry.
- 2026-11-03: ADR candidate: which Launch Services senders count as the user's act. Waits on M8's record of the sender
  each Finder path reports, since the decision reopens if Finder and `open -a` cannot be told apart.
- 2026-11-03: Accepted after the review gate. No ADR written.
- 2026-11-03: Scheduled as UTERM-015 M1-M3 and UTERM-015 M4-M6 in queue.md.
- 2026-11-03: Amended "Folders": the terminal declares `public.folder` at the owner rank and the image viewer at the
  alternate rank. Folders said only that the type mapping picks, and two equal claims fail its test. Amended UTERM-006,
  UTERM-008, and UTERM-009 to declare their types and gain a pane-local Open... with no key.
- 2026-11-03: M1 work-queue best guesses (work-queue best guess). Amended "How a file type maps to an applet", which
  said equal-rank claims fail a test and nothing about unrelated types that tie. A file whose type conforms to two
  unrelated declared types can tie at run time, and the test cannot see it. The router now asks the user to pick, and
  refuses with a message when nothing can ask, so no default is picked. Amended M1's last check, which said "Type and
  placement work runs off the main thread, so a path on a slow network volume never stalls the UI". Only type resolution
  and file-system checks move off it. Choosing the pane and changing the window stay on the main thread. Review fix: a
  symlink's type comes from its target, and its start directory is the path as named, not the resolved target, matching
  the shell's logical paths. Also recorded: saved choices live in one defaults dictionary keyed by exact type, a symlink
  is followed before classifying its target, and the declared-type check takes the imported types as an input that M2
  fills from `Info.plist`.
- 2026-11-03: M2 work-queue best guesses (work-queue best guess). Amended M2, M7, and M8 and the Launch Services
  decision.
  1. Approvals moved out of M2. The session grant bound to the sender's PID and PID version, and the single prompt for a
     batch from a sender that needs approval, both need UTERM-004 M6's approval flow, which is not built. They are the
     new M7, and the queue row `UTERM-015 M4-M6` is now `UTERM-015 M4-M7`, since M7 has M4's dependency. M2 keeps
     building the identity and tests that two PID versions are two identities.
  2. The Finder measurement moved out of M2. The decision said M2 records the sender a cold-launch Finder open and a
     warm one report, before the authority is built. The Automation consent to drive Finder with `osascript` was
     denied, so neither was recorded. The authority was built as settled, since the `open -a` record gave a sender
     (`com.apple.open` or an exited process) that no Apple opener's requirement matches. The Finder record is the new
     user-check milestone M8, and it is not in the queue. It needs no dependency, and a queue row for it would wait on
     UTERM-004 M6 for no reason. If Finder cannot be told apart from `open -a`, the decision reopens then.
  3. The opener list narrowed. The decision named Finder, the Dock, Spotlight, Quick Look, and Recent Items. On this
     macOS (build 25G83), Finder is `com.apple.finder`, the Dock is `com.apple.dock`, and Spotlight is
     `com.apple.Spotlight`. All three are platform binaries with platform identifier 26 and no team. Quick Look's
     program is not a file on the system volume, so no identifier could be read for it. Recent Items has no
     program found either. `com.apple.systemuiserver` exists, and nothing showed that it sends opens, so it is not
     listed. No event from the Dock or Spotlight was sent either, so their identifiers are read from the programs
     and unmeasured as senders. A list that names a program nobody measured is a guess about who the user's act is. The narrower
     list fails safe, since an unlisted opener is refused with a message. Quick Look and Recent Items return with a
     measured identifier.
  4. No attribute names the originator behind a go-between. The decision said M2 checks. An event from `open -a`
     carries `keySenderAuditTokenAttr` and `keyActualSenderAuditToken`. The sender token names `/usr/bin/open`
     (`com.apple.open`) while that process is alive, and nothing once it has exited. The actual-sender token names the
     Launch Services UI agent (`com.apple.coreservices.uiagent`, platform binary), cold and warm. It is a helper, not
     the program that ran `open`. The authority reads the sender token only, so a go-between stays refused, and M7
     gives it Allow once only.
  5. Measurements, on Darwin 25.6.0, running the debug build directly with a scratch layout. A warm `open -a` of a
     folder, an `open -a` of a file and a folder, and a cold `open -a` launched with `--env` all reported the same.
     The sender token's process was `open`, identified as `com.apple.open` in one run and already exited, so
     unidentified, in two. Both refuse. The actual-sender token was `com.apple.coreservices.uiagent` every time. The
     sender's process had exited by the time of lookup in two of three runs, which is why "a sender that already
     exited is unidentified" is the common case for `open -a`. A debug build logs one line per open event with the
     identifier, team, platform flag, PID, and PID version of each token, so any sender can be measured again by hand.
  6. The refusal message is coalesced to one per 30 seconds, whoever sends. The message names the first sender in the
     window and folds the rest into a count on the next one. The interval is one constant. A per-sender interval
     would let a loop of different senders post without bound.
  7. The batch confirmation threshold is 10 files, so a batch of 11 asks and a batch of 10 does not. The decision
     asked for a fixed count and named none. It is one constant.
  8. `Info.plist` holds one document type, `public.folder`, at the Alternate rank, and no imported types, since the
     only declared type is a system type. The entry is written by hand, and a test fails when it drifts from the
     catalog. It is not generated, since the catalog has one entry.
  9. The reply to an open-documents event is AppKit's own. The delegate method returns nothing, so a refused sender
     and an accepted one get the same reply, and success, missing, unsupported, and denied cannot differ.
  10. A cold-launch open waits for restore, and the layout opens no default window while one waits. When the replay
      leaves no window, because every file failed, the app opens one default window. A warm open that fails with no
      window open leaves the app with none, as closing the last window does.
- 2026-11-03: M2 review fix (work-queue best guess). Amended M2's first check, which said "Open With in Finder and a
  drop on the Dock icon open the file in uniterm, at launch and while running". Only the user can run it, and a check
  only the user can run blocks DONE. It now says an open-documents event from an Apple opener opens its file, proven
  with a sender fixture. The hand check is M8's, so one milestone owns it. Also amended the opener wording, which said
  "platform-binary requirements". The code matches an Apple-anchored requirement on the identifier, since the platform
  identifier measured, 26, is tied to the OS release. M8 has its own queue row, because it needs no dependency. Its
  result can reopen the Launch Services decision before M7 builds on it.
- 2026-11-04: M3 work-queue best guesses (work-queue best guess). Amended M3's pane-local Open check, which said "and
  in a controller-owned pane that controller gets no path or content outside its scope, tested with fixture
  controllers and scopes". No controller, scope, or event channel exists yet, so there is nothing to test it against.
  M4 already holds the check, "A pane whose source lies outside a controller's scope sends that controller no path
  or content from it", so M3 now says only that the pane-local Open replaces its source, proven on a fixture applet.
  Also recorded: the window commands are `uniterm.open` and `uniterm.open-with`, with the palette titles "Open File
  or Folder" and "Open File or Folder With", so the palette tells them apart from a viewer's "Open...". A selection
  above 10 files asks first, as Finder's batch does, since the user can pick hundreds of files. The panel's start
  folder falls back to home when the reported folder no longer exists, since the panel would otherwise fall back to
  AppKit's own memory.
- 2026-11-04: M8 work-queue best guesses (work-queue best guess). Amended M8's first check, which said the sender is
  "read from the debug log line of a build run directly". When Finder or the Dock launches uniterm cold, no shell owns
  the process, so its standard error goes nowhere. The same line goes to the unified log at debug level, which is not
  persisted, so it is read live with `log stream --level debug`. Amended M8's last check, which said the release build
  opens "the file". `Info.plist` declares only `public.folder`, so the Dock icon accepts only a folder. A file would
  fail the check for the wrong reason. The run's `osascript` call to drive Finder was denied again, so nothing was
  measured, and M8 stays in progress.
- 2026-11-04: Amended M8's last check, which said Open With in Finder opens a folder. Finder has no Open With for
  folders, and a folder is the only type uniterm declares, so Finder's Open With never offers uniterm today. The check
  now drags a folder onto uniterm's icon in a Finder window, which Finder also sends.
- 2026-11-04: M8 done. Finder sends as `com.apple.finder` and the Dock as `com.apple.dock`, cold and warm, and
  `open -a` never does, so "Opens that arrive through Launch Services" stands as settled. The ADR candidate on which
  Launch Services senders count as the user's act no longer waits on this record. It stays Undecided.
- 2026-11-05: Amended "Scope" for UTERM-016. The out-of-scope list said "Every viewer is read-only." The map viewer
  now edits and saves the GeoJSON file it shows. Opening and routing are unchanged, and no other viewer writes.
- 2026-11-08: Amended "How a file type maps to an applet". The rule matched a file's type alone, so a file whose type
  conformed to no declaration was refused. Opening `README.md` from Finder then launched uniterm and opened no pane.
  The system types `.md` as `com.unknown.md`, another app's type that does not conform to
  `net.daringfireball.markdown`, and Launch Services prefers that claim over uniterm's import. The user chose a
  fallback: when the preferred type matches no declaration, the router pools the claims of every type the system
  registers for the extension. The user chose it over claiming `com.unknown.md`, which names another app's type, and
  over leaving the refusal.

## References

- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): restored state is inert
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): each applet owns its payload
- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): control authority,
  separate powers, and explicit scope
